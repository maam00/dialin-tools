#!/usr/bin/env python3
"""Decode Bluetooth LE captures down to ATT, so we can see (and replay) exactly
what an app wrote to the camera.

Reads Apple PacketLogger ``.pklg`` captures (both the legacy big-endian layout
and the newer little-endian one), btsnoop files (``.btsnoop`` / Android
``btsnoop_hci.log``), and pcap/pcapng with Bluetooth HCI link types 201/187/254
(``idevicebtlogger -f pcap``, Wireshark). Decodes HCI ACL -> L2CAP (with fragment reassembly) ->
ATT / SMP / LE signalling, tracks GATT discovery to name handles, and produces:

  a. a timeline                         (default, or --timeline)
  b. reassembled transfers saved to disk (--extract DIR)
  c. a replay script of every write     (--replay OUT.json)
  d. a diff of two captures             (--diff A B)
  e. a summary                          (--summary)

Usage (from ``ble/``)::

    python -m fuji_ble.capture restore.pklg                 # timeline + summary
    python -m fuji_ble.capture restore.pklg --summary
    python -m fuji_ble.capture restore.pklg --extract out/  # files + manifest.json
    python -m fuji_ble.capture restore.pklg --replay restore.replay.json
    python -m fuji_ble.capture --diff restore1.pklg restore2.pklg
    python -m fuji_ble.capture restore.pklg --handles dump.json   # no discovery in capture

Stdlib only, Python 3.12+. Nothing here talks to a radio.

Record layouts (verified against public parsers, 2026-10-08):

* PacketLogger: no file header. Each record is ``u32 length`` (counts every
  byte after itself), ``u32 seconds``, ``u32 microseconds``, ``u8 type``, then
  the packet. Legacy files are big-endian; newer ones are little-endian (BlueZ
  calls these "pklg v2"). Sources: Wireshark ``wiretap/packetlogger.c`` and
  ``epan/dissectors/packet-packetlogger.c``; BlueZ ``src/shared/btsnoop.c``.
  Types: 00 HCI command, 01 HCI event, 02 ACL sent, 03 ACL received, 08/09 SCO
  sent/received, 0A/0B LMP sent/received (BlueZ: 0B = vendor diagnostic),
  12/13 ISO sent/received (BlueZ only), F7 syslog, F8 kernel, F9 kernel debug,
  FA error, FB power, FC note, FD config, FE new controller. Anything else is
  kept as "other" and counted in --summary so unknown iOS types show up.
* btsnoop: ``"btsnoop\\0"``, u32 version (1), u32 datalink (1001 H1, 1002 H4,
  2001 BlueZ monitor), then records of u32 original length, u32 included
  length, u32 flags (bit0 received, bit1 command/event), u32 drops, i64
  microseconds since 0000-01-01 (big-endian throughout).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import difflib
import hashlib
import json
import re
import struct
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

__all__ = [
    "CaptureError", "HciRecord", "CaptureFile", "read_capture", "parse_capture",
    "build_pklg", "build_btsnoop", "Decoder", "Decoded", "Event", "Transfer",
    "decode_file", "decode_bytes", "find_transfers", "replay_script", "summarize",
    "format_timeline", "format_summary", "diff_captures", "format_diff",
    "extract_transfers", "load_handle_map", "save_handle_map", "describe_value", "set_focus", "main",
]

# --------------------------------------------------------------------------
# UUIDs and names
# --------------------------------------------------------------------------

SIG_SUFFIX = "-0000-1000-8000-00805f9b34fb"
CCCD = "00002902" + SIG_SUFFIX
PRIMARY_SERVICE = 0x2800
SECONDARY_SERVICE = 0x2801
INCLUDE = 0x2802
CHARACTERISTIC = 0x2803
FUJI_COMPANY_ID = 0x04D8
FUJI_BACKUP_MAGIC = b"FUJIFILMX-BACKUP"


def uuid16(u: int) -> str:
    return f"0000{u & 0xFFFF:04x}{SIG_SUFFIX}"


def uuid_from_le(b: bytes) -> str:
    """ATT carries UUIDs little-endian, as 2, 4 or 16 bytes."""
    if len(b) == 2:
        return uuid16(int.from_bytes(b, "little"))
    if len(b) == 4:
        return f"{int.from_bytes(b, 'little'):08x}{SIG_SUFFIX}"
    if len(b) == 16:
        h = b[::-1].hex()
        return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"
    return b.hex()


def uuid_to_le(u: str) -> bytes:
    """Inverse of uuid_from_le: 2 bytes for SIG-base 16-bit UUIDs, else 16."""
    u = norm_uuid(u) or u
    if u.endswith(SIG_SUFFIX) and u.startswith("0000"):
        return int(u[4:8], 16).to_bytes(2, "little")
    return bytes.fromhex(u.replace("-", ""))[::-1]


def short_uuid(u: str | None) -> str:
    if not u:
        return ""
    if u.endswith(SIG_SUFFIX) and u.startswith("0000"):
        return u[4:8]
    return u[:8]


def sig16(u: str | None) -> int | None:
    if u and u.endswith(SIG_SUFFIX) and u.startswith("0000"):
        return int(u[4:8], 16)
    return None


# Fujifilm GATT, X100VI fw 1.31 (fffw ffbt/cfg/gatt-ad14d4.yaml) plus the names
# used by fuji-bridge (FujiBLE / FujiBackup.swift), libfuji lib/bluetooth.c and
# docs/FUJIFILM-PROTOCOL.md §3.3. Unknown characteristics carry only their service label.
FUJI_SERVICES: dict[str, str] = {
    "a9d2b304-e8d6-4902-8336-352b772d7597": "PAIR_ADVERT",
    "15ca59fe-620c-464d-a987-223fab660cde": "LENS",
    "123d8f06-62a1-4935-9322-833c531ee225": "PAIRING",
    "91f1de68-dff6-466e-8b65-ff13b0f16fb8": "PAIRING_BASIC",
    "4e941240-d01d-46b9-a5ea-67636806830b": "WIFI",
    "4c0020fe-f3b6-40de-acc9-77d129067b14": "STATE",
    "6514eb81-4e8f-458d-aa2a-e691336cdfac": "CONTROL",
    "e872b11f-d526-4ae1-9bb4-89a99d48fa59": "TIME",
    "3b46ec2b-48ba-41fd-b1b8-ed860b60d22b": "GEOTAG",
    "af854c2e-b214-458e-97e2-912c4ecf2cb8": "FILE",
    "804daa8e-ffeb-4ab3-8e75-6edd7303208d": "RECONNECT",
    "117c4142-edd4-4c77-8696-dd18eebb770a": "CAMERA_INFO_BASIC",
}

FUJI_CHARS: dict[str, tuple[str | None, str]] = {
    # PAIR_ADVERT (a9d2b304): read-only, meaning unknown
    "9c72c205-5740-4f17-9949-0d3fadf2f67a": (None, "PAIR_ADVERT"),
    "4bf16f6d-7264-4e76-b0d2-52cde16d2c7d": (None, "PAIR_ADVERT"),
    "389363e4-712e-4cf2-a72e-bfcf7fb6adc1": (None, "PAIR_ADVERT"),
    "cae8c738-4bb6-4605-98c1-58331c87f3b6": (None, "PAIR_ADVERT"),
    "27870478-94a9-4345-849b-efa3bf37887f": (None, "PAIR_ADVERT"),
    "e8e40d50-a625-4f1d-96ed-8cec034f5690": (None, "PAIR_ADVERT"),
    "49a12959-dfaa-4eb2-89ce-62548ad948f3": (None, "PAIR_ADVERT"),
    # LENS
    "68887a7a-10a7-4a4a-aadd-6f9db1abaa0e": ("LENS_NAME", "LENS"),
    "621a98d8-6314-4c3e-a683-eea1d6166606": ("LENS_FW_VERSION", "LENS"),
    "df287e0c-c23f-4f80-afdd-c2b570288cdb": (None, "LENS"),
    # PAIRING
    "85b9163e-62d1-49ff-a6f5-054b4630d4a1": ("CLIENT_NAME", "PAIRING"),
    "a80be3f8-8bcb-4add-a725-170b7a53adc9": (None, "PAIRING"),
    "7ede1988-b27e-43fc-80f4-6fec994f0552": (None, "PAIRING"),
    "aba356eb-9633-4e60-b73f-f52516dbd671": ("PAIRING_TOKEN", "PAIRING"),
    "763514e8-c627-4b9e-b7e8-89074ad3ccc7": (None, "PAIRING"),
    "eb4166b0-9cca-445e-a4e4-75b3817fd57a": (None, "PAIRING"),
    "f557d96b-8284-4667-8793-b971c1deca2a": ("SECURE_PAIRING_STATUS", "PAIRING"),
    # WIFI
    "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4": ("WIFI_SSID", "WIFI"),
    "e809256a-915c-4967-92e8-53b7d4cad213": ("WIFI_PASSWORD", "WIFI"),
    "bd45f887-a6be-4cb7-8565-390df38bf5bf": (None, "WIFI"),
    "8814441b-1d7b-4046-891d-d8f80864cc8e": (None, "WIFI"),
    "aab609c4-94dd-4d89-bc60-665d5090b828": (None, "WIFI"),
    "c95d91ae-b247-4d6d-8661-7dd5d6a0f85b": ("GEOTAG_INTERVAL", "WIFI"),
    "75823784-fbb7-4b71-abae-cd9a34072e3c": (None, "WIFI"),
    "caedb497-83bf-482c-91ef-91cf6f1216ff": (None, "WIFI"),
    "98934b2c-756c-4632-aa2f-dcba1bfec824": (None, "WIFI"),
    "82a9f452-c5ce-4ef5-8203-3fc9a47f8171": (None, "WIFI"),
    "2a125640-706d-4dd1-b420-c0f4ab93c361": (None, "WIFI"),
    "deef7187-3f43-4364-9e22-11a8c8a15951": (None, "WIFI"),
    # STATE
    "a68e3f66-0fcc-4395-8d4c-aa980b5877fa": ("WIFI_AP_STATE", "STATE"),
    "bd17ba04-b76b-4892-a545-b73ba1f74dae": (None, "STATE"),
    "f9150137-5d40-4801-a8dc-f7fc5b01da50": ("TIME_SYNC_REQUEST", "STATE"),
    "ad06c7b7-f41a-46f4-a29a-712055319122": ("GEOTAG_REQUEST", "STATE"),
    "049ec406-ef75-4205-a390-08fe209c51f0": (None, "STATE"),
    "2f6cb772-1d69-448e-8819-fe6b5c20b094": (None, "STATE"),
    "e6692c5c-b7cd-44f4-95fc-eda07ce32560": (None, "STATE"),
    "11438c83-cfb0-4511-841b-759e0d2321c8": ("BACKUP_STATE", "STATE"),
    "4b3a413c-230f-42bc-b3ed-b1db2eadee82": (None, "STATE"),
    "34d8c8de-e2a9-43ff-822c-7d945dd8d8e1": (None, "STATE"),
    "20ea1fac-19d8-48a8-a80c-535d34300958": (None, "STATE"),
    "1587b102-0b6d-4b63-9226-66fcc6d17387": (None, "STATE"),
    # CONTROL
    "600655e6-3637-42f1-8fb2-44efc5c63b13": ("FUNCTION_LAUNCH", "CONTROL"),
    "fb15c357-364f-49d3-b5c5-1e32c0ded038": (None, "CONTROL"),
    "7fcf49c6-4ff0-4777-a03d-1a79166af7a8": ("SHUTTER", "CONTROL"),
    "b1307521-7ac5-4199-aaee-9d094781ce69": (None, "CONTROL"),
    "861442ab-b94e-4935-90d9-41e291d91374": (None, "CONTROL"),
    "43070f6c-51e0-4887-86a7-5f762bda5791": (None, "CONTROL"),
    "2674f0b0-f909-4e73-8656-338e9c74457f": (None, "CONTROL"),
    "f14e7a88-6f57-4872-a69b-b47ef3295c9b": ("BACKUP_REQUEST", "CONTROL"),
    "f1897eb9-a9aa-40f0-8ce6-2fa7915bc459": (None, "CONTROL"),
    # TIME / GEOTAG
    "b9bfd37f-ccad-4d36-a1ee-018e792b3edf": ("DATETIME", "TIME"),
    "c52edbce-1fe2-4ecc-9483-907e6592be9e": (None, "TIME"),
    "0f36ec14-29e5-411a-a1b6-64ee8383f090": ("GEOTAG_LOCATION", "GEOTAG"),
    # FILE
    "e3fbbfcf-f326-4b0f-82cf-b00ae1b107a2": (None, "FILE"),
    "051dd980-df9d-4472-a2e1-35811dd24ee1": ("FILE_TRANSFER_INDEX", "FILE"),
    "c922ac69-9480-4348-8f4b-9ee29bc30d1d": ("FILE_INFORMATION", "FILE"),
    "7f3400fe-17e7-4b80-8a0e-81b0343c1b49": ("FILE_PARTIAL_SIZE", "FILE"),
    "ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea": ("FILE_PARTIAL_DATA", "FILE"),
    "68052e8a-fb91-404f-8847-0eb4be24308c": ("FILE_TRANSFER_RESULT", "FILE"),
    "2e27ed9f-5506-41cd-ba48-dac06669ad95": ("FILE_TRANSACTION_STATE", "FILE"),
    # RECONNECT
    "f90f7d3a-3b64-45c6-ab21-933900184837": (None, "RECONNECT"),
    "7170fd5a-56d9-4c19-b043-7a7047d8e1a0": (None, "RECONNECT"),
}

SIG_NAMES: dict[int, str] = {
    0x1800: "GAP", 0x1801: "GATT", 0x180A: "DEVICE_INFO", 0x180F: "BATTERY",
    0x1805: "CURRENT_TIME_SVC",
    0x2800: "PRIMARY_SERVICE", 0x2801: "SECONDARY_SERVICE", 0x2802: "INCLUDE",
    0x2803: "CHARACTERISTIC", 0x2900: "EXT_PROPS", 0x2901: "USER_DESCRIPTION",
    0x2902: "CCCD", 0x2903: "SCCD", 0x2904: "PRESENTATION_FORMAT",
    0x2A00: "DEVICE_NAME", 0x2A01: "APPEARANCE", 0x2A04: "PPCP",
    0x2A05: "SERVICE_CHANGED", 0x2A19: "BATTERY_LEVEL", 0x2A23: "SYSTEM_ID",
    0x2A24: "MODEL_NUMBER", 0x2A25: "SERIAL_NUMBER", 0x2A26: "FIRMWARE_REV",
    0x2A27: "HARDWARE_REV", 0x2A28: "SOFTWARE_REV", 0x2A29: "MANUFACTURER",
    0x2A2B: "CURRENT_TIME", 0x2A50: "PNP_ID", 0x2AA6: "CENTRAL_ADDR_RESOLUTION",
    0x2AC9: "RPA_ONLY", 0x2B29: "CLIENT_SUPPORTED_FEATURES",
    0x2B2A: "DATABASE_HASH", 0x2B3A: "SERVER_SUPPORTED_FEATURES",
}

OTHER_NAMES: dict[str, str] = {
    "7905f431-b5ce-4e99-a40f-4b1e122d00d0": "APPLE_ANCS",
    "89d3502b-0f36-433a-8ef4-c502ad55f8dc": "APPLE_AMS",
    "d0611e78-bbb4-4591-a5f8-487910ae4366": "APPLE_CONTINUITY",
    "9fa480e0-4967-4542-9390-d343dc5d04ae": "APPLE_NEARBY",
}

# X100VI firmware 1.31 GATT layout from fffw gatt-ad14d4.yaml. fffw's "index"
# looks like the characteristic declaration handle: chars step by 2, and by 3
# after a notify/indicate char (room for a CCCD). So value handle = index + 1
# and CCCD = index + 2. UNVERIFIED on a real camera: names resolved from this
# table are marked with "?" and --summary checks it against any discovery in
# the capture. Columns: kind, declaration handle, uuid, props (r w n i).
_PROFILE_AD14D4 = """
S 0x0001 1800
C 0x0011 2a00 r
C 0x0021 2a01 r
S 0x1001 1801
C 0x1011 2a05 r
S 0x1101 180a
C 0x1102 2a29 r
C 0x1104 2a24 r
C 0x1106 2a25 r
C 0x1108 2a27 r
C 0x110a 2a26 r
C 0x110c 2a28 r
S 0x2001 a9d2b304-e8d6-4902-8336-352b772d7597
C 0x2002 9c72c205-5740-4f17-9949-0d3fadf2f67a r
C 0x2004 4bf16f6d-7264-4e76-b0d2-52cde16d2c7d r
C 0x2006 389363e4-712e-4cf2-a72e-bfcf7fb6adc1 r
C 0x2008 cae8c738-4bb6-4605-98c1-58331c87f3b6 r
C 0x200a 27870478-94a9-4345-849b-efa3bf37887f r
C 0x200c e8e40d50-a625-4f1d-96ed-8cec034f5690 r
C 0x200e 49a12959-dfaa-4eb2-89ce-62548ad948f3 r
S 0x3001 15ca59fe-620c-464d-a987-223fab660cde
C 0x3002 68887a7a-10a7-4a4a-aadd-6f9db1abaa0e r
C 0x3004 621a98d8-6314-4c3e-a683-eea1d6166606 r
C 0x3006 df287e0c-c23f-4f80-afdd-c2b570288cdb r
S 0x4001 123d8f06-62a1-4935-9322-833c531ee225
C 0x4002 85b9163e-62d1-49ff-a6f5-054b4630d4a1 w
C 0x4004 a80be3f8-8bcb-4add-a725-170b7a53adc9 w
C 0x4006 7ede1988-b27e-43fc-80f4-6fec994f0552 rw
C 0x4008 aba356eb-9633-4e60-b73f-f52516dbd671 w
C 0x400a 763514e8-c627-4b9e-b7e8-89074ad3ccc7 w
C 0x400c eb4166b0-9cca-445e-a4e4-75b3817fd57a w
C 0x400e f557d96b-8284-4667-8793-b971c1deca2a rw
S 0x4501 4e941240-d01d-46b9-a5ea-67636806830b
C 0x4502 bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4 rwn
C 0x4505 e809256a-915c-4967-92e8-53b7d4cad213 r
C 0x4507 bd45f887-a6be-4cb7-8565-390df38bf5bf rwn
C 0x450a 8814441b-1d7b-4046-891d-d8f80864cc8e r
C 0x450c aab609c4-94dd-4d89-bc60-665d5090b828 rwn
C 0x450f c95d91ae-b247-4d6d-8661-7dd5d6a0f85b rwn
C 0x4512 75823784-fbb7-4b71-abae-cd9a34072e3c rwn
C 0x4515 caedb497-83bf-482c-91ef-91cf6f1216ff rwn
C 0x4518 98934b2c-756c-4632-aa2f-dcba1bfec824 rwn
C 0x451b 82a9f452-c5ce-4ef5-8203-3fc9a47f8171 rwn
S 0x5001 4c0020fe-f3b6-40de-acc9-77d129067b14
C 0x5002 a68e3f66-0fcc-4395-8d4c-aa980b5877fa ri
C 0x5005 bd17ba04-b76b-4892-a545-b73ba1f74dae ri
C 0x5008 f9150137-5d40-4801-a8dc-f7fc5b01da50 rn
C 0x500b ad06c7b7-f41a-46f4-a29a-712055319122 rn
C 0x500e 049ec406-ef75-4205-a390-08fe209c51f0 ri
C 0x5011 2f6cb772-1d69-448e-8819-fe6b5c20b094 ri
C 0x5014 e6692c5c-b7cd-44f4-95fc-eda07ce32560 rn
C 0x5017 11438c83-cfb0-4511-841b-759e0d2321c8 ri
C 0x501a 4b3a413c-230f-42bc-b3ed-b1db2eadee82 ri
C 0x501d 34d8c8de-e2a9-43ff-822c-7d945dd8d8e1 r
C 0x501f 20ea1fac-19d8-48a8-a80c-535d34300958 r
C 0x5021 1587b102-0b6d-4b63-9226-66fcc6d17387 r
S 0x6001 6514eb81-4e8f-458d-aa2a-e691336cdfac
C 0x6002 600655e6-3637-42f1-8fb2-44efc5c63b13 w
C 0x6004 fb15c357-364f-49d3-b5c5-1e32c0ded038 w
C 0x6006 7fcf49c6-4ff0-4777-a03d-1a79166af7a8 w
C 0x6008 b1307521-7ac5-4199-aaee-9d094781ce69 w
C 0x600a 861442ab-b94e-4935-90d9-41e291d91374 w
C 0x600c 43070f6c-51e0-4887-86a7-5f762bda5791 w
C 0x600e 2674f0b0-f909-4e73-8656-338e9c74457f w
C 0x6010 f14e7a88-6f57-4872-a69b-b47ef3295c9b w
C 0x6012 f1897eb9-a9aa-40f0-8ce6-2fa7915bc459 w
S 0x7001 e872b11f-d526-4ae1-9bb4-89a99d48fa59
C 0x7002 b9bfd37f-ccad-4d36-a1ee-018e792b3edf w
C 0x7004 c52edbce-1fe2-4ecc-9483-907e6592be9e w
S 0x8001 3b46ec2b-48ba-41fd-b1b8-ed860b60d22b
C 0x8002 0f36ec14-29e5-411a-a1b6-64ee8383f090 w
S 0x9001 af854c2e-b214-458e-97e2-912c4ecf2cb8
C 0x9002 e3fbbfcf-f326-4b0f-82cf-b00ae1b107a2 r
C 0x9004 051dd980-df9d-4472-a2e1-35811dd24ee1 w
C 0x9006 c922ac69-9480-4348-8f4b-9ee29bc30d1d rw
C 0x9008 7f3400fe-17e7-4b80-8a0e-81b0343c1b49 rw
C 0x900a ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea rw
C 0x900c 68052e8a-fb91-404f-8847-0eb4be24308c w
C 0x900e 2e27ed9f-5506-41cd-ba48-dac06669ad95 n
S 0xa001 804daa8e-ffeb-4ab3-8e75-6edd7303208d
C 0xa002 f90f7d3a-3b64-45c6-ab21-933900184837 rn
C 0xa005 7170fd5a-56d9-4c19-b043-7a7047d8e1a0 rwn
"""


def _all_known_uuids() -> list[str]:
    out = list(FUJI_SERVICES) + list(FUJI_CHARS) + list(OTHER_NAMES)
    out += [uuid16(u) for u in SIG_NAMES]
    return out


def norm_uuid(s: Any) -> str | None:
    """Accepts '2a00', '0x2A00', 'f14e7a88' (resolved against the known
    tables), 32 hex digits or the dashed form. Returns lowercase dashed 128-bit,
    or the 8-hex prefix itself if it can't be resolved, or None."""
    if s is None:
        return None
    if isinstance(s, int):
        return uuid16(s) if s <= 0xFFFF else f"{s:08x}{SIG_SUFFIX}"
    t = str(s).strip().lower()
    if t.startswith("0x"):
        t = t[2:]
    if re.fullmatch(r"[0-9a-f]{4}", t):
        return uuid16(int(t, 16))
    if re.fullmatch(r"[0-9a-f]{8}", t):
        hits = [u for u in _all_known_uuids() if u.startswith(t)]
        return hits[0] if len(hits) == 1 else t
    if re.fullmatch(r"[0-9a-f]{32}", t):
        return f"{t[0:8]}-{t[8:12]}-{t[12:16]}-{t[16:20]}-{t[20:32]}"
    if re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", t):
        return t
    return None


