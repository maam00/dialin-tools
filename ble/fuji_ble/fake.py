"""A simulated X100VI over a bleak-shaped API, for rehearsal (`--fake`) and tests. No Bluetooth involved.

The GATT table is fffw's ad14d4 (X100VI fw 1.31+) from gatt.py. Behaviour is ported, not imported, from
fuji-bridge's test doubles and field notes (read only, never run):
  * Tests/BluetoothTests.swift:6-76      FakeFujiGATT: status 07 96 00 00, pairing-pending reads, busy answers
  * Tests/RecipeBackupTests.swift:6-41   FakeBackupCamera: BACKUP_STATE answer, one transaction-state notify per
                                         chunk ([state, 0, index, 0]), chunks pulled by reads, 03 00 finish
  * FujiBluetooth.swift:412-414          an X100VI drops the link the moment the pairing code is confirmed
  * FujiBluetooth.swift:423-426          a body bonded to a phone never answers a connect from anyone else
  * libfuji lib/bluetooth.c:32-34        FILE_INFORMATION "backup.dat", 0x827c = 33404 bytes

Scenarios (comma-separated with --fake):
  ok                 happy path (default): bonded secure body, deterministic 33,404-byte backup
  pairing            first 3 SECURE_STATUS reads fail "insufficient encryption" (macOS pairing prompt), then the
                     camera drops the link right after the first good read; works after reconnecting
  not-paired         every encrypted read fails "insufficient authentication"
  busy               BACKUP_STATE answers 0
  bad-checksum       the last chunk carries a wrong u16 sum
  stall              no FILE_TRANSACTION_STATE notifications after the transfer starts
  drop-mid-backup    the link drops after 50 chunks
  nondeterministic   counters at 0x0CC/0x0D0 change between backups (helios saw this on an X-T5)
  paired-elsewhere   connect times out (bonded to another phone)
  stale-bond         connect fails with "Peer removed pairing information"
  no-camera          the scan hears only non-Fujifilm devices
  bt-off, bt-denied  Bluetooth unavailable
  read-errors        a few reads fail with ATT errors (dump must carry on)
  basic              older firmware: token advert, no SECURE_STATUS
  basic-reconnect    with basic: after pairing the advert no longer carries the token, and the camera ignores a
                     BACKUP_REQUEST on a connection that didn't send the pairing token (X100VI fw 1.10 behaviour,
                     per furble FujifilmBasic.cpp:57-83; unverified on the real body)
  pairing-mode       advertise the a9d2b304 pairing service
  ble-restore        the camera speaks the standard restore protocol (RESTORE_REQUEST/RESTORE_STATE, 128-byte frames,
                     per-frame FILE_TRANSACTION_STATE acks; docs/FUJIFILM-PROTOCOL.md §3.7) and applies a good file
  fw110              an X100VI on firmware 1.10: the basic GATT profile 76ab62 (pairing key in
                     91f1de68, no Wi-Fi passphrase, RESTORE_* present), name "1D7BX100VI-1D7B", the FILE_TRANSFER
                     service in the advert, token only while not yet registered, the pairing key required on every
                     connection, open Wi-Fi AP. Implies ble-restore.
  restore-busy       (ble-restore) RESTORE_STATE answers 0 (busy)
  restore-reject     (ble-restore) the first frame write fails with an ATT error (an incompatible file)
  restore-error      (ble-restore) the last frame is answered with transaction state 0 (error)
  ap-fail            FUNCTION_LAUNCH_REQUEST is answered with AP_STATE 0x8000 (not started)
  gps-ask            the camera asks for a location (LOCATION_REQUEST 01 00) twice after you subscribe
  powered-off        (fw110) the camera is switched off: only its standby advert (service 731893f9, 02 + the
                     registered pairing key + power-switch state 00), the shape captured from an X100VI during
                     development; connections refused

Restore: pass `restore=RestoreProfile(...)` (fuji_ble.restore_profile) to make the fake camera speak that upload
protocol: the request arms it, it signals ready, takes frames (acking them in `ack` pacing), checks the transport
sum, validates the file (magic, same model/serial, optional `validator`), and serves the restored file on every
later backup. Without `restore`, uploads are accepted and ignored (no completion signal), as before.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import random
import struct
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

from . import gatt
from .client import ScanResult, Sighting, Transport

SCENARIOS = {
    "ok", "pairing", "not-paired", "busy", "bad-checksum", "stall", "drop-mid-backup", "nondeterministic",
    "paired-elsewhere", "stale-bond", "no-camera", "bt-off", "bt-denied", "read-errors", "basic", "pairing-mode",
    "basic-reconnect", "ble-restore", "fw110", "restore-busy", "restore-reject", "restore-error", "ap-fail", "gps-ask",
    "powered-off",
}


#: Characteristic the fake "ticks" on while subscribed (NOTIFICATION_6, gatt-ad14d4.yaml:261).
TICKER_CHAR = "e6692c5c-b7cd-44f4-95fc-eda07ce32560"


class FakeATTError(Exception):
    """Shaped like bleak.exc.BleakGATTProtocolError: args (code, message), `.code`."""

    MESSAGES = {0x05: "GATT Protocol Error: Insufficient Authentication", 0x0F: "GATT Protocol Error: Insufficient Encryption",
                0x02: "GATT Protocol Error: Read Not Permitted", 0x0E: "GATT Protocol Error: Unlikely Error",
                0x0D: "GATT Protocol Error: Invalid Attribute Value Length", 0x80: "GATT Protocol Error: Application Error"}

    def __init__(self, code: int) -> None:
        super().__init__(code, self.MESSAGES.get(code, f"GATT Protocol Error {code:#04x}"))
        self.code = code


class FakeBluetoothUnavailable(Exception):
    """Shaped like bleak.exc.BleakBluetoothNotAvailableError (name matters to client.map_bluetooth_unavailable)."""

    def __init__(self, msg: str, reason_name: str) -> None:
        super().__init__(msg)

        class _Reason:
            name = reason_name

        self.reason = _Reason()


FakeBluetoothUnavailable.__name__ = "BleakBluetoothNotAvailableError"


@dataclass
class FakeDescriptor:
    uuid: str
    handle: int


@dataclass
class FakeChar:
    uuid: str
    handle: int
    properties: list[str]
    service_uuid: str
    descriptors: list[FakeDescriptor] = field(default_factory=list)
    description: str = ""


@dataclass
class FakeService:
    uuid: str
    handle: int
    characteristics: list[FakeChar]
    description: str = ""


@dataclass
class FakeDevice:
    address: str
    name: str
    details: Any = None


def make_backup_file(serial: str = "5FA12345", size: int = 33404, counter: int = 0) -> bytes:
    """A FUJIFILMX-BACKUP container with the helios header layout (FUJI_BLOB_FORMAT.md:48-66) and a deterministic body.
    33,404 bytes = libfuji's BLE capture (bluetooth.c:34). `counter` changes 0x0CC/0x0D0 like a real body might."""
    rng = random.Random(1234)
    body = bytearray(rng.getrandbits(8) for _ in range(size))
    body[0:16] = gatt.BACKUP_MAGIC
    body[0x10:0x14] = b"0100"
    body[0x14:0x34] = b"X100VI".ljust(0x20, b"\x00")
    body[0x34:0x54] = serial.encode().ljust(0x20, b"\x00")
    body[0x54:0x98] = bytes(0x98 - 0x54)
    struct.pack_into("<I", body, 0x98, 0xA8)
    struct.pack_into("<I", body, 0x9C, 0)
    struct.pack_into("<I", body, 0xA0, size - 0xA8)
    struct.pack_into("<I", body, 0xA4, 0)
    struct.pack_into("<I", body, 0xCC, 0x1000 + counter)
    struct.pack_into("<I", body, 0xD0, 0x2000 + counter * 3)
    return bytes(body)


