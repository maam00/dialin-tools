"""Fujifilm X100VI Bluetooth LE client: scan, pair, dump, backup, watch, restore (plan).

Transport is bleak (CoreBluetooth on macOS, BlueZ on Linux). Every flow takes a `Transport`, so the same code
runs against the simulated camera in `fake.py` for rehearsal and tests.

Protocol sources are cited inline as project + repo-relative path:line, and the flows are written up in
docs/FUJIFILM-PROTOCOL.md section 3. The published projects that matter most:
  fuji-bridge FujiBridge/FujiBluetooth.swift  (secure handshake, macOS pairing quirks, X100VI fw 1.32 field notes)
  fuji-bridge FujiBridge/FujiBackup.swift     (settings backup)
  libfuji lib/bluetooth.c, furble lib/furble/FujifilmSecure.cpp (pairing and subscriptions)
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import platform
import re
import struct
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable, Iterable, Optional

from . import gatt
from .gatt import hexs
from .restore_profile import RestoreProfile

#: The name written to the camera's client-name characteristic (85b9163e). Dial In identifies itself by this name only,
#: the same name the Swift tools (dialin-cam) use.
DEFAULT_CLIENT_NAME = "Dial In"

# ============================================================================================
# Logging with timing
# ============================================================================================


class Log:
    """Console + file logger. Every line carries time since start; steps report their duration."""

    def __init__(self, stream=None, file_path: Optional[Path] = None, verbose: bool = False) -> None:
        self.stream = stream or sys.stdout
        self.verbose = verbose
        self.t0 = time.monotonic()
        self.file = None
        self.file_path = file_path
        if file_path is not None:
            file_path.parent.mkdir(parents=True, exist_ok=True)
            self.file = open(file_path, "a", encoding="utf-8")

    def elapsed(self) -> float:
        return time.monotonic() - self.t0

    def _emit(self, text: str, console: bool) -> None:
        stamp = f"[{self.elapsed():8.3f}s] "
        lines = text.splitlines() or [""]
        out = "\n".join((stamp if i == 0 else " " * len(stamp)) + ln for i, ln in enumerate(lines))
        if console:
            print(out, file=self.stream, flush=True)
        if self.file:
            self.file.write(out + "\n")
            self.file.flush()

    def info(self, text: str) -> None:
        self._emit(text, True)

    def detail(self, text: str) -> None:
        """Always in the log file; on the console only with --verbose."""
        self._emit("  . " + text, self.verbose)

    def warn(self, text: str) -> None:
        self._emit("WARNING: " + text, True)

    def error(self, text: str) -> None:
        self._emit("ERROR: " + text, True)

    def plain(self, text: str = "") -> None:
        """Untimed output (tables, summaries)."""
        print(text, file=self.stream, flush=True)
        if self.file:
            self.file.write(text + "\n")
            self.file.flush()

    @contextlib.contextmanager
    def step(self, what: str):
        start = time.monotonic()
        self._emit(f"-> {what} ...", True)
        try:
            yield
        except BaseException as exc:
            took = time.monotonic() - start
            reason = "interrupted" if isinstance(exc, (KeyboardInterrupt, asyncio.CancelledError)) else describe_exception(exc)
            self._emit(f"   FAIL {what} after {took:.2f}s: {reason}", True)
            raise
        else:
            self._emit(f"   ok   {what} ({time.monotonic() - start:.2f}s)", True)

    def close(self) -> None:
        if self.file:
            self.file.close()
            self.file = None


# ============================================================================================
# Errors with plain-English explanations
# ============================================================================================


class FujiBleError(Exception):
    """An error the CLI can explain. `hint` is what the user should do next."""

    exit_code = 1

    def __init__(self, message: str, hint: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.hint = hint


class BluetoothUnavailable(FujiBleError):
    exit_code = 3


class CameraNotFound(FujiBleError):
    exit_code = 2


class PairedElsewhere(FujiBleError):
    exit_code = 4


class NotPaired(FujiBleError):
    exit_code = 4


class StaleBond(FujiBleError):
    exit_code = 4


class LinkDropped(FujiBleError):
    exit_code = 5


class Unsupported(FujiBleError):
    exit_code = 5


class TransferFailed(FujiBleError):
    exit_code = 5

    def __init__(self, message: str, hint: str = "", partial: Optional[bytes] = None) -> None:
        super().__init__(message, hint)
        self.partial = partial


class BackupBusy(TransferFailed):
    pass


class RestoreRefused(FujiBleError):
    exit_code = 6


CAMERA_CHECKLIST = (
    "Checklist:\n"
    "  1. Camera switched ON (not asleep: half-press the shutter to wake it).\n"
    "  2. Camera: MENU > NETWORK/USB SETTING > Bluetooth settings > Bluetooth ON/OFF = ON.\n"
    "  3. The FUJIFILM app closed on your phone (swipe it away), or the phone's Bluetooth off.\n"
    "     A camera connected to a phone stops advertising, so this Mac can't see it\n"
    "     (fuji-bridge FujiBluetooth.swift:352-355).\n"
    "  4. Mac within a couple of metres of the camera."
)


def describe_exception(exc: BaseException) -> str:
    if isinstance(exc, FujiBleError):
        return exc.message
    name = type(exc).__name__
    text = str(exc)
    code = _att_code(exc)
    if code is not None and len(getattr(exc, "args", ())) >= 2 and isinstance(exc.args[1], str):
        return f"{exc.args[1]} (ATT error {code:#04x})"
    if isinstance(exc, (asyncio.TimeoutError, TimeoutError)):
        return f"timed out{': ' + text if text else ''}"
    return f"{name}: {text}" if text else name


def _att_code(exc: BaseException) -> Optional[int]:
    code = getattr(exc, "code", None)
    try:
        return int(code) if code is not None else None
    except (TypeError, ValueError):
        return None


def is_pairing_pending(exc: BaseException) -> bool:
    """ATT 'insufficient authentication' (5), 'insufficient encryption' (15) or key size (12): no bond yet.
    fuji-bridge FujiBluetooth.swift:248-253."""
    if _att_code(exc) in (0x05, 0x0C, 0x0F, 0x08):
        return True
    text = str(exc).lower()
    return any(s in text for s in ("insufficient encryption", "insufficient authentication", "encryption is insufficient",
                                   "authentication is insufficient", "insufficient authorization"))


def is_stale_bond(exc: BaseException) -> bool:
    text = str(exc).lower()
    return "peer removed pairing information" in text or "pairing information" in text and "removed" in text


def is_disconnect(exc: BaseException) -> bool:
    if isinstance(exc, LinkDropped):
        return True
    text = str(exc).lower()
    return any(s in text for s in ("disconnected", "not connected", "is not connected", "device has disconnected"))


def map_bluetooth_unavailable(exc: BaseException) -> Optional[BluetoothUnavailable]:
    """Turn bleak's 'Bluetooth not available' errors (and their Linux equivalents) into plain English."""
    on_mac = sys.platform == "darwin"
    reason = getattr(exc, "reason", None)
    rname = getattr(reason, "name", "") if reason is not None else ""
    text = str(exc)
    low = text.lower()
    if rname == "POWERED_OFF" or "powered off" in low or "turned off" in low or "org.bluez.error.notready" in low:
        hint = ("Turn Bluetooth on: Control Center > Bluetooth, or System Settings > Bluetooth." if on_mac
                else "Run: sudo rfkill unblock bluetooth && bluetoothctl power on")
        return BluetoothUnavailable("Bluetooth is turned off on this computer.", hint)
    if rname.startswith("DENIED") or "denied" in low or "not authorized" in low or "unauthorized" in low:
        if on_mac:
            hint = ("macOS is blocking Bluetooth for the app this command runs in.\n"
                    "  System Settings > Privacy & Security > Bluetooth > switch ON your terminal app\n"
                    "  (Terminal, iTerm, VS Code, ...). Then quit and reopen that app and run the command again.\n"
                    "  If your terminal isn't listed, run the command once from Terminal.app; macOS asks the first time.")
        else:
            hint = "Add your user to the 'bluetooth' group (sudo usermod -aG bluetooth $USER), log out and back in."
        return BluetoothUnavailable("This program is not allowed to use Bluetooth.", hint)
    if rname in ("NO_BLUETOOTH", "NO_BLE_CENTRAL_ROLE") or "no bluetooth adapters" in low or "unsupported" in low:
        return BluetoothUnavailable("No usable Bluetooth LE adapter was found.",
                                    "Check the computer has Bluetooth (Linux: `bluetoothctl list`, `hciconfig`).")
    if not on_mac and ("org.freedesktop.dbus" in low or isinstance(exc, (FileNotFoundError, ConnectionRefusedError))):
        return BluetoothUnavailable("Can't talk to the BlueZ Bluetooth service.",
                                    "Run: sudo systemctl enable --now bluetooth   (then check `bluetoothctl show`).")
    if type(exc).__name__ == "BleakBluetoothNotAvailableError":
        return BluetoothUnavailable(f"Bluetooth is not available: {text}",
                                    "Check Bluetooth is on and this app is allowed to use it.")
    return None


# ============================================================================================
# Sightings and transports
# ============================================================================================


@dataclass
class Sighting:
    device: Any  # bleak BLEDevice, or a fake
    address: str
    name: str
    rssi: int
    manufacturer_data: dict[int, bytes]
    service_uuids: list[str]
    advert: gatt.AdvertInfo
    first_seen: float = 0.0
    last_seen: float = 0.0
    adverts: int = 1

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "address": self.address,
            "rssi": self.rssi,
            "manufacturer_data": {f"{k:#06x}": bytes(v).hex() for k, v in self.manufacturer_data.items()},
            "service_uuids": self.service_uuids,
            "decoded": {
                "kind": self.advert.kind,
                "meaning": self.advert.describe(),
                "type_byte": self.advert.type_byte,
                "tag": self.advert.tag,
                "token": self.advert.token.hex() if self.advert.token else None,
            },
            "adverts_heard": self.adverts,
        }


@dataclass
class ScanResult:
    cameras: list[Sighting]
    other_devices: int
    seconds: float


class Transport:
    """Where Bluetooth comes from. Subclasses: BleakTransport (real radio) and fake.FakeTransport."""

    platform = sys.platform
    is_fake = False

    async def scan(self, timeout: float, log: Log, stop_when: Optional[Callable[[dict[str, Sighting]], bool]] = None
                   ) -> ScanResult:
        raise NotImplementedError

    def make_client(self, sighting: Sighting, disconnected_callback: Callable[[Any], None], timeout: float) -> Any:
        raise NotImplementedError

    def describe(self) -> str:
        return "unknown"


class BleakTransport(Transport):
    def describe(self) -> str:
        try:
            from importlib.metadata import version

            v = version("bleak")
        except Exception:
            v = "?"
        backend = {"darwin": "CoreBluetooth", "linux": "BlueZ", "win32": "WinRT"}.get(sys.platform, sys.platform)
        return f"bleak {v} on {backend} ({platform.platform()})"

    async def scan(self, timeout: float, log: Log, stop_when=None) -> ScanResult:
        try:
            from bleak import BleakScanner
        except ImportError as exc:  # pragma: no cover - environment problem
            raise FujiBleError("bleak is not installed in this Python.",
                               "Run: cd ble && .venv/bin/pip install -r requirements.txt") from exc

        found: dict[str, Sighting] = {}
        others: set[str] = set()
        start = time.monotonic()

        def on_advert(device, adv) -> None:
            now = time.monotonic()
            prev = found.get(device.address)
            services = sorted(set((prev.service_uuids if prev else []) + [s.lower() for s in (adv.service_uuids or [])]))
            mfr = dict(prev.manufacturer_data) if prev else {}
            mfr.update({k: bytes(v) for k, v in (adv.manufacturer_data or {}).items()})
            info = gatt.decode_advert(mfr, services)
            if info is None:
                others.add(device.address)
                return
            name = adv.local_name or device.name or (prev.name if prev else "") or ""
            if prev is None:
                s = Sighting(device, device.address, name, adv.rssi, mfr, services, info, now, now, 1)
                found[device.address] = s
                log.detail(f"heard Fujifilm {name or '?'} {device.address} rssi {adv.rssi} mfr {mfr.get(gatt.FUJIFILM_COMPANY_ID, b'').hex() or '-'} "
                           f"services {[gatt.short_uuid(u) for u in services]}")
            else:
                changed = prev.advert.kind != info.kind or prev.service_uuids != services
                prev.device, prev.rssi, prev.manufacturer_data, prev.service_uuids, prev.advert = device, adv.rssi, mfr, services, info
                prev.name = name or prev.name
                prev.last_seen = now
                prev.adverts += 1
                if changed:
                    log.detail(f"advert changed for {prev.name} {device.address}: {info.kind} services "
                               f"{[gatt.short_uuid(u) for u in services]}")

        scanner = BleakScanner(detection_callback=on_advert)
        starter = asyncio.ensure_future(scanner.start())
        done, _ = await asyncio.wait({starter}, timeout=8.0)
        if not done:
            log.info("Still waiting for Bluetooth to start. If macOS is asking whether this terminal may use Bluetooth, "
                     "click Allow (OK).")
            done, _ = await asyncio.wait({starter}, timeout=52.0)
            if not done:
                starter.cancel()
                raise BluetoothUnavailable(
                    "Bluetooth never became ready (waited 60 s).",
                    "Is a macOS permission dialog waiting behind another window? Otherwise check System Settings > "
                    "Privacy & Security > Bluetooth for your terminal app.")
        try:
            starter.result()
        except Exception as exc:
            mapped = map_bluetooth_unavailable(exc)
            if mapped:
                raise mapped from exc
            raise
        ready = time.monotonic()
        log.detail(f"Bluetooth ready after {ready - start:.2f} s; listening {timeout:.0f} s")
        try:
            deadline = ready + timeout
            while time.monotonic() < deadline:
                if stop_when is not None and stop_when(found):
                    break
                await asyncio.sleep(0.1)
        finally:
            with contextlib.suppress(Exception):
                await scanner.stop()
        return ScanResult(list(found.values()), len(others), time.monotonic() - start)

    def make_client(self, sighting: Sighting, disconnected_callback, timeout: float):
        from bleak import BleakClient

        return BleakClient(sighting.device, disconnected_callback=disconnected_callback, timeout=timeout)


# ============================================================================================
# Remembering the camera between runs
# ============================================================================================


def default_out_dir() -> Path:
    return Path(__file__).resolve().parent.parent / "captures"


def timestamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


def load_last_camera(out_dir: Path) -> dict:
    try:
        return json.loads((out_dir / "last-camera.json").read_text())
    except Exception:
        return {}


def save_last_camera(out_dir: Path, sighting: Sighting, extra: Optional[dict] = None) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    data = {"name": sighting.name, "address": sighting.address, "tag": sighting.advert.tag, "saved_at": timestamp()}
    if sighting.advert.token:
        data["token"] = sighting.advert.token.hex()
    data.update(extra or {})
    (out_dir / "last-camera.json").write_text(json.dumps(data, indent=2) + "\n")