def _looks_uuid(s: Any) -> bool:
    return isinstance(s, str) and norm_uuid(s) is not None and len(s.strip()) >= 4


def _external_names() -> dict[str, str]:
    """Names from fuji_ble.gatt when that module exists. Its API isn't fixed
    yet, so accept any of: {uuid: name}, {name: uuid}, {uuid: obj-with-.name},
    or UPPER_CASE = "uuid" constants. Never fails."""
    mod = None
    try:
        from . import gatt as mod  # type: ignore[no-redef]
    except Exception:
        try:
            import fuji_ble.gatt as mod  # type: ignore[no-redef]
        except Exception:
            return {}
    out: dict[str, str] = {}

    def put(u: Any, name: Any) -> None:
        nu = norm_uuid(u) if isinstance(u, (str, int)) else None
        # gatt.py calls characteristics no source names "unknown-xxxxxxxx"; our
        # local "SERVICE/?" label says more, so skip those
        if (nu and isinstance(name, str) and name and not _looks_uuid(name)
                and not name.lower().startswith("unknown")):
            out.setdefault(nu, name)

    # The current gatt.py: CHARACTERISTICS / SERVICES = {uuid: obj with .name}
    for table in ("CHARACTERISTICS", "SERVICES"):
        obj = getattr(mod, table, None)
        if isinstance(obj, dict):
            for k, v in obj.items():
                put(k, v if isinstance(v, str) else (v.get("name") if isinstance(v, dict) else getattr(v, "name", None)))
    if out:
        return out
    try:  # any other shape
        for attr in dir(mod):
            if attr.startswith("_"):
                continue
            obj = getattr(mod, attr, None)
            if isinstance(obj, str) and attr.isupper() and _looks_uuid(obj) and len(obj) >= 8:
                put(obj, attr)
            elif isinstance(obj, dict):
                for k, v in list(obj.items())[:2000]:
                    if isinstance(k, str) and _looks_uuid(k) and len(k) >= 4:
                        if isinstance(v, str):
                            put(k, v)
                        elif isinstance(v, dict):
                            put(k, v.get("name"))
                        else:
                            put(k, getattr(v, "name", None))
                    elif isinstance(k, str) and isinstance(v, str) and _looks_uuid(v) and len(v) >= 8:
                        put(v, k)
                    elif isinstance(v, dict) and "uuid" in v:
                        put(v.get("uuid"), v.get("name") or (k if isinstance(k, str) else None))
                    elif hasattr(v, "uuid"):
                        put(getattr(v, "uuid"), getattr(v, "name", None) or (k if isinstance(k, str) else None))
    except Exception:
        pass
    return out


_EXTERNAL: dict[str, str] | None = None


def uuid_name(u: str | None) -> str | None:
    """Friendly name for a UUID: fuji_ble.gatt first, then the local tables."""
    global _EXTERNAL
    if not u:
        return None
    if _EXTERNAL is None:
        _EXTERNAL = _external_names()
    if u in _EXTERNAL:
        return _EXTERNAL[u]
    if u in FUJI_CHARS:
        name, svc = FUJI_CHARS[u]
        return name or f"{svc}/?"
    if u in FUJI_SERVICES:
        return FUJI_SERVICES[u] + "_SVC"
    if u in OTHER_NAMES:
        return OTHER_NAMES[u]
    s = sig16(u)
    if s is not None and s in SIG_NAMES:
        return SIG_NAMES[s]
    if len(u) == 8:  # unresolved prefix
        for full in FUJI_CHARS:
            if full.startswith(u):
                return uuid_name(full)
    return None


# --------------------------------------------------------------------------
# Capture readers
# --------------------------------------------------------------------------


class CaptureError(Exception):
    """The input isn't a capture this module can read."""


@dataclass
class HciRecord:
    n: int                 # record number in the file (0-based)
    ts: float              # seconds since the Unix epoch
    kind: str              # cmd evt acl sco iso lmp syslog kernel note ... other
    sent: bool | None      # True = host -> controller (the phone sending)
    data: bytes            # HCI packet without any H4 indicator, or note text
    ptype: int = -1        # original pklg type / H4 indicator / monitor opcode
    truncated: bool = False
    offset: int = 0        # byte offset in the file


@dataclass
class CaptureFile:
    fmt: str
    records: list[HciRecord]
    warnings: list[str] = field(default_factory=list)
    type_counts: Counter = field(default_factory=Counter)
    size: int = 0


PKLG_TYPES: dict[int, tuple[str, bool | None]] = {
    0x00: ("cmd", True), 0x01: ("evt", False),
    0x02: ("acl", True), 0x03: ("acl", False),
    0x08: ("sco", True), 0x09: ("sco", False),
    0x0A: ("lmp", True), 0x0B: ("lmp", False),
    0x12: ("iso", True), 0x13: ("iso", False),
    0xF7: ("syslog", None), 0xF8: ("kernel", None), 0xF9: ("kernel_debug", None),
    0xFA: ("error", None), 0xFB: ("power", None), 0xFC: ("note", None),
    0xFD: ("config", None), 0xFE: ("new_controller", None),
}
PKLG_CODE = {v: k for k, v in PKLG_TYPES.items()}
TEXT_KINDS = {"syslog", "kernel", "kernel_debug", "error", "power", "note", "config", "new_controller"}
PKLG_MAX_LEN = 0x40000          # parse limit (Wireshark: 256 KiB)
PKLG_PLAUSIBLE_LEN = 0x10000    # detection limit (Wireshark: < 65536)
MAX_TS_JUMP = 30 * 86400        # seconds; bigger jumps mean we're misaligned

BTSNOOP_MAGIC = b"btsnoop\0"
BTSNOOP_EPOCH_DELTA = 0x00DCDDB30F2F8000  # microseconds from 0000-01-01 to 1970-01-01
H4_KIND = {0x01: "cmd", 0x02: "acl", 0x03: "sco", 0x04: "evt", 0x05: "iso"}
MONITOR_OPS = {2: ("cmd", True), 3: ("evt", False), 4: ("acl", True), 5: ("acl", False),
               6: ("sco", True), 7: ("sco", False), 12: ("note", None), 13: ("syslog", None),
               18: ("iso", True), 19: ("iso", False)}


def _pklg_hdr(data: bytes, off: int, e: str) -> tuple[int, int, int, int] | None:
    """(length, secs, usecs, type) if a plausible record header sits at off."""
    if off + 12 > len(data):
        return None
    ln, secs, usecs = struct.unpack_from(e + "III", data, off)
    if ln < 8 or ln > PKLG_MAX_LEN or usecs >= 1_000_000:
        return None
    t = data[off + 12] if ln >= 9 and off + 12 < len(data) else -1
    return ln, secs, usecs, t


def _pklg_chain(data: bytes, off: int, e: str, want: int = 3) -> int:
    """How many consecutive plausible records (sane length, steady clock) start
    at off. Unknown record types are allowed (iOS may add some), but the run
    must contain at least one known type. Reaching EOF exactly counts as a pass."""
    n = known = 0
    prev = None
    while n < want or (not known and n < want + 64):
        h = _pklg_hdr(data, off, e)
        if h is None:
            if off == len(data) and n:
                return max(n, want) if known else 0
            return n if known else 0
        ln, secs, _, t = h
        if ln >= PKLG_PLAUSIBLE_LEN or (prev is not None and abs(secs - prev) > MAX_TS_JUMP):
            return n if known else 0
        if t in PKLG_TYPES:
            known += 1
        if off + 4 + ln > len(data):
            return n + 1 if n and known else 0  # a truncated tail is fine after good records
        prev = secs
        off += 4 + ln
        n += 1
        if off == len(data):
            return max(n, want) if known else 0
    return min(n, want) if known else 0


def _detect_pklg(data: bytes) -> tuple[str, int]:
    limit = min(len(data), 1 << 16)
    for start in range(0, max(1, limit)):
        best = None
        for e in (">", "<"):
            score = _pklg_chain(data, start, e, want=4)
            if score >= 1 and (best is None or score > best[1]):
                best = (e, score)
        if best and (best[1] >= 3 or (start == 0 and best[1] >= 1 and len(data) < 4096)):
            return best[0], start
    raise CaptureError("not a PacketLogger (.pklg) or btsnoop file: no valid records found")


def _pklg_resync(data: bytes, start: int, e: str, stop: int | None = None) -> int | None:
    for p in range(start, min(stop or len(data), len(data))):
        if _pklg_chain(data, p, e, want=2) >= 2:
            return p
    return None


def _read_pklg(data: bytes, cap: CaptureFile) -> None:
    e, off = _detect_pklg(data)
    cap.fmt = "pklg (big-endian, legacy)" if e == ">" else "pklg (little-endian)"
    if off:
        cap.warnings.append(f"skipped {off} bytes of garbage before the first record")
    prev_secs: int | None = None
    n = 0
    end = len(data)
    while off < end:
        h = _pklg_hdr(data, off, e)
        ok = h is not None and (prev_secs is None or abs(h[1] - prev_secs) <= MAX_TS_JUMP)
        if ok and h is not None:
            nxt = off + 4 + h[0]
            if nxt > end:
                # a truncated last record, or a corrupt length: a later valid chain decides
                p = _pklg_resync(data, off + 1, e)
                if p is None:
                    ln, secs, usecs, t = h
                    kind, sent = PKLG_TYPES.get(t, ("other", None))
                    cap.records.append(HciRecord(n, secs + usecs / 1e6, kind, sent,
                                                 data[off + 13:end], t, truncated=True, offset=off))
                    cap.type_counts[t] += 1
                    cap.warnings.append(f"record {n} at offset {off} truncated: needs {h[0] + 4} bytes, file has {end - off}")
                    break
                cap.warnings.append(f"skipped {p - off} bytes of garbage at offset {off} (bad record length)")
                off = p
                continue
            if nxt < end:
                h2 = _pklg_hdr(data, nxt, e)
                if h2 is None or abs(h2[1] - h[1]) > MAX_TS_JUMP:
                    # the next header is wrong: was this length corrupt? look for a chain inside it
                    p = _pklg_resync(data, off + 1, e, stop=nxt)
                    if p is not None:
                        cap.warnings.append(f"skipped {p - off} bytes of garbage at offset {off} (bad record length)")
                        off = p
                        continue
        if not ok or h is None:
            nxt = _pklg_resync(data, off + 1, e)
            if nxt is None:
                cap.warnings.append(f"{end - off} trailing bytes at offset {off} are not records; ignored")
                break
            cap.warnings.append(f"skipped {nxt - off} bytes of garbage at offset {off}")
            off = nxt
            continue
        ln, secs, usecs, t = h
        prev_secs = secs
        if ln == 8:  # header with no type/payload
            off += 12
            continue
        kind, sent = PKLG_TYPES.get(t, ("other", None))
        cap.records.append(HciRecord(n, secs + usecs / 1e6, kind, sent,
                                     bytes(data[off + 13:off + 4 + ln]), t, offset=off))
        cap.type_counts[t] += 1
        n += 1
        off += 4 + ln


def _bts_hdr(data: bytes, off: int, datalink: int, prev_ts: int | None) -> tuple | None:
    if off + 24 > len(data):
        return None
    orig, incl, flags, drops, ts = struct.unpack_from(">IIIIq", data, off)
    if incl > orig or incl > 0x10000 or incl == 0:
        return None
    if datalink in (1001, 1002) and flags > 3:
        return None
    if datalink == 2001 and (flags & 0xFFFF) > 0x40:
        return None
    if prev_ts is not None and abs(ts - prev_ts) > MAX_TS_JUMP * 1_000_000:
        return None
    return orig, incl, flags, drops, ts


def _read_btsnoop(data: bytes, cap: CaptureFile) -> None:
    if len(data) < 16:
        raise CaptureError("btsnoop header truncated")
    version, datalink = struct.unpack_from(">II", data, 8)
    cap.fmt = f"btsnoop v{version} datalink {datalink}"
    if version != 1:
        cap.warnings.append(f"btsnoop version {version} (expected 1); trying anyway")
    if datalink not in (1001, 1002, 2001):
        cap.warnings.append(f"btsnoop datalink {datalink} not supported well; treating as H4")
        datalink = 1002
    off = 16
    end = len(data)
    prev_ts: int | None = None
    n = 0
    while off < end:
        h = _bts_hdr(data, off, datalink, prev_ts)
        if h is None:
            nxt = None
            for p in range(off + 1, end - 23):
                h1 = _bts_hdr(data, p, datalink, prev_ts)
                if h1 and p + 24 + h1[1] <= end:
                    q = p + 24 + h1[1]
                    if q == end or _bts_hdr(data, q, datalink, h1[4]):
                        nxt = p
                        break
            if nxt is None:
                cap.warnings.append(f"{end - off} trailing bytes at offset {off} are not records; ignored")
                break
            cap.warnings.append(f"skipped {nxt - off} bytes of garbage at offset {off}")
            off = nxt
            continue
        orig, incl, flags, _drops, ts = h
        pkt = bytes(data[off + 24:off + 24 + incl])
        truncated = len(pkt) < incl or incl < orig
        if len(pkt) < incl:
            cap.warnings.append(f"record {n} at offset {off} truncated at end of file")
        prev_ts = ts
        secs = (ts - BTSNOOP_EPOCH_DELTA) / 1e6
        if datalink == 1002:
            if not pkt:
                off += 24 + incl
                continue
            ind = pkt[0]
            kind = H4_KIND.get(ind, "other")
            sent = not (flags & 1)
            body = pkt[1:]
            ptype = ind
        elif datalink == 1001:
            sent = not (flags & 1)
            kind = ("cmd" if sent else "evt") if flags & 2 else "acl"
            body = pkt
            ptype = flags
        else:  # 2001 BlueZ monitor
            opcode = flags & 0xFFFF
            kind, sent = MONITOR_OPS.get(opcode, ("other", None))
            body = pkt
            ptype = opcode
        cap.records.append(HciRecord(n, secs, kind, sent, body, ptype, truncated, off))
        cap.type_counts[ptype] += 1
        n += 1
        off += 24 + incl
        if len(pkt) < incl:
            break