class FakeCamera:
    """Camera state that survives reconnects (bond, pairing progress, backups served)."""

    def __init__(self, scenarios: set[str] | str = "ok", *, name: str = "X100VI", tag: str = "1D7B8",
                 table: Optional[list[dict]] = None, values: Optional[dict[str, bytes]] = None,
                 restore: Any = None, validator: Optional[Callable[[bytes], Optional[str]]] = None,
                 settings: Optional[bytes] = None) -> None:
        if isinstance(scenarios, str):
            scenarios = {s.strip() for s in scenarios.split(",") if s.strip()}
        unknown = set(scenarios) - SCENARIOS
        if unknown:
            raise ValueError(f"unknown fake scenario(s) {sorted(unknown)}; choose from {sorted(SCENARIOS)}")
        self.scenarios = set(scenarios) or {"ok"}
        if "fw110" in self.scenarios:
            self.scenarios |= {"ble-restore"}
            if name == "X100VI":
                name = "1D7BX100VI-1D7B"  # 4-char short serial + model (fffw db-paired.json)
            if tag == "1D7B8":
                tag = "1D7B"
        self.name = name
        self.tag = tag
        self.address = "FAKE-X100VI-0000-1D7B8"
        self.ops: list[tuple[str, str, bytes]] = []
        self.services = self._build_services(table)
        self.values: dict[str, bytes] = self._initial_values()
        if values:
            self.values.update(values)
        self.pending_pairing = 3 if "pairing" in self.scenarios else 0
        self.drop_after_pairing = "pairing" in self.scenarios
        self.backups_served = 0
        self.connections = 0
        # Per-transfer state
        self.partial_size = gatt.BACKUP_PARTIAL_SIZE
        self.chunks: list[bytes] = []
        self.chunk_index = 0
        self.file = b""
        self.transfer_result: Optional[bytes] = None
        self.backup_armed = False
        self.client: Optional["FakeClient"] = None
        # What the camera holds; backups serve it, a successful restore replaces it.
        self.settings = settings if settings is not None else (
            make_backup_file(size=70524) if "fw110" in self.scenarios else make_backup_file())  # X100VI fw 1.10: 70,524 B
        # Basic-profile token bookkeeping
        self.token = bytes([0xDE, 0xAD, 0xBE, 0xEF])
        self.paired = False
        self.token_conn = -1
        # Restore simulation
        self.restore = restore
        self.validator = validator
        self.restore_state = "idle"  # idle | armed | received
        self.upload = bytearray()
        self.upload_seq = 0
        self.upload_frames = 0
        self.declared_size: Optional[int] = None
        self.restores_applied = 0
        self.restore_errors: list[str] = []
        self._staged: Optional[bytes] = None
        # Standard restore simulation (scenario ble-restore / fw110)
        self.std_restore_enabled = "ble-restore" in self.scenarios
        self.xr: Optional[dict] = None
        self.standard_frames_seen = 0
        # Wi-Fi / location bookkeeping
        self.function_launches: list[int] = []
        self.locations: list[dict] = []
        self.time_writes: list[tuple[str, bytes]] = []

    # ---- table ---------------------------------------------------------------------------

    def _build_services(self, table: Optional[list[dict]]) -> list[FakeService]:
        services: list[FakeService] = []
        handle = 1
        if table is not None:  # replay a captured dump (captures/gatt-*.json)
            for s in table:
                chars = []
                for c in s.get("characteristics", []):
                    handle += 2
                    chars.append(FakeChar(c["uuid"], c.get("handle") or handle, list(c.get("properties", [])), s["uuid"]))
                services.append(FakeService(s["uuid"], s.get("handle") or handle, chars))
            return services
        if "fw110" in self.scenarios:  # fffw gatt-76ab62.yaml (X100VI fw 1.11; expected on 1.10)
            for s_uuid, chars_t in gatt.X100VI_76AB62:
                svc_handle = handle
                chars = []
                for c_uuid, props, _len in chars_t:
                    handle += 2
                    descs = [FakeDescriptor("00002902-0000-1000-8000-00805f9b34fb", handle + 1)] if \
                        {"notify", "indicate"} & set(props) else []
                    chars.append(FakeChar(c_uuid, handle, list(props), s_uuid, descs))
                services.append(FakeService(s_uuid, svc_handle, chars))
                handle += 16
            return services
        by_service: dict[str, list[gatt.CharInfo]] = {}
        for info in gatt.CHARACTERISTICS.values():
            if info.length is None:  # not in ad14d4
                continue
            by_service.setdefault(info.service, []).append(info)
        if "basic" in self.scenarios:
            by_service["123d8f06-62a1-4935-9322-833c531ee225"] = [
                c for c in by_service["123d8f06-62a1-4935-9322-833c531ee225"] if c.uuid != gatt.SECURE_STATUS]
        for s_uuid, infos in by_service.items():
            svc_handle = handle
            chars = []
            for info in infos:
                handle += 2
                descs = [FakeDescriptor("00002902-0000-1000-8000-00805f9b34fb", handle + 1)] if \
                    {"notify", "indicate"} & set(info.props) else []
                chars.append(FakeChar(info.uuid, handle, list(info.props), s_uuid, descs))
            services.append(FakeService(s_uuid, svc_handle, chars))
            handle += 16
        return services

    def _initial_values(self) -> dict[str, bytes]:
        def z(text: str, n: int) -> bytes:
            return text.encode().ljust(n, b"\x00")

        return {
            gatt.DEVICE_NAME: self.name.encode(),
            gatt._sig("2a01"): b"\x00\x00",
            gatt._sig("2a29"): b"FUJIFILM",
            gatt.MODEL_NUMBER: b"X100VI",
            gatt._sig("2a25"): b"5FA12345",
            gatt._sig("2a27"): b"1.00",
            gatt.FIRMWARE_REVISION: b"1.32" if "basic" not in self.scenarios else b"1.11",
            gatt._sig("2a28"): b"1.32",
            gatt.SECURE_STATUS: bytes([0x07, 0x96, 0x00, 0x00]),
            "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4": z(f"FUJIFILM-X100VI-{self.tag}", 32),
            "e809256a-915c-4967-92e8-53b7d4cad213": z("s3cretpass", 20),
            gatt.GEOTAG_SYNC_INTERVAL: gatt.u16le(30),
            gatt.AP_STATE: b"\x00\x00",
            gatt.BACKUP_STATE: b"\x00\x00",
            "68887a7a-10a7-4a4a-aadd-6f9db1abaa0e": z("FUJINON 23mm F2", 64),
            gatt.FILE_PARTIAL_SIZE: gatt.u32le(0),
            gatt.FILE_INFORMATION: bytes(44),
            gatt.CAMERA_WIFI_ADDRESS: b"02-11-22-33-44-55",
            gatt.CAMERA_IDENTITY_NUMBER: b"Y0000001",
            gatt.RESTORE_STATE: b"\x00\x00",
        } | ({gatt.FIRMWARE_REVISION: b"1.10", gatt.DEVICE_NAME: self.name.encode(),
              gatt.CAMERA_SSID: z(f"FUJIFILM-X100VI-{self.tag}", 32)} if "fw110" in self.scenarios else {})

    def char(self, uuid: str) -> Optional[FakeChar]:
        for s in self.services:
            for c in s.characteristics:
                if c.uuid == uuid:
                    return c
        return None

    # ---- advertising ---------------------------------------------------------------------

    def sighting(self) -> Sighting:
        if "powered-off" in self.scenarios:
            mfr = {gatt.FUJIFILM_COMPANY_ID: bytes([gatt.ADV_TYPE_BASIC_TOKEN]) + self.token + b"\x00"}
            services = [gatt.SVC_BASIC_STARTUP]
            info = gatt.decode_advert(mfr, services)
            assert info is not None
            now = time.monotonic()
            return Sighting(FakeDevice(self.address, self.name), self.address, self.name, -65, mfr, services, info, now, now, 10)
        if "fw110" in self.scenarios:
            # Basic body: the FILE_TRANSFER service in the advert; type 02 + pairing key while registering.
            mfr = {} if self.paired and "pairing-mode" not in self.scenarios else \
                {gatt.FUJIFILM_COMPANY_ID: bytes([gatt.ADV_TYPE_BASIC_TOKEN]) + self.token}
            services = [gatt.SVC_FILE_TRANSFER]
            info = gatt.decode_advert(mfr, services)
            assert info is not None
            now = time.monotonic()
            return Sighting(FakeDevice(self.address, self.name), self.address, self.name, -52, mfr, services, info, now, now, 7)
        if "basic" in self.scenarios and "basic-reconnect" in self.scenarios and self.paired:
            mfr = {gatt.FUJIFILM_COMPANY_ID: bytes([0x03]) + self.tag.encode()}  # no token once registered (assumed)
            services = [gatt.SVC_CAMERA_INFO_BASIC]
        elif "basic" in self.scenarios:
            mfr = {gatt.FUJIFILM_COMPANY_ID: bytes([gatt.ADV_TYPE_BASIC_TOKEN]) + self.token}
            services = [gatt.SVC_CAMERA_INFO_BASIC]
        else:
            mfr = {gatt.FUJIFILM_COMPANY_ID: bytes([gatt.ADV_TYPE_SECURE_TAG]) + self.tag.encode()}
            services = [gatt.SVC_SECURE_PAIRING_ADVERT] if "pairing-mode" in self.scenarios else [gatt.SVC_RECONNECT_ADVERT]
        info = gatt.decode_advert(mfr, services)
        assert info is not None
        now = time.monotonic()
        return Sighting(FakeDevice(self.address, self.name), self.address, self.name, -52, mfr, services, info, now, now, 7)

    # ---- notifications -------------------------------------------------------------------

    def notify(self, uuid: str, value: bytes, delay: float = 0.01) -> None:
        client = self.client
        if client is None or not client.is_connected or uuid not in client.callbacks:
            return
        ch = self.char(uuid)
        cb = client.callbacks[uuid]

        def fire() -> None:
            if client.is_connected and uuid in client.callbacks:
                self.ops.append(("notify", uuid, value))
                cb(ch, bytearray(value))

        asyncio.get_running_loop().call_later(delay, fire)

    # ---- behaviour -----------------------------------------------------------------------

    def on_read(self, uuid: str) -> bytes:
        if "read-errors" in self.scenarios and uuid in ("8814441b-1d7b-4046-891d-d8f80864cc8e", "34d8c8de-e2a9-43ff-822c-7d945dd8d8e1"):
            raise FakeATTError(0x0E)
        if uuid in (gatt.SECURE_STATUS, "e809256a-915c-4967-92e8-53b7d4cad213"):
            if "not-paired" in self.scenarios:
                raise FakeATTError(0x05)
            if self.pending_pairing > 0:
                self.pending_pairing -= 1
                raise FakeATTError(0x0F)
            if self.drop_after_pairing:
                # fuji-bridge FujiBluetooth.swift:412-414: the X100VI drops the link the moment the code is
                # confirmed, then waits for the (now bonded) device to come back.
                self.drop_after_pairing = False
                assert self.client is not None
                self.client.drop("camera dropped the link after pairing (simulated)")
                raise RuntimeError("Peripheral disconnected")
        if uuid == gatt.FILE_PARTIAL_DATA:
            return self._next_chunk()
        if uuid == gatt.FILE_INFORMATION and self.file:
            return gatt.build_file_information("backup.dat", len(self.file))
        return self.values.get(uuid, b"\x00\x00")

    def _needs_token(self) -> bool:
        return "basic-reconnect" in self.scenarios or "fw110" in self.scenarios

    def on_write(self, uuid: str, data: bytes) -> None:
        self.values[uuid] = data
        if self._restore_write(uuid, data):
            return
        if self._standard_restore_write(uuid, data):
            return
        if uuid == gatt.PAIRING_TOKEN and data == self.token:
            self.token_conn = self.connections
            self.paired = True
        if uuid == gatt.FUNCTION_LAUNCH_REQUEST:
            self.function_launches.append(struct.unpack_from("<H", data)[0] if len(data) >= 2 else -1)
            if "ap-fail" in self.scenarios:
                self.notify(gatt.AP_STATE, gatt.u16le(0x8000), 0.05)
            else:  # AP state: starting (0x8002), then up (0x8001)
                self.notify(gatt.AP_STATE, gatt.u16le(0x8002), 0.03)
                self.notify(gatt.AP_STATE, gatt.u16le(0x8001), 0.08)
            return
        if uuid == gatt.LOCATION_FIX:
            self.locations.append(gatt.decode_location(data))
            return
        if uuid in (gatt.TIME, gatt.UTC_TIME_AND_ZONE):
            self.time_writes.append((uuid, data))
            return
        if uuid == gatt.CLIENT_NAME:
            self.notify(gatt.TIME_SYNC_REQUEST, b"\x02\x00", 0.05)  # furble Fujifilm.cpp:24-27 "configured"
        elif uuid == gatt.BACKUP_REQUEST and data[:1] == b"\x01":
            if self._needs_token() and self.token_conn != self.connections:
                return  # a registered basic body ignores clients that didn't present the token on this link
            self.backup_armed = "busy" not in self.scenarios
            self.backups_served += 1
            if "nondeterministic" in self.scenarios:
                self.file = make_backup_file(counter=self.backups_served)
            else:
                self.file = self.settings
            self.notify(gatt.BACKUP_STATE, b"\x00\x00" if "busy" in self.scenarios else b"\x01\x00", 0.05)
        elif uuid == gatt.FILE_PARTIAL_SIZE:
            self.partial_size = struct.unpack_from("<I", data)[0] or gatt.BACKUP_PARTIAL_SIZE
        elif uuid == gatt.FILE_TRANSFER_INDEX and self.backup_armed:
            self.backup_armed = False
            self._start_transfer()
        elif uuid == gatt.FILE_TRANSFER_RESULT:
            self.transfer_result = data

    # ---- restore simulation ----------------------------------------------------------------

    @staticmethod
    def _pad(hexv: Optional[str], default: bytes, n: int) -> bytes:
        v = bytes.fromhex(hexv) if hexv else default
        return v + bytes(max(0, n - len(v)))

    def _restore_write(self, uuid: str, data: bytes) -> bool:
        """True when the write belonged to the simulated restore."""
        r = self.restore
        if r is None:
            return False
        if r.request_char and uuid == r.request_char and data == bytes.fromhex(r.request_value or ""):
            self.restore_state = "armed"
            self.upload = bytearray()
            self.upload_seq = r.seq_start
            self.upload_frames = 0
            self.declared_size = None
            self._staged = None
            if r.ready_char:
                self.notify(r.ready_char, self._pad(r.ready_value_prefix, b"\x01", 2), 0.05)
            return True
        if self.restore_state == "idle":
            return False
        if uuid == gatt.FILE_INFORMATION:
            self.declared_size = gatt.parse_file_information(data)[1]
            return True
        if uuid in (gatt.FILE_PARTIAL_SIZE, gatt.FILE_TRANSFER_INDEX):
            return True
        if uuid == gatt.FILE_PARTIAL_DATA and self.restore_state == "armed":
            ch = gatt.parse_partial_data(data)
            last = (ch.seq == r.last_seq) if r.last_seq is not None else (
                self.declared_size is not None and len(self.upload) + len(ch.payload) - (2 if r.trailer_sum else 0) >= self.declared_size)
            if not last and ch.seq != self.upload_seq:
                self._restore_fail(f"frame seq {ch.seq} but expected {self.upload_seq}")
                return True
            self.upload_seq += 1
            self.upload_frames += 1
            if not last:
                self.upload += ch.payload
                if r.pacing == "ack":
                    self.notify(r.ack_char, bytes([2, 0, self.upload_frames & 0xFF, 0]), 0.002)
                return True
            body = ch.payload
            if r.trailer_sum:
                body, tail = ch.payload[:-2], ch.payload[-2:]
                if int.from_bytes(tail, "little") != gatt.byte_sum16(bytes(self.upload) + body):
                    self._restore_fail("transport sum mismatch")
                    return True
            self.upload += body
            self.restore_state = "received"
            if r.finish_after_complete or not r.finish_char:
                self._judge()
            return True
        if r.finish_char and uuid == r.finish_char and self.restore_state == "received":
            if data == bytes.fromhex(r.finish_value or ""):
                if not r.finish_after_complete:
                    self._judge()
                if self._staged is not None:
                    self.settings = self._staged
                    self.restores_applied += 1
                    self._staged = None
            self.restore_state = "idle"
            return True
        return False

    def _standard_restore_write(self, uuid: str, data: bytes) -> bool:
        """The standard restore as the camera side (docs/FUJIFILM-PROTOCOL.md §3.7). True when the write belonged to it.
        Written from the spec, not from client.standard_restore, and it checks every rule the client must follow."""
        if not self.std_restore_enabled:
            return False
        if uuid == gatt.RESTORE_REQUEST:
            if self._needs_token() and self.token_conn != self.connections:
                return True  # unregistered on this link: no answer at all
            busy = "restore-busy" in self.scenarios or data != gatt.RESTORE_REQUEST_SETTINGS
            self.xr = None if busy else {"state": "armed", "data": bytearray(), "declared": None, "name": None,
                                         "expect": 0, "frames": 0, "staged": None, "partial_size": None, "index": None}
            self.notify(gatt.RESTORE_STATE, b"\x00\x00" if busy else b"\x01\x00", 0.03)
            return True
        xr = self.xr
        if xr is None:
            return False
        if uuid == gatt.FILE_PARTIAL_SIZE and xr["state"] == "armed":
            xr["partial_size"] = struct.unpack_from("<I", data)[0]
            return True
        if uuid == gatt.FILE_TRANSFER_INDEX and xr["state"] == "armed":
            xr["index"] = struct.unpack_from("<I", data)[0]
            return True
        if uuid == gatt.FILE_INFORMATION and xr["state"] == "armed":
            name, size = gatt.parse_file_information(data)
            if len(data) != 44 or name != gatt.RESTORE_FILE_NAME or xr["partial_size"] != gatt.RESTORE_CHUNK or xr["index"] != 0:
                self._standard_restore_fail(f"bad setup: info {data.hex()} partial {xr['partial_size']} index {xr['index']}")
                return True
            xr["declared"], xr["name"], xr["state"] = size, name, "receiving"
            self.notify(gatt.FILE_TRANSACTION_STATE, bytes([gatt.TS_START, 0, 0, 0]), 0.003)
            return True
        if uuid == gatt.FILE_PARTIAL_DATA and xr["state"] == "receiving":
            self.standard_frames_seen += 1
            if "restore-reject" in self.scenarios and xr["frames"] == 0:
                self._standard_restore_fail("rejected the first frame (simulated incompatible file)", notify=False)
                raise FakeATTError(0x80)
            try:
                fr = gatt.parse_restore_frame(data)
            except gatt.FramingError as exc:
                self._standard_restore_fail(f"malformed frame: {exc}", notify=False)
                raise FakeATTError(0x0D) from exc
            if not fr.last and (fr.seq != xr["expect"] or fr.trailer != 0 or fr.size != gatt.RESTORE_CHUNK):
                self._standard_restore_fail(f"frame seq {fr.seq} size {fr.size} trailer {fr.trailer:#x}, expected seq {xr['expect']}")
                return True
            xr["data"] += fr.file_bytes
            xr["frames"] += 1
            xr["expect"] += 1
            if xr["frames"] == 1:
                head = bytes(xr["data"])
                if head[:16] != gatt.BACKUP_MAGIC or head[0x14:0x54] != self.settings[0x14:0x54]:
                    self._standard_restore_fail("not a backup from this body (rejected at the first frame)", notify=False)
                    raise FakeATTError(0x80)
            if not fr.last:
                self.notify(gatt.FILE_TRANSACTION_STATE, bytes([gatt.TS_TRANSFERRING, 0]) + gatt.u16le(fr.seq), 0.002)
                return True
            f = bytes(xr["data"])
            want = gatt.byte_sum16(f)
            why = None
            if int.from_bytes(fr.data[-2:], "little") != want or fr.trailer != want:
                why = f"transport sum: in-data {fr.data[-2:].hex()} trailer {fr.trailer:#06x}, computed {want:#06x}"
            elif len(f) != xr["declared"]:
                why = f"FILE_INFORMATION said {xr['declared']} bytes, got {len(f)}"
            elif "restore-error" in self.scenarios:
                why = "camera refused the file (simulated)"
            elif self.validator is not None:
                why = self.validator(f)
            if why:
                self._standard_restore_fail(why)
                return True
            xr["staged"], xr["state"] = f, "done"
            self.notify(gatt.FILE_TRANSACTION_STATE, bytes([gatt.TS_FILE_DONE, 0, 0xFF, 0xFF]), 0.002)
            return True
        if uuid == gatt.FILE_TRANSFER_RESULT:
            if data == gatt.RESULT_END and xr["state"] == "done" and xr["staged"] is not None:
                self.settings = xr["staged"]
                self.restores_applied += 1
            elif xr["state"] != "failed":
                self.restore_errors.append(f"transfer result {data.hex()} in state {xr['state']}")
            self.transfer_result = data
            self.xr = None
            return True
        return False

    def _standard_restore_fail(self, why: str, notify: bool = True) -> None:
        self.restore_errors.append(why)
        if self.xr is not None:
            self.xr["state"] = "failed"
        if notify:
            self.notify(gatt.FILE_TRANSACTION_STATE, bytes([gatt.TS_ERROR, 0, 0xFF, 0xFF]), 0.002)

    def _judge(self) -> None:
        r = self.restore
        f = bytes(self.upload)
        why = None
        if f[:16] != gatt.BACKUP_MAGIC:
            why = "not a FUJIFILMX-BACKUP file"
        elif f[0x14:0x54] != self.settings[0x14:0x54]:
            why = "file is from another body"
        elif self.declared_size is not None and self.declared_size != len(f):
            why = f"FILE_INFORMATION said {self.declared_size} bytes, got {len(f)}"
        elif self.validator is not None:
            why = self.validator(f)
        if why:
            self._restore_fail(why)
            return
        self._staged = f
        if not r.finish_char:
            self.settings = f
            self.restores_applied += 1
            self._staged = None
        if r.complete_char:
            self.notify(r.complete_char, self._pad(r.complete_value_prefix, b"\x03\x00", 4), 0.003)

    def _restore_fail(self, why: str) -> None:
        self.restore_errors.append(why)
        self.restore_state = "idle"
        self._staged = None
        r = self.restore
        if r.complete_char:
            self.notify(r.complete_char, b"\x04\x00\x00\x00", 0.003)

    def _start_transfer(self) -> None:
        # Written independently of gatt.plan_upload_frames so the test of one isn't the mirror of the other:
        # full chunks of `partial_size`, then the remainder + u16 sum with seq 0xFFFF.
        data, size = self.file, self.partial_size
        pieces = [data[i : i + size] for i in range(0, len(data), size)]
        total = sum(data) & 0xFFFF
        if "bad-checksum" in self.scenarios:
            total ^= 0x5A5A
        self.chunks = [struct.pack("<HI", i, len(p)) + p for i, p in enumerate(pieces[:-1])]
        last = pieces[-1] + struct.pack("<H", total)
        self.chunks.append(struct.pack("<HI", 0xFFFF, len(last)) + last)
        self.chunk_index = 0
        if "stall" not in self.scenarios:
            self.notify(gatt.FILE_TRANSACTION_STATE, bytes([1, 0, 0, 0]))

    def _next_chunk(self) -> bytes:
        if not self.chunks or self.chunk_index >= len(self.chunks):
            return struct.pack("<HI", 0, 0)
        chunk = self.chunks[self.chunk_index]
        self.chunk_index += 1
        if "drop-mid-backup" in self.scenarios and self.chunk_index == 50:
            assert self.client is not None
            asyncio.get_running_loop().call_later(0.005, self.client.drop, "camera went to sleep (simulated)")
            return chunk
        if self.chunk_index < len(self.chunks):
            self.notify(gatt.FILE_TRANSACTION_STATE, bytes([2, 0, self.chunk_index & 0xFF, 0]), 0.002)
        else:
            self.notify(gatt.FILE_TRANSACTION_STATE, bytes([3, 0, 0, 0]), 0.002)
        return chunk