def remembered_token(out_dir: Path, sighting: Sighting) -> Optional[bytes]:
    """Basic-profile bodies (X100VI firmware before the secure profile, e.g. 1.10/1.11 = 76ab62): the 4-byte token
    advertised during PAIRING REGISTRATION must be written again on EVERY later connection (furble
    FujifilmBasic.cpp:57-83 keeps it in NVS for exactly this). `pair` saves it in last-camera.json."""
    if sighting.advert.token:
        return sighting.advert.token
    last = load_last_camera(out_dir)
    tok = last.get("token")
    if not tok:
        return None
    same = (last.get("address") == sighting.address or (last.get("tag") and last.get("tag") == sighting.advert.tag)
            or (last.get("name") and last.get("name") == sighting.name))
    return bytes.fromhex(tok) if same else None


def remembered_identification(out_dir: Path, sighting: Sighting) -> Optional[int]:
    """Secure bodies: the identification number derived at pairing (value | 0x20000000) is written again on every
    later connection (docs/FUJIFILM-PROTOCOL.md §3.5). `pair` saves it."""
    last = load_last_camera(out_dir)
    n = last.get("identification_number")
    if not n:
        return None
    same = last.get("address") == sighting.address or (last.get("tag") and last.get("tag") == sighting.advert.tag)
    return int(n) if same else None


# ============================================================================================
# Finding a camera
# ============================================================================================


@dataclass
class FindOptions:
    address: Optional[str] = None
    name: Optional[str] = None
    scan_timeout: float = 15.0
    connect_timeout: float = 20.0
    prefer_pairing: bool = False
    out_dir: Path = field(default_factory=default_out_dir)
    settle: float = 1.5  # keep listening this long after the first match (more adverts, scan responses)


def _matches(s: Sighting, opts: FindOptions) -> bool:
    if opts.address and s.address.lower() != opts.address.lower():
        return False
    if opts.name:
        needle = opts.name.lower()
        if needle not in (s.name or "").lower() and needle != (s.advert.tag or "").lower():
            return False
    return True


def pick_camera(cameras: Iterable[Sighting], opts: FindOptions, remembered: Optional[dict] = None) -> Optional[Sighting]:
    """Address/name filter, then (for pairing) a pairing-mode advert, then the remembered body, then the strongest.
    Same priorities as fuji-bridge FujiBluetooth.swift:473-506."""
    candidates = [s for s in cameras if _matches(s, opts)]
    if not candidates:
        return None
    if opts.prefer_pairing:
        pairing = [s for s in candidates if s.advert.kind in ("secure-pairing", "basic-pairing")]
        if pairing:
            candidates = pairing
    remembered = remembered or {}
    for key in ("address", "tag"):
        val = remembered.get(key)
        if val:
            hit = [s for s in candidates if (s.address if key == "address" else s.advert.tag) == val]
            if hit:
                return max(hit, key=lambda s: s.rssi)
    return max(candidates, key=lambda s: s.rssi)


async def scan_cameras(transport: Transport, log: Log, timeout: float) -> ScanResult:
    with log.step(f"Scanning {timeout:.0f} s for Fujifilm cameras (manufacturer id 0x04D8)"):
        result = await transport.scan(timeout, log)
    return result


async def find_camera(transport: Transport, log: Log, opts: FindOptions) -> Sighting:
    settle = opts.settle
    first_match: dict[str, float] = {}

    def stop_when(found: dict[str, Sighting]) -> bool:
        hits = [s for s in found.values() if _matches(s, opts) and s.advert.kind != "basic-off"]
        if opts.prefer_pairing and hits and not any(s.advert.kind in ("secure-pairing", "basic-pairing") for s in hits):
            # In PAIRING REGISTRATION an X100VI fw 1.32 keeps the bonded-style advert (fuji-bridge :495-497),
            # so take whatever we have after a few seconds rather than waiting for a9d2b304.
            if "t" in first_match and time.monotonic() - first_match["t"] < max(4.0 * settle / 1.5, settle):
                return False
        if hits and "t" not in first_match:
            first_match["t"] = time.monotonic()
        return bool(hits) and time.monotonic() - first_match["t"] >= settle

    what = "a Fujifilm camera"
    if opts.address or opts.name:
        what += f" matching {opts.address or opts.name!r}"
    with log.step(f"Looking for {what} (up to {opts.scan_timeout:.0f} s)"):
        result = await transport.scan(opts.scan_timeout, log, stop_when=stop_when)
        awake = [s for s in result.cameras if s.advert.kind != "basic-off"]
        chosen = pick_camera(awake, opts, load_last_camera(opts.out_dir))
        if chosen is None and any(_matches(s, opts) for s in result.cameras):
            off = next(s for s in result.cameras if _matches(s, opts))
            raise CameraNotFound(
                f"{off.name or 'The camera'} is switched OFF: it only sends its Bluetooth standby advert (registered "
                f"pairing key {off.advert.token.hex() if off.advert.token else '?'}). Turn the camera on and retry.",
                "`python -m fuji_ble adopt` (camera off is fine) saves that key, so the Mac can present it later "
                "without a new PAIRING REGISTRATION (keeps the iPhone's pairing; unverified on hardware).")
        if chosen is None:
            seen = ", ".join(f"{s.name or '?'} [{s.address}]" for s in result.cameras)
            msg = "No Fujifilm camera found" if not result.cameras else f"No camera matched the filter (saw: {seen})"
            raise CameraNotFound(f"{msg}. Heard {result.other_devices} other Bluetooth device(s), so the radio works.",
                                 CAMERA_CHECKLIST)
    if len(result.cameras) > 1:
        log.info(f"Several Fujifilm bodies heard; using {chosen.name or '?'} [{chosen.address}]. Pick another with --address.")
    log.info(f"Camera: {chosen.name or '(no name)'} [{chosen.address}] rssi {chosen.rssi} dBm, advert: {chosen.advert.describe()}"
             + (f", tag {chosen.advert.tag}" if chosen.advert.tag else ""))
    return chosen


# ============================================================================================
# A connected camera
# ============================================================================================