def _linktype_packet(linktype: int, pkt: bytes) -> tuple[str, bool | None, bytes, int] | None:
    """pcap link types: 201 H4 + 4-byte direction (idevicebtlogger, Wireshark),
    187 H4 without direction, 254 BlueZ monitor."""
    if linktype == 201 and len(pkt) >= 5:
        sent = not (struct.unpack_from(">I", pkt)[0] & 1)
        return H4_KIND.get(pkt[4], "other"), sent, pkt[5:], pkt[4]
    if linktype == 187 and pkt:
        kind = H4_KIND.get(pkt[0], "other")
        sent = True if kind == "cmd" else False if kind == "evt" else None
        return kind, sent, pkt[1:], pkt[0]
    if linktype == 254 and len(pkt) >= 4:
        opcode = struct.unpack_from(">H", pkt, 2)[0]
        kind, sent = MONITOR_OPS.get(opcode, ("other", None))
        return kind, sent, pkt[4:], opcode
    return None


def _read_pcap(data: bytes, cap: CaptureFile) -> None:
    magic = data[:4]
    e = "<" if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
    frac = 1e9 if magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d") else 1e6
    if len(data) < 24:
        raise CaptureError("pcap header truncated")
    linktype = struct.unpack_from(e + "I", data, 20)[0] & 0xFFFF
    cap.fmt = f"pcap linktype {linktype}"
    if linktype not in (187, 201, 254):
        raise CaptureError(f"pcap link type {linktype} is not Bluetooth HCI (want 201, 187 or 254)")
    if linktype == 187:
        cap.warnings.append("pcap link type 187 has no direction field: ACL direction is unknown")
    off, n = 24, 0
    while off + 16 <= len(data):
        secs, fr, incl, _orig = struct.unpack_from(e + "IIII", data, off)
        if incl > 0x40000:
            cap.warnings.append(f"bad pcap record length at offset {off}; stopped")
            break
        pkt = data[off + 16:off + 16 + incl]
        r = _linktype_packet(linktype, pkt)
        if r:
            cap.records.append(HciRecord(n, secs + fr / frac, r[0], r[1], r[2], r[3], len(pkt) < incl, off))
            cap.type_counts[r[3]] += 1
            n += 1
        off += 16 + incl


def _read_pcapng(data: bytes, cap: CaptureFile) -> None:
    e = "<"
    if len(data) >= 12 and data[8:12] == b"\x4d\x3c\x2b\x1a":
        e = "<"
    elif len(data) >= 12 and data[8:12] == b"\x1a\x2b\x3c\x4d":
        e = ">"
    ifaces: list[tuple[int, float]] = []
    off, n = 0, 0
    cap.fmt = "pcapng"
    while off + 12 <= len(data):
        btype, blen = struct.unpack_from(e + "II", data, off)
        if blen < 12 or off + blen > len(data):
            cap.warnings.append(f"bad pcapng block at offset {off}; stopped")
            break
        body = data[off + 8:off + blen - 4]
        if btype == 0x0A0D0D0A and len(body) >= 4:
            e = "<" if body[:4] == b"\x4d\x3c\x2b\x1a" else ">"
            ifaces = []
        elif btype == 1 and len(body) >= 8:
            lt = struct.unpack_from(e + "H", body)[0]
            res = 1e-6
            o = 8
            while o + 4 <= len(body):
                code, ln = struct.unpack_from(e + "HH", body, o)
                if code == 0:
                    break
                if code == 9 and ln >= 1:
                    v = body[o + 4]
                    res = 2.0 ** -(v & 0x7F) if v & 0x80 else 10.0 ** -v
                o += 4 + ((ln + 3) & ~3)
            ifaces.append((lt, res))
        elif btype in (6, 3) and ifaces:
            if btype == 6 and len(body) >= 20:
                iid, hi, lo, incl, _orig = struct.unpack_from(e + "IIIII", body)
                pkt = body[20:20 + incl]
            elif btype == 3 and len(body) >= 4:
                iid, hi, lo = 0, 0, 0
                pkt = body[4:]
            else:
                off += blen
                continue
            lt, res = ifaces[iid] if iid < len(ifaces) else ifaces[0]
            r = _linktype_packet(lt, pkt)
            if r:
                cap.records.append(HciRecord(n, ((hi << 32) | lo) * res, r[0], r[1], r[2], r[3], offset=off))
                cap.type_counts[r[3]] += 1
                n += 1
        off += blen
    if ifaces and not cap.records:
        cap.warnings.append(f"pcapng has no Bluetooth HCI packets (link types {[i[0] for i in ifaces]})")


_OTHER_MAGIC = {b"PK\x03\x04": "a zip archive (a sysdiagnose? unzip it and look under logs/Bluetooth)",
                b"bplist": "a binary plist", b"<?xml": "an XML file", b"\x1f\x8b": "gzip data (gunzip it first)"}


def parse_capture(data: bytes) -> CaptureFile:
    cap = CaptureFile(fmt="?", records=[], size=len(data))
    if not data:
        raise CaptureError("empty file")
    if data.startswith(BTSNOOP_MAGIC):
        _read_btsnoop(data, cap)
    elif data[:4] in (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4", b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d"):
        _read_pcap(data, cap)
    elif data[:4] == b"\x0a\x0d\x0d\x0a":
        _read_pcapng(data, cap)
    else:
        try:
            _read_pklg(data, cap)
        except CaptureError as exc:
            hint = next((v for k, v in _OTHER_MAGIC.items() if data.startswith(k)), None)
            msg = f"{exc}; first bytes {data[:16].hex(' ')}"
            if hint:
                msg += f" look like {hint}"
            else:
                msg += ". If a newer PacketLogger wrote this, try its File > Export as btsnoop"
            raise CaptureError(msg) from None
    return cap


def read_capture(path: str | Path) -> CaptureFile:
    return parse_capture(Path(path).read_bytes())


# --------------------------------------------------------------------------
# Writers (synthetic captures for tests; --to-btsnoop conversion)
# --------------------------------------------------------------------------


def build_pklg(records: Iterable[HciRecord], little_endian: bool = True) -> bytes:
    e = "<" if little_endian else ">"
    out = bytearray()
    for r in records:
        code = PKLG_CODE.get((r.kind, r.sent), r.ptype if r.ptype >= 0 else 0xFC)
        secs = int(r.ts)
        usecs = int(round((r.ts - secs) * 1e6))
        if usecs >= 1_000_000:
            secs, usecs = secs + 1, usecs - 1_000_000
        payload = bytes([code]) + r.data
        out += struct.pack(e + "III", 8 + len(payload), secs, usecs) + payload
    return bytes(out)


def build_btsnoop(records: Iterable[HciRecord]) -> bytes:
    """H4 (datalink 1002) btsnoop; non-HCI records (notes, syslog) are dropped."""
    ind = {"cmd": 1, "acl": 2, "sco": 3, "evt": 4, "iso": 5}
    out = bytearray(BTSNOOP_MAGIC + struct.pack(">II", 1, 1002))
    for r in records:
        if r.kind not in ind:
            continue
        pkt = bytes([ind[r.kind]]) + r.data
        flags = (0 if r.sent else 1) | (2 if r.kind in ("cmd", "evt") else 0)
        ts = int(round(r.ts * 1e6)) + BTSNOOP_EPOCH_DELTA
        out += struct.pack(">IIIIq", len(pkt), len(pkt), flags, 0, ts) + pkt
    return bytes(out)


# --------------------------------------------------------------------------
# Protocol tables
# --------------------------------------------------------------------------

ATT_OPS = {
    0x01: "ErrorRsp", 0x02: "MtuReq", 0x03: "MtuRsp", 0x04: "FindInfoReq",
    0x05: "FindInfoRsp", 0x06: "FindByTypeReq", 0x07: "FindByTypeRsp",
    0x08: "ReadByTypeReq", 0x09: "ReadByTypeRsp", 0x0A: "ReadReq", 0x0B: "ReadRsp",
    0x0C: "ReadBlobReq", 0x0D: "ReadBlobRsp", 0x0E: "ReadMultiReq", 0x0F: "ReadMultiRsp",
    0x10: "ReadByGroupReq", 0x11: "ReadByGroupRsp", 0x12: "WriteReq", 0x13: "WriteRsp",
    0x16: "PrepWriteReq", 0x17: "PrepWriteRsp", 0x18: "ExecWriteReq", 0x19: "ExecWriteRsp",
    0x1B: "Notify", 0x1D: "Indicate", 0x1E: "Confirm", 0x20: "ReadMultiVarReq",
    0x21: "ReadMultiVarRsp", 0x23: "MultiNotify", 0x52: "WriteCmd", 0xD2: "SignedWriteCmd",
}
ATT_CLIENT_OPS = {0x02, 0x04, 0x06, 0x08, 0x0A, 0x0C, 0x0E, 0x10, 0x12, 0x16, 0x18, 0x1E, 0x20, 0x52, 0xD2}
ATT_REQUESTS = {0x02, 0x04, 0x06, 0x08, 0x0A, 0x0C, 0x0E, 0x10, 0x12, 0x16, 0x18, 0x20}
ATT_RESPONSES = {0x03, 0x05, 0x07, 0x09, 0x0B, 0x0D, 0x0F, 0x11, 0x13, 0x17, 0x19, 0x21}
ATT_ERRORS = {
    0x01: "Invalid Handle", 0x02: "Read Not Permitted", 0x03: "Write Not Permitted",
    0x04: "Invalid PDU", 0x05: "Insufficient Authentication", 0x06: "Request Not Supported",
    0x07: "Invalid Offset", 0x08: "Insufficient Authorization", 0x09: "Prepare Queue Full",
    0x0A: "Attribute Not Found", 0x0B: "Attribute Not Long", 0x0C: "Insufficient Key Size",
    0x0D: "Invalid Attribute Value Length", 0x0E: "Unlikely Error", 0x0F: "Insufficient Encryption",
    0x10: "Unsupported Group Type", 0x11: "Insufficient Resources", 0x12: "Database Out Of Sync",
    0x13: "Value Not Allowed", 0xFC: "Write Request Rejected", 0xFD: "CCCD Improperly Configured",
    0xFE: "Procedure Already In Progress", 0xFF: "Out Of Range",
}
DATA_WRITE_OPS = {"WriteReq", "WriteCmd", "SignedWriteCmd", "LongWrite"}

SMP_CODES = {
    0x01: "PairingRequest", 0x02: "PairingResponse", 0x03: "PairingConfirm",
    0x04: "PairingRandom", 0x05: "PairingFailed", 0x06: "EncryptionInformation",
    0x07: "CentralIdentification", 0x08: "IdentityInformation",
    0x09: "IdentityAddressInformation", 0x0A: "SigningInformation",
    0x0B: "SecurityRequest", 0x0C: "PairingPublicKey", 0x0D: "PairingDHKeyCheck",
    0x0E: "KeypressNotification",
}
SMP_IO = {0: "DisplayOnly", 1: "DisplayYesNo", 2: "KeyboardOnly", 3: "NoInputNoOutput", 4: "KeyboardDisplay"}
SMP_FAIL = {
    1: "Passkey Entry Failed", 2: "OOB Not Available", 3: "Authentication Requirements",
    4: "Confirm Value Failed", 5: "Pairing Not Supported", 6: "Encryption Key Size",
    7: "Command Not Supported", 8: "Unspecified Reason", 9: "Repeated Attempts",
    0x0A: "Invalid Parameters", 0x0B: "DHKey Check Failed", 0x0C: "Numeric Comparison Failed",
    0x0D: "BR/EDR Pairing In Progress", 0x0E: "Cross-transport Key Derivation Not Allowed",
    0x0F: "Key Rejected",
}
HCI_REASONS = {
    0x05: "Authentication Failure", 0x06: "PIN or Key Missing", 0x08: "Connection Timeout",
    0x13: "Remote User Terminated", 0x14: "Remote Low Resources", 0x15: "Remote Power Off",
    0x16: "Local Host Terminated", 0x1F: "Unspecified Error", 0x22: "LL Response Timeout",
    0x28: "Instant Passed", 0x3B: "Unacceptable Connection Parameters",
    0x3D: "MIC Failure", 0x3E: "Failed To Establish",
}
LE_SIG = {
    0x01: "CommandReject", 0x06: "DisconnReq", 0x07: "DisconnRsp", 0x12: "ConnParamUpdateReq",
    0x13: "ConnParamUpdateRsp", 0x14: "LeCreditConnReq", 0x15: "LeCreditConnRsp",
    0x16: "FlowControlCredit", 0x17: "CreditConnReq", 0x18: "CreditConnRsp",
    0x19: "CreditReconfReq", 0x1A: "CreditReconfRsp",
}
EATT_PSM = 0x0027


def _u16(b: bytes, o: int = 0) -> int:
    return int.from_bytes(b[o:o + 2], "little")


def _u32(b: bytes, o: int = 0) -> int:
    return int.from_bytes(b[o:o + 4], "little")


def _addr(b: bytes) -> str:
    return ":".join(f"{x:02X}" for x in reversed(b[:6]))


def _reason(code: int) -> str:
    return f"0x{code:02x} {HCI_REASONS.get(code, '')}".strip()


def _hex(b: bytes, limit: int | None = None) -> str:
    if limit is not None and len(b) > limit:
        return b[:limit].hex(" ") + " .."
    return b.hex(" ")


def _ascii(b: bytes) -> str | None:
    t = b.rstrip(b"\0")
    if len(t) >= 1 and all(32 <= c < 127 for c in t) and b"\0" not in t:
        return t.decode("ascii")
    return None


# --------------------------------------------------------------------------
# Value decoders ("decoded meaning where known")
# --------------------------------------------------------------------------


def fuji_chunk(v: bytes) -> tuple[int, int] | None:
    """FILE_PARTIAL_DATA framing (fuji-bridge FujiBackup.swift): u16 seq,
    u32 len, len bytes; seq 0xFFFF is the last chunk and its data ends with a
    u16 sum of all data bytes. Returns (seq, len) when it fits exactly."""
    if len(v) < 6:
        return None
    seq, n = struct.unpack_from("<HI", v)
    if 6 + n == len(v):
        return seq, n
    return None


def _generic(v: bytes) -> str:
    if not v:
        return ""
    if FUJI_BACKUP_MAGIC in v[:64]:
        return f"contains {FUJI_BACKUP_MAGIC.decode()} magic"
    fc = fuji_chunk(v)
    if fc and fc[1] > 0:
        return f"fuji chunk? seq={'LAST' if fc[0] == 0xFFFF else fc[0]} len={fc[1]}"
    a = _ascii(v)
    if a is not None and len(a) >= 3:
        return repr(a)
    if len(v) == 1:
        return f"={v[0]}"
    if len(v) == 2:
        return f"u16={_u16(v)}"
    if len(v) == 4:
        return f"u32={_u32(v)}"
    return ""


def _enum16(table: dict[int, str], what: str):
    def f(v: bytes, op: str) -> str:
        if len(v) < 2:
            return _generic(v)
        x = _u16(v)
        label = table.get(x)
        return f"{what} {x} ({label})" if label else f"{what} {x} (UNKNOWN value)"
    return f


def _text(what: str):
    def f(v: bytes, op: str) -> str:
        a = _ascii(v)
        return f'{what} "{a}"' if a is not None else _generic(v)
    return f


def _dec_secure_status(v: bytes, op: str) -> str:
    if len(v) == 4:
        return f"status {v.hex()}" + (" (byte 3 = 0x20: client ack)" if v[3] == 0x20 else "")
    return _generic(v)


def _dec_file_info(v: bytes, op: str) -> str:
    if len(v) == 44:
        raw = v[:40].split(b"\0", 1)[0]
        if all(32 <= c < 127 for c in raw):
            return f'file "{raw.decode()}" size {_u32(v, 40)}'
    return _generic(v)


def _dec_chunk(v: bytes, op: str) -> str:
    fc = fuji_chunk(v)
    if fc:
        seq, n = fc
        if seq == 0xFFFF:
            return f"LAST chunk len={n} (ends with u16 sum {_u16(v, len(v) - 2):#06x})"
        extra = f"; {FUJI_BACKUP_MAGIC.decode()} magic" if FUJI_BACKUP_MAGIC in v[6:40] else ""
        return f"chunk seq={seq} len={n}{extra}"
    if len(v) >= 6:
        seq, n = struct.unpack_from("<HI", v)
        if 6 + n < len(v):
            return f"chunk? seq={seq} len={n} (+{len(v) - 6 - n} extra bytes)"
    return _generic(v)


def _dec_txn_state(v: bytes, op: str) -> str:
    if len(v) >= 2:
        x = _u16(v)
        label = {1: "chunk ready", 2: "chunk ready", 3: "transfer complete"}.get(x, "UNKNOWN")
        rest = f" +{v[2:].hex()}" if len(v) > 2 else ""
        return f"state {x} ({label}){rest}"
    return _generic(v)


def _dec_datetime(v: bytes, op: str) -> str:
    if len(v) >= 7:
        y = _u16(v)
        return f"{y:04d}-{v[2]:02d}-{v[3]:02d} {v[4]:02d}:{v[5]:02d}:{v[6]:02d}"
    return _generic(v)