class FakeClient:
    """Duck-types the parts of bleak.BleakClient that client.Session uses."""

    def __init__(self, camera: FakeCamera, disconnected_callback: Optional[Callable[[Any], None]], timeout: float) -> None:
        self.camera = camera
        self.disconnected_callback = disconnected_callback
        self.timeout = timeout
        self._connected = False
        self.callbacks: dict[str, Callable] = {}
        self.address = camera.address
        self.name = camera.name
        self.mtu_size = 185
        self._ticker: Optional[asyncio.Future] = None

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def services(self) -> list[FakeService]:
        return self.camera.services

    async def connect(self, **_kwargs) -> None:
        cam = self.camera
        if "paired-elsewhere" in cam.scenarios:
            await asyncio.sleep(min(self.timeout, 0.3))
            raise asyncio.TimeoutError()
        if "powered-off" in cam.scenarios:
            await asyncio.sleep(min(self.timeout, 0.2))
            raise asyncio.TimeoutError()
        if "stale-bond" in cam.scenarios:
            raise RuntimeError("Failed to connect to peripheral: Error Domain=CBErrorDomain Code=14 "
                               "\"Peer removed pairing information\"")
        await asyncio.sleep(0.02)
        self._connected = True
        cam.connections += 1
        cam.client = self

    async def disconnect(self) -> None:
        self._connected = False
        self.callbacks.clear()
        if self._ticker is not None:
            self._ticker.cancel()

    def drop(self, reason: str) -> None:
        if not self._connected:
            return
        self._connected = False
        self.callbacks.clear()
        if self.disconnected_callback:
            self.disconnected_callback(self)

    async def pair(self, *args, **kwargs) -> None:
        self.camera.ops.append(("pair", "", b""))

    def _uuid(self, char) -> str:
        return (char.uuid if hasattr(char, "uuid") else str(char)).lower()

    def _check(self) -> None:
        if not self._connected:
            raise RuntimeError("disconnected")

    async def read_gatt_char(self, char, **_kwargs) -> bytearray:
        self._check()
        u = self._uuid(char)
        await asyncio.sleep(0.001)
        self.camera.ops.append(("read", u, b""))
        value = self.camera.on_read(u)
        return bytearray(value)

    async def write_gatt_char(self, char, data, response: Optional[bool] = None) -> None:
        self._check()
        u = self._uuid(char)
        await asyncio.sleep(0.001)
        self.camera.ops.append(("write", u, bytes(data)))
        self.camera.on_write(u, bytes(data))

    async def start_notify(self, char, callback, **_kwargs) -> None:
        self._check()
        u = self._uuid(char)
        self.camera.ops.append(("subscribe", u, b""))
        self.callbacks[u] = callback
        if u == gatt.LOCATION_REQUEST and "gps-ask" in self.camera.scenarios:
            self.camera.notify(u, b"\x01\x00", 0.1)
            self.camera.notify(u, b"\x01\x00", 0.3)
        if u == TICKER_CHAR and self._ticker is None:
            self._ticker = asyncio.ensure_future(self._tick())

    async def _tick(self) -> None:
        """Pretend the user is turning a dial: a NOTIFICATION_6 value every 0.5 s while subscribed (exercises `watch`)."""
        n = 0
        while self._connected and TICKER_CHAR in self.callbacks:
            await asyncio.sleep(0.5)
            n += 1
            self.camera.notify(TICKER_CHAR, bytes([n & 0xFF, 0]), 0)

    async def stop_notify(self, char) -> None:
        self.callbacks.pop(self._uuid(char), None)