class Session:
    """One BLE connection, with step-logged GATT helpers and buffered notifications."""

    def __init__(self, transport: Transport, sighting: Sighting, log: Log, *, connect_timeout: float = 20.0,
                 op_timeout: float = 10.0, out_dir: Optional[Path] = None) -> None:
        self.out_dir = out_dir or default_out_dir()
        self.transport = transport
        self.sighting = sighting
        self.log = log
        self.connect_timeout = connect_timeout
        self.op_timeout = op_timeout
        self.client: Any = None
        self.chars: dict[str, Any] = {}
        self.duplicates: list[str] = []
        self.services: list[Any] = []
        self.queues: dict[str, asyncio.Queue] = {}
        self.listeners: list[Callable[[str, bytes], None]] = []
        self.subscribed: set[str] = set()
        self.disconnected = asyncio.Event()
        self.disconnect_reason = ""
        self.connected_at = 0.0
        self.ops: list[dict] = []  # trace of everything we sent/received (saved with dumps)
        self.reveal_secrets = False  # Wi-Fi password etc. stay out of logs/traces unless asked

    # ---- connection ----------------------------------------------------------------------

    def _on_disconnect(self, _client) -> None:
        self.disconnected.set()
        if not self.disconnect_reason:
            self.disconnect_reason = "camera closed the link"
        self.log.info(f"Bluetooth link closed ({self.disconnect_reason}).")

    async def connect(self) -> None:
        s = self.sighting
        self.client = self.transport.make_client(s, self._on_disconnect, self.connect_timeout)
        with self.log.step(f"Connecting to {s.name or s.address} (timeout {self.connect_timeout:.0f} s)"):
            try:
                await self.client.connect()
            except Exception as exc:
                raise self._explain_connect_failure(exc) from exc
        self.connected_at = time.monotonic()
        self.disconnected.clear()
        self.disconnect_reason = ""
        self._index_services()
        mtu = getattr(self.client, "mtu_size", None)
        self.log.info(f"Connected. {len(self.services)} services, {len(self.chars)} characteristics, ATT MTU {mtu}.")
        if self.duplicates:
            self.log.warn(f"Characteristic UUIDs that appear more than once (first one used): {self.duplicates}")

    def _explain_connect_failure(self, exc: BaseException) -> Exception:
        mapped = map_bluetooth_unavailable(exc)
        if mapped:
            return mapped
        if is_stale_bond(exc):
            return StaleBond(
                "macOS remembers an old pairing with this camera that the camera has forgotten.",
                "System Settings > Bluetooth > find the camera (X100VI...) > (i) > Forget This Device.\n"
                "  Then run `python -m fuji_ble pair` with the camera in PAIRING REGISTRATION.")
        if isinstance(exc, (asyncio.TimeoutError, TimeoutError)) or "timed out" in str(exc).lower():
            remembered = load_last_camera(self.out_dir)
            known = remembered.get("tag") and remembered.get("tag") == self.sighting.advert.tag
            if self.sighting.advert.kind == "bonded" and not known:
                # fuji-bridge FujiBluetooth.swift:423-426: a bonded body advertises for its own phone and never
                # answers anyone else (seen from a Mac next to an X100VI paired with a phone).
                return PairedElsewhere(
                    "The camera is bonded to another device (probably the FUJIFILM app on your phone) and ignored this computer.",
                    "Either close that app / turn off the phone's Bluetooth and retry, or register this computer:\n"
                    "  camera MENU > NETWORK/USB SETTING > Bluetooth settings > PAIRING REGISTRATION, then\n"
                    "  run `python -m fuji_ble pair`.")
            return LinkDropped(
                f"The camera didn't accept the connection within {self.connect_timeout:.0f} s.",
                "Is a phone app holding the camera (close it)? Is the camera asleep? Move closer and retry.\n" + CAMERA_CHECKLIST)
        if "not found" in str(exc).lower() or type(exc).__name__ == "BleakDeviceNotFoundError":
            return CameraNotFound("The camera disappeared before we could connect.", CAMERA_CHECKLIST)
        return LinkDropped(f"Connecting failed: {describe_exception(exc)}", CAMERA_CHECKLIST)

    def _index_services(self) -> None:
        self.chars.clear()
        self.duplicates.clear()
        self.services = sorted(list(self.client.services), key=lambda svc: getattr(svc, "handle", 0))
        for svc in self.services:
            for ch in svc.characteristics:
                u = ch.uuid.lower()
                if u in self.chars:
                    self.duplicates.append(u)
                    continue
                self.chars[u] = ch

    async def close(self) -> None:
        if self.client is None:
            return
        try:
            if getattr(self.client, "is_connected", False):
                self.disconnect_reason = "we disconnected"
                with self.log.step("Disconnecting"):
                    await asyncio.wait_for(self.client.disconnect(), 8)
        except Exception as exc:
            self.log.detail(f"disconnect: {describe_exception(exc)}")

    @property
    def is_connected(self) -> bool:
        return bool(self.client is not None and getattr(self.client, "is_connected", False) and not self.disconnected.is_set())

    # ---- GATT helpers --------------------------------------------------------------------

    def has(self, uuid: str) -> bool:
        return uuid.lower() in self.chars

    def props(self, uuid: str) -> list[str]:
        ch = self.chars.get(uuid.lower())
        return list(getattr(ch, "properties", [])) if ch is not None else []

    def _char(self, uuid: str):
        ch = self.chars.get(uuid.lower())
        if ch is None:
            raise Unsupported(f"The camera has no characteristic {gatt.char_label(uuid)}.",
                              "Run `python -m fuji_ble dump` and share captures/gatt-*.json.")
        return ch

    def _trace(self, op: str, uuid: str, data: bytes = b"", **extra) -> None:
        self.ops.append({"t": round(self.log.elapsed(), 4), "op": op, "char": uuid, "hex": bytes(data).hex(), **extra})

    async def _guard(self, coro: Awaitable, what: str, timeout: float):
        if self.disconnected.is_set():
            raise LinkDropped(f"Bluetooth link already closed ({self.disconnect_reason}) before: {what}.",
                              "The camera may have gone to sleep. Wake it and run the command again.")
        task = asyncio.ensure_future(coro)
        gone = asyncio.ensure_future(self.disconnected.wait())
        try:
            done, _ = await asyncio.wait({task, gone}, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
        finally:
            gone.cancel()
        if task in done:
            try:
                return task.result()
            except FujiBleError:
                raise
            except Exception as exc:
                if self.disconnected.is_set() or is_disconnect(exc):
                    self.disconnected.set()
                    raise LinkDropped(f"Bluetooth link dropped during: {what} ({self.disconnect_reason or describe_exception(exc)}).",
                                      "Camera asleep or out of range? Wake it and retry.") from exc
                raise
        task.cancel()
        with contextlib.suppress(BaseException):
            await task
        if gone in done:
            raise LinkDropped(f"Bluetooth link dropped during: {what} ({self.disconnect_reason}).",
                              "Camera asleep or out of range? Set AUTO POWER OFF longer for the test, wake it, retry.")
        raise TimeoutError(f"no answer within {timeout:.0f} s: {what}")

    async def read(self, uuid: str, timeout: Optional[float] = None, quiet: bool = False) -> bytes:
        ch = self._char(uuid)
        t = time.monotonic()
        try:
            value = bytes(await self._guard(self.client.read_gatt_char(ch), f"read {gatt.char_label(uuid)}",
                                            timeout or self.op_timeout))
        except Exception as exc:
            self._trace("read-error", uuid, error=describe_exception(exc))
            raise
        info = gatt.char_info(uuid)
        secret = bool(info and info.secret and not self.reveal_secrets)
        shown = f"<{len(value)} bytes, redacted>" if secret else hexs(value, 48)
        self._trace("read", uuid, b"" if secret else value, **({"redacted": len(value)} if secret else {}))
        msg = f"read  {gatt.char_label(uuid)} = {shown} ({(time.monotonic() - t) * 1000:.0f} ms)"
        self.log.detail(msg) if quiet else self.log.info("   " + msg)
        return value

    async def write(self, uuid: str, data: bytes, *, timeout: Optional[float] = None, quiet: bool = False,
                    response: bool = True) -> None:
        if uuid.lower() in gatt.NEVER_WRITE:
            raise Unsupported(f"Refusing to write {gatt.char_label(uuid)}: Dial In never writes it "
                              "(it identifies the connecting app on newer bodies).")
        ch = self._char(uuid)
        t = time.monotonic()
        try:
            await self._guard(self.client.write_gatt_char(ch, bytes(data), response=response),
                              f"write {gatt.char_label(uuid)}", timeout or self.op_timeout)
        except Exception as exc:
            self._trace("write-error", uuid, data, error=describe_exception(exc))
            raise
        self._trace("write", uuid, data)
        msg = f"write {gatt.char_label(uuid)} <- {hexs(data, 48)} ({(time.monotonic() - t) * 1000:.0f} ms)"
        self.log.detail(msg) if quiet else self.log.info("   " + msg)

    def _on_notify(self, char, data) -> None:
        uuid = char.uuid.lower() if hasattr(char, "uuid") else str(char).lower()
        value = bytes(data)
        info = gatt.char_info(uuid)
        self._trace("notify", uuid, b"" if (info and info.secret and not self.reveal_secrets) else value)
        q = self.queues.setdefault(uuid, asyncio.Queue())
        q.put_nowait(value)
        for listener in list(self.listeners):
            try:
                listener(uuid, value)
            except Exception as exc:  # a broken printer must not kill the session
                self.log.detail(f"listener error: {exc}")

    async def subscribe(self, uuid: str, *, required: bool = False, quiet: bool = False) -> bool:
        uuid = uuid.lower()
        if uuid in self.subscribed:
            return True
        if not self.has(uuid):
            if required:
                raise Unsupported(f"The camera has no characteristic {gatt.char_label(uuid)} to subscribe to.")
            self.log.detail(f"skip subscribe {gatt.char_label(uuid)}: not on this camera")
            return False
        props = self.props(uuid)
        if "notify" not in props and "indicate" not in props:
            if required:
                raise Unsupported(f"{gatt.char_label(uuid)} doesn't notify (properties {props}).")
            self.log.detail(f"skip subscribe {gatt.char_label(uuid)}: properties {props}")
            return False
        self.queues.setdefault(uuid, asyncio.Queue())
        try:
            await self._guard(self.client.start_notify(self._char(uuid), self._on_notify),
                              f"subscribe {gatt.char_label(uuid)}", self.op_timeout)
        except Exception as exc:
            self._trace("subscribe-error", uuid, error=describe_exception(exc))
            if required:
                raise
            self.log.warn(f"subscribe {gatt.char_label(uuid)} failed: {describe_exception(exc)}")
            return False
        self.subscribed.add(uuid)
        self._trace("subscribe", uuid)
        msg = f"subscribed {gatt.char_label(uuid)} ({'/'.join(p for p in props if p in ('notify', 'indicate'))})"
        self.log.detail(msg) if quiet else self.log.info("   " + msg)
        return True

    def drain(self, uuid: str) -> list[bytes]:
        q = self.queues.get(uuid.lower())
        out = []
        while q is not None and not q.empty():
            out.append(q.get_nowait())
        return out

    async def next_value(self, uuid: str, timeout: float) -> Optional[bytes]:
        """Next notification on `uuid` (buffered since subscribe), or None on timeout / link loss."""
        q = self.queues.setdefault(uuid.lower(), asyncio.Queue())
        if not q.empty():
            return q.get_nowait()
        if timeout <= 0 or self.disconnected.is_set():
            return None
        getter = asyncio.ensure_future(q.get())
        gone = asyncio.ensure_future(self.disconnected.wait())
        try:
            done, _ = await asyncio.wait({getter, gone}, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
        finally:
            gone.cancel()
        if getter in done:
            return getter.result()
        getter.cancel()
        return None


async def open_session(transport: Transport, log: Log, sighting: Sighting, opts: FindOptions) -> Session:
    session = Session(transport, sighting, log, connect_timeout=opts.connect_timeout, out_dir=opts.out_dir)
    await session.connect()
    return session


# ============================================================================================
# Identify: secure status ack + client name (the per-connection handshake)
# ============================================================================================


@dataclass
class IdentifyResult:
    mode: str  # "secure" | "basic" | "none"
    status_before: Optional[str] = None
    status_written: Optional[str] = None
    client_name: str = ""
    pairing_prompt_seen: bool = False
    identification_number: Optional[int] = None  # secure bodies: what we wrote (saved and reused)
    serial_read: Optional[str] = None  # basic bodies: 2a25, read before sending the pairing key


async def read_through_pairing(session: Session, uuid: str, log: Log, *, attempts: int, pause: float,
                               on_prompt: Optional[Callable[[], None]] = None) -> bytes:
    """The first encrypted read starts OS pairing. macOS fails it at once with 'Encryption is insufficient' while
    the user compares the 6-digit code, and dropping the link makes the camera show 'pairing canceled'. So keep
    the link and ask again (fuji-bridge FujiBluetooth.swift:230-246: 30 tries, 2 s apart)."""
    attempt = 0
    while True:
        try:
            return await session.read(uuid, timeout=30)
        except Exception as exc:
            if not is_pairing_pending(exc):
                raise
            attempt += 1
            if attempt == 1:
                if on_prompt:
                    on_prompt()
            if attempt > attempts:
                raise NotPaired(
                    "The camera wants an encrypted (paired) link and this computer isn't paired with it.",
                    "Run `python -m fuji_ble pair` with the camera in PAIRING REGISTRATION\n"
                    "  (MENU > NETWORK/USB SETTING > Bluetooth settings > PAIRING REGISTRATION).") from exc
            log.info(f"   waiting for the pairing to be confirmed ({attempt}/{attempts}) ...")
            await asyncio.sleep(pause)


async def identify(session: Session, log: Log, client_name: str, *, pairing_attempts: int = 5, pause: float = 2.0,
                   token: Optional[bytes] = None, on_prompt: Optional[Callable[[], None]] = None,
                   identification_number: Optional[int] = None) -> IdentifyResult:
    """The per-connection handshake (docs/FUJIFILM-PROTOCOL.md §3.4-3.5):
    * Secure bodies (X100VI fw 1.30+): read CLIENT_ID_NUMBER (f557d96b, u32), write back our id:
      the saved one, else the value with 0x20000000 OR-ed in -- the same bytes as the "byte 3 = 0x20" rule
      (fuji-bridge, furble) on a first pairing.
    * Basic bodies (fw 1.10/1.11): read the serial number (2a25), write the 4-byte pairing key from the PAIRING
      REGISTRATION advert (aba356eb) -- on EVERY connection.
    * Then the client name (85b9163e), UTF-8 + NUL. Nothing else: the app-identity characteristic (8b5ecf55) is never
      written (gatt.NEVER_WRITE); Dial In identifies itself by its client name only."""
    result = IdentifyResult(mode="none", client_name=client_name)

    def prompt() -> None:
        result.pairing_prompt_seen = True
        if on_prompt:
            on_prompt()

    with log.step("Identifying to the camera (pairing key / identification number + client name)"):
        if session.has(gatt.SECURE_STATUS):
            status = await read_through_pairing(session, gatt.SECURE_STATUS, log, attempts=pairing_attempts, pause=pause,
                                                on_prompt=prompt)
            result.status_before = status.hex()
            if len(status) != 4:
                raise Unsupported(f"Identification number was {len(status)} bytes ({hexs(status)}); expected 4.")
            ident = gatt.client_id_number(status, identification_number)
            ack = gatt.u32le(ident)
            await session.write(gatt.SECURE_STATUS, ack)
            result.status_written = ack.hex()
            result.identification_number = ident
            result.mode = "secure"
        elif session.has(gatt.PAIRING_TOKEN):
            if session.has(gatt.SERIAL_NUMBER):
                try:
                    result.serial_read = gatt.decode_value("utf8", await session.read(gatt.SERIAL_NUMBER, quiet=True)).strip("'")
                except Exception as exc:  # we log and still try the key
                    log.warn(f"couldn't read the serial number (2a25) before the pairing key: {describe_exception(exc)}")
            if token is not None:
                await session.write(gatt.PAIRING_TOKEN, token)
                result.mode = "basic"
            else:
                log.warn("Basic-profile camera (older firmware) and no saved pairing token (pairing key): the camera will ignore us. "
                         "Run `pair` once with the camera in PAIRING REGISTRATION; it saves the key in last-camera.json.")
        else:
            log.warn("No identification-number characteristic and no pairing key: skipping that step.")
        await session.write(gatt.CLIENT_NAME, gatt.encode_client_name(client_name))
    return result


async def subscribe_many(session: Session, uuids: Iterable[str], log: Log, *, quiet: bool = True) -> tuple[list[str], list[str]]:
    ok, missing = [], []
    for u in uuids:
        (ok if await session.subscribe(u, quiet=quiet) else missing).append(u)
    return ok, missing


def profile_from_firmware(fw: str) -> str:
    """gatt-profiles-map.csv:5-6: X100VI 1.11 -> basic 76ab62, 1.31 -> secure ad14d4. Accepts '1.32', 'Ver1.32', '0132'."""
    m = re.search(r"(\d+)\.(\d+)", fw) or re.search(r"\b(\d{2})(\d{2})\b", fw)
    if not m:
        return "unknown"
    major, minor = int(m.group(1)), int(m.group(2))
    if (major, minor) >= (1, 30):  # the secure profile arrived with 1.30 (fffw saw 1.11 basic, 1.31 secure)
        return "secure (expected GATT profile ad14d4)"
    if major >= 1:
        return "basic (expected GATT profile 76ab62, token pairing)"
    return "unknown"


async def read_identity(session: Session, log: Log) -> dict:
    """What we read right after registering: GAP name, camera identity number, SSID, Wi-Fi MAC, firmware, model number."""
    out = {}
    for key, uuid in (("device_name", gatt.DEVICE_NAME), ("model", gatt.MODEL_NUMBER), ("firmware", gatt.FIRMWARE_REVISION),
                      ("identity_number", gatt.CAMERA_IDENTITY_NUMBER), ("ssid", gatt.CAMERA_SSID), ("wifi_mac", gatt.CAMERA_WIFI_ADDRESS)):
        if session.has(uuid):
            try:
                out[key] = gatt.decode_value("utf8", await session.read(uuid, quiet=True)).strip("'")
            except Exception as exc:
                out[key] = f"<unreadable: {describe_exception(exc)}>"
    if "firmware" in out:
        out["profile"] = profile_from_firmware(out["firmware"])
    return out


def print_notification(log: Log, uuid: str, value: bytes, reveal: bool = False) -> None:
    log.info(f"   notify {gatt.char_label(uuid)} = {hexs(value, 48)}  [{gatt.decode_char(uuid, value, reveal_secrets=reveal)}]")


# ============================================================================================
# pair
# ============================================================================================


@dataclass
class PairOptions:
    client_name: str = DEFAULT_CLIENT_NAME
    attempts: int = 30
    pause: float = 2.0
    listen: float = 5.0
    geotag_interval: Optional[int] = None
    sync_time: bool = False
    verify: bool = True
    reconnect_pause: float = 2.0


PAIR_INSTRUCTIONS_MAC = (
    "CONFIRM ON BOTH SIDES NOW:\n"
    "  * Mac: a 'Bluetooth Pairing Request' alert (or a notification, top-right) shows a 6-digit code.\n"
    "    Click Connect / Pair. If you see nothing, open Notification Center.\n"
    "  * Camera: the same 6-digit code. Check it matches, press MENU/OK.\n"
    "  This tool keeps the link open and retries for up to a minute."
)
PAIR_INSTRUCTIONS_LINUX = (
    "CONFIRM ON BOTH SIDES NOW:\n"
    "  * Pi/Linux: answer 'yes' in the bluetoothctl window running `agent KeyboardDisplay` + `default-agent`.\n"
    "  * Camera: the same 6-digit code. Check it matches, press MENU/OK."
)


async def pair_flow(transport: Transport, log: Log, find: FindOptions, opts: PairOptions) -> dict:
    log.info("Pairing. Before you start: camera ON, Bluetooth ON, the FUJIFILM phone app closed, then on the camera\n"
             "  MENU > NETWORK/USB SETTING > Bluetooth settings > PAIRING REGISTRATION (it shows a 'pairing' screen).")
    find.prefer_pairing = True
    find.scan_timeout = max(find.scan_timeout, 60.0)
    sighting = await find_camera(transport, log, find)
    # Basic bodies (fw before the secure profile) advertise a 4-byte token only while in PAIRING REGISTRATION; keep it
    # across the reconnects below and save it, because every later connection must send it again.
    pair_token = sighting.advert.token
    if sighting.advert.kind == "basic-pairing":
        log.info("Basic-profile camera (older firmware): no 6-digit code; the tool sends the pairing token "
                 f"{pair_token.hex() if pair_token else '?'} from the advert. Confirm on the camera if it asks.")
    instructions = PAIR_INSTRUCTIONS_MAC if transport.platform == "darwin" else PAIR_INSTRUCTIONS_LINUX
    pairing_seen = False
    last_exc: Optional[BaseException] = None

    def prompt() -> None:
        nonlocal pairing_seen
        pairing_seen = True
        log.plain("\n" + instructions + "\n")

    for attempt in range(1, 4):
        session: Optional[Session] = None
        try:
            session = await open_session(transport, log, sighting, find)
            if transport.platform.startswith("linux"):
                # BlueZ: explicit bond (libfuji bluetooth.c:437-444 create_bond; furble secureConnection()).
                with log.step("Asking BlueZ to pair (needs a bluetoothctl agent running)"):
                    try:
                        await session.client.pair()
                    except NotImplementedError:
                        pass
                    except Exception as exc:
                        log.warn(f"BlueZ pair() said: {describe_exception(exc)} (continuing; maybe already bonded)")
            ident = await identify(session, log, opts.client_name, pairing_attempts=opts.attempts, pause=opts.pause,
                                   token=sighting.advert.token or pair_token, on_prompt=prompt)
            with log.step("Subscribing to the camera's notifications (two rounds)"):
                ok, missing = await subscribe_many(session, gatt.FIRST_SUBSCRIPTION_ROUND + gatt.SECOND_SUBSCRIPTION_ROUND, log)
            log.info(f"   {len(ok)} subscribed; not on this camera: {[gatt.short_uuid(u) for u in missing] or 'none'}")
            session.listeners.append(lambda u, v: print_notification(log, u, v))
            if opts.geotag_interval is not None:
                # furble FujifilmSecure.cpp:186-192 writes 10. Optional here: it changes a camera setting.
                await session.write(gatt.GEOTAG_SYNC_INTERVAL, gatt.u16le(opts.geotag_interval))
            if opts.sync_time:
                session.listeners.append(lambda u, v: asyncio.ensure_future(_answer_time_sync(session, log, u, v)))
            identity = await read_identity(session, log)
            if opts.listen > 0:
                with log.step(f"Listening {opts.listen:.0f} s for the camera's first notifications"):
                    await asyncio.sleep(opts.listen)
            dropped_during_listen = session.disconnected.is_set()
            save_last_camera(find.out_dir, sighting, {"identity": identity, "client_name": opts.client_name,
                                                      **({"token": pair_token.hex()} if pair_token else {}),
                                                      **({"identification_number": ident.identification_number}
                                                         if ident.identification_number else {})})
            await session.close()
            bond = "skipped"
            if opts.verify:
                bond = await _verify_bond(transport, log, sighting, find, opts.reconnect_pause)
            summary = {
                "camera": sighting.to_json(),
                "identify": ident.__dict__,
                "identity": identity,
                "subscribed": ok,
                "missing_subscriptions": missing,
                "attempt": attempt,
                "bond_check": bond,
                "dropped_during_listen": dropped_during_listen,
            }
            log.plain("")
            log.plain("PAIRED AND REGISTERED." if bond in ("ok", "skipped") else "REGISTERED, BUT THE BOND CHECK FAILED (see above).")
            if dropped_during_listen:
                log.plain("  Note:        the camera closed the link while we listened (it may do this after registering).")
            log.plain(f"  Bond check:  {bond}")
            log.plain(f"  Camera:      {identity.get('device_name', sighting.name)}  firmware {identity.get('firmware', '?')}"
                      f"  -> {identity.get('profile', '?')}")
            log.plain(f"  Mode:        {ident.mode}; status {ident.status_before} -> {ident.status_written}")
            log.plain(f"  Client name: {opts.client_name!r} (the camera may list this name)")
            log.plain("  Next:        python -m fuji_ble dump")
            return summary
        except (LinkDropped, PairedElsewhere) as exc:
            last_exc = exc
            # fuji-bridge FujiBluetooth.swift:412-414,449-451: an X100VI drops the link the moment the code is
            # confirmed, then waits for the bonded device to come back. Reconnect and run the handshake again.
            # (A connect timeout right after pairing looks like "bonded elsewhere"; retry it too once we've paired.)
            retry = isinstance(exc, LinkDropped) or pairing_seen
            if attempt < 3 and retry:
                log.info(f"Link lost {'after pairing ' if pairing_seen else ''}({exc.message.rstrip('.')}). This is expected on an X100VI "
                         f"right after the code is confirmed. Reconnecting (attempt {attempt + 1} of 3) ...")
                if session is not None:
                    await session.close()
                await asyncio.sleep(opts.reconnect_pause)
                again = FindOptions(address=None, name=sighting.advert.tag or find.name, scan_timeout=30,
                                    connect_timeout=find.connect_timeout, out_dir=find.out_dir, settle=find.settle)
                try:
                    sighting = await find_camera(transport, log, again)
                except CameraNotFound:
                    log.info("Didn't hear it again by its tag; retrying the same device.")
                continue
            raise
        finally:
            if session is not None:
                await session.close()
    raise last_exc if last_exc else NotPaired("Pairing did not complete.")


async def _verify_bond(transport: Transport, log: Log, sighting: Sighting, find: FindOptions, pause: float = 2.0) -> str:
    """Reconnect and do one encrypted read: proves the OS bond and the camera's registration survive a new link."""
    await asyncio.sleep(pause)
    try:
        with log.step("Checking the bond: reconnecting and reading SECURE_STATUS with no pairing prompt"):
            again = FindOptions(name=sighting.advert.tag or None, scan_timeout=30, connect_timeout=find.connect_timeout,
                                out_dir=find.out_dir, settle=find.settle)
            try:
                target = await find_camera(transport, log, again)
            except CameraNotFound:
                target = sighting
            session = await open_session(transport, log, target, find)
            try:
                status = await read_through_pairing(session, gatt.SECURE_STATUS, log, attempts=2, pause=2.0) \
                    if session.has(gatt.SECURE_STATUS) else await session.read(gatt.DEVICE_NAME)
                log.info(f"   read OK without a pairing prompt ({hexs(status)})")
            finally:
                await session.close()
        return "ok"
    except FujiBleError as exc:
        return f"FAILED: {exc.message}"
    except Exception as exc:
        return f"FAILED: {describe_exception(exc)}"


def time_sync_payload(session_has: Callable[[str], bool]) -> Optional[tuple[str, bytes]]:
    """The answer to a TIME_SYNC_REQUEST: UTC_TIME_AND_ZONE (12 bytes) when the body has that characteristic, else
    TIME (7 bytes, local time). Raw offset excludes DST; the DST flag says it's on."""
    import datetime as _dt

    if session_has(gatt.UTC_TIME_AND_ZONE):
        now = _dt.datetime.now().astimezone()
        dst = bool(time.localtime().tm_isdst > 0)
        raw = -time.timezone  # raw (standard-time) offset, without DST
        return gatt.UTC_TIME_AND_ZONE, gatt.encode_utc_time_and_zone(now.astimezone(_dt.timezone.utc), raw, dst)
    if session_has(gatt.TIME):
        return gatt.TIME, gatt.encode_date_time()
    return None


async def _answer_time_sync(session: Session, log: Log, uuid: str, value: bytes) -> None:
    """On a TIME_SYNC_REQUEST notify (f9150137), send the time (time_sync_payload)."""
    if uuid != gatt.TIME_SYNC_REQUEST:
        return
    what = time_sync_payload(session.has)
    if what is None:
        return
    try:
        await session.write(*what)
    except Exception as exc:
        log.warn(f"time sync write failed: {describe_exception(exc)}")


# ============================================================================================
# dump
# ============================================================================================


@dataclass
class DumpOptions:
    identify: bool = False
    client_name: str = DEFAULT_CLIENT_NAME
    include_secrets: bool = False
    listen: float = 0.0
    read_timeout: float = 8.0


async def dump_flow(transport: Transport, log: Log, find: FindOptions, opts: DumpOptions) -> tuple[dict, Path]:
    out_path = find.out_dir / f"gatt-{timestamp()}.json"
    result: dict = {
        "tool": "fuji_ble dump",
        "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "transport": transport.describe(),
        "camera": None,
        "connection": {},
        "identify": None,
        "identity": {},
        "services": [],
        "comparison_with_x100vi_ad14d4": {},
        "notifications": [],
        "errors": [],
    }
    session: Optional[Session] = None
    try:
        sighting = await find_camera(transport, log, find)
        result["camera"] = sighting.to_json()
        session = Session(transport, sighting, log, connect_timeout=find.connect_timeout, out_dir=find.out_dir)
        session.reveal_secrets = opts.include_secrets
        t = time.monotonic()
        await session.connect()
        result["connection"] = {"connect_seconds": round(time.monotonic() - t, 3), "mtu": getattr(session.client, "mtu_size", None)}

        if opts.identify:
            try:
                ident = await identify(session, log, opts.client_name, pairing_attempts=3,
                                       token=remembered_token(find.out_dir, session.sighting),
                                       identification_number=remembered_identification(find.out_dir, session.sighting))
                result["identify"] = ident.__dict__
            except Exception as exc:
                result["errors"].append({"step": "identify", "error": describe_exception(exc)})
                log.warn(f"identify failed, continuing with the dump: {describe_exception(exc)}")

        needs_bond = 0
        reconnects_left = 1
        if transport.platform == "darwin":
            log.info("Note: reading an encrypted characteristic can make macOS pop a 'Bluetooth Pairing Request'. If the camera "
                     "isn't in PAIRING REGISTRATION you can click Cancel; the dump carries on.")
        work: list[tuple[dict, Any]] = []
        for svc in session.services:
            s_uuid = svc.uuid.lower()
            s_info = gatt.SERVICES.get(s_uuid)
            s_entry = {"uuid": s_uuid, "name": s_info.name if s_info else None, "handle": getattr(svc, "handle", None),
                       "characteristics": []}
            result["services"].append(s_entry)
            for ch in sorted(svc.characteristics, key=lambda c: getattr(c, "handle", 0)):
                u = ch.uuid.lower()
                info = gatt.char_info(u)
                entry: dict = {
                    "uuid": u,
                    "service": s_uuid,
                    "name": info.name if info else None,
                    "handle": getattr(ch, "handle", None),
                    "properties": list(getattr(ch, "properties", [])),
                    "expected_properties": list(info.props) if info else None,
                    "descriptors": [{"uuid": d.uuid, "handle": getattr(d, "handle", None)} for d in getattr(ch, "descriptors", [])],
                    "source": info.source if info else None,
                }
                s_entry["characteristics"].append(entry)
                work.append((entry, ch))
        with log.step(f"Reading every readable characteristic ({len(session.chars)} total)"):
            current_service = None
            for entry, ch in work:
                u, props = entry["uuid"], entry["properties"]
                if entry["service"] != current_service:
                    current_service = entry["service"]
                    log.info(f"   service {gatt.service_label(current_service)}")
                if "read" not in props:
                    log.info(f"      {gatt.char_label(u):46s} [{','.join(props)}]")
                    continue
                if not session.is_connected and reconnects_left > 0:
                    reconnects_left -= 1
                    log.info("   The link dropped; reconnecting once to finish the dump ...")
                    await session.close()
                    session = Session(transport, sighting, log, connect_timeout=find.connect_timeout, out_dir=find.out_dir)
                    session.reveal_secrets = opts.include_secrets
                    await session.connect()
                t0 = time.monotonic()
                try:
                    value = await session.read(u, timeout=opts.read_timeout, quiet=True)
                    secret = bool(entry["name"] and gatt.CHARACTERISTICS[u].secret and not opts.include_secrets)
                    entry["read"] = {
                        "ok": True,
                        "len": len(value),
                        "hex": None if secret else value.hex(),
                        "decoded": gatt.decode_char(u, value, reveal_secrets=opts.include_secrets),
                        "ms": round((time.monotonic() - t0) * 1000),
                    }
                    log.info(f"      {gatt.char_label(u):46s} [{','.join(props)}] = {entry['read']['decoded']}")
                except Exception as exc:
                    pending = is_pairing_pending(exc)
                    needs_bond += pending
                    entry["read"] = {"ok": False, "error": describe_exception(exc), "needs_bond": pending,
                                     "ms": round((time.monotonic() - t0) * 1000)}
                    result["errors"].append({"step": f"read {u}", "error": describe_exception(exc)})
                    log.info(f"      {gatt.char_label(u):46s} [{','.join(props)}] READ FAILED: {describe_exception(exc)}"
                             + (" (needs a bond)" if pending else ""))
                    if isinstance(exc, LinkDropped) and reconnects_left <= 0:
                        raise
        identity = {}
        for key, uuid in (("device_name", gatt.DEVICE_NAME), ("model", gatt.MODEL_NUMBER), ("firmware", gatt.FIRMWARE_REVISION)):
            for s in result["services"]:
                for c in s["characteristics"]:
                    if c["uuid"] == uuid and c.get("read", {}).get("ok"):
                        identity[key] = str(c["read"]["decoded"]).strip("'")
        if "firmware" in identity:
            identity["profile"] = profile_from_firmware(identity["firmware"])
        result["identity"] = identity

        present = set(session.chars)
        expected = set(gatt.X100VI_AD14D4)
        mismatched = []
        for u in sorted(present & expected):
            got = sorted(session.props(u))
            want = sorted(gatt.CHARACTERISTICS[u].props)
            # CoreBluetooth reports extra flags (e.g. 'write-without-response'); only flag missing ones.
            if not set(want) <= set(got):
                mismatched.append({"uuid": u, "expected": want, "got": got})
        result["comparison_with_x100vi_ad14d4"] = {
            "missing": sorted(expected - present),
            "unexpected": sorted(present - expected),
            "property_mismatches": mismatched,
            "matches": not (expected - present) and not mismatched,
        }

        if opts.listen > 0:
            notes: list = result["notifications"]
            session.listeners.append(lambda u, v: (notes.append({"t": round(log.elapsed(), 3), "uuid": u, "hex": v.hex()}),
                                                   print_notification(log, u, v, opts.include_secrets)))
            with log.step(f"Subscribing to every notify/indicate characteristic and listening {opts.listen:.0f} s"):
                await subscribe_many(session, [u for u in session.chars if {"notify", "indicate"} & set(session.props(u))], log)
                await asyncio.sleep(opts.listen)

        cmp = result["comparison_with_x100vi_ad14d4"]
        log.plain("")
        log.plain(f"Camera: {identity.get('device_name', sighting.name)}  model {identity.get('model', '?')}  "
                  f"firmware {identity.get('firmware', '?')} -> {identity.get('profile', '?')}")
        log.plain(f"Services {len(session.services)}, characteristics {len(session.chars)}, read errors {len(result['errors'])}"
                  + (f" ({needs_bond} need a bond: run `pair`)" if needs_bond else ""))
        if cmp["matches"]:
            log.plain("GATT table matches fffw's X100VI fw 1.31 table (ad14d4)" +
                      (f", plus {len(cmp['unexpected'])} extra characteristic(s)." if cmp["unexpected"] else "."))
        else:
            log.plain(f"GATT differs from ad14d4: missing {[gatt.short_uuid(u) for u in cmp['missing']]}, "
                      f"unexpected {[gatt.short_uuid(u) for u in cmp['unexpected']]}, "
                      f"property mismatches {len(cmp['property_mismatches'])}")
        return result, out_path
    except BaseException as exc:
        result["errors"].append({"step": "fatal", "error": describe_exception(exc)})
        raise
    finally:
        if session is not None:
            result["trace"] = session.ops
            await session.close()
        if result["camera"] is not None:
            find.out_dir.mkdir(parents=True, exist_ok=True)
            out_path.write_text(json.dumps(result, indent=2) + "\n")
            log.info(f"Saved {out_path}")


# ============================================================================================
# backup
# ============================================================================================


@dataclass
class BackupOptions:
    identify: bool = True
    client_name: str = DEFAULT_CLIENT_NAME
    runs: int = 2
    partial_size: int = gatt.BACKUP_PARTIAL_SIZE
    state_timeout: float = 10.0  # FujiBackup.swift:8,45
    chunk_timeout: float = 20.0  # FujiBackup.swift:53


@dataclass
class BackupResult:
    name: str
    data: bytes
    reported_size: Optional[int]
    expected_sum: Optional[int]
    computed_sum: int
    checksum_ok: Optional[bool]
    seq_report: str
    chunks: int
    seconds: float
    header: dict

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.data).hexdigest()

    def meta(self) -> dict:
        return {
            "name": self.name,
            "size": len(self.data),
            "reported_size": self.reported_size,
            "sha256": self.sha256,
            "checksum": {"expected": self.expected_sum, "computed": self.computed_sum, "ok": self.checksum_ok},
            "chunks": self.chunks,
            "seq": self.seq_report,
            "seconds": round(self.seconds, 3),
            "bytes_per_second": round(len(self.data) / self.seconds) if self.seconds else None,
            "header": self.header,
        }


async def backup_once(session: Session, log: Log, opts: BackupOptions, label: str = "") -> BackupResult:
    """The settings backup exactly as fuji-bridge FujiBackup.run (FujiBackup.swift:35-97):
    1 subscribe FILE_TRANSACTION_STATE + BACKUP_STATE, 2 write BACKUP_REQUEST 01 00, 3 wait <=10 s for BACKUP_STATE 1,
    4 write FILE_PARTIAL_SIZE u32 120 and FILE_TRANSFER_INDEX u32 0, 5 on each state 1/2 read FILE_PARTIAL_DATA,
    6 on state 3 verify the sum, read FILE_INFORMATION, write FILE_TRANSFER_RESULT 03 00 (00 00 on any error)."""
    for needed in (gatt.BACKUP_REQUEST, gatt.BACKUP_STATE, gatt.FILE_PARTIAL_DATA, gatt.FILE_TRANSACTION_STATE):
        if not session.has(needed):
            raise Unsupported(f"This camera doesn't offer the Bluetooth settings backup (no {gatt.char_label(needed)}).",
                              "Run `python -m fuji_ble dump` and share the JSON.")
    t_start = time.monotonic()
    asm = gatt.BackupAssembler()
    with log.step(f"Settings backup{label}"):
        await session.subscribe(gatt.FILE_TRANSACTION_STATE, required=True)
        await session.subscribe(gatt.BACKUP_STATE)
        for stale_uuid in (gatt.FILE_TRANSACTION_STATE, gatt.BACKUP_STATE):
            for v in session.drain(stale_uuid):
                log.detail(f"dropped stale {gatt.char_label(stale_uuid)} {hexs(v)}")
        try:
            await session.write(gatt.BACKUP_REQUEST, gatt.BACKUP_REQUEST_SETTINGS)
            ready = await _wait_backup_ready(session, log, opts.state_timeout)
            if not ready:
                raise TransferFailed("The camera never said it was ready to send the backup.")
            await session.write(gatt.FILE_PARTIAL_SIZE, gatt.u32le(opts.partial_size))
            await session.write(gatt.FILE_TRANSFER_INDEX, gatt.u32le(0))
            next_progress = 4096
            while True:
                value = await session.next_value(gatt.FILE_TRANSACTION_STATE, opts.chunk_timeout)
                if value is None:
                    if session.disconnected.is_set():
                        raise LinkDropped(f"Bluetooth link dropped after {len(asm.data)} bytes ({session.disconnect_reason}).",
                                          "Wake the camera (half-press), keep it close, and run backup again.")
                    raise TransferFailed(
                        f"No transfer-state notification for {opts.chunk_timeout:.0f} s after {len(asm.data)} bytes "
                        f"({len(asm.seqs)} chunks).",
                        "The camera stopped sending. If it happens at 0 bytes the request sequence may differ on this body: "
                        "share captures/backup-*.log.")
                st = gatt.parse_transaction_state(value)
                log.detail(f"transaction state {st.state} aux {st.aux_hex}")
                if st.state in (1, 2):
                    raw = await session.read(gatt.FILE_PARTIAL_DATA, quiet=True)
                    try:
                        ch = asm.add(raw)
                    except gatt.FramingError as exc:
                        raise TransferFailed(f"The camera sent a malformed chunk: {exc}") from exc
                    log.detail(f"chunk seq {ch.seq:#06x} len {ch.length}{' LAST' if ch.last else ''}")
                    if len(asm.data) >= next_progress:
                        rate = len(asm.data) / max(time.monotonic() - t_start, 1e-6)
                        log.info(f"   {len(asm.data):6d} bytes, {len(asm.seqs)} chunks, {rate / 1024:.1f} KB/s")
                        next_progress += 4096
                elif st.state == 3:
                    ok = asm.checksum_ok()
                    if ok is False:
                        raise TransferFailed(
                            f"The backup arrived damaged: camera checksum {asm.expected_sum:#06x}, ours {asm.sum16:#06x}.",
                            "Run backup again. If it repeats at the same size, share the log.")
                    if ok is None:
                        log.warn("The last chunk carried no checksum (no seq 0xFFFF chunk seen); can't verify the data.")
                    name, size = "backup.dat", None
                    if session.has(gatt.FILE_INFORMATION):
                        try:
                            name, size = gatt.parse_file_information(await session.read(gatt.FILE_INFORMATION))
                            name = name or "backup.dat"
                        except Exception as exc:
                            log.warn(f"couldn't read FILE_INFORMATION: {describe_exception(exc)}")
                    data = bytes(asm.data)
                    if size and 0 < size < len(data):  # FujiBackup.swift:84
                        log.info(f"   trimming to the reported size {size} (received {len(data)})")
                        data = data[:size]
                    elif size and size > len(data):
                        log.warn(f"camera reported {size} bytes but we received {len(data)}")
                    try:
                        await session.write(gatt.FILE_TRANSFER_RESULT, gatt.TRANSFER_RESULT_OK)
                    except Exception as exc:
                        log.warn(f"couldn't write FILE_TRANSFER_RESULT 03 00: {describe_exception(exc)}")
                    return BackupResult(name, data, size, asm.expected_sum, asm.sum16, ok, asm.seq_report(), len(asm.seqs),
                                        time.monotonic() - t_start, gatt.sniff_backup_header(data))
                else:
                    raise TransferFailed(f"The camera ended the transfer (state {st.state}, {hexs(value)}).",
                                         "Leave the camera's menus and playback, then retry.")
        except BaseException as exc:
            if session.is_connected:
                with contextlib.suppress(Exception):
                    await session.write(gatt.FILE_TRANSFER_RESULT, gatt.TRANSFER_RESULT_ERROR, timeout=3)
            if isinstance(exc, TransferFailed) and exc.partial is None:
                exc.partial = bytes(asm.data)
            elif isinstance(exc, LinkDropped):
                raise TransferFailed(exc.message, exc.hint, partial=bytes(asm.data)) from exc
            raise


async def _wait_backup_ready(session: Session, log: Log, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    busy_seen = False
    while True:
        remaining = deadline - time.monotonic()
        value = await session.next_value(gatt.BACKUP_STATE, max(remaining, 0))
        if value is None:
            break
        log.info(f"   BACKUP_STATE = {hexs(value)} ({gatt.decode_value('backup_state', value)})")
        if value[:1] == b"\x01":
            return True
        busy_seen = True
    if session.disconnected.is_set():
        raise LinkDropped("Bluetooth link dropped while waiting for the camera to prepare the backup.")
    if busy_seen:
        raise BackupBusy("The camera said it is busy (BACKUP_STATE 0).",
                         "Leave the camera's menus/playback, make sure no other app is connected, and retry.")
    # Deviation from FujiBackup.swift:45 (which gives up here): BACKUP_STATE is also readable (gatt-ad14d4.yaml:267-270),
    # so look once before giving up. Logged loudly because it's our inference.
    log.warn(f"No BACKUP_STATE indication within {timeout:.0f} s. Reading it directly (our fallback, not in the references).")
    try:
        value = await session.read(gatt.BACKUP_STATE)
    except Exception as exc:
        raise TransferFailed(f"No answer to the backup request ({describe_exception(exc)}).") from exc
    if value[:1] == b"\x01":
        log.warn("BACKUP_STATE reads 1 (ready). Continuing.")
        return True
    raise TransferFailed(f"No answer to the backup request (BACKUP_STATE reads {hexs(value)}).",
                         "Is the camera in a menu or playback? Are we registered? Try `pair`, then backup again.")


def save_backup(out_dir: Path, stem: str, result: BackupResult) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{stem}.bin"
    path.write_bytes(result.data)
    return path


async def backup_flow(transport: Transport, log: Log, find: FindOptions, opts: BackupOptions,
                      session: Optional[Session] = None) -> dict:
    """Connect, identify, download the settings file `runs` times, save, compare. With `session`, reuse it
    (used by restore for its same-session safety backup)."""
    stamp = timestamp()
    own = session is None
    meta: dict = {"tool": "fuji_ble backup", "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "transport": transport.describe(),
                  "runs": [], "deterministic": None, "difference": None, "errors": []}
    meta_path = find.out_dir / f"backup-{stamp}.json"
    results: list[BackupResult] = []
    try:
        if own:
            sighting = await find_camera(transport, log, find)
            session = await open_session(transport, log, sighting, find)
        assert session is not None
        meta["camera"] = session.sighting.to_json()
        if opts.identify:
            try:
                meta["identify"] = (await identify(session, log, opts.client_name, pairing_attempts=5,
                                                   token=remembered_token(find.out_dir, session.sighting),
                                                   identification_number=remembered_identification(find.out_dir, session.sighting))).__dict__
            except NotPaired:
                raise
            except Exception as exc:
                if isinstance(exc, LinkDropped):
                    raise
                meta["errors"].append({"step": "identify", "error": describe_exception(exc)})
                log.warn(f"identify failed ({describe_exception(exc)}); trying the backup anyway")
        meta["identity"] = await read_identity(session, log)
        for run in range(1, opts.runs + 1):
            label = f" (run {run} of {opts.runs})" if opts.runs > 1 else ""
            if run > 1:
                await asyncio.sleep(1.5)  # let the camera settle after FILE_TRANSFER_RESULT
            try:
                res = await backup_once(session, log, opts, label)
            except TransferFailed as exc:
                if exc.partial:
                    p = find.out_dir / f"backup-{stamp}-run{run}.partial.bin"
                    find.out_dir.mkdir(parents=True, exist_ok=True)
                    p.write_bytes(exc.partial)
                    log.info(f"Saved the {len(exc.partial)} bytes received so far to {p}")
                meta["errors"].append({"step": f"run {run}", "error": exc.message})
                if results:  # keep run 1's file; report run 2's failure
                    log.warn(f"run {run} failed: {exc.message}")
                    break
                raise
            stem = f"backup-{stamp}" if run == 1 else f"backup-{stamp}-run{run}"
            path = save_backup(find.out_dir, stem, res)
            results.append(res)
            m = res.meta() | {"file": str(path)}
            meta["runs"].append(m)
            hdr = res.header
            log.plain("")
            log.plain(f"Backup{label}: {path}")
            log.plain(f"  name {res.name!r}, {len(res.data)} bytes (camera said {res.reported_size}), sha256 {res.sha256}")
            log.plain(f"  checksum {'OK' if res.checksum_ok else 'not checked' if res.checksum_ok is None else 'BAD'}, "
                      f"{res.chunks} chunks ({res.seq_report}), {res.seconds:.1f} s")
            if hdr.get("magic_ok"):
                log.plain(f"  header: FUJIFILMX-BACKUP v{hdr.get('version')} model {hdr.get('model')!r} serial {hdr.get('serial')!r}"
                          f" payload {hdr.get('payload_start'):#x}+{hdr.get('payload_len')} "
                          f"({'consistent' if hdr.get('length_consistent') else 'INCONSISTENT'} with size)")
            else:
                log.plain(f"  header: no FUJIFILMX-BACKUP magic (first bytes {hexs(res.data[:16])}). New container? Keep the file.")
            log.plain("")
        if len(results) >= 2:
            diff = gatt.first_difference(results[0].data, results[1].data)
            meta["deterministic"] = diff is None
            meta["difference"] = diff
            if diff is None:
                log.plain("DETERMINISTIC: both runs are byte-identical.")
            else:
                log.plain(f"NOT deterministic: {diff['differing_bytes']} byte(s) differ, first at {diff['first_offset_hex']} "
                          f"(offsets {', '.join(diff['offsets_hex'][:12])}{' ...' if len(diff['offsets_hex']) > 12 else ''}). "
                          "Likely counters; helios saw volatile counters at 0x0CC/0x0D0 and 0x584 on an X-T5.")
        return meta
    finally:
        if session is not None:
            meta["trace_ops"] = len(session.ops)
            if own:
                await session.close()
        if meta.get("camera") is not None:
            find.out_dir.mkdir(parents=True, exist_ok=True)
            meta_path.write_text(json.dumps(meta, indent=2) + "\n")
            log.info(f"Saved {meta_path}")


# ============================================================================================
# watch
# ============================================================================================


@dataclass
class WatchOptions:
    identify: bool = True
    client_name: str = DEFAULT_CLIENT_NAME
    duration: float = 0.0  # 0 = until Ctrl-C
    poll: float = 0.0  # re-read readable chars every N s and print changes
    include_secrets: bool = False


async def watch_flow(transport: Transport, log: Log, find: FindOptions, opts: WatchOptions) -> Path:
    out_path = find.out_dir / f"watch-{timestamp()}.jsonl"
    find.out_dir.mkdir(parents=True, exist_ok=True)
    sighting = await find_camera(transport, log, find)
    session = await open_session(transport, log, sighting, find)
    events = open(out_path, "w", encoding="utf-8")
    count = 0
    try:
        if opts.identify:
            try:
                await identify(session, log, opts.client_name, pairing_attempts=5, token=remembered_token(find.out_dir, sighting),
                               identification_number=remembered_identification(find.out_dir, sighting))
            except Exception as exc:
                if isinstance(exc, LinkDropped):
                    raise
                log.warn(f"identify failed ({describe_exception(exc)}); watching anyway")

        def on_event(uuid: str, value: bytes) -> None:
            nonlocal count
            count += 1
            print_notification(log, uuid, value, opts.include_secrets)
            events.write(json.dumps({"t": round(log.elapsed(), 4), "uuid": uuid, "name": gatt.char_info(uuid).name
                                     if gatt.char_info(uuid) else None, "hex": value.hex()}) + "\n")
            events.flush()

        session.listeners.append(on_event)
        notifying = [u for u in session.chars if {"notify", "indicate"} & set(session.props(u))]
        with log.step(f"Subscribing to all {len(notifying)} notify/indicate characteristics"):
            ok, failed = await subscribe_many(session, notifying, log, quiet=False)
        if failed:
            log.warn(f"couldn't subscribe to {[gatt.short_uuid(u) for u in failed]}")
        last: dict[str, bytes] = {}
        readable = [u for u in session.chars if "read" in session.props(u)]
        log.plain("")
        log.plain(f"Watching {len(ok)} characteristics{' and polling ' + str(len(readable)) + ' readable ones every ' + str(opts.poll) + ' s' if opts.poll else ''}."
                  " Now change things on the camera (menus, dials, power). Ctrl-C to stop.")
        log.plain("")
        deadline = time.monotonic() + opts.duration if opts.duration > 0 else None
        next_poll = time.monotonic()
        while deadline is None or time.monotonic() < deadline:
            if session.disconnected.is_set():
                raise LinkDropped(f"The camera closed the Bluetooth link ({session.disconnect_reason}).",
                                  "Turning the camera off or letting it sleep does this. Wake it and run watch again.")
            if opts.poll and time.monotonic() >= next_poll:
                for u in readable:
                    try:
                        v = await session.read(u, quiet=True)
                    except Exception:
                        continue
                    if u in last and last[u] != v:
                        log.info(f"   CHANGED {gatt.char_label(u)}: {hexs(last[u], 24)} -> {hexs(v, 24)} "
                                 f"[{gatt.decode_char(u, v, reveal_secrets=opts.include_secrets)}]")
                        events.write(json.dumps({"t": round(log.elapsed(), 4), "uuid": u, "poll": True, "hex": v.hex()}) + "\n")
                    last[u] = v
                next_poll = time.monotonic() + opts.poll
            await asyncio.sleep(0.2)
    finally:
        events.close()
        await session.close()
        log.info(f"{count} notifications. Saved {out_path}")
    return out_path


# ============================================================================================
# restore (EXPERIMENTAL: dry-run plan by default, live path gated and mostly TODO)
# ============================================================================================

#: Characteristics with a documented meaning that must never be used as a restore request.
NOT_A_RESTORE_REQUEST = {gatt.BACKUP_REQUEST, gatt.TIME, gatt.FUNCTION_LAUNCH, gatt.SHUTTER, gatt.SECURE_STATUS, gatt.CLIENT_NAME,
                         gatt.GEOTAG, gatt.PAIRING_TOKEN, gatt.FILE_TRANSFER_RESULT, gatt.FILE_TRANSFER_INDEX,
                         gatt.FILE_PARTIAL_SIZE, gatt.FILE_PARTIAL_DATA, gatt.FILE_INFORMATION}
#: BACKUP_REQUEST values with a known meaning (1 settings, 2 IPTC). A capture may show another value starting a restore.
BACKUP_REQUEST_KNOWN = {"0100", "0200"}

RESTORE_TODOS = [
    ("R1", "Which characteristic and value start a restore. Candidates (write-only, unexplained, service 6514eb81): "
           + ", ".join(gatt.short_uuid(u) for u in gatt.RESTORE_REQUEST_CANDIDATES)
           + ". By analogy BACKUP_REQUEST is f14e7a88 = 01 00. Decide from a PacketLogger capture of a restore."),
    ("R2", "How the camera says 'ready to receive'. By analogy BACKUP_STATE 11438c83 = 1; unexplained indications "
           + ", ".join(gatt.short_uuid(u) for u in gatt.RESTORE_STATE_CANDIDATES) + " are candidates."),
    ("R3", "Whether the client writes FILE_INFORMATION (c922ac69, read+write) first with name[40] + u32 size."),
    ("R4", "Per-chunk flow control: does the camera notify FILE_TRANSACTION_STATE after each written chunk, "
           "or does the client pace itself? Write with response assumed."),
    ("R5", "Upload framing assumed to mirror download: u16 seq (0,1,2,...), u32 len, data; last frame seq 0xFFFF "
           "carrying the u16 sum of all data bytes. Chunk size 120 assumed (max 242 by the 248-byte char)."),
    ("R6", "Completion: who writes FILE_TRANSFER_RESULT 68052e8a and with what (03 00 assumed); whether the camera "
           "reboots/applies and needs a power-cycle (USB restore does, docs/FUJIFILM-PROTOCOL.md §2.10)."),
    ("R7", "The file's own checksum (X100VI: u16 at 0x108, docs/FUJIFILM-PROTOCOL.md §4.6). "
           "Until then, only restore UNEDITED backups from this same camera."),
    ("R8", "Clean state: USB restore must be the first operation after power-cycle; an unsaved menu overlay or "
           "stale session gets 0x200F (docs/FUJIFILM-PROTOCOL.md §2.10). Assume the same over BLE: power-cycle the camera first."),
]


@dataclass
class RestoreOptions:
    file: Path = Path()
    dry_run: bool = True
    i_understand: bool = False
    chunk_size: Optional[int] = None  # overrides the profile
    request_char: Optional[str] = None  # overrides the profile
    request_value: Optional[str] = None  # hex
    show_all: bool = False
    client_name: str = DEFAULT_CLIENT_NAME
    allow_other_body: bool = False
    profile: Optional[RestoreProfile] = None  # default: mirrored-from-download guesses
    chunk_ack_timeout: Optional[float] = None  # first-frame ack wait (profile: 2 s in auto pacing)
    request_wait: Optional[float] = None
    final_timeout: Optional[float] = None
    verify_after: bool = True  # download the file again after the restore and compare
    # "profile": the capture-derived / mirrored RestoreProfile engine (default here, for old callers and tests).
    # "standard": the documented restore (standard_restore, docs/FUJIFILM-PROTOCOL.md §3.7); the CLI uses it unless
    # --profile/--request-char is given.
    protocol: str = "profile"
    pre_wait: float = 0.0  # pause after discovery before a backup/restore (the CLI uses 3 s)


def effective_profile(opts: RestoreOptions) -> RestoreProfile:
    """The profile with command-line overrides applied (a copy; the caller's object is left alone)."""
    p = RestoreProfile.from_dict(opts.profile.to_dict()) if opts.profile else RestoreProfile()
    if opts.request_char:
        p.request_char = gatt.normalize_uuid(opts.request_char)
        p.request_value = (opts.request_value or "").replace(" ", "")
    if opts.chunk_size:
        p.chunk_size = opts.chunk_size
    if opts.request_wait is not None:
        p.request_wait = opts.request_wait
        p.ready_timeout = min(p.ready_timeout, max(opts.request_wait, 0.05)) if p.ready_char is None else p.ready_timeout
    if opts.final_timeout is not None:
        p.complete_timeout = opts.final_timeout
    p.validate()
    return p


@dataclass
class PlannedOp:
    op: str  # write | subscribe | wait | read | note
    char: Optional[str]
    data: bytes = b""
    note: str = ""
    status: str = "mirrored"  # mirrored (from the documented backup) | INFERRED | CAPTURED | TODO
    kind: str = ""  # request | ready | listen | setup | frame | complete | finish

    def render(self) -> str:
        label = gatt.char_label(self.char) if self.char else ""
        if self.op == "write":
            body = f"WRITE {label} <- {hexs(self.data, 40)} ({len(self.data)} B)"
        elif self.op == "subscribe":
            body = f"SUBSCRIBE {label}"
        elif self.op == "wait":
            body = f"WAIT {label}" + (f" for {hexs(self.data)}.." if self.data else "")
        elif self.op == "read":
            body = f"READ {label}"
        else:
            body = "NOTE"
        return f"[{self.status:8s}] {body}" + (f"  -- {self.note}" if self.note else "")


def build_restore_plan(data: bytes, opts: RestoreOptions, name: str = "backup.dat") -> list[PlannedOp]:
    p = effective_profile(opts)
    st = p.status
    frames = p.frames(data)
    plan: list[PlannedOp] = [
        PlannedOp("note", None, note="connect + identify (secure status ack or basic token, + client name), as for backup"),
        PlannedOp("note", None, note="SAFETY: download a fresh backup over the same connection first; refuse if it fails"),
    ]
    for u in p.subscribe:
        plan.append(PlannedOp("subscribe", u, note="log anything it says" if u in gatt.RESTORE_STATE_CANDIDATES else "",
                              status=st if p.captured else ("mirrored" if u == gatt.FILE_TRANSACTION_STATE else "INFERRED")))
    if p.request_char:
        src = "from the capture" if p.captured and not opts.request_char else "given on the command line"
        plan.append(PlannedOp("write", p.request_char, bytes.fromhex(p.request_value or ""), kind="request",
                              note=f"restore request {src} (R1)", status=st if not opts.request_char else "INFERRED"))
    else:
        plan.append(PlannedOp("note", None, note="<TODO R1: restore request characteristic + value. NOTHING is invented here.>",
                              status="TODO"))
    if p.ready_char:
        plan.append(PlannedOp("wait", p.ready_char, bytes.fromhex(p.ready_value_prefix or ""), kind="ready",
                              note=f"ready signal, up to {p.ready_timeout:g} s; no frame is sent without it (R2)", status=st))
    else:
        plan.append(PlannedOp("wait", None, kind="listen",
                              note=f"<TODO R2: 'ready to receive' signal; we log every notification for {p.request_wait:g} s>",
                              status="TODO"))
    for char, value, note in p.setup_writes(data, name):
        plan.append(PlannedOp("write", char, value, kind="setup", note=f"{note} (R3)", status=st))
    for i, frame in enumerate(frames):
        last = i == len(frames) - 1
        plan.append(PlannedOp("write", gatt.FILE_PARTIAL_DATA, frame, kind="frame", status=st,
                              note=f"frame {i + 1}/{len(frames)}" + (" (last, u16 sum)" if last and p.trailer_sum else "") + " (R4/R5)"))
    complete = PlannedOp("wait", p.complete_char, bytes.fromhex(p.complete_value_prefix or ""), kind="complete",
                         note="completion state (R6)", status=st if p.captured else "TODO") if p.complete_char else None
    finish = PlannedOp("write", p.finish_char, bytes.fromhex(p.finish_value or ""), kind="finish",
                       note="finish (R6)" + ("" if p.captured else ": mirrors backup's 03 00"), status=st) if p.finish_char else None
    for op in ([complete, finish] if p.finish_after_complete else [finish, complete]):
        if op is not None:
            plan.append(op)
    plan.append(PlannedOp("note", None, note="VERIFY: download the file again and compare; power-cycle and check C1-C7 "
                                             "(a stale session can accept a transfer and quietly not commit it)"))
    return plan


def print_restore_plan(log: Log, plan: list[PlannedOp], data: bytes, opts: RestoreOptions, header: dict) -> None:
    p = effective_profile(opts)
    frames = [op for op in plan if op.kind == "frame"]
    log.plain("")
    log.plain("RESTORE PLAN (EXPERIMENTAL). Each line says where it comes from:")
    log.plain("  mirrored = copied from the documented backup flow; INFERRED = our guess; CAPTURED = from a restore capture;"
              " TODO = unknown, not sent.")
    log.plain(f"  File: {opts.file} ({len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}, u16 sum {gatt.byte_sum16(data):#06x})")
    if header.get("magic_ok"):
        log.plain(f"  Header: FUJIFILMX-BACKUP model {header.get('model')!r} serial {header.get('serial')!r}")
    else:
        log.plain("  Header: NO FUJIFILMX-BACKUP magic. A live restore will refuse this file.")
    log.plain(f"  Frames: {len(frames)} x FILE_PARTIAL_DATA at {p.chunk_size} data bytes each")
    for line in p.describe():
        log.plain("  " + line)
    log.plain("")
    shown = 0
    for op in plan:
        if op.kind == "frame" and not opts.show_all:
            shown += 1
            if 3 < shown <= len(frames) - 2:
                if shown == 4:
                    log.plain(f"  ... {len(frames) - 5} more frames (use --show-all, or see the plan file) ...")
                continue
        log.plain("  " + op.render())
    if not p.captured:
        log.plain("")
        log.plain("Unknowns (TODO), to settle with a PacketLogger capture of a backup -> restore:")
        for code, text in RESTORE_TODOS:
            log.plain(f"  {code}: {text}")


def restore_gate(p: RestoreProfile, opts: RestoreOptions, header: dict, log: Log) -> None:
    """Every refusal that doesn't need the radio."""
    if not opts.i_understand:
        raise RestoreRefused("Refusing a live restore without --i-understand-this-is-experimental.",
                             "This writes every camera setting at once over an unverified protocol.")
    if not header.get("magic_ok"):
        raise RestoreRefused("The file has no FUJIFILMX-BACKUP header; refusing to send it.")
    if not (p.request_char and p.request_value):
        raise RestoreRefused(
            "The restore request is unknown (TODO R1), so there is nothing safe to send.",
            "Capture a restore with PacketLogger, then pass --profile from `restore-profile`, or "
            "--request-char <uuid> --request-value <hex> read off the capture.")
    req = p.request_char
    if req in NOT_A_RESTORE_REQUEST:
        captured_backup_variant = req == gatt.BACKUP_REQUEST and p.captured and not opts.request_char \
            and (p.request_value or "").lower() not in BACKUP_REQUEST_KNOWN
        if not captured_backup_variant:
            raise RestoreRefused(f"{gatt.char_label(req)} has a known, different meaning; it is not a restore request.")
        log.warn(f"The capture starts the restore with BACKUP_REQUEST = {p.request_value} (not 01 00/02 00). Using it.")
    elif req not in gatt.RESTORE_REQUEST_CANDIDATES and not p.captured:
        log.warn(f"{gatt.char_label(req)} is not one of the historical restore-request candidates. Proceeding only because you named it.")


def standard_restore_gate(opts: RestoreOptions, header: dict) -> None:
    if not opts.i_understand:
        raise RestoreRefused("Refusing a live restore without --i-understand-this-is-experimental.",
                             "This writes every camera setting at once. Rehearse with --fake fw110 first.")
    if not header.get("magic_ok"):
        raise RestoreRefused("The file has no FUJIFILMX-BACKUP header; refusing to send it.")
    if not header.get("length_consistent", True):
        raise RestoreRefused("The file's header length doesn't match its size; refusing to send it.")


def print_standard_plan(log: Log, plan: list[PlannedOp], data: bytes, opts: RestoreOptions, header: dict) -> None:
    frames = [op for op in plan if op.kind == "frame"]
    log.plain("")
    log.plain("RESTORE PLAN: the standard Bluetooth settings restore (docs/FUJIFILM-PROTOCOL.md §3.7).")
    log.plain(f"  File: {opts.file} ({len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}, u16 sum {gatt.byte_sum16(data):#06x})")
    if header.get("magic_ok"):
        log.plain(f"  Header: FUJIFILMX-BACKUP model {header.get('model')!r} serial {header.get('serial')!r}")
    else:
        log.plain("  Header: NO FUJIFILMX-BACKUP magic. A live restore will refuse this file.")
    log.plain(f"  Frames: {len(frames)} x FILE_PARTIAL_DATA (u16 seq, u32 size, {gatt.RESTORE_CHUNK} data bytes, u16 trailer)")
    log.plain("")
    shown = 0
    for op in plan:
        if op.kind == "frame" and not opts.show_all:
            shown += 1
            if 3 < shown <= len(frames) - 2:
                if shown == 4:
                    log.plain(f"  ... {len(frames) - 5} more frames (use --show-all, or see the plan file) ...")
                continue
        log.plain("  " + op.render())


async def restore_flow(transport: Transport, log: Log, find: FindOptions, opts: RestoreOptions) -> dict:
    path = opts.file
    if not path.exists():
        raise RestoreRefused(f"No such file: {path}")
    data = path.read_bytes()
    if not 0 < len(data) <= 256 * 1024:
        raise RestoreRefused(f"{path} is {len(data)} bytes; a settings backup is 33-71 KB.")
    header = gatt.sniff_backup_header(data)
    use_standard = opts.protocol == "standard" and opts.profile is None and not opts.request_char
    if opts.protocol not in ("standard", "profile"):
        raise RestoreRefused(f"Unknown restore protocol {opts.protocol!r} (standard or profile).")
    p = effective_profile(opts)
    if use_standard:
        plan = standard_restore_plan(data)
        print_standard_plan(log, plan, data, opts, header)
    else:
        plan = build_restore_plan(data, opts)
        print_restore_plan(log, plan, data, opts, header)
    stamp = timestamp()
    plan_path = find.out_dir / f"restore-plan-{stamp}.jsonl"
    find.out_dir.mkdir(parents=True, exist_ok=True)
    with open(plan_path, "w") as f:
        for op in plan:
            f.write(json.dumps({"status": op.status, "op": op.op, "kind": op.kind, "char": op.char, "hex": op.data.hex(),
                                "note": op.note}) + "\n")
    log.info(f"Full plan (every frame) saved to {plan_path}")
    report: dict = {"file": str(path), "size": len(data), "plan": str(plan_path), "dry_run": opts.dry_run,
                    "protocol": "standard" if use_standard else "profile", **({} if use_standard else {"profile": p.to_dict()})}

    if opts.dry_run:
        log.plain("")
        log.plain("DRY RUN: nothing was sent to the camera. (Live mode needs --no-dry-run "
                  "--i-understand-this-is-experimental" + (")." if use_standard else " and a restore request from a capture.)"))
        return report

    if use_standard:
        standard_restore_gate(opts, header)
    else:
        restore_gate(p, opts, header, log)
    sighting = await find_camera(transport, log, find)
    session = await open_session(transport, log, sighting, find)
    try:
        await identify(session, log, opts.client_name, pairing_attempts=5, token=remembered_token(find.out_dir, sighting),
                       identification_number=remembered_identification(find.out_dir, sighting))
        # Same-session safety backup: refuse to write unless we hold a fresh copy of what's on the camera now.
        with log.step("SAFETY BACKUP over this same connection (required before any restore write)"):
            safety = await backup_flow(transport, log, find, BackupOptions(identify=False, runs=1, client_name=opts.client_name),
                                       session=session)
        if not safety.get("runs"):
            raise RestoreRefused("The safety backup failed, so the restore is refused.")
        safety_run = safety["runs"][0]
        cam_hdr = safety_run.get("header", {})
        report["safety_backup"] = safety_run
        if not opts.allow_other_body and (cam_hdr.get("model"), cam_hdr.get("serial")) != (header.get("model"), header.get("serial")):
            raise RestoreRefused(
                f"The file is from {header.get('model')} {header.get('serial')!r} but this camera is "
                f"{cam_hdr.get('model')} {cam_hdr.get('serial')!r}.", "Restore only a backup taken from this same camera.")
        if safety_run.get("sha256") == hashlib.sha256(data).hexdigest():
            log.info("The camera already holds exactly this file (same SHA-256). Restoring it anyway proves the path.")
        log.warn("LIVE RESTORE STARTING. Watch the camera screen.")
        if use_standard:
            if opts.pre_wait > 0:
                await asyncio.sleep(opts.pre_wait)
            res = await standard_restore(session, log, data)
            report["sent"] = True
            report["standard"] = res.to_json()
            report["final_transaction_state"] = res.final_hex
            log.plain("")
            log.plain(f"Upload sent: {res.frames_sent}/{res.frames_total} frames in {res.seconds:.1f} s; camera "
                      + ("reported file received (state 3), we wrote transfer result 03 00." if res.camera_said_done else
                         "never reported file received (verify before trusting it)."))
        else:
            final = await _execute_restore(session, log, plan, p, opts)
            report["sent"] = True
            report["final_transaction_state"] = final.hex() if final else None
            log.plain("")
            if final is None:
                log.plain("Upload sent, but the camera gave NO completion signal (R6). Assume it was NOT applied until proven.")
            else:
                log.plain(f"Upload sent; the camera's last transfer state was {hexs(final)}.")
        if opts.verify_after and session.is_connected:
            report["verify"] = await _verify_after_restore(session, log, find, opts, data)
        log.plain("Prove it: power-cycle the camera, then check C1-C7 on the camera, and over USB:\n"
                  "  dialin-cam settings-get  +  python -m fuji_ble.correlate diff <restored file> <new file>\n"
                  "(expect only counter bytes to differ).")
        return report
    finally:
        report["trace"] = session.ops
        await session.close()
        (find.out_dir / f"restore-{stamp}.json").write_text(json.dumps(report, indent=2, default=str) + "\n")


async def _verify_after_restore(session: Session, log: Log, find: FindOptions, opts: RestoreOptions, data: bytes) -> dict:
    """Download the camera's file again over the same link and compare with what we sent. Best effort: a camera
    that reboots to apply drops the link, which is reported, not raised."""
    await asyncio.sleep(1.5)
    try:
        res = await backup_once(session, log, BackupOptions(identify=False, runs=1, client_name=opts.client_name),
                                " (post-restore check)")
    except FujiBleError as exc:
        log.warn(f"post-restore download failed ({exc.message}); power-cycle and run `backup`, then compare.")
        return {"ok": None, "error": exc.message}
    diff = gatt.first_difference(res.data, data)
    if diff is None:
        log.plain("POST-RESTORE CHECK: the camera now serves exactly the file we sent.")
    else:
        log.plain(f"POST-RESTORE CHECK: {diff['differing_bytes']} byte(s) differ from what we sent, first at "
                  f"{diff['first_offset_hex']} ({', '.join(diff['offsets_hex'][:8])}). Counters are expected; slot bytes are not.")
    return {"ok": diff is None, "difference": diff, "sha256": res.sha256}


def _prefix_ok(value: Optional[bytes], prefix: bytes) -> bool:
    return value is not None and value[: len(prefix)] == prefix


async def _execute_restore(session: Session, log: Log, plan: list[PlannedOp], p: RestoreProfile,
                           opts: RestoreOptions) -> Optional[bytes]:
    """Run the plan. Pacing (R4): `ack` waits for p.ack_char after every frame, `fixed` sleeps p.gap_ms, `auto` waits
    up to chunk_ack_timeout after the first frame and keeps doing whatever the camera did."""
    for op in plan:
        if op.op == "subscribe" and op.char:
            await session.subscribe(op.char)
    session.listeners.append(lambda u, v: print_notification(log, u, v))
    acks: Optional[bool] = {"ack": True, "fixed": False}.get(p.pacing)
    first_ack_wait = opts.chunk_ack_timeout if opts.chunk_ack_timeout is not None else 2.0
    final: Optional[bytes] = None
    last_ack: Optional[bytes] = None
    sent = 0
    frames = sum(1 for op in plan if op.kind == "frame")
    for op in plan:
        if op.op == "write" and op.char:
            if op.kind == "frame":
                if sent == 0:
                    for stale in session.drain(p.ack_char):
                        log.info(f"   (before the first frame the camera sent {gatt.char_label(p.ack_char)} {hexs(stale)}; not an ack)")
                await session.write(op.char, op.data, quiet=True, response=p.frame_with_response)
                sent += 1
                if acks is None:
                    ack = await session.next_value(p.ack_char, first_ack_wait)
                    acks = ack is not None
                    last_ack = ack
                    log.info(f"   first frame {'acknowledged: ' + hexs(ack) if ack else f'not acknowledged within {first_ack_wait} s; pacing {p.gap_ms:g} ms per frame'}")
                elif acks:
                    ack = await session.next_value(p.ack_char, max(p.ack_timeout, first_ack_wait))
                    if ack is None:
                        raise TransferFailed(f"The camera stopped acknowledging after frame {sent}/{frames}.")
                    last_ack = ack
                    log.detail(f"frame {sent}: {gatt.char_label(p.ack_char)} {hexs(ack)}")
                else:
                    await asyncio.sleep(p.gap_ms / 1000)
                if sent % 40 == 0:
                    log.info(f"   {sent}/{frames} frames sent")
            else:
                await session.write(op.char, op.data, response=p.request_with_response if op.kind == "request" else True)
        elif op.op == "wait":
            if op.kind == "listen":
                log.info(f"   listening {p.request_wait:g} s for the camera's answer to the restore request (R2) ...")
                await asyncio.sleep(p.request_wait)
            elif op.kind == "ready":
                deadline = time.monotonic() + p.ready_timeout
                got = None
                while time.monotonic() < deadline:
                    v = await session.next_value(op.char, deadline - time.monotonic())
                    if v is None:
                        break
                    log.info(f"   {gatt.char_label(op.char)} = {hexs(v)}")
                    if _prefix_ok(v, op.data):
                        got = v
                        break
                if got is None:
                    raise TransferFailed(f"The camera never said it was ready ({gatt.char_label(op.char)} starting "
                                         f"{hexs(op.data) or 'any'} within {p.ready_timeout:g} s). Nothing was uploaded.",
                                         "Check the request against the capture; is the camera in a menu or playback?")
            elif op.kind == "complete":
                seen: list[bytes] = []
                if acks and op.char == p.ack_char and last_ack is not None and sent == frames:
                    seen.append(last_ack)  # the last frame's acknowledgement may already be the verdict
                if not (seen and (not op.data or _prefix_ok(seen[-1], op.data))):
                    deadline = time.monotonic() + p.complete_timeout
                    while time.monotonic() < deadline:
                        v = await session.next_value(op.char, deadline - time.monotonic())
                        if v is None:
                            break
                        seen.append(v)
                        if _prefix_ok(v, op.data):
                            break
                        log.info(f"   {gatt.char_label(op.char)} = {hexs(v)} (not the completion value yet)")
                final = seen[-1] if seen else None
                log.info(f"   final transaction state: {hexs(final) if final else f'none within {p.complete_timeout:g} s'}")
                if final is not None and op.data and not _prefix_ok(final, op.data):
                    raise TransferFailed(f"The camera ended with {hexs(final)}, not the completion value {hexs(op.data)}.",
                                         "It probably refused the file (checksum, other body, not a clean state).")
    return final


# ============================================================================================
# Standard restore (docs/FUJIFILM-PROTOCOL.md §3.7), step for step.
# This replaces the capture-derived profile when protocol="standard" (the CLI default).
# ============================================================================================

RESTORE_CHARS: tuple[str, ...] = (
    gatt.RESTORE_REQUEST, gatt.RESTORE_STATE, gatt.FILE_PARTIAL_SIZE, gatt.FILE_TRANSFER_INDEX, gatt.FILE_INFORMATION,
    gatt.FILE_PARTIAL_DATA, gatt.FILE_TRANSACTION_STATE, gatt.FILE_TRANSFER_RESULT,
)


class RestoreBusy(TransferFailed):
    exit_code = 5


class RestoreRejected(TransferFailed):
    exit_code = 5


@dataclass
class StandardRestoreResult:
    frames_sent: int
    frames_total: int
    final_state: Optional[int]  # last FILE_TRANSACTION_STATE state (3 = file received)
    final_hex: Optional[str]
    result_written: Optional[str]  # what we wrote to FILE_TRANSFER_RESULT (0300 on success)
    seconds: float
    camera_said_done: bool

    def to_json(self) -> dict:
        return dict(self.__dict__)


def standard_restore_plan(data: bytes, name: str = gatt.RESTORE_FILE_NAME) -> list[PlannedOp]:
    """The writes and waits of the standard restore, for the dry run. Status SPEC = docs/FUJIFILM-PROTOCOL.md §3.7."""
    frames = gatt.restore_frames(data)
    st = "SPEC"
    plan = [
        PlannedOp("note", None, note="connect + identify (pairing key or identification number, client name), as for backup",
                  status=st),
        PlannedOp("note", None, note="SAFETY: download a fresh backup over the same connection first; refuse if it fails"),
        PlannedOp("subscribe", gatt.FILE_TRANSACTION_STATE, status=st, note="transfer progress"),
        PlannedOp("subscribe", gatt.RESTORE_STATE, status=st),
        PlannedOp("write", gatt.RESTORE_REQUEST, gatt.RESTORE_REQUEST_SETTINGS, kind="request", status=st,
                  note="restore request 1 = settings"),
        PlannedOp("wait", gatt.RESTORE_STATE, b"\x01\x00", kind="ready", status=st,
                  note=f"RESTORE_STATE 1 = ready within {gatt.RESTORE_STATE_TIMEOUT:g} s (0 = busy -> cancel)"),
        PlannedOp("write", gatt.FILE_PARTIAL_SIZE, gatt.u32le(gatt.RESTORE_CHUNK), kind="setup", status=st, note="u32 120"),
        PlannedOp("write", gatt.FILE_TRANSFER_INDEX, gatt.u32le(0), kind="setup", status=st, note="u32 0"),
        PlannedOp("write", gatt.FILE_INFORMATION, gatt.build_restore_file_information(len(data), name), kind="setup",
                  status=st, note=f"name[40] {name!r} + u32 size {len(data)}"),
        PlannedOp("wait", gatt.FILE_TRANSACTION_STATE, b"\x01\x00", kind="start", status=st,
                  note=f"transfer started (state 1) within {gatt.RESTORE_ACK_TIMEOUT:g} s"),
    ]
    for i, fr in enumerate(frames):
        last = i == len(frames) - 1
        plan.append(PlannedOp("write", gatt.FILE_PARTIAL_DATA, fr, kind="frame", status=st,
                              note=f"frame {i + 1}/{len(frames)}" + (" (seq 0xFFFF; sum in data + trailer)" if last else "")
                              + "; then wait FILE_TRANSACTION_STATE: 2 next, 3 done, 0 error"))
    plan.append(PlannedOp("write", gatt.FILE_TRANSFER_RESULT, gatt.RESULT_END, kind="finish", status=st,
                          note="transfer result 03 00 after state 3 (00 00 after state 0, 02 00 on anything else)"))
    plan.append(PlannedOp("note", None, note="VERIFY: download the file again and compare; power-cycle and check C1-C7"))
    return plan


async def standard_restore(session: Session, log: Log, data: bytes, *, name: str = gatt.RESTORE_FILE_NAME,
                       state_timeout: float = gatt.RESTORE_STATE_TIMEOUT,
                       ack_timeout: float = gatt.RESTORE_ACK_TIMEOUT,
                       min_mtu: int = gatt.RESTORE_MIN_MTU) -> StandardRestoreResult:
    """Upload a settings file with the standard restore (docs/FUJIFILM-PROTOCOL.md §3.7):
    1 subscribe FILE_TRANSACTION_STATE + RESTORE_STATE; 2 write RESTORE_REQUEST 01 00; 3 wait <=10 s for RESTORE_STATE,
    need 1 (ready); 4 write FILE_PARTIAL_SIZE u32 120, FILE_TRANSFER_INDEX u32 0, FILE_INFORMATION
    'backup.dat' + u32 size; 5 wait <=10 s for FILE_TRANSACTION_STATE 1 (started); 6 for each 128-byte frame
    (gatt.restore_frames): write with response, wait <=10 s for FILE_TRANSACTION_STATE: 2 -> next frame,
    3 -> write FILE_TRANSFER_RESULT 03 00 and finish, 0 -> write 00 00 and fail, anything else -> write 02 00 and fail.
    Every failure after the request writes FILE_TRANSFER_RESULT (cancel 02 00, or fail 00 00)."""
    for needed in RESTORE_CHARS:
        if not session.has(needed):
            raise Unsupported(f"This camera doesn't offer the Bluetooth settings restore (no {gatt.char_label(needed)}).",
                              "Run `python -m fuji_ble dump` and share the JSON.")
    mtu = getattr(session.client, "mtu_size", None)
    if isinstance(mtu, int) and mtu < min_mtu:
        raise TransferFailed(f"The Bluetooth link's MTU is {mtu}; a 128-byte restore frame needs at least {min_mtu} "
                             f"(we ask for {gatt.PREFERRED_MTU}).", "Reconnect; on a Pi raise the MTU in bluetoothd.")
    frames = gatt.restore_frames(data)
    t0 = time.monotonic()
    result_written: Optional[str] = None

    async def finish(value: bytes) -> None:
        nonlocal result_written
        if session.is_connected:
            with contextlib.suppress(Exception):
                await session.write(gatt.FILE_TRANSFER_RESULT, value, timeout=gatt.WRITE_TIMEOUT)
                result_written = value.hex()

    def state_of(v: bytes) -> tuple[int, int]:
        st = gatt.parse_transaction_state(v)
        seq = struct.unpack_from("<H", st.aux)[0] if len(st.aux) >= 2 else -1
        return st.state, seq

    with log.step("Restore: request"):
        await session.subscribe(gatt.FILE_TRANSACTION_STATE, required=True)
        await session.subscribe(gatt.RESTORE_STATE, required=True)
        for u in (gatt.FILE_TRANSACTION_STATE, gatt.RESTORE_STATE):
            for v in session.drain(u):
                log.detail(f"dropped stale {gatt.char_label(u)} {hexs(v)}")
        await session.write(gatt.RESTORE_REQUEST, gatt.RESTORE_REQUEST_SETTINGS)
        rs = await session.next_value(gatt.RESTORE_STATE, state_timeout)
        if rs is None:
            await finish(gatt.RESULT_CANCEL)
            if session.disconnected.is_set():
                raise LinkDropped("Bluetooth link dropped right after the restore request.")
            raise TransferFailed(f"No RESTORE_STATE answer within {state_timeout:g} s. Nothing was uploaded.",
                                 "Are we registered (basic bodies need the saved pairing key)? Run `pair`, then retry.")
        log.info(f"   RESTORE_STATE = {hexs(rs)}")
        if (gatt._u16(rs) if len(rs) >= 2 else rs[0]) != gatt.STATE_TRANSFERABLE:
            await finish(gatt.RESULT_CANCEL)
            raise RestoreBusy("The camera said it can't take a restore now (RESTORE_STATE 0). Nothing was uploaded.",
                              "Another function may be in use on the camera, or the battery is low. "
                              "Leave menus/playback, charge, retry.")
    with log.step(f"Restore: file information ({len(data)} bytes, {len(frames)} frames)"):
        try:
            await session.write(gatt.FILE_PARTIAL_SIZE, gatt.u32le(gatt.RESTORE_CHUNK))
            await session.write(gatt.FILE_TRANSFER_INDEX, gatt.u32le(0))
            for v in session.drain(gatt.FILE_TRANSACTION_STATE):
                log.detail(f"dropped stale transaction state {hexs(v)}")
            await session.write(gatt.FILE_INFORMATION, gatt.build_restore_file_information(len(data), name))
        except Exception as exc:
            await finish(gatt.RESULT_CANCEL)
            raise TransferFailed(f"The camera refused a restore setup write ({describe_exception(exc)}). Nothing was "
                                 "uploaded.") from exc
        v = await session.next_value(gatt.FILE_TRANSACTION_STATE, ack_timeout)
        if v is None or state_of(v)[0] != gatt.TS_START:
            await finish(gatt.RESULT_CANCEL)
            raise TransferFailed("The camera didn't report transfer started (state 1) after FILE_INFORMATION "
                                 f"({hexs(v) if v else f'nothing within {ack_timeout:g} s'}). Nothing was uploaded.")
    sent = 0
    final_state: Optional[int] = None
    final_hex: Optional[str] = None
    done = False
    with log.step("Restore: frames"):
        for i, frame in enumerate(frames):
            try:
                await session.write(gatt.FILE_PARTIAL_DATA, frame, quiet=True, timeout=gatt.WRITE_TIMEOUT + 5)
            except Exception as exc:
                await finish(gatt.RESULT_CANCEL)
                if session.disconnected.is_set():
                    raise LinkDropped(f"Bluetooth link dropped at frame {i + 1}/{len(frames)}.") from exc
                raise RestoreRejected(
                    f"The camera rejected frame {i + 1}/{len(frames)} ({describe_exception(exc)}).",
                    "The camera refuses files it considers incompatible (another body or firmware). "
                    "Restore only a file this body produced.") from exc
            sent += 1
            v = await session.next_value(gatt.FILE_TRANSACTION_STATE, ack_timeout)
            if v is None:
                await finish(gatt.RESULT_CANCEL)
                if session.disconnected.is_set():
                    raise LinkDropped(f"Bluetooth link dropped after frame {sent}/{len(frames)}.")
                raise TransferFailed(f"No acknowledgement within {ack_timeout:g} s after frame {sent}/{len(frames)}.")
            state, seq = state_of(v)
            final_state, final_hex = state, v.hex()
            log.detail(f"frame {sent}: state {state} ({gatt.TRANSACTION_STATE_NAMES.get(state, '?')}) seq {seq}")
            if sent % 50 == 0:
                log.info(f"   {sent}/{len(frames)} frames ({(time.monotonic() - t0):.0f} s)")
            if state == gatt.TS_TRANSFERRING:
                continue
            if state == gatt.TS_FILE_DONE:
                if sent < len(frames):
                    log.warn(f"The camera reported file received after {sent}/{len(frames)} frames (accepted as done).")
                await finish(gatt.RESULT_END)
                done = True
                break
            if state == gatt.TS_ERROR:
                await finish(gatt.RESULT_FAIL)
                raise RestoreRejected(f"The camera reported Error (state 0) after frame {sent}/{len(frames)}: it refused "
                                      "the file.", "Checksum or model/firmware mismatch. Restore an unedited file from this "
                                      "body first; check the edit's checksum.")
            await finish(gatt.RESULT_CANCEL)
            raise TransferFailed(f"Unexpected transfer state {hexs(v)} after frame {sent}/{len(frames)}.")
    if not done:
        log.warn("Every frame was acknowledged but the camera never reported file received (state 3). "
                 "Verify with a fresh backup.")
    with contextlib.suppress(Exception):
        for u in (gatt.RESTORE_STATE, gatt.FILE_TRANSACTION_STATE):
            await session.client.stop_notify(session._char(u))
            session.subscribed.discard(u)
    return StandardRestoreResult(sent, len(frames), final_state, final_hex, result_written, time.monotonic() - t0, done)


# ============================================================================================
# Wi-Fi activation (docs/FUJIFILM-PROTOCOL.md §3.8): FUNCTION_LAUNCH_REQUEST -> AP_STATE up -> join the camera's AP
# ============================================================================================


@dataclass
class WifiOptions:
    identify: bool = True
    client_name: str = DEFAULT_CLIENT_NAME
    function: int = gatt.FUNCTION_REMOTE  # 1 import, 3 in-camera viewing, 4 remote shooting
    timeout: float = 15.0
    hold: float = 0.0  # keep the Bluetooth link open this long after the AP is up (time to join Wi-Fi)
    include_secrets: bool = False


async def wifi_flow(transport: Transport, log: Log, find: FindOptions, opts: WifiOptions) -> dict:
    """Ask the camera to start its Wi-Fi access point and print what to join (docs/FUJIFILM-PROTOCOL.md §3.8):
    read the SSID (bf6dc9cf), CAMERA_WIFI_ADDRESS (49a12959, the BSSID) and, when the body has it, the passphrase
    (e809256a; absent on the basic profile, so the AP is open); write FUNCTION_LAUNCH_REQUEST u16; wait for
    AP_STATE 0x8001 (up). Then join that network (WPA2 only if a passphrase exists) and open PTP/IP."""
    sighting = await find_camera(transport, log, find)
    session = await open_session(transport, log, sighting, find)
    session.reveal_secrets = opts.include_secrets
    out: dict = {"function": opts.function, "function_name": gatt.FUNCTION_CODES.get(opts.function, "?")}
    try:
        if opts.identify:
            out["identify"] = (await identify(session, log, opts.client_name, token=remembered_token(find.out_dir, sighting),
                                              identification_number=remembered_identification(find.out_dir, sighting))).__dict__
        await session.subscribe(gatt.AP_STATE, required=True)
        ssid = gatt.decode_value("utf8", await session.read(gatt.CAMERA_SSID)).strip("'") if session.has(gatt.CAMERA_SSID) else ""
        mac = gatt.decode_value("utf8", await session.read(gatt.CAMERA_WIFI_ADDRESS)).strip("'") \
            if session.has(gatt.CAMERA_WIFI_ADDRESS) else ""
        passphrase = ""
        if session.has(gatt.CAMERA_PASSPHRASE):
            passphrase = gatt.decode_value("utf8", await session.read(gatt.CAMERA_PASSPHRASE)).strip("'")
        for v in session.drain(gatt.AP_STATE):
            log.detail(f"dropped stale AP_STATE {hexs(v)}")
        with log.step(f"Requesting the camera's Wi-Fi (FUNCTION_LAUNCH_REQUEST = {opts.function})"):
            await session.write(gatt.FUNCTION_LAUNCH_REQUEST, gatt.u16le(opts.function))
            deadline = time.monotonic() + opts.timeout
            state = None
            while time.monotonic() < deadline:
                v = await session.next_value(gatt.AP_STATE, deadline - time.monotonic())
                if v is None:
                    break
                state = gatt._u16(v)
                log.info(f"   AP_STATE = {gatt.decode_ap_state(v)}")
                if state in (gatt.AP_LAUNCHED, 0x8003):
                    break
        out.update({"ssid": ssid, "bssid": mac.replace("-", ":"), "security": "WPA2" if passphrase else "open",
                    "passphrase": passphrase if opts.include_secrets else ("<redacted>" if passphrase else ""),
                    "ap_state": f"{state:#06x}" if state is not None else None,
                    "launched": state in (gatt.AP_LAUNCHED, 0x8003)})
        log.plain("")
        if out["launched"]:
            log.plain(f"CAMERA WI-FI IS UP: join SSID {ssid!r} (BSSID {out['bssid'] or '?'}, {out['security']}"
                      + (f", passphrase {passphrase!r}" if passphrase and opts.include_secrets else
                         ", passphrase hidden: add --include-secrets" if passphrase else ", no passphrase") + ").")
            log.plain("  Then PTP/IP: TCP 192.168.0.1:55740 (docs/FUJIFILM-PROTOCOL.md §5).")
            if opts.hold > 0:
                with log.step(f"Holding the Bluetooth link {opts.hold:.0f} s while you join"):
                    await asyncio.sleep(opts.hold)
        else:
            log.plain(f"The camera didn't report AP_STATE up within {opts.timeout:.0f} s (last {out['ap_state']}).")
        return out
    finally:
        await session.close()
        find.out_dir.mkdir(parents=True, exist_ok=True)
        (find.out_dir / f"wifi-{timestamp()}.json").write_text(json.dumps(out, indent=2, default=str) + "\n")


# ============================================================================================
# Location + time sync (docs/FUJIFILM-PROTOCOL.md §3.3)
# ============================================================================================


@dataclass
class LocationOptions:
    lat: float = 0.0
    lon: float = 0.0
    alt_m: float = 0.0
    speed_mps: float = 0.0
    identify: bool = True
    client_name: str = DEFAULT_CLIENT_NAME
    answer_for: float = 0.0  # keep answering the camera's LOCATION_REQUEST requests for S seconds
    sync_setting: Optional[bool] = None  # write LOCATION_SYNC_SETTING on/off (a camera setting)
    cycle: Optional[int] = None  # write LOCATION_SYNC_INTERVAL seconds (a camera setting)
    sync_time: bool = False  # also answer TIME_SYNC_REQUEST with the clock


async def location_flow(transport: Transport, log: Log, find: FindOptions, opts: LocationOptions) -> dict:
    """Send a GPS fix: LOCATION_FIX (0f36ec14, 23 bytes, gatt.encode_location) written once now, and again every
    time the camera notifies LOCATION_REQUEST (ad06c7b7) while we listen.
    Optional settings: LOCATION_SYNC_SETTING u16 1/0 (aab609c4), LOCATION_SYNC_INTERVAL u16 seconds (c95d91ae)."""
    sighting = await find_camera(transport, log, find)
    session = await open_session(transport, log, sighting, find)
    out: dict = {"lat": opts.lat, "lon": opts.lon, "writes": 0, "requests": 0}
    try:
        if opts.identify:
            await identify(session, log, opts.client_name, token=remembered_token(find.out_dir, sighting),
                           identification_number=remembered_identification(find.out_dir, sighting))
        if not session.has(gatt.LOCATION_FIX):
            raise Unsupported("This camera has no LOCATION_FIX characteristic.")
        await session.subscribe(gatt.LOCATION_REQUEST)
        if opts.sync_time:
            await session.subscribe(gatt.TIME_SYNC_REQUEST)
            session.listeners.append(lambda u, v: asyncio.ensure_future(_answer_time_sync(session, log, u, v)))
        if opts.sync_setting is not None and session.has(gatt.LOCATION_SYNC_SETTING):
            await session.write(gatt.LOCATION_SYNC_SETTING, gatt.u16le(gatt.LOCATION_SYNC_ON if opts.sync_setting
                                                                      else gatt.LOCATION_SYNC_OFF))
        if opts.cycle is not None and session.has(gatt.LOCATION_SYNC_INTERVAL):
            await session.write(gatt.LOCATION_SYNC_INTERVAL, gatt.u16le(opts.cycle))

        async def send() -> None:
            await session.write(gatt.LOCATION_FIX, gatt.encode_location(opts.lat, opts.lon, alt_m=opts.alt_m,
                                                                              speed_mps=opts.speed_mps))
            out["writes"] += 1

        with log.step(f"Sending location {opts.lat:.6f}, {opts.lon:.6f}"):
            await send()
        if opts.answer_for > 0:
            with log.step(f"Answering the camera's location requests for {opts.answer_for:.0f} s"):
                deadline = time.monotonic() + opts.answer_for
                while time.monotonic() < deadline:
                    v = await session.next_value(gatt.LOCATION_REQUEST, deadline - time.monotonic())
                    if v is None:
                        if session.disconnected.is_set():
                            break
                        continue
                    out["requests"] += 1
                    log.info(f"   LOCATION_REQUEST = {hexs(v)}: sending the fix")
                    await send()
        log.plain(f"Location sent {out['writes']} time(s); the camera asked {out['requests']} time(s).")
        return out
    finally:
        await session.close()


# ============================================================================================
# adopt: take the registered pairing key from the camera's standby advert (no connection, no write)
# ============================================================================================


async def adopt_flow(transport: Transport, log: Log, find: FindOptions, timeout: float = 15.0) -> dict:
    """A basic body that is switched off advertises 02 + its REGISTERED pairing key (the one the phone that registered
    it presents; docs/FUJIFILM-PROTOCOL.md §3.2). Save it as ours,
    so `backup`/`restore` can present the same key without a new PAIRING REGISTRATION, which would replace the
    iPhone's. Listens only. Hypothesis: the basic profile has no bond, so the key is the whole identity check."""
    result = await scan_cameras(transport, log, timeout)
    cams = [s for s in result.cameras if _matches(s, find) and s.advert.token and s.advert.kind in ("basic-off", "basic-pairing")]
    if not cams:
        raise CameraNotFound("No basic-firmware camera advertising a pairing key. Switch the camera OFF (Bluetooth "
                             "stays on) or put it in PAIRING REGISTRATION, then retry.", CAMERA_CHECKLIST)
    s = max(cams, key=lambda c: c.rssi)
    save_last_camera(find.out_dir, s, {"token": s.advert.token.hex(), "adopted_from": s.advert.kind})
    log.plain("")
    log.plain(f"ADOPTED the pairing key {s.advert.token.hex()} of {s.name} ({'camera off: the registered key' if s.advert.kind == 'basic-off' else 'pairing advert'}).")
    log.plain("  Next: turn the camera ON (iPhone Bluetooth off), then `python -m fuji_ble dump --identify` and `backup`.")
    log.plain("  If the camera ignores us, fall back to `pair` (camera in PAIRING REGISTRATION).")
    return {"name": s.name, "address": s.address, "token": s.advert.token.hex(), "kind": s.advert.kind}