def _dec_geotag(v: bytes, op: str) -> str:
    if len(v) >= 23:
        lat, lon, alt = struct.unpack_from("<iii", v)
        y = _u16(v, 16)
        return (f"lat {lat / 1e7:.5f} lon {lon / 1e7:.5f} alt {alt} "
                f"{y:04d}-{v[18]:02d}-{v[19]:02d} {v[20]:02d}:{v[21]:02d}:{v[22]:02d}")
    return _generic(v)


def _dec_cccd(v: bytes, op: str) -> str:
    if len(v) >= 2:
        x = _u16(v)
        return {0: "notifications OFF", 1: "enable NOTIFY", 2: "enable INDICATE",
                3: "enable notify+indicate"}.get(x, f"CCCD {x:#06x}")
    return _generic(v)


def _dec_service_changed(v: bytes, op: str) -> str:
    if len(v) >= 4:
        return f"service changed 0x{_u16(v):04x}-0x{_u16(v, 2):04x}"
    return _generic(v)


VALUE_DECODERS = {
    "f14e7a88": _enum16({1: "settings backup", 2: "IPTC"}, "backup request"),
    "600655e6": _enum16({1: "import images", 3: "in-camera viewing (Wi-Fi)", 4: "remote shooting (Wi-Fi)",
                         5: "firmware update"}, "function"),
    "7fcf49c6": _enum16({0: "release", 1: "shutter command", 2: "press", 3: "half-press / focus"}, "shutter"),
    "85b9163e": _text("client name"),
    "f557d96b": _dec_secure_status,
    "aba356eb": lambda v, op: f"token {v.hex()}",
    "051dd980": lambda v, op: f"index {_u32(v)}" if len(v) == 4 else _generic(v),
    "7f3400fe": lambda v, op: f"partial size {_u32(v)}" if len(v) == 4 else _generic(v),
    "c922ac69": _dec_file_info,
    "ac0c799a": _dec_chunk,
    "68052e8a": _enum16({3: "finish / OK", 0: "abort / error"}, "result"),
    "2e27ed9f": _dec_txn_state,
    "11438c83": lambda v, op: {0: "backup state 0 (busy)", 1: "backup state 1 (ready)"}.get(v[0], f"backup state {v[0]}") if v else "",
    "a68e3f66": lambda v, op: {0: "AP busy", 1: "AP up"}.get(v[0], f"AP state {v[0]}") if v else "",
    "bf6dc9cf": _text("SSID"),
    "e809256a": lambda v, op: f"Wi-Fi password ({len(v.rstrip(bytes(1)))} chars, not shown)",
    "c95d91ae": lambda v, op: f"geotag interval {_u16(v)} s" if len(v) >= 2 else _generic(v),
    "b9bfd37f": _dec_datetime,
    "0f36ec14": _dec_geotag,
    "68887a7a": _text("lens"),
    "621a98d8": _text("lens fw"),
    "2902": _dec_cccd,
    "2a05": _dec_service_changed,
    "2a00": _text("name"), "2a24": _text("model"), "2a25": _text("serial"),
    "2a26": _text("firmware"), "2a27": _text("hardware"), "2a28": _text("software"),
    "2a29": _text("manufacturer"),
}


def describe_value(uuid: str | None, value: bytes, op: str = "") -> str:
    fn = VALUE_DECODERS.get(short_uuid(uuid)) if uuid else None
    if fn:
        try:
            return fn(value, op)
        except Exception:
            pass
    return _generic(value)


# --------------------------------------------------------------------------
# GATT databases and handle maps
# --------------------------------------------------------------------------


@dataclass
class Attr:
    uuid: str
    kind: str                 # service | include | decl | value | desc | attr
    props: str = ""           # r w x n i (read, write, write-no-rsp, notify, indicate)
    src: str = "discovered"   # discovered | user | profile


class GattDb:
    def __init__(self, src: str = "discovered"):
        self.src = src
        self.attrs: dict[int, Attr] = {}
        self.services: dict[int, tuple[int, str]] = {}   # start -> (end, uuid)

    def __len__(self) -> int:
        return len(self.attrs)

    def put(self, h: int, uuid: str, kind: str, props: str = "") -> None:
        cur = self.attrs.get(h)
        if cur and cur.kind in ("value", "service", "decl") and kind == "attr":
            return
        self.attrs[h] = Attr(uuid, kind, props or (cur.props if cur else ""), self.src)

    def add_service(self, start: int, end: int, uuid: str) -> None:
        self.services[start] = (end, uuid)
        self.put(start, uuid, "service")

    def add_char(self, decl: int, vh: int, uuid: str, props: str) -> None:
        self.put(decl, uuid16(CHARACTERISTIC), "decl", props)
        self.put(vh, uuid, "value", props)

    def get(self, h: int) -> Attr | None:
        return self.attrs.get(h)

    def owner(self, h: int) -> tuple[int, Attr] | None:
        """The characteristic value a descriptor handle belongs to."""
        best = None
        for vh, a in self.attrs.items():
            if a.kind == "value" and vh < h and (best is None or vh > best[0]):
                best = (vh, a)
        if best is None:
            return None
        # don't cross a service or characteristic declaration
        for k, a in self.attrs.items():
            if best[0] < k < h and a.kind in ("service", "decl"):
                return None
        return best


_PROPS_BITS = [(0x02, "r"), (0x04, "x"), (0x08, "w"), (0x10, "n"), (0x20, "i")]


def _props_str(p: int) -> str:
    return "".join(ch for bit, ch in _PROPS_BITS if p & bit)


def profile_db(name: str) -> GattDb | None:
    if name in ("", "none", None):
        return None
    if name != "ad14d4":
        raise ValueError(f"unknown profile {name!r} (known: ad14d4, none)")
    return _db_from_table(_PROFILE_AD14D4, "profile")


def _db_from_table(text: str, src: str) -> GattDb:
    db = GattDb(src)
    rows = [ln.split() for ln in text.strip().splitlines() if ln.strip() and not ln.startswith("#")]
    for row in rows:
        if row[0] == "S":
            db.put(int(row[1], 16), norm_uuid(row[2]) or row[2], "service")
        elif row[0] == "C":
            decl = int(row[1], 16)
            u = norm_uuid(row[2]) or row[2]
            props = row[3] if len(row) > 3 else ""
            db.add_char(decl, decl + 1, u, props)
            if "n" in props or "i" in props:
                db.put(decl + 2, CCCD, "desc")
    return db


def _fffw_yaml_to_table(text: str) -> str:
    rows: list[str] = []
    cur: list | None = None
    for line in text.splitlines():
        m = re.match(r"^-\s+index:\s*(0x[0-9a-fA-F]+)", line)
        if m:
            cur = ["S", m.group(1), None]
            rows.append(cur)  # type: ignore[arg-type]
            continue
        m = re.match(r"^\s+-\s+index:\s*(0x[0-9a-fA-F]+)", line)
        if m:
            cur = ["C", m.group(1), None, ""]
            rows.append(cur)  # type: ignore[arg-type]
            continue
        m = re.match(r"^\s+uuid:\s*'?([0-9a-fA-F-]+)'?", line)
        if m and cur is not None:
            cur[2] = m.group(1)
            continue
        m = re.match(r"^\s+-\s+(read|write|notify|indicate)\s*$", line)
        if m and cur is not None and cur[0] == "C":
            cur[3] += m.group(1)[0]
    return "\n".join(" ".join(str(x) for x in r if x is not None) for r in rows if r[2])


def _parse_handle(v: Any) -> int | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v if 0 < v <= 0xFFFF else None
    if isinstance(v, str):
        t = v.strip().lower()
        try:
            h = int(t, 16) if t.startswith("0x") else int(t)
        except ValueError:
            return None
        return h if 0 < h <= 0xFFFF else None
    return None