class FakeTransport(Transport):
    is_fake = True

    def __init__(self, camera: FakeCamera, platform: str = "darwin") -> None:
        self.camera = camera
        self.platform = platform

    def describe(self) -> str:
        return f"SIMULATED X100VI (scenarios: {','.join(sorted(self.camera.scenarios))}), no Bluetooth used"

    async def scan(self, timeout: float, log, stop_when=None) -> ScanResult:
        cam = self.camera
        if "bt-off" in cam.scenarios:
            from .client import map_bluetooth_unavailable

            raise map_bluetooth_unavailable(FakeBluetoothUnavailable("Bluetooth device is turned off", "POWERED_OFF"))
        if "bt-denied" in cam.scenarios:
            from .client import map_bluetooth_unavailable

            raise map_bluetooth_unavailable(FakeBluetoothUnavailable("Bluetooth access is denied by the user", "DENIED_BY_USER"))
        start = time.monotonic()
        found: dict[str, Sighting] = {}
        deadline = start + min(timeout, 2.0)
        while time.monotonic() < deadline:
            if "no-camera" not in cam.scenarios and not found:
                s = cam.sighting()
                found[s.address] = s
                log.detail(f"heard Fujifilm {s.name} {s.address} rssi {s.rssi} (simulated)")
            if stop_when is not None and stop_when(found):
                break
            await asyncio.sleep(0.05)
        return ScanResult(list(found.values()), 3, time.monotonic() - start)

    def make_client(self, sighting: Sighting, disconnected_callback, timeout: float) -> FakeClient:
        return FakeClient(self.camera, disconnected_callback, timeout)


def camera_from_dump(path: Path, scenarios: set[str] | str = "ok") -> FakeCamera:
    """Replay harness: a fake camera with the services and read values of a real `dump` (captures/gatt-*.json)."""
    doc = json.loads(Path(path).read_text())
    values = {}
    for s in doc.get("services", []):
        for c in s.get("characteristics", []):
            r = c.get("read") or {}
            if r.get("ok") and r.get("hex"):
                values[c["uuid"]] = bytes.fromhex(r["hex"])
    cam_doc = doc.get("camera") or {}
    tag = (cam_doc.get("decoded") or {}).get("tag") or "REPLAY"
    return FakeCamera(scenarios, name=cam_doc.get("name") or "X100VI (replay)", tag=tag, table=doc.get("services"), values=values)


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()