def load_handle_map(path: str | Path, offset: int = 0) -> GattDb:
    """A handle -> UUID table for captures without discovery. Accepts:
    * JSON {"0x900b": "ac0c799a-...", ...} or {"ac0c799a-...": 36875, ...}
    * any JSON (e.g. our `ble dump`) holding objects with "handle" + "uuid"
      keys, at any depth; objects with "characteristics" count as services
    * an fffw gatt-*.yaml (index = declaration handle, value = index + 1)
    * another capture (.pklg/.btsnoop/.pcap...) that contains GATT discovery,
      e.g. the first capture where the app paired: its discovered table is reused
    `offset` is added to every handle (use 1 if a dump lists declaration
    handles rather than value handles)."""
    p = Path(path)
    raw = p.read_bytes()
    if (p.suffix.lower() in CAPTURE_SUFFIXES or raw.startswith(BTSNOOP_MAGIC)
            or raw[:4] in (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4", b"\x0a\x0d\x0d\x0a")):
        other = decode_bytes(raw, str(p), profile="none")
        db = GattDb("user")
        for (peer, side), d in other.dbs.items():
            if side == "remote" and (other.focus is None or peer in other.focus):
                for h, a in d.attrs.items():
                    db.attrs.setdefault(h, Attr(a.uuid, a.kind, a.props, "user"))
        if not db.attrs:
            raise ValueError(f"{path}: that capture has no GATT discovery to borrow handles from")
        return _shift(db, offset)
    text = raw.decode("utf-8", "replace")
    if p.suffix.lower() in (".yaml", ".yml") or re.search(r"^-\s+index:", text, re.M):
        db = _db_from_table(_fffw_yaml_to_table(text), "user")
    else:
        db = GattDb("user")
        obj = json.loads(text)

        def walk(o: Any, depth: int = 0) -> None:
            if depth > 12:
                return
            if isinstance(o, dict):
                h = _parse_handle(o.get("handle"))
                u = norm_uuid(o.get("uuid")) if isinstance(o.get("uuid"), (str, int)) else None
                if h is not None and u:
                    kind = o.get("kind") if o.get("kind") in ("service", "include", "decl", "value", "desc", "attr") else (
                        "service" if "characteristics" in o else (
                            "desc" if sig16(u) is not None and 0x2900 <= (sig16(u) or 0) <= 0x29FF else "value"))
                    props = o.get("properties") or o.get("props") or ""
                    if isinstance(props, list):
                        props = "".join({"read": "r", "write": "w", "write-without-response": "x",
                                         "notify": "n", "indicate": "i"}.get(str(x).lower(), "") for x in props)
                    db.put(h, u, kind, props if isinstance(props, str) else "")
                for k, v in o.items():
                    hk = _parse_handle(k) if isinstance(k, str) and re.fullmatch(r"(0x)?[0-9a-fA-F]+", k.strip()) else None
                    if hk is not None and isinstance(v, str) and norm_uuid(v):
                        db.put(hk, norm_uuid(v) or v, "value")
                    elif isinstance(k, str) and len(k) > 4 and norm_uuid(k) and _parse_handle(v) is not None:
                        db.put(_parse_handle(v) or 0, norm_uuid(k) or k, "value")
                    else:
                        walk(v, depth + 1)
            elif isinstance(o, list):
                for v in o:
                    walk(v, depth + 1)

        walk(obj)
    return _shift(db, offset)


CAPTURE_SUFFIXES = {".pklg", ".btsnoop", ".log", ".cfa", ".pcap", ".pcapng", ".snoop"}


def _shift(db: GattDb, offset: int) -> GattDb:
    if not offset:
        return db
    shifted = GattDb(db.src)
    for h, a in db.attrs.items():
        if 0 < h + offset <= 0xFFFF:
            shifted.attrs[h + offset] = a
    return shifted


def save_handle_map(dec: "Decoded", path: str | Path) -> int:
    """Write the camera's discovered handle table as JSON usable with --handles."""
    rows = []
    for (peer, side), db in sorted(dec.dbs.items()):
        if side != "remote" or (dec.focus is not None and peer not in dec.focus):
            continue
        for h, a in sorted(db.attrs.items()):
            rows.append({"handle": f"0x{h:04x}", "uuid": a.uuid, "kind": a.kind, "props": a.props,
                         "name": uuid_name(a.uuid), "peer": peer})
    Path(path).write_text(json.dumps({"source": dec.path, "source_sha256": dec.sha256, "handles": rows}, indent=2) + "\n")
    return len(rows)


# --------------------------------------------------------------------------
# Decoder: HCI -> L2CAP -> ATT/SMP
# --------------------------------------------------------------------------


@dataclass
class Event:
    n: int
    rec: int
    ts: float
    layer: str                  # hci | att | smp | l2cap | note
    op: str
    dir: str = ""               # out = phone -> device, in = device -> phone
    conn: int | None = None
    peer: str | None = None
    handle: int | None = None
    side: str | None = None     # GATT server: remote (device) or local (phone)
    value: bytes = b""
    offset: int | None = None
    status: str | None = None
    info: str = ""
    uuid: str | None = None
    name: str | None = None
    map_src: str = ""
    meaning: str = ""
    cid: int | None = None
    frags: int = 1
    superseded: bool = False    # a part of a LongWrite/LongRead (that event has the value)
    synthetic: bool = False     # LongWrite / LongRead / reassembled values
    parts: list[int] = field(default_factory=list)
    reply: int | None = None    # for requests: event number of the response

    def to_json(self, t0: float = 0.0) -> dict[str, Any]:
        d: dict[str, Any] = {
            "n": self.n, "record": self.rec, "t": round(self.ts - t0, 6), "layer": self.layer,
            "op": self.op, "dir": self.dir,
        }
        for k in ("conn", "peer", "handle", "side", "offset", "status", "uuid", "name", "map_src", "cid"):
            v = getattr(self, k)
            if v not in (None, ""):
                d[k] = v
        if self.handle is not None:
            d["handle_hex"] = f"0x{self.handle:04x}"
        if self.value or self.layer == "att":
            d["len"] = len(self.value)
            d["value_hex"] = self.value.hex()
        if self.info:
            d["info"] = self.info
        if self.meaning:
            d["meaning"] = self.meaning
        if self.frags > 1:
            d["acl_fragments"] = self.frags
        if self.superseded:
            d["superseded"] = True
        if self.synthetic:
            d["synthetic"] = True
        if self.parts:
            d["parts"] = self.parts
        if self.reply is not None:
            d["reply"] = self.reply
        return d


@dataclass
class Conn:
    handle: int
    peer: str | None = None
    peer_type: int | None = None
    role: str | None = None
    start: float | None = None
    end: float | None = None
    encrypted: bool = False
    mtu: int = 23
    client_mtu: int | None = None
    server_mtu: int | None = None
    disconnect: str | None = None
    acl: dict = field(default_factory=dict)
    pending: dict = field(default_factory=dict)
    prepq: dict = field(default_factory=dict)
    reads: dict = field(default_factory=dict)
    eatt_chan: dict = field(default_factory=dict)
    sig_pending: dict = field(default_factory=dict)
    sdu: dict = field(default_factory=dict)
    att_bytes: Counter = field(default_factory=Counter)
    transport: str = "LE"
    other_l2cap: int = 0

    @property
    def key(self) -> str:
        return self.peer or f"conn-0x{self.handle:04x}"


class Decoder:
    def __init__(self, keep_notes: bool = True):
        self.keep_notes = keep_notes
        self.events: list[Event] = []
        self.warnings: list[str] = []
        self.conns: dict[int, Conn] = {}
        self.all_conns: list[Conn] = []
        self.dbs: dict[tuple[str, str], GattDb] = {}
        self.adverts: dict[str, dict[str, Any]] = {}
        self.kind_counts: Counter = Counter()
        self.t0: float | None = None
        self.t_end: float | None = None
        self._cur_rec = 0

    # -- plumbing ---------------------------------------------------------
    def warn(self, rec: HciRecord | None, msg: str) -> None:
        where = f"record {rec.n}: " if rec is not None else ""
        self.warnings.append(where + msg)

    def emit(self, rec: HciRecord, layer: str, op: str, **kw: Any) -> Event:
        ev = Event(len(self.events), rec.n, rec.ts, layer, op, **kw)
        self.events.append(ev)
        return ev

    def conn(self, h: int, rec: HciRecord | None = None) -> Conn:
        c = self.conns.get(h)
        if c is None:
            c = Conn(h, start=rec.ts if rec else None)
            self.conns[h] = c
            self.all_conns.append(c)
        return c

    def peer_of(self, h: int) -> str:
        c = self.conns.get(h)
        return c.key if c else f"conn-0x{h:04x}"

    def db(self, c: Conn, side: str) -> GattDb:
        k = (c.key, side)
        if k not in self.dbs:
            self.dbs[k] = GattDb("discovered")
        return self.dbs[k]

    def feed(self, rec: HciRecord) -> None:
        self.kind_counts[rec.kind] += 1
        if self.t0 is None and rec.ts > 0:
            self.t0 = rec.ts
        self.t_end = rec.ts
        if rec.truncated and rec.kind in ("acl", "cmd", "evt"):
            self.warn(rec, f"truncated {rec.kind} record skipped")
            return
        try:
            if rec.kind == "acl":
                self._acl(rec)
            elif rec.kind == "evt":
                self._evt(rec)
            elif rec.kind == "cmd":
                self._cmd(rec)
            elif rec.kind in TEXT_KINDS:
                self._note(rec)
        except Exception as exc:  # a malformed packet must never stop the run
            self.warn(rec, f"decode error ({type(exc).__name__}: {exc})")

    # -- HCI --------------------------------------------------------------
    def _cmd(self, rec: HciRecord) -> None:
        d = rec.data
        if len(d) < 3:
            return
        opcode, plen = _u16(d), d[2]
        p = d[3:3 + plen]
        if opcode == 0x2019 and len(p) >= 2:      # LE Enable Encryption
            self.emit(rec, "hci", "LE StartEncryption", conn=_u16(p) & 0xFFF, peer=self.peer_of(_u16(p) & 0xFFF),
                      info="LTK in capture (link plaintext at HCI anyway)")
        elif opcode == 0x201A and len(p) >= 2:
            self.emit(rec, "hci", "LE LtkReply", conn=_u16(p) & 0xFFF, peer=self.peer_of(_u16(p) & 0xFFF))
        elif opcode == 0x201B and len(p) >= 2:
            self.emit(rec, "hci", "LE LtkNegReply", conn=_u16(p) & 0xFFF, peer=self.peer_of(_u16(p) & 0xFFF),
                      info="no key for this peer")
        elif opcode == 0x0406 and len(p) >= 3:
            self.emit(rec, "hci", "Disconnect", conn=_u16(p) & 0xFFF, peer=self.peer_of(_u16(p) & 0xFFF),
                      info=f"reason {_reason(p[2])}")
        elif opcode == 0x200D and len(p) >= 12:
            self.emit(rec, "hci", "LE CreateConnection", peer=_addr(p[6:12]), info=f"to {_addr(p[6:12])}")
        elif opcode == 0x2043 and len(p) >= 9:
            self.emit(rec, "hci", "LE ExtCreateConnection", peer=_addr(p[3:9]), info=f"to {_addr(p[3:9])}")

    def _evt(self, rec: HciRecord) -> None:
        d = rec.data
        if len(d) < 2:
            return
        code, plen = d[0], d[1]
        p = d[2:2 + plen]
        if code == 0x3E and p:
            self._le_meta(rec, p)
        elif code == 0x05 and len(p) >= 4:        # Disconnection Complete
            h = _u16(p, 1) & 0xFFF
            c = self.conns.pop(h, None)
            if c is None:
                c = Conn(h)
                self.all_conns.append(c)
            c.end = rec.ts
            c.disconnect = _reason(p[3])
            self._flush_conn(rec, c)
            self.emit(rec, "hci", "Disconnected", conn=h, peer=c.key,
                      status="ok" if p[0] == 0 else f"error 0x{p[0]:02x}", info=f"reason {_reason(p[3])}")
        elif code in (0x08, 0x59) and len(p) >= 4:  # Encryption Change (v1/v2)
            h = _u16(p, 1) & 0xFFF
            c = self.conn(h, rec)
            on = p[3] != 0 and p[0] == 0
            c.encrypted = on
            info = ("encryption ON" if on else "encryption OFF") + (f", key size {p[4]}" if code == 0x59 and len(p) >= 5 else "")
            self.emit(rec, "hci", "EncryptionChange", conn=h, peer=c.key,
                      status="ok" if p[0] == 0 else f"error 0x{p[0]:02x} {HCI_REASONS.get(p[0], '')}".strip(), info=info)
        elif code == 0x30 and len(p) >= 3:
            h = _u16(p, 1) & 0xFFF
            self.emit(rec, "hci", "EncryptionKeyRefresh", conn=h, peer=self.peer_of(h),
                      status="ok" if p[0] == 0 else f"error 0x{p[0]:02x}")
        elif code == 0x03 and len(p) >= 11:       # BR/EDR Connection Complete
            h = _u16(p, 1) & 0xFFF
            if p[0] == 0:
                old = self.conns.pop(h, None)
                if old is not None:
                    self._flush_conn(rec, old)
                c = Conn(h, peer=_addr(p[3:9]), role="BR/EDR", start=rec.ts, transport="BR/EDR")
                self.conns[h] = c
                self.all_conns.append(c)
            self.emit(rec, "hci", "Connected (BR/EDR)", conn=h, peer=_addr(p[3:9]),
                      status="ok" if p[0] == 0 else f"error 0x{p[0]:02x}")
        elif code == 0x0F and len(p) >= 4 and p[0] != 0:  # Command Status failure
            op = _u16(p, 2)
            if op in (0x200D, 0x2043, 0x2019):
                self.emit(rec, "hci", "CommandFailed", info=f"opcode 0x{op:04x} status 0x{p[0]:02x}")

    def _le_meta(self, rec: HciRecord, p: bytes) -> None:
        sub = p[0]
        q = p[1:]
        if sub in (0x01, 0x0A, 0x29) and len(q) >= 11:  # (Enhanced) Connection Complete
            status, h, role, ptype = q[0], _u16(q, 1) & 0xFFF, q[3], q[4]
            peer = _addr(q[5:11])
            if status != 0:
                self.emit(rec, "hci", "ConnectFailed", peer=peer, status=f"error 0x{status:02x}")
                return
            old = self.conns.pop(h, None)
            if old is not None:
                self._flush_conn(rec, old)
            c = Conn(h, peer=peer, peer_type=ptype, role="central" if role == 0 else "peripheral", start=rec.ts)
            self.conns[h] = c
            self.all_conns.append(c)
            adv = self.adverts.get(peer, {})
            if sub in (0x0A, 0x29) and len(q) >= 23 and not adv:
                rpa = _addr(q[17:23])          # peer RPA when the controller resolved it
                if rpa in self.adverts:
                    adv = self.adverts[rpa]
                    self.adverts.setdefault(peer, adv)
            tag = " (Fujifilm advert)" if adv.get("fuji") else ""
            nm = f' "{adv["name"]}"' if adv.get("name") else ""
            self.emit(rec, "hci", "Connected", conn=h, peer=peer,
                      info=f"LE, phone is {c.role}, peer {peer}{nm}{tag}")
        elif sub == 0x03 and len(q) >= 9:
            h = _u16(q, 1) & 0xFFF
            self.emit(rec, "hci", "ConnUpdate", conn=h, peer=self.peer_of(h),
                      info=f"interval {_u16(q, 3) * 1.25:.2f} ms latency {_u16(q, 5)} timeout {_u16(q, 7) * 10} ms")
        elif sub == 0x05 and len(q) >= 2:
            self.emit(rec, "hci", "LE LtkRequest", conn=_u16(q) & 0xFFF, peer=self.peer_of(_u16(q) & 0xFFF))
        elif sub == 0x07 and len(q) >= 10:
            h = _u16(q) & 0xFFF
            self.emit(rec, "hci", "DataLength", conn=h, peer=self.peer_of(h), info=f"tx {_u16(q, 2)} B / rx {_u16(q, 6)} B per LL packet")
        elif sub == 0x0C and len(q) >= 5:
            self.emit(rec, "hci", "PhyUpdate", conn=_u16(q, 1) & 0xFFF, peer=self.peer_of(_u16(q, 1) & 0xFFF), info=f"tx PHY {q[3]} rx PHY {q[4]}")
        elif sub == 0x02 and q:
            self._adv_reports(rec, q, extended=False)
        elif sub == 0x0D and q:
            self._adv_reports(rec, q, extended=True)

    def _adv_reports(self, rec: HciRecord, q: bytes, extended: bool) -> None:
        num, o = q[0], 1
        for _ in range(min(num, 32)):
            if extended:
                if o + 24 > len(q):
                    return
                addr = _addr(q[o + 3:o + 9])
                dlen = q[o + 23]
                data = q[o + 24:o + 24 + dlen]
                o += 24 + dlen
            else:
                if o + 9 > len(q):
                    return
                addr = _addr(q[o + 2:o + 8])
                dlen = q[o + 8]
                data = q[o + 9:o + 9 + dlen]
                o += 9 + dlen + 1
            info = self.adverts.setdefault(addr, {"count": 0, "fuji": False, "name": None, "first": rec.ts})
            info["count"] += 1
            i = 0
            while i < len(data):
                ln = data[i]
                if ln == 0 or i + 1 + ln > len(data):
                    break
                t, v = data[i + 1], data[i + 2:i + 1 + ln]
                if t == 0xFF and len(v) >= 2 and _u16(v) == FUJI_COMPANY_ID:
                    info["fuji"] = True
                    info["mfg"] = v.hex()
                elif t in (0x08, 0x09):
                    info["name"] = v.decode("utf-8", "replace")
                elif t in (0x06, 0x07) and any(uuid_from_le(v[k:k + 16]) in FUJI_SERVICES for k in range(0, len(v) - 15, 16)):
                    info["fuji"] = True
                i += 1 + ln

    def _note(self, rec: HciRecord) -> None:
        if not self.keep_notes:
            return
        d = rec.data
        if rec.kind == "syslog" and len(d) > 5:
            parts = [x.decode("utf-8", "replace") for x in d[5:].split(b"\0")]
            parts = [x for x in parts if x]
            text = f"{parts[0]}: {parts[-1]}" if len(parts) >= 2 else (parts[0] if parts else "")
        else:
            text = d.split(b"\0", 1)[0].decode("utf-8", "replace")
        self.emit(rec, "note", rec.kind, info=text[:300])

    # -- ACL / L2CAP ------------------------------------------------------
    def _acl(self, rec: HciRecord) -> None:
        d = rec.data
        if len(d) < 4:
            self.warn(rec, "ACL packet shorter than its header")
            return
        hdr, dlen = struct.unpack_from("<HH", d)
        h, pb = hdr & 0x0FFF, (hdr >> 12) & 3
        frag = d[4:4 + dlen]
        if len(frag) < dlen:
            self.warn(rec, f"ACL data truncated ({len(frag)} of {dlen} bytes)")
        c = self.conn(h, rec)
        sent = bool(rec.sent)
        buf = c.acl.get(sent)
        if pb in (0b00, 0b10, 0b11):              # start of an L2CAP PDU
            if buf:
                self.warn(rec, f"new L2CAP start on 0x{h:03x} while {len(buf[0])} bytes were pending; dropped them")
            buf = [bytearray(frag), 1]
        else:                                     # continuation
            if not buf:
                self.warn(rec, f"ACL continuation on 0x{h:03x} without a start; dropped")
                return
            buf[0] += frag
            buf[1] += 1
        data = buf[0]
        if len(data) >= 4:
            ln, cid = struct.unpack_from("<HH", data)
            if len(data) >= 4 + ln:
                if len(data) > 4 + ln:
                    self.warn(rec, f"{len(data) - 4 - ln} extra bytes after L2CAP PDU on 0x{h:03x}; ignored")
                c.acl.pop(sent, None)
                self._l2cap(rec, c, sent, cid, bytes(data[4:4 + ln]), buf[1])
                return
        c.acl[sent] = buf

    def _l2cap(self, rec: HciRecord, c: Conn, sent: bool, cid: int, pdu: bytes, frags: int) -> None:
        if cid == 0x0004:
            self._att(rec, c, sent, 0, pdu, frags)
        elif cid == 0x0006:
            self._smp(rec, c, sent, pdu)
        elif cid == 0x0005:
            self._le_sig(rec, c, sent, pdu)
        elif cid in c.eatt_chan:
            self._eatt(rec, c, sent, cid, pdu, frags)
        else:
            # BR/EDR signalling, audio (A2DP/AVDTP), Apple's own channels ...: count only
            c.other_l2cap += 1

    def _eatt(self, rec: HciRecord, c: Conn, sent: bool, cid: int, pdu: bytes, frags: int) -> None:
        key = (sent, cid)
        st = c.sdu.get(key)
        if st is None:
            if len(pdu) < 2:
                return
            want = _u16(pdu)
            st = [want, bytearray(pdu[2:])]
        else:
            st[1] += pdu
        if len(st[1]) >= st[0]:
            c.sdu.pop(key, None)
            self._att(rec, c, sent, c.eatt_chan[cid], bytes(st[1][:st[0]]), frags)
        else:
            c.sdu[key] = st

    def _le_sig(self, rec: HciRecord, c: Conn, sent: bool, pdu: bytes) -> None:
        if len(pdu) < 4:
            return
        code, ident, ln = pdu[0], pdu[1], _u16(pdu, 2)
        p = pdu[4:4 + ln]
        name = LE_SIG.get(code, f"Signal 0x{code:02x}")
        info = ""
        if code == 0x12 and len(p) >= 8:
            info = (f"interval {_u16(p) * 1.25:.2f}-{_u16(p, 2) * 1.25:.2f} ms latency {_u16(p, 4)} "
                    f"timeout {_u16(p, 6) * 10} ms")
        elif code == 0x13 and len(p) >= 2:
            info = "accepted" if _u16(p) == 0 else "rejected"
        elif code == 0x14 and len(p) >= 10:
            spsm, scid = _u16(p), _u16(p, 2)
            c.sig_pending[ident] = (spsm, [scid])
            info = f"SPSM 0x{spsm:04x} scid 0x{scid:04x} mtu {_u16(p, 4)}" + (" (EATT)" if spsm == EATT_PSM else "")
        elif code == 0x15 and len(p) >= 10:
            dcid, result = _u16(p), _u16(p, 8)
            spsm, scids = c.sig_pending.pop(ident, (None, []))
            if result == 0 and spsm == EATT_PSM:
                self._add_eatt(c, scids + [dcid])
            info = f"dcid 0x{dcid:04x} result {result}"
        elif code == 0x17 and len(p) >= 8:
            spsm = _u16(p)
            scids = [_u16(p, i) for i in range(8, len(p) - 1, 2)]
            c.sig_pending[ident] = (spsm, scids)
            info = f"SPSM 0x{spsm:04x} cids {[hex(x) for x in scids]}" + (" (EATT)" if spsm == EATT_PSM else "")
        elif code == 0x18 and len(p) >= 8:
            result = _u16(p, 6)
            dcids = [_u16(p, i) for i in range(8, len(p) - 1, 2)]
            spsm, scids = c.sig_pending.pop(ident, (None, []))
            if spsm == EATT_PSM:
                for s, dd in zip(scids, dcids):
                    if dd:
                        self._add_eatt(c, [s, dd])
            info = f"result {result} cids {[hex(x) for x in dcids]}"
        self.emit(rec, "l2cap", name, dir="out" if sent else "in", conn=c.handle, peer=c.key, info=info)

    def _add_eatt(self, c: Conn, cids: list[int]) -> None:
        chan = 1 + len(set(c.eatt_chan.values()))
        for x in cids:
            if x:
                c.eatt_chan[x] = chan
        self.warnings.append(f"EATT channel {chan} opened on 0x{c.handle:03x} (cids {[hex(x) for x in cids]}); decoded best-effort")

    # -- SMP --------------------------------------------------------------
    def _smp(self, rec: HciRecord, c: Conn, sent: bool, pdu: bytes) -> None:
        if not pdu:
            return
        code, p = pdu[0], pdu[1:]
        name = SMP_CODES.get(code, f"SMP 0x{code:02x}")
        info = ""
        if code in (0x01, 0x02) and len(p) >= 6:
            io, oob, auth, ks, ikd, rkd = p[:6]
            flags = []
            if auth & 0x03:
                flags.append("bonding")
            if auth & 0x04:
                flags.append("MITM")
            if auth & 0x08:
                flags.append("SecureConnections")
            if auth & 0x10:
                flags.append("keypress")
            info = (f"io={SMP_IO.get(io, io)} oob={oob} auth=[{','.join(flags)}] maxkey={ks} "
                    f"keys init=0x{ikd:02x} resp=0x{rkd:02x}")
        elif code == 0x05 and p:
            info = f"reason 0x{p[0]:02x} {SMP_FAIL.get(p[0], '')}".strip()
        elif code == 0x0B and p:
            info = f"auth=0x{p[0]:02x}"
        elif code == 0x0C:
            info = "P-256 public key (LE Secure Connections)"
        elif code == 0x06:
            info = "LTK distributed"
        elif code == 0x08:
            info = "IRK distributed"
        elif code == 0x09 and len(p) >= 7:
            info = f"identity address {_addr(p[1:7])} ({'random' if p[0] else 'public'})"
        self.emit(rec, "smp", name, dir="out" if sent else "in", conn=c.handle, peer=c.key, info=info)

    # -- ATT --------------------------------------------------------------
    def _att(self, rec: HciRecord, c: Conn, sent: bool, chan: int, pdu: bytes, frags: int) -> None:
        if not pdu:
            return
        op, p = pdu[0], pdu[1:]
        name = ATT_OPS.get(op, f"ATT 0x{op:02x}")
        client = op in ATT_CLIENT_OPS
        side = ("remote" if sent else "local") if client else ("local" if sent else "remote")
        d = "out" if sent else "in"
        c.att_bytes[d] += len(pdu)
        ev = self.emit(rec, "att", name, dir=d, conn=c.handle, peer=c.key, side=side,
                       cid=4 if chan == 0 else None, frags=frags)
        pkey = (side, chan)
        db = self.db(c, side)

        def short(what: str) -> None:
            ev.status = "malformed"
            self.warn(rec, f"short {name} ({len(pdu)} bytes): {what}")

        pend = None
        if op in ATT_RESPONSES or op == 0x01:
            pend = c.pending.pop(pkey, None)
            if pend is not None:
                pend[2].reply = ev.n
        if op in ATT_REQUESTS:
            if pkey in c.pending:
                self.warn(rec, f"{name} while {ATT_OPS.get(c.pending[pkey][0])} still unanswered")

        def wait(params: dict[str, Any]) -> None:
            c.pending[pkey] = (op, params, ev)

        if op == 0x01:  # Error Response
            if len(p) < 4:
                return short("need opcode, handle, code")
            rop, h, code = p[0], _u16(p, 1), p[3]
            msg = ATT_ERRORS.get(code, "Application Error" if 0x80 <= code <= 0x9F else "?")
            ev.handle = h
            ev.status = f"error 0x{code:02x}"
            ev.info = f"{ATT_OPS.get(rop, hex(rop))} 0x{h:04x}: {msg}"
            if code == 0x0A and rop in (0x04, 0x06, 0x08, 0x10):
                ev.info += " (end of discovery range)"
                ev.status = "end"
            elif pend is not None:
                pend[2].status = f"error 0x{code:02x} {msg}"
                for lw in pend[1].get("long", []):
                    lw.status = f"error 0x{code:02x} {msg}"
                if rop in (0x0A, 0x0C):
                    self._finish_read(rec, c, side, pend[1].get("h"))
            return
        if op == 0x02 or op == 0x03:
            if len(p) < 2:
                return short("need MTU")
            m = _u16(p)
            if op == 0x02:
                c.client_mtu = m
                ev.info = f"client Rx MTU {m}"
                wait({})
            else:
                c.server_mtu = m
                c.mtu = max(23, min(m, c.client_mtu or m))
                ev.info = f"server Rx MTU {m} -> ATT_MTU {c.mtu}"
            return
        if op == 0x04:
            if len(p) < 4:
                return short("need range")
            ev.info = f"0x{_u16(p):04x}-0x{_u16(p, 2):04x}"
            wait({})
            return
        if op == 0x05:
            if not p:
                return short("need format")
            size = 2 if p[0] == 1 else 16
            items = []
            for i in range(1, len(p) - size - 1, 2 + size):
                h, u = _u16(p, i), uuid_from_le(p[i + 2:i + 2 + size])
                db.put(h, u, "desc" if sig16(u) and 0x2900 <= (sig16(u) or 0) <= 0x29FF else "attr")
                items.append(f"0x{h:04x}={short_uuid(u)}")
            ev.info = f"{len(items)} handles: " + ", ".join(items[:6]) + (" .." if len(items) > 6 else "")
            return
        if op == 0x06:
            if len(p) < 6:
                return short("need range+type")
            typ, val = _u16(p, 4), p[6:]
            ev.info = f"0x{_u16(p):04x}-0x{_u16(p, 2):04x} type {typ:04x} value {val.hex()}"
            wait({"type": typ, "value": val})
            return
        if op == 0x07:
            found = [(_u16(p, i), _u16(p, i + 2)) for i in range(0, len(p) - 3, 4)]
            if pend and pend[1].get("type") in (PRIMARY_SERVICE, SECONDARY_SERVICE):
                su = uuid_from_le(pend[1]["value"])
                for s, e in found:
                    db.add_service(s, e, su)
            ev.info = ", ".join(f"0x{s:04x}-0x{e:04x}" for s, e in found)
            return
        if op in (0x08, 0x10):
            if len(p) < 6:
                return short("need range+uuid")
            u = uuid_from_le(p[4:])
            ev.info = f"0x{_u16(p):04x}-0x{_u16(p, 2):04x} {uuid_name(u) or short_uuid(u)}"
            wait({"uuid": u})
            return
        if op == 0x09:
            if not p or p[0] < 2:
                return short("need length")
            ln = p[0]
            want = pend[1].get("uuid") if pend else None
            items = []
            for i in range(1, len(p) - ln + 1, ln):
                h, val = _u16(p, i), p[i + 2:i + ln]
                if want == uuid16(CHARACTERISTIC) and len(val) >= 5:
                    props, vh, cu = val[0], _u16(val, 1), uuid_from_le(val[3:])
                    db.add_char(h, vh, cu, _props_str(props))
                    items.append(f"0x{vh:04x}={uuid_name(cu) or short_uuid(cu)}[{_props_str(props)}]")
                elif want == uuid16(INCLUDE) and len(val) >= 4:
                    db.put(h, uuid16(INCLUDE), "include")
                    items.append(f"include 0x{_u16(val):04x}-0x{_u16(val, 2):04x}")
                elif want:
                    db.put(h, want, "value")
                    ev.handle = ev.handle or h
                    ev.value = ev.value or val
                    items.append(f"0x{h:04x}={val.hex()}")
            ev.info = ", ".join(items[:6]) + (" .." if len(items) > 6 else "")
            return
        if op == 0x11:
            if not p or p[0] < 4:
                return short("need length")
            ln = p[0]
            items = []
            for i in range(1, len(p) - ln + 1, ln):
                s, e, u = _u16(p, i), _u16(p, i + 2), uuid_from_le(p[i + 4:i + ln])
                db.add_service(s, e, u)
                items.append(f"0x{s:04x}-0x{e:04x} {uuid_name(u) or short_uuid(u)}")
            ev.info = ", ".join(items)
            return
        if op == 0x0A:
            if len(p) < 2:
                return short("need handle")
            ev.handle = _u16(p)
            self._finish_read(rec, c, side, ev.handle)
            wait({"h": ev.handle})
            return
        if op == 0x0B:
            ev.value = p
            if pend:
                ev.handle = pend[1].get("h")
                c.reads[(side, ev.handle)] = [bytearray(p), [ev.n]]
                if len(p) < c.mtu - 1:
                    self._finish_read(rec, c, side, ev.handle)
            return
        if op == 0x0C:
            if len(p) < 4:
                return short("need handle+offset")
            ev.handle, ev.offset = _u16(p), _u16(p, 2)
            wait({"h": ev.handle, "off": ev.offset})
            return
        if op == 0x0D:
            ev.value = p
            if pend:
                ev.handle, ev.offset = pend[1].get("h"), pend[1].get("off")
                acc = c.reads.get((side, ev.handle))
                if acc is not None and ev.offset == len(acc[0]):
                    acc[0] += p
                    acc[1].append(ev.n)
                else:
                    if acc is not None:
                        self._finish_read(rec, c, side, ev.handle)
                    self.warn(rec, f"Read Blob at offset {ev.offset} without the start of the value")
                    c.reads[(side, ev.handle)] = [bytearray(b"\0" * (ev.offset or 0)) + p, [ev.n]]
                if len(p) < c.mtu - 1:
                    self._finish_read(rec, c, side, ev.handle)
            return
        if op in (0x0E, 0x20):
            hs = [_u16(p, i) for i in range(0, len(p) - 1, 2)]
            ev.info = "handles " + ", ".join(f"0x{h:04x}" for h in hs)
            wait({"hs": hs})
            return
        if op in (0x0F, 0x21):
            ev.value = p
            return
        if op in (0x12, 0x52, 0xD2):
            if len(p) < 2:
                return short("need handle")
            ev.handle = _u16(p)
            ev.value = p[2:] if op != 0xD2 else p[2:-12]
            if op == 0x12:
                ev.status = "pending"
                wait({"h": ev.handle})
            else:
                ev.status = "no-rsp"
                if op == 0xD2:
                    ev.info = "signed (12-byte signature stripped)"
            return
        if op == 0x13:
            if pend:
                ev.handle = pend[1].get("h")
                pend[2].status = "ok"
            return
        if op == 0x16:
            if len(p) < 4:
                return short("need handle+offset")
            ev.handle, ev.offset, ev.value = _u16(p), _u16(p, 2), p[4:]
            ev.superseded = True
            ev.status = "queued"
            c.prepq.setdefault(side, []).append((ev.handle, ev.offset, ev.value, ev))
            ev.info = f"part at offset {ev.offset}"
            wait({"h": ev.handle, "off": ev.offset, "v": ev.value})
            return
        if op == 0x17:
            if len(p) < 4:
                return short("need handle+offset")
            ev.handle, ev.offset, ev.value = _u16(p), _u16(p, 2), p[4:]
            ev.superseded = True
            if pend:
                if (pend[1].get("h"), pend[1].get("off"), pend[1].get("v")) != (ev.handle, ev.offset, ev.value):
                    ev.info = "echo MISMATCH"
                    self.warn(rec, "Prepare Write Response doesn't echo the request")
                else:
                    ev.info = "echo ok"
            return
        if op == 0x18:
            if not p:
                return short("need flags")
            queue = c.prepq.pop(side, [])
            if p[0] == 0x01:
                ev.info = f"execute {len(queue)} queued parts"
                longs = self._assemble_long_write(rec, c, side, ev, queue)
                wait({"long": longs})
            else:
                ev.info = f"cancel {len(queue)} queued parts"
                for item in queue:
                    item[3].status = "cancelled"
                wait({"long": []})
            return
        if op == 0x19:
            if pend:
                for lw in pend[1].get("long", []):
                    lw.status = "ok"
            return
        if op in (0x1B, 0x1D):
            if len(p) < 2:
                return short("need handle")
            ev.handle, ev.value = _u16(p), p[2:]
            return
        if op == 0x23:  # Multiple Handle Value Notification
            i = 0
            first = True
            while i + 4 <= len(p):
                h, ln = _u16(p, i), _u16(p, i + 2)
                val = p[i + 4:i + 4 + ln]
                if first:
                    ev.handle, ev.value, ev.op = h, val, "Notify"
                    ev.info = "from multiple-handle notification"
                    first = False
                else:
                    self.emit(rec, "att", "Notify", dir=d, conn=c.handle, peer=c.key, side=side,
                              handle=h, value=val, info="from multiple-handle notification")
                i += 4 + ln
            return
        if op == 0x1E:
            return
        ev.value = p
        ev.info = "unknown ATT opcode"

    def _assemble_long_write(self, rec: HciRecord, c: Conn, side: str, exec_ev: Event,
                             queue: list) -> list[Event]:
        by_handle: dict[int, list] = {}
        for item in queue:
            by_handle.setdefault(item[0], []).append(item)
        out = []
        for h, items in by_handle.items():
            buf = bytearray()
            for _, off, part, pev in items:
                if off > len(buf):
                    self.warn(rec, f"prepare write gap at offset {len(buf)}..{off} on 0x{h:04x}; zero-filled")
                    buf += b"\0" * (off - len(buf))
                buf[off:off + len(part)] = part
                pev.status = "executed"
            lw = self.emit(rec, "att", "LongWrite", dir=exec_ev.dir, conn=c.handle, peer=c.key, side=side,
                           handle=h, value=bytes(buf), status="pending", synthetic=True,
                           parts=[it[3].n for it in items],
                           info=f"reassembled from {len(items)} prepare writes")
            out.append(lw)
        return out

    def _finish_read(self, rec: HciRecord, c: Conn, side: str, h: int | None) -> None:
        if h is None:
            return
        acc = c.reads.pop((side, h), None)
        if acc is None or len(acc[1]) < 2:
            return
        first = self.events[acc[1][0]]
        for n in acc[1]:
            self.events[n].superseded = True
        self.emit(rec, "att", "LongRead", dir=first.dir, conn=c.handle, peer=c.key, side=side, handle=h,
                  value=bytes(acc[0]), synthetic=True, parts=list(acc[1]), status="ok",
                  info=f"reassembled from {len(acc[1])} read responses")

    def _flush_conn(self, rec: HciRecord, c: Conn) -> None:
        for (side, h) in list(c.reads):
            self._finish_read(rec, c, side, h)
        for sent, buf in c.acl.items():
            if buf:
                self.warn(rec, f"connection 0x{c.handle:03x} ended with {len(buf[0])} bytes of an unfinished L2CAP PDU")
        for side, q in c.prepq.items():
            if q:
                self.warn(rec, f"connection 0x{c.handle:03x} ended with {len(q)} prepared writes never executed")
        c.acl.clear()
        c.prepq.clear()
        c.pending.clear()

    def finish(self) -> None:
        last = HciRecord(-1, self.t_end or 0.0, "end", None, b"")
        for c in list(self.conns.values()):
            for (side, h) in list(c.reads):
                self._finish_read(last, c, side, h)
            for sent, buf in c.acl.items():
                if buf:
                    self.warn(None, f"capture ended with {len(buf[0])} bytes of an unfinished L2CAP PDU on 0x{c.handle:03x}")
            for side, q in c.prepq.items():
                if q:
                    self.warn(None, f"capture ended with {len(q)} prepared writes never executed on 0x{c.handle:03x}")


# --------------------------------------------------------------------------
# Decoded capture: name resolution + analysis
# --------------------------------------------------------------------------


@dataclass
class Decoded:
    path: str
    fmt: str
    size: int
    sha256: str
    n_records: int
    type_counts: Counter
    kind_counts: Counter
    events: list[Event]
    warnings: list[str]
    conns: list[Conn]
    dbs: dict[tuple[str, str], GattDb]
    adverts: dict[str, dict[str, Any]]
    user_db: GattDb | None
    profile: GattDb | None
    profile_name: str
    t0: float
    t_end: float
    focus: set[str] | None = None            # peers treated as "the camera" (None = all)
    camera_scores: dict[str, int] = field(default_factory=dict)

    def rel(self, ts: float) -> float:
        return ts - self.t0

    def in_focus(self, ev: Event) -> bool:
        return self.focus is None or ev.peer is None or ev.peer in self.focus

    def resolve(self, peer: str | None, side: str | None, h: int | None) -> tuple[str | None, str]:
        if h is None:
            return None, ""
        if side is None:
            side = "remote"
        own = self.dbs.get((peer or "", side))
        if own and own.get(h):
            return own.get(h).uuid, "discovered"  # type: ignore[union-attr]
        if side == "remote":
            others = {db.get(h).uuid for (pk, s), db in self.dbs.items()  # type: ignore[union-attr]
                      if s == "remote" and db.get(h)}
            if len(others) == 1:
                return others.pop(), "discovered"
            if self.user_db and self.user_db.get(h):
                return self.user_db.get(h).uuid, "user"  # type: ignore[union-attr]
            if self.profile and self.profile.get(h):
                return self.profile.get(h).uuid, "profile"  # type: ignore[union-attr]
        return None, ""

    def db_for(self, peer: str | None, side: str | None, src: str) -> GattDb | None:
        if src == "discovered":
            own = self.dbs.get((peer or "", side or "remote"))
            if own:
                return own
            for (pk, s), db in self.dbs.items():
                if s == (side or "remote") and len(db):
                    return db
            return None
        return self.user_db if src == "user" else self.profile if src == "profile" else None

    def label(self, ev: Event) -> str:
        if ev.handle is None:
            return ""
        nm = ev.name or (short_uuid(ev.uuid) if ev.uuid else "?")
        return nm + ("?" if ev.map_src == "profile" else "")


def _resolve_events(dec: Decoded) -> None:
    for ev in dec.events:
        if ev.layer != "att" or ev.handle is None:
            continue
        u, src = dec.resolve(ev.peer, ev.side, ev.handle)
        ev.uuid, ev.map_src = u, src
        ev.name = uuid_name(u) if u else None
        if u == CCCD:
            db = dec.db_for(ev.peer, ev.side, src)
            own = db.owner(ev.handle) if db else None
            if own:
                ev.name = f"CCCD({uuid_name(own[1].uuid) or short_uuid(own[1].uuid)})"
                ev.info = (ev.info + " " if ev.info else "") + f"char 0x{own[0]:04x}"
        if ev.op in ("ReadReq", "ReadBlobReq", "ErrorRsp", "WriteRsp", "PrepWriteRsp"):
            continue
        if ev.value or ev.op in DATA_WRITE_OPS:
            ev.meaning = describe_value(u, ev.value, ev.op)


def _camera_peers(dec: Decoded) -> dict[str, int]:
    """Score each peer: Fujifilm advert (+10), Fuji UUIDs in its discovered
    GATT (+10), its ATT handles fit the user map or fallback profile (+5)."""
    handles: dict[str, set[int]] = {}
    for ev in dec.events:
        if ev.layer == "att" and ev.peer and ev.side == "remote" and ev.handle is not None:
            handles.setdefault(ev.peer, set()).add(ev.handle)
    scores: dict[str, int] = {}
    for p, hs in handles.items():
        sc = 0
        if dec.adverts.get(p, {}).get("fuji"):
            sc += 10
        db = dec.dbs.get((p, "remote"))
        if db and any(a.uuid in FUJI_CHARS or a.uuid in FUJI_SERVICES for a in db.attrs.values()):
            sc += 10
        for ref in (dec.user_db, dec.profile):
            if ref is not None and hs:
                hit = sum(1 for h in hs if ref.get(h) is not None and ref.get(h).kind in ("value", "desc"))  # type: ignore[union-attr]
                if hit >= max(1, 0.8 * len(hs)) and (len(hs) >= 3 or ref is dec.user_db):
                    sc += 5
                    break
        scores[p] = sc
    return scores


def set_focus(dec: Decoded, peers: Iterable[str] | None = None, all_peers: bool = False) -> None:
    """Pick which connections count as the camera. Default: auto (score >= 5);
    falls back to every peer when nothing scores."""
    if all_peers:
        dec.focus = None
    elif peers:
        want = {p.upper() if ":" in p else p for p in peers}
        dec.focus = {p for p in dec.camera_scores if p.upper() in want or p in want} or set(want)
    else:
        cams = {p for p, s in dec.camera_scores.items() if s >= 5}
        dec.focus = cams if cams and len(cams) < len(dec.camera_scores) else None


def decode_bytes(data: bytes, path: str = "<bytes>", handle_map: GattDb | None = None,
                 profile: str = "ad14d4", keep_notes: bool = True) -> Decoded:
    cap = parse_capture(data)
    dec = Decoder(keep_notes=keep_notes)
    for rec in cap.records:
        dec.feed(rec)
    dec.finish()
    t0 = dec.t0 if dec.t0 is not None else (cap.records[0].ts if cap.records else 0.0)
    out = Decoded(
        path=path, fmt=cap.fmt, size=len(data), sha256=hashlib.sha256(data).hexdigest(),
        n_records=len(cap.records), type_counts=cap.type_counts, kind_counts=dec.kind_counts,
        events=dec.events, warnings=cap.warnings + dec.warnings, conns=dec.all_conns, dbs=dec.dbs,
        adverts=dec.adverts, user_db=handle_map, profile=profile_db(profile), profile_name=profile,
        t0=t0, t_end=dec.t_end if dec.t_end is not None else t0,
    )
    _resolve_events(out)
    out.camera_scores = _camera_peers(out)
    set_focus(out)
    return out


def decode_file(path: str | Path, handle_map: GattDb | None = None, profile: str = "ad14d4",
                keep_notes: bool = True) -> Decoded:
    return decode_bytes(Path(path).read_bytes(), str(path), handle_map, profile, keep_notes)


# --------------------------------------------------------------------------
# (b) Transfers
# --------------------------------------------------------------------------


@dataclass
class Transfer:
    idx: int
    kind: str          # write | notify | read
    peer: str | None
    side: str | None
    handle: int
    uuid: str | None
    name: str | None
    map_src: str
    events: list[Event]
    raw: bytes
    framing: dict[str, Any] | None = None
    payload: bytes | None = None
    skipped_failed: int = 0

    @property
    def start(self) -> float:
        return self.events[0].ts

    @property
    def end(self) -> float:
        return self.events[-1].ts

    @property
    def data(self) -> bytes:
        return self.payload if self.payload is not None else self.raw

    @property
    def label(self) -> str:
        return (self.name or (short_uuid(self.uuid) if self.uuid else f"h{self.handle:04x}")) + \
            ("?" if self.map_src == "profile" else "")

    def to_json(self, t0: float) -> dict[str, Any]:
        d: dict[str, Any] = {
            "idx": self.idx, "kind": self.kind, "peer": self.peer, "handle": self.handle,
            "handle_hex": f"0x{self.handle:04x}", "uuid": self.uuid, "name": self.name,
            "map_src": self.map_src, "chunks": len(self.events), "raw_bytes": len(self.raw),
            "raw_sha256": hashlib.sha256(self.raw).hexdigest(),
            "start": round(self.start - t0, 6), "end": round(self.end - t0, 6),
            "duration_s": round(self.end - self.start, 6),
            "first_event": self.events[0].n, "last_event": self.events[-1].n,
            "first_record": self.events[0].rec, "last_record": self.events[-1].rec,
            "chunk_sizes": sorted(Counter(len(e.value) for e in self.events).items()),
        }
        if self.skipped_failed:
            d["skipped_failed_writes"] = self.skipped_failed
        if self.framing:
            d["framing"] = self.framing
        if self.payload is not None:
            d["payload_bytes"] = len(self.payload)
            d["payload_sha256"] = hashlib.sha256(self.payload).hexdigest()
        m = self.data.find(FUJI_BACKUP_MAGIC)
        if m >= 0:
            d["magic"] = {"text": FUJI_BACKUP_MAGIC.decode(), "offset": m}
        d["head_hex"] = self.data[:32].hex()
        return d


def analyse_framing(chunks: list[bytes]) -> tuple[dict[str, Any], bytes] | None:
    """Fuji FILE_PARTIAL_DATA framing over a run of chunks, if it fits."""
    if len(chunks) < 1:
        return None
    parsed = [fuji_chunk(c) for c in chunks]
    good = sum(1 for x in parsed if x)
    if good < max(1, int(0.9 * len(chunks))):
        return None
    payload = bytearray()
    seqs = []
    for c, x in zip(chunks, parsed):
        if x:
            seqs.append(x[0])
            payload += c[6:6 + x[1]]
        else:
            seqs.append(None)
    info: dict[str, Any] = {"type": "fuji u16 seq + u32 len", "chunks_framed": good, "chunks": len(chunks)}
    plain = [s for s in seqs if s is not None and s != 0xFFFF]
    if plain:
        info["first_seq"] = plain[0]
        gaps = [(a, b) for a, b in zip(plain, plain[1:]) if b != a + 1]
        if gaps:
            info["seq_anomalies"] = gaps[:20]
    info["has_last_marker"] = bool(seqs and seqs[-1] == 0xFFFF)
    if info["has_last_marker"] and len(payload) >= 2:
        body, stored = bytes(payload[:-2]), _u16(payload, len(payload) - 2)
        calc = sum(body) & 0xFFFF
        info["checksum"] = {"stored": f"0x{stored:04x}", "computed": f"0x{calc:04x}", "ok": stored == calc}
        return info, body
    return info, bytes(payload)


def find_transfers(dec: Decoded, gap: float = 2.0, min_chunks: int = 2) -> list[Transfer]:
    """Group consecutive data-bearing ATT operations on one characteristic.
    A run ends after `gap` seconds of silence on that characteristic, at a
    disconnect, after a Fuji LAST chunk (seq 0xFFFF), or when the Fuji
    sequence number restarts."""
    runs: dict[tuple, dict[str, Any]] = {}
    done: list[dict[str, Any]] = []

    def close(key: tuple) -> None:
        r = runs.pop(key, None)
        if r:
            done.append(r)

    for ev in dec.events:
        if ev.layer == "hci" and ev.op == "Disconnected":
            for key in [k for k in runs if k[0] == ev.peer]:
                close(key)
            continue
        if ev.layer != "att" or ev.superseded or ev.handle is None or not dec.in_focus(ev):
            continue
        if ev.op in DATA_WRITE_OPS:
            kind = "write"
        elif ev.op in ("Notify", "Indicate"):
            kind = "notify"
        elif ev.op in ("ReadRsp", "ReadBlobRsp", "LongRead"):
            kind = "read"
        else:
            continue
        if ev.uuid == CCCD:
            continue
        key = (ev.peer, ev.side, ev.handle, kind)
        r = runs.get(key)
        if kind == "write" and ev.status and ev.status.startswith("error"):
            if r:
                r["failed"] += 1
            continue
        fc = fuji_chunk(ev.value)
        if r is not None:
            if ev.ts - r["events"][-1].ts > gap:
                close(key)
                r = None
            elif fc and r["last_seq"] is not None and fc[0] != 0xFFFF and fc[0] <= r["last_seq"]:
                close(key)
                r = None
        if r is None:
            r = {"key": key, "events": [], "last_seq": None, "failed": 0}
            runs[key] = r
        r["events"].append(ev)
        r["last_seq"] = fc[0] if fc else None
        if fc and fc[0] == 0xFFFF:
            close(key)
    for key in list(runs):
        close(key)
    done.sort(key=lambda r: r["events"][0].n)
    out: list[Transfer] = []
    for r in done:
        evs = r["events"]
        if len(evs) < min_chunks:
            continue
        peer, side, h, kind = r["key"]
        raw = b"".join(e.value for e in evs)
        t = Transfer(len(out), kind, peer, side, h, evs[0].uuid, evs[0].name, evs[0].map_src, evs, raw,
                     skipped_failed=r["failed"])
        fr = analyse_framing([e.value for e in evs])
        if fr:
            t.framing, t.payload = fr
        out.append(t)
    return out


def _safe(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", s).strip("_") or "x"


def extract_transfers(dec: Decoded, transfers: list[Transfer], out_dir: str | Path) -> dict[str, Any]:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, Any] = {"source": dec.path, "source_sha256": dec.sha256, "transfers": []}
    for t in transfers:
        base = f"{t.idx:02d}-{_safe(t.label)}-{t.kind}"
        raw_name = base + ".raw.bin"
        (out / raw_name).write_bytes(t.raw)
        entry = t.to_json(dec.t0)
        entry["raw_file"] = raw_name
        if t.payload is not None:
            pay_name = base + ".payload.bin"
            (out / pay_name).write_bytes(t.payload)
            entry["payload_file"] = pay_name
        manifest["transfers"].append(entry)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


# --------------------------------------------------------------------------
# (c) Replay script
# --------------------------------------------------------------------------

REPLAY_FORMAT = "fuji-ble-replay/1"


def replay_script(dec: Decoded, include_reads: bool = False, transfers: list[Transfer] | None = None) -> dict[str, Any]:
    """Every write the phone made to the device's GATT server, in order."""
    by_event: dict[int, int] = {}
    for t in transfers or []:
        for e in t.events:
            by_event[e.n] = t.idx
    steps: list[dict[str, Any]] = []
    last_t: float | None = None
    since: list[Event] = []
    unmapped = set()
    for ev in dec.events:
        if ev.layer != "att" or ev.superseded or not dec.in_focus(ev):
            continue
        if ev.op in ("Notify", "Indicate") and ev.side == "remote":
            since.append(ev)
            continue
        if ev.side != "remote" or ev.dir != "out":
            continue
        is_write = ev.op in DATA_WRITE_OPS
        is_read = include_reads and ev.op in ("ReadReq",)
        if not (is_write or is_read):
            continue
        step: dict[str, Any] = {
            "i": len(steps), "t": round(dec.rel(ev.ts), 6),
            "dt": round(ev.ts - last_t, 6) if last_t is not None else 0.0,
            "event": ev.n, "record": ev.rec, "peer": ev.peer,
            "handle": ev.handle, "handle_hex": f"0x{ev.handle:04x}" if ev.handle is not None else None,
            "uuid": ev.uuid, "name": ev.name, "map_src": ev.map_src or None,
        }
        if ev.uuid is None:
            unmapped.add(ev.handle)
        if is_write and ev.uuid == CCCD:
            x = _u16(ev.value) if len(ev.value) >= 2 else 0
            db = dec.db_for(ev.peer, ev.side, ev.map_src)
            own = db.owner(ev.handle) if db and ev.handle is not None else None
            step.update({
                "op": "subscribe" if x else "unsubscribe",
                "mode": {1: "notify", 2: "indicate", 3: "notify+indicate"}.get(x, "off"),
                "char_uuid": own[1].uuid if own else None,
                "char_name": uuid_name(own[1].uuid) if own else None,
                "char_handle": own[0] if own else None,
                "value_hex": ev.value.hex(),
            })
        elif is_write:
            step.update({
                "op": "write", "with_response": ev.op != "WriteCmd" and ev.op != "SignedWriteCmd",
                "long": ev.op == "LongWrite", "len": len(ev.value), "value_hex": ev.value.hex(),
                "status": ev.status,
            })
            if ev.meaning:
                step["meaning"] = ev.meaning
            if ev.n in by_event:
                step["transfer"] = by_event[ev.n]
        else:
            rsp = dec.events[ev.reply] if ev.reply is not None else None
            val = rsp.value if rsp is not None else b""
            if rsp is not None and rsp.superseded:
                longs = [e for e in dec.events if e.op == "LongRead" and rsp.n in e.parts]
                if longs:
                    val = longs[0].value
            step.update({"op": "read", "response_hex": val.hex(), "status": "ok" if rsp is not None and rsp.op != "ErrorRsp" else (rsp.status if rsp else None)})
        if since:
            n = since[-1]
            step["after_notify"] = {"uuid": n.uuid, "name": n.name, "handle": n.handle,
                                    "value_hex": n.value.hex(), "t": round(dec.rel(n.ts), 6),
                                    "count_since_prev_step": len(since)}
            since = []
        steps.append(step)
        last_t = ev.ts
    mtus = {c.key: c.mtu for c in dec.conns if c.server_mtu}
    return {
        "format": REPLAY_FORMAT,
        "source": dec.path, "source_sha256": dec.sha256,
        "generated": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "profile_fallback": dec.profile_name,
        "devices": sorted({s["peer"] for s in steps if s.get("peer")}),
        "att_mtu": mtus,
        "notes": [
            "Steps are every ATT write the phone sent to the device's GATT server, in capture order.",
            "op=subscribe/unsubscribe are CCCD writes: on CoreBluetooth/bleak use start_notify/stop_notify on char_uuid instead of writing the descriptor.",
            "long=true: the app sent this value with Prepare/Execute Write; a with-response write longer than ATT_MTU-3 does the same through the OS.",
            "after_notify: the last notification/indication from the device before this write; a replayer can wait for it.",
            "map_src=profile means the UUID came from the fffw ad14d4 table, not from this capture (unverified).",
        ],
        "unmapped_handles": sorted(f"0x{h:04x}" for h in unmapped if h is not None),
        "steps": steps,
    }


# --------------------------------------------------------------------------
# (e) Summary
# --------------------------------------------------------------------------


def _iso(ts: float) -> str:
    try:
        return _dt.datetime.fromtimestamp(ts).isoformat(timespec="milliseconds")
    except (OverflowError, OSError, ValueError):
        return str(ts)


def _type_name(fmt: str, code: int) -> str:
    if fmt.startswith("pklg"):
        k = PKLG_TYPES.get(code)
        return f"0x{code:02x} {k[0]}{'/sent' if k and k[1] else '/recv' if k and k[1] is False else ''}" if k else f"0x{code:02x} UNKNOWN"
    return f"{code}"


def summarize(dec: Decoded, transfers: list[Transfer]) -> dict[str, Any]:
    chars: dict[tuple, dict[str, Any]] = {}
    out_bytes = in_bytes = 0
    for ev in dec.events:
        if ev.layer != "att" or ev.handle is None or ev.superseded or not dec.in_focus(ev):
            continue
        if ev.op in DISCOVERY_OPS or (ev.op == "ErrorRsp" and ev.status == "end"):
            continue
        key = (ev.peer, ev.side, ev.handle)
        row = chars.get(key)
        if row is None:
            row = chars[key] = {
                "name": dec.label(ev), "uuid": ev.uuid, "handle": f"0x{ev.handle:04x}", "server": ev.side,
                "peer": ev.peer, "map_src": ev.map_src, "writes": 0, "write_bytes": 0, "notifies": 0,
                "notify_bytes": 0, "reads": 0, "read_bytes": 0, "errors": 0,
                "first": round(dec.rel(ev.ts), 6), "last": 0.0,
            }
        row["last"] = round(dec.rel(ev.ts), 6)
        if ev.op in DATA_WRITE_OPS:
            row["writes"] += 1
            row["write_bytes"] += len(ev.value)
        elif ev.op in ("Notify", "Indicate"):
            row["notifies"] += 1
            row["notify_bytes"] += len(ev.value)
        elif ev.op in ("ReadRsp", "ReadBlobRsp", "LongRead"):
            row["reads"] += 1
            row["read_bytes"] += len(ev.value)
        elif ev.op == "ErrorRsp" and ev.status != "end":
            row["errors"] += 1
    for c in dec.conns:
        if dec.focus is None or c.key in dec.focus:
            out_bytes += c.att_bytes.get("out", 0)
            in_bytes += c.att_bytes.get("in", 0)
    disc = sum(len(db) for (pk, s), db in dec.dbs.items() if s == "remote")
    used_src = Counter(r["map_src"] or "unmapped" for r in chars.values())
    check = None
    if dec.profile is not None:
        agree = disagree = 0
        examples = []
        for (pk, s), db in dec.dbs.items():
            if s != "remote":
                continue
            for h, a in db.attrs.items():
                pa = dec.profile.get(h)
                if a.kind != "value" or pa is None:
                    continue
                if pa.uuid == a.uuid:
                    agree += 1
                else:
                    disagree += 1
                    if len(examples) < 5:
                        examples.append(f"0x{h:04x}: capture {short_uuid(a.uuid)} vs profile {short_uuid(pa.uuid)}")
        if agree or disagree:
            check = {"profile": dec.profile_name, "agree": agree, "disagree": disagree, "examples": examples}
    hint = None
    if dec.user_db is not None:
        unmapped = {int(r["handle"], 16) for r in chars.values() if not r["uuid"]}
        plus1 = sum(1 for h in unmapped if dec.user_db.get(h - 1))
        if unmapped and plus1 >= max(1, len(unmapped) // 2):
            hint = f"{plus1} of {len(unmapped)} unmapped handles are a mapped handle + 1: try --handle-offset 1"
    security = [
        f"{dec.rel(ev.ts):.3f}s {ev.op} {ev.info}".strip()
        for ev in dec.events
        if dec.in_focus(ev) and (ev.layer == "smp" or ev.op in (
            "EncryptionChange", "EncryptionKeyRefresh", "LE StartEncryption", "LE LtkRequest", "LE LtkNegReply"))
    ]
    big = max(transfers, key=lambda t: len(t.raw), default=None)
    rows = sorted(chars.values(), key=lambda r: (-(r["write_bytes"] + r["notify_bytes"] + r["read_bytes"]), r["handle"]))
    return {
        "file": dec.path, "format": dec.fmt, "bytes": dec.size, "sha256": dec.sha256,
        "records": dec.n_records,
        "record_types": {_type_name(dec.fmt, k): v for k, v in sorted(dec.type_counts.items())},
        "start": _iso(dec.t0), "end": _iso(dec.t_end), "duration_s": round(dec.t_end - dec.t0, 3),
        "focus": sorted(dec.focus) if dec.focus is not None else None,
        "camera_scores": dec.camera_scores,
        "connections": [
            {"handle": f"0x{c.handle:03x}", "peer": c.peer, "role": c.role,
             "camera": (dec.focus is not None and c.key in dec.focus) or dec.camera_scores.get(c.key, 0) >= 5,
             "start": round(dec.rel(c.start), 3) if c.start else None,
             "end": round(dec.rel(c.end), 3) if c.end else None,
             "transport": c.transport, "other_l2cap_pdus": c.other_l2cap,
             "encrypted": c.encrypted, "att_mtu": c.mtu, "disconnect": c.disconnect,
             "att_bytes_out": c.att_bytes.get("out", 0), "att_bytes_in": c.att_bytes.get("in", 0)}
            for c in dec.conns
        ],
        "fuji_adverts": {a: v for a, v in dec.adverts.items() if v.get("fuji")},
        "security": security,
        "gatt": {"discovered_handles": disc, "user_map_handles": len(dec.user_db) if dec.user_db else 0,
                 "profile": dec.profile_name, "names_by_source": dict(used_src),
                 "profile_check": check, "hint": hint},
        "characteristics": rows,
        "att_bytes": {"phone_to_device": out_bytes, "device_to_phone": in_bytes},
        "value_bytes": {
            "written": sum(r["write_bytes"] for r in rows if r["server"] == "remote"),
            "notified": sum(r["notify_bytes"] for r in rows if r["server"] == "remote"),
            "read": sum(r["read_bytes"] for r in rows if r["server"] == "remote"),
        },
        "transfers": [t.to_json(dec.t0) for t in transfers],
        "biggest_transfer": big.to_json(dec.t0) if big else None,
        "warnings": len(dec.warnings),
        "first_warnings": dec.warnings[:10],
    }


def format_summary(s: dict[str, Any]) -> str:
    L: list[str] = []
    L.append(f"File      {s['file']}  ({s['format']}, {s['bytes']} bytes, {s['records']} records)")
    L.append(f"Time      {s['start']} -> {s['end']}  ({s['duration_s']} s)")
    L.append("Records   " + ", ".join(f"{k}: {v}" for k, v in s["record_types"].items()))
    if s["focus"] is not None:
        L.append(f"Focus     camera connection(s) {', '.join(s['focus'])}; other peers are left out "
                 f"(--all-peers to include them)")
    elif sum(1 for v in s["camera_scores"].values()) > 1:
        L.append("WARNING   several devices have ATT traffic and none was identified as the camera; "
                 "everything is included. Pick one with --peer (addresses below)")
    for c in s["connections"]:
        if c["transport"] != "LE":
            L.append(f"Conn      {c['handle']} peer {c['peer'] or '?'} ({c['transport']}, not decoded: "
                     f"{c['other_l2cap_pdus']} L2CAP PDUs)")
            continue
        L.append(f"Conn      {c['handle']} peer {c['peer'] or '?'} ({c['role'] or '?'}){' CAMERA' if c['camera'] else ''}  "
                 f"t={c['start']}..{c['end'] if c['end'] is not None else 'open'}  ATT_MTU {c['att_mtu']}  "
                 f"{'encrypted' if c['encrypted'] else 'not encrypted'}  "
                 f"ATT bytes out {c['att_bytes_out']} / in {c['att_bytes_in']}"
                 + (f"  disconnect {c['disconnect']}" if c["disconnect"] else ""))
    for a, v in s["fuji_adverts"].items():
        L.append(f"Camera?   {a} advertises Fujifilm data ({v.get('name') or 'no name'}, {v['count']} adverts)")
    if s["security"]:
        L.append("Security")
        L.extend("          " + x for x in s["security"][:20])
    g = s["gatt"]
    L.append(f"GATT map  discovered {g['discovered_handles']} handles, user map {g['user_map_handles']}, "
             f"fallback profile {g['profile']}; names by source {g['names_by_source']}")
    if g["profile_check"]:
        pc = g["profile_check"]
        L.append(f"          profile {pc['profile']} vs discovery: {pc['agree']} agree, {pc['disagree']} disagree"
                 + (f" e.g. {pc['examples']}" if pc["examples"] else ""))
    if g["hint"]:
        L.append("          HINT: " + g["hint"])
    L.append(f"ATT bytes phone->device {s['att_bytes']['phone_to_device']}, device->phone {s['att_bytes']['device_to_phone']}; "
             f"values written {s['value_bytes']['written']}, notified {s['value_bytes']['notified']}, read {s['value_bytes']['read']}")
    L.append("")
    L.append(f"{'characteristic':<34} {'handle':>6} {'srv':>3} {'writes':>7} {'bytes':>8} {'notif':>6} {'bytes':>8} {'reads':>6} {'bytes':>8} {'err':>4}  first..last s")
    for r in s["characteristics"]:
        L.append(f"{(r['name'] or '?')[:34]:<34} {r['handle']:>6} {'cam' if r['server'] == 'remote' else 'ph':>3} "
                 f"{r['writes']:>7} {r['write_bytes']:>8} {r['notifies']:>6} {r['notify_bytes']:>8} "
                 f"{r['reads']:>6} {r['read_bytes']:>8} {r['errors']:>4}  {r['first']:.3f}..{r['last']:.3f}")
    L.append("")
    if s["transfers"]:
        L.append("Transfers (consecutive data on one characteristic)")
        for t in s["transfers"]:
            L.append("  " + _transfer_line(t))
    else:
        L.append("Transfers: none (no characteristic carried 2+ consecutive data chunks)")
    b = s["biggest_transfer"]
    if b:
        L.append("")
        L.append(f"BIGGEST TRANSFER: #{b['idx']} {b['kind']} {b['name'] or b['handle_hex']} — "
                 f"{b['raw_bytes']} bytes in {b['chunks']} chunks, starts t={b['start']:.6f}s "
                 f"(event {b['first_event']}, record {b['first_record']}), ends t={b['end']:.6f}s "
                 f"(event {b['last_event']}, record {b['last_record']}), {b['duration_s']:.3f} s")
    if s["warnings"]:
        L.append("")
        L.append(f"Warnings: {s['warnings']} (first {len(s['first_warnings'])} below; --warnings shows all)")
        L.extend("  " + w for w in s["first_warnings"])
    return "\n".join(L)


def _transfer_line(t: dict[str, Any]) -> str:
    fr = t.get("framing")
    extra = ""
    if fr:
        extra = f" fuji-framed payload {t.get('payload_bytes')} B"
        if fr.get("checksum"):
            extra += " checksum " + ("OK" if fr["checksum"]["ok"] else f"BAD ({fr['checksum']})")
        if fr.get("seq_anomalies"):
            extra += f" seq gaps {fr['seq_anomalies'][:3]}"
    if t.get("magic"):
        extra += f" [{t['magic']['text']} @ {t['magic']['offset']}]"
    if t.get("skipped_failed_writes"):
        extra += f" ({t['skipped_failed_writes']} failed writes skipped)"
    return (f"#{t['idx']:<2} {t['kind']:<6} {(t['name'] or '?') + ('?' if t['map_src'] == 'profile' else ''):<26} "
            f"{t['handle_hex']} {t['chunks']:>5} chunks {t['raw_bytes']:>7} B  t={t['start']:.3f}..{t['end']:.3f}s{extra}")


# --------------------------------------------------------------------------
# (a) Timeline
# --------------------------------------------------------------------------

DISCOVERY_OPS = {"FindInfoReq", "FindInfoRsp", "FindByTypeReq", "FindByTypeRsp", "ReadByTypeReq",
                 "ReadByTypeRsp", "ReadByGroupReq", "ReadByGroupRsp"}


def select_events(dec: Decoded, notes: bool = False, ops: set[str] | None = None,
                  text: str | None = None, hide_discovery: bool = False) -> list[Event]:
    out = []
    for ev in dec.events:
        if ev.layer == "note" and not notes:
            continue
        if not dec.in_focus(ev):
            continue
        if ops and ev.op not in ops:
            continue
        if hide_discovery and (ev.op in DISCOVERY_OPS or (ev.op == "ErrorRsp" and ev.status == "end")):
            continue
        if text:
            hay = " ".join(str(x) for x in (ev.op, ev.name, ev.uuid, ev.info, ev.meaning,
                                             f"0x{ev.handle:04x}" if ev.handle is not None else "")).lower()
            if text.lower() not in hay:
                continue
        out.append(ev)
    return out


def format_event(dec: Decoded, ev: Event, preview: int = 16, abs_time: bool = False) -> str:
    t = _iso(ev.ts)[11:] if abs_time else f"{dec.rel(ev.ts):11.6f}"
    arrow = {"out": "->", "in": "<-"}.get(ev.dir, " .")
    conn = f"{ev.conn:03x}" if ev.conn is not None else "   "
    op = ("*" if ev.synthetic else "") + ev.op
    handle = f"0x{ev.handle:04x}" if ev.handle is not None else ""
    su = short_uuid(ev.uuid) if ev.uuid else ""
    name = dec.label(ev) if ev.handle is not None else ""
    length = str(len(ev.value)) if (ev.value or ev.layer == "att" and ev.op in DATA_WRITE_OPS) else ""
    data = _hex(ev.value, preview) if ev.value else ""
    bits = [x for x in (ev.meaning, ev.info) if x]
    if ev.status and ev.status not in ("ok",) and ev.layer == "att":
        bits.append(f"[{ev.status}]")
    elif ev.status and ev.layer != "att" and ev.status != "ok":
        bits.append(f"[{ev.status}]")
    if ev.frags > 1:
        bits.append(f"({ev.frags} ACL frags)")
    if ev.superseded and ev.op.startswith("Prep"):
        pass
    meaning = "  ".join(bits)
    if ev.handle is None and not ev.value:
        return f"{ev.n:>6} {t} {arrow} {conn} {op:<20} {meaning}".rstrip()
    return (f"{ev.n:>6} {t} {arrow} {conn} {op:<20} {handle:>6} {su:<8} {name[:30]:<30} "
            f"{length:>5}  {data:<{preview * 3 + 2}} {meaning}").rstrip()


def format_timeline(dec: Decoded, events: list[Event] | None = None, preview: int = 16,
                    abs_time: bool = False) -> str:
    evs = dec.events if events is None else events
    head = (f"{'#':>6} {'time':>11} dir con {'op':<20} {'handle':>6} {'uuid':<8} {'name':<30} {'len':>5}  "
            f"{'data':<{preview * 3 + 2}} meaning")
    lines = [head]
    lines += [format_event(dec, ev, preview, abs_time) for ev in evs]
    lines.append("")
    lines.append("dir: -> phone to device, <- device to phone.  *op = reassembled (long write/read).  "
                 "name? = from the fallback profile, not from this capture.")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# (d) Diff
# --------------------------------------------------------------------------


def _byte_ranges(a: bytes, b: bytes, merge: int = 4) -> list[tuple[int, int]]:
    """Differing [start, end) ranges over the common length, merged when closer than `merge`."""
    out: list[list[int]] = []
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            if out and i - out[-1][1] < merge:
                out[-1][1] = i + 1
            else:
                out.append([i, i + 1])
    if len(a) != len(b):
        out.append([min(len(a), len(b)), max(len(a), len(b))])
    return [(x, y) for x, y in out]


def _step_key(s: dict[str, Any]) -> tuple:
    return (s["op"], s.get("uuid") or s.get("handle_hex"), s.get("with_response"))


def _step_name(s: dict[str, Any]) -> str:
    nm = s.get("name") or (short_uuid(s.get("uuid")) if s.get("uuid") else s.get("handle_hex"))
    if s["op"] in ("subscribe", "unsubscribe"):
        return f"{s['op']} {s.get('char_name') or nm}"
    return f"{s['op']} {nm}"


def diff_captures(a: Decoded, b: Decoded, gap: float = 2.0, min_chunks: int = 2) -> dict[str, Any]:
    ta, tb = find_transfers(a, gap, min_chunks), find_transfers(b, gap, min_chunks)
    ra, rb = replay_script(a, transfers=ta), replay_script(b, transfers=tb)
    sa = [s for s in ra["steps"] if "transfer" not in s]
    sb = [s for s in rb["steps"] if "transfer" not in s]
    sm = difflib.SequenceMatcher(a=[_step_key(s) for s in sa], b=[_step_key(s) for s in sb], autojunk=False)
    control: list[dict[str, Any]] = []
    same = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for x, y in zip(sa[i1:i2], sb[j1:j2]):
                if x["value_hex"] == y["value_hex"]:
                    same += 1
                else:
                    control.append({"change": "value", "a": x, "b": y})
        else:
            for x in sa[i1:i2]:
                control.append({"change": "only_a", "a": x})
            for y in sb[j1:j2]:
                control.append({"change": "only_b", "b": y})
    # transfers: pair in order per (characteristic, kind)
    def tkey(t: Transfer) -> tuple:
        return (t.uuid or f"0x{t.handle:04x}", t.kind)
    pairs: list[dict[str, Any]] = []
    used_b: set[int] = set()
    for t in ta:
        match = next((u for u in tb if u.idx not in used_b and tkey(u) == tkey(t)), None)
        if match is None:
            pairs.append({"a": t.to_json(a.t0), "b": None})
            continue
        used_b.add(match.idx)
        da, db_ = t.data, match.data
        rng = _byte_ranges(da, db_)
        entry: dict[str, Any] = {"a": t.to_json(a.t0), "b": match.to_json(b.t0), "identical": da == db_,
                                 "compared": "payload" if t.payload is not None and match.payload is not None else "raw",
                                 "ranges": [{"start": s, "end": e,
                                             "a_hex": da[s:e].hex() if s < len(da) else "",
                                             "b_hex": db_[s:e].hex() if s < len(db_) else ""} for s, e in rng[:200]],
                                 "n_ranges": len(rng)}
        pairs.append(entry)
    for u in tb:
        if u.idx not in used_b:
            pairs.append({"a": None, "b": u.to_json(b.t0)})
    return {"a": a.path, "b": b.path, "control_identical": same, "control_changes": control,
            "control_steps": [len(sa), len(sb)], "transfers": pairs}


def format_diff(d: dict[str, Any]) -> str:
    L = [f"A = {d['a']}", f"B = {d['b']}", ""]
    na, nb = d["control_steps"]
    L.append(f"Control writes (outside transfers): A {na}, B {nb}; {d['control_identical']} identical")
    for c in d["control_changes"]:
        if c["change"] == "value":
            x, y = c["a"], c["b"]
            L.append(f"  ~ {_step_name(x)}: A[{x['i']}] {x['value_hex'] or '-'} -> B[{y['i']}] {y['value_hex'] or '-'}"
                     + (f"   ({x.get('meaning')} -> {y.get('meaning')})" if x.get("meaning") or y.get("meaning") else ""))
        elif c["change"] == "only_a":
            x = c["a"]
            L.append(f"  - only in A[{x['i']}] t={x['t']:.3f}: {_step_name(x)} {x.get('value_hex', '')}")
        else:
            y = c["b"]
            L.append(f"  + only in B[{y['i']}] t={y['t']:.3f}: {_step_name(y)} {y.get('value_hex', '')}")
    if not d["control_changes"]:
        L.append("  (no differences)")
    L.append("")
    L.append("Transfers")
    if not d["transfers"]:
        L.append("  (none in either capture)")
    for p in d["transfers"]:
        a, b = p["a"], p["b"]
        if a is None or b is None:
            t = a or b
            L.append(f"  {'- only in A' if b is None else '+ only in B'}: #{t['idx']} {t['kind']} {t['name'] or t['handle_hex']} "
                     f"{t['raw_bytes']} B")
            continue
        name = a["name"] or a["handle_hex"]
        sizes = f"A {a.get('payload_bytes', a['raw_bytes'])} B / B {b.get('payload_bytes', b['raw_bytes'])} B ({p['compared']})"
        if p["identical"]:
            L.append(f"  = {a['kind']} {name}: identical, {sizes}")
            continue
        L.append(f"  ~ {a['kind']} {name}: {sizes}, {p['n_ranges']} differing range(s)")
        for r in p["ranges"][:40]:
            L.append(f"      0x{r['start']:06x}..0x{r['end']:06x} ({r['end'] - r['start']} B): "
                     f"A {r['a_hex'][:48] or '-'}  B {r['b_hex'][:48] or '-'}")
        if p["n_ranges"] > 40:
            L.append(f"      ... {p['n_ranges'] - 40} more (use --json)")
    return "\n".join(L)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def _load(path: str, args: argparse.Namespace) -> Decoded:
    hm = load_handle_map(args.handles, args.handle_offset) if args.handles else None
    dec = decode_file(path, hm, args.profile, keep_notes=True)
    if args.peer or args.all_peers:
        set_focus(dec, args.peer, args.all_peers)
    return dec


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="python -m fuji_ble.capture",
        description="Decode a PacketLogger (.pklg), btsnoop, pcap or pcapng Bluetooth capture down to ATT: "
                    "timeline, reassembled transfers, replay script, summary, diff. See the module docstring.")
    ap.add_argument("capture", nargs="?", help=".pklg / .btsnoop / btsnoop_hci.log / .pcap / .pcapng")
    ap.add_argument("--diff", nargs=2, metavar=("A", "B"), help="compare two captures")
    ap.add_argument("--timeline", action="store_true", help="(a) print the timeline (default)")
    ap.add_argument("--summary", action="store_true", help="(e) characteristics used, bytes, biggest transfer")
    ap.add_argument("--extract", metavar="DIR", help="(b) save reassembled transfers + manifest.json in DIR")
    ap.add_argument("--replay", metavar="OUT.json", help="(c) write the replay script ('-' = stdout)")
    ap.add_argument("--replay-reads", action="store_true", help="also put the app's reads in the replay script")
    ap.add_argument("--handles", metavar="MAP",
                    help="handle->UUID map: an earlier capture that has discovery, --save-handles JSON, "
                         "`python -m fuji_ble dump` JSON, or an fffw gatt-*.yaml")
    ap.add_argument("--handle-offset", type=int, default=0, help="add N to every handle in --handles")
    ap.add_argument("--save-handles", metavar="OUT.json", help="save the camera's discovered handle table (for --handles)")
    ap.add_argument("--profile", default="ad14d4", choices=["ad14d4", "none"],
                    help="fallback handle table for handles the capture never discovers (default ad14d4 = X100VI fw 1.31)")
    ap.add_argument("--peer", action="append", metavar="ADDR",
                    help="only this connection (address as printed, or conn-0x0040); repeatable. "
                         "Default: auto-detect the camera")
    ap.add_argument("--all-peers", action="store_true", help="include every connection (watch, headphones ...)")
    ap.add_argument("--notes", action="store_true", help="timeline: include PacketLogger notes/syslog lines")
    ap.add_argument("--no-discovery", action="store_true", help="timeline: hide GATT discovery PDUs")
    ap.add_argument("--ops", metavar="LIST", help="timeline: only these ops, e.g. WriteReq,WriteCmd,LongWrite,Notify")
    ap.add_argument("--filter", metavar="TEXT", help="timeline: only events mentioning TEXT (name, uuid, handle)")
    ap.add_argument("--abs-time", action="store_true", help="timeline: wall-clock times")
    ap.add_argument("--preview", type=int, default=16, help="timeline: hex bytes to show (default 16)")
    ap.add_argument("--gap", type=float, default=2.0, help="transfers: seconds of silence that end a run (default 2)")
    ap.add_argument("--min-chunks", type=int, default=2, help="transfers: minimum chunks (default 2)")
    ap.add_argument("--json", action="store_true", help="JSON output for --timeline/--summary/--diff")
    ap.add_argument("--warnings", action="store_true", help="print every decoder warning")
    ap.add_argument("--to-btsnoop", metavar="OUT", help="convert the capture's HCI records to btsnoop (H4)")
    args = ap.parse_args(argv)

    try:
        if args.diff:
            a, b = _load(args.diff[0], args), _load(args.diff[1], args)
            d = diff_captures(a, b, args.gap, args.min_chunks)
            print(json.dumps(d, indent=2) if args.json else format_diff(d))
            return 0
        if not args.capture:
            ap.error("give a capture file (or --diff A B)")
        dec = _load(args.capture, args)
    except CaptureError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    transfers = find_transfers(dec, args.gap, args.min_chunks)
    did = False
    if args.save_handles:
        n = save_handle_map(dec, args.save_handles)
        print(f"Saved {n} discovered handles to {args.save_handles}" + ("" if n else " (the capture has no discovery)"))
        did = True
    if args.to_btsnoop:
        cap = read_capture(args.capture)
        Path(args.to_btsnoop).write_bytes(build_btsnoop(cap.records))
        print(f"wrote {args.to_btsnoop}", file=sys.stderr)
        did = True
    if args.extract:
        m = extract_transfers(dec, transfers, args.extract)
        print(f"Saved {len(m['transfers'])} transfer(s) to {args.extract}/ (manifest.json lists them)")
        for t in m["transfers"]:
            files = t["raw_file"] + (f" + {t['payload_file']}" if t.get("payload_file") else "")
            print("  " + _transfer_line(t) + f"  -> {files}")
        did = True
    if args.replay:
        rs = replay_script(dec, args.replay_reads, transfers)
        text = json.dumps(rs, indent=2) + "\n"
        if args.replay == "-":
            sys.stdout.write(text)
        else:
            Path(args.replay).write_text(text)
            print(f"Wrote {len(rs['steps'])} replay steps to {args.replay}"
                  + (f" ({len(rs['unmapped_handles'])} handles without a UUID)" if rs["unmapped_handles"] else ""))
        did = True
    show_timeline = args.timeline or not (did or args.summary)
    show_summary = args.summary or not (did or args.timeline)
    if show_timeline:
        evs = select_events(dec, notes=args.notes, ops=set(args.ops.split(",")) if args.ops else None,
                            text=args.filter, hide_discovery=args.no_discovery)
        if args.json:
            print(json.dumps([e.to_json(dec.t0) for e in evs], indent=1))
        else:
            print(format_timeline(dec, evs, args.preview, args.abs_time))
    if show_summary:
        s = summarize(dec, transfers)
        if args.json:
            print(json.dumps(s, indent=2))
        else:
            if show_timeline:
                print()
            print(format_summary(s))
    if args.warnings:
        print(f"\n{len(dec.warnings)} warning(s)")
        for w in dec.warnings:
            print("  " + w)
    return 0


if __name__ == "__main__":
    sys.exit(main())
