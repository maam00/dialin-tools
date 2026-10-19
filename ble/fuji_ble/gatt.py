"""X100VI Bluetooth LE map: UUIDs, names, properties, decoders and file-service framing.

Everything in this module is pure (no bleak, no I/O) so it can be unit-tested without a camera.

Primary source for the table: tiredboffin/fffw `ffbt/cfg/gatt-ad14d4.yaml`, the GATT dump that
`ffbt/cfg/gatt-profiles-map.csv:5` assigns to the X100VI on firmware 1.31 ("v4.0 #secure").
The yaml's own header says "X-T5 0430" (gatt-ad14d4.yaml:1): the profile is identified by the
SHA-1 of the table, and X100VI 1.31, X-T50 1.31, X-S20 3.30 and X-T5 4.30 all share it
(gatt-profiles-map.csv:5,7,9,11). X100VI firmware 1.11 uses the older basic profile 76ab62
(gatt-profiles-map.csv:6).

Published projects cited per row (all MIT; paths are relative to each project's repository root):
  FB  = Th0rgal/fuji-bridge  FujiBridge/FujiBluetooth.swift, FujiBackup.swift
  LF  = petabyt/libfuji      lib/bluetooth.c
  FU  = gkoh/furble          lib/furble/Fujifilm*.{h,cpp}
  FF  = tiredboffin/fffw     ffbt/cfg/gatt-ad14d4.yaml (properties `flags` and max length `l`)
  DOC = docs/FUJIFILM-PROTOCOL.md (Dial In's protocol reference)

Every characteristic also carries a Dial In label in our own words (CHAR_LABELS); the sources' earlier labels are
kept in `notes` so older logs still read.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from typing import Optional

# --------------------------------------------------------------------------------------------
# Advertising
# --------------------------------------------------------------------------------------------

#: Bluetooth SIG company identifier Fujifilm uses in manufacturer data.
#: FU lib/furble/Fujifilm.h:35, FB FujiBluetooth.swift:15, libfuji libfuji.json "mfgData": "0xd8,0x04".
FUJIFILM_COMPANY_ID = 0x04D8

#: Manufacturer-data type byte (the byte right after the company id).
#: 0x02 = basic pairing advert carrying a 4-byte token (FU FujifilmBasic.h:30-32, FujifilmBasic.cpp:23-34,
#: LF bluetooth.c:102-103). Secure bodies send 0x01 + a 5-byte ASCII serial tag (FU FujifilmSecure.h:33-44;
#: real X100VI fw 1.32 bytes in FB Tests/BluetoothTests.swift:81,91).
ADV_TYPE_SECURE_TAG = 0x01
ADV_TYPE_BASIC_TOKEN = 0x02

# Service UUIDs seen in adverts.
SVC_SECURE_PAIRING_ADVERT = "a9d2b304-e8d6-4902-8336-352b772d7597"  # FB :56-57, FU FujifilmSecure.cpp:13
SVC_RECONNECT_ADVERT = "804daa8e-ffeb-4ab3-8e75-6edd7303208d"  # FB :58-59 (bonded body looking for its phone)
SVC_CAMERA_INFO_BASIC = "117c4142-edd4-4c77-8696-dd18eebb770a"  # FU FujifilmBasic.cpp:13, LF bluetooth.c:46
#: Standby service (basic): advertised by a basic body that is switched off with Bluetooth on, with manufacturer data
#: 02 + the registered 4-byte pairing key + a power-switch byte (shape captured from an X100VI fw 1.10 during development).
SVC_BASIC_STARTUP = "731893f9-744e-4899-b7e3-174106ff2b82"
SVC_FURBLE_PRIMARY = "731893f9-744e-4899-b7e3-174106ff2b82"  # FU FujifilmSecure.cpp:14 (not in ad14d4)


# --------------------------------------------------------------------------------------------
# GATT map
# --------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class ServiceInfo:
    uuid: str
    name: str
    source: str
    notes: str = ""


@dataclass(frozen=True)
class CharInfo:
    uuid: str
    name: str
    service: str
    props: tuple[str, ...]  # as listed in FF gatt-ad14d4.yaml `flags`
    length: Optional[int]  # FF gatt-ad14d4.yaml `l` (max value length), None if not in ad14d4
    decoder: str  # key into DECODERS
    source: str
    notes: str = ""
    secret: bool = False  # redact the value in logs/JSON unless asked

    @property
    def short(self) -> str:
        return short_uuid(self.uuid)


def _sig(u16: str) -> str:
    return f"0000{u16.lower()}-0000-1000-8000-00805f9b34fb"


Y = "fffw/ffbt/cfg/gatt-ad14d4.yaml"
FBS = "fuji-bridge/FujiBridge/FujiBluetooth.swift"
FBK = "fuji-bridge/FujiBridge/FujiBackup.swift"
LFB = "libfuji/lib/bluetooth.c"
FUH = "furble/lib/furble/FujifilmSecure.h"
FUB = "furble/lib/furble/Fujifilm.h"

SERVICES: dict[str, ServiceInfo] = {
    s.uuid: s
    for s in [
        ServiceInfo(_sig("1800"), "Generic Access", f"{Y}:3"),
        ServiceInfo(_sig("1801"), "Generic Attribute", f"{Y}:16"),
        ServiceInfo(_sig("180a"), "Device Information", f"{Y}:24"),
        ServiceInfo(SVC_SECURE_PAIRING_ADVERT, "Secure pairing advert service", f"{Y}:57; {FBS}:56-57",
                    "Advertised in pairing mode by secure bodies. Its 7 read-only chars are unnamed in every source."),
        ServiceInfo("15ca59fe-620c-464d-a987-223fab660cde", "Lens", f"{Y}:95; {LFB}:61-63"),
        ServiceInfo("123d8f06-62a1-4935-9322-833c531ee225", "Pairing (secure)", f"{Y}:113; {FBS}:17-18; {LFB}:7"),
        ServiceInfo("4e941240-d01d-46b9-a5ea-67636806830b", "Wi-Fi / notifications", f"{Y}:153; {FBS}:36; {LFB}:16-17"),
        ServiceInfo("4c0020fe-f3b6-40de-acc9-77d129067b14", "Camera state (indications)", f"{Y}:222; {FBS}:26,62; {LFB}:75-76"),
        ServiceInfo("6514eb81-4e8f-458d-aa2a-e691336cdfac", "Control (shutter, function launch, backup request)",
                    f"{Y}:294; {FBS}:46; {LFB}:90"),
        ServiceInfo("e872b11f-d526-4ae1-9bb4-89a99d48fa59", "Time", f"{Y}:342; {LFB}:49-52"),
        ServiceInfo("3b46ec2b-48ba-41fd-b1b8-ed860b60d22b", "Geotag", f"{Y}:355; {LFB}:95-97"),
        ServiceInfo("af854c2e-b214-458e-97e2-912c4ecf2cb8", "File transfer (settings backup)", f"{Y}:363; {FBS}:63; {LFB}:30-31,65",
                    "libfuji: 'generic file reading service - both for backups and equipment status json'."),
        ServiceInfo(SVC_RECONNECT_ADVERT, "Reconnect / notification 3", f"{Y}:404; {FBS}:33,58-59; {LFB}:12-13"),
        # Seen in sources but not in the ad14d4 (X100VI fw 1.31) table:
        ServiceInfo("91f1de68-dff6-466e-8b65-ff13b0f16fb8", "Pairing (basic, older firmware)", f"{FBS}:21; {LFB}:54-55; {FUB}:37-38",
                    "Not in ad14d4. Present on basic-profile bodies (X100VI fw 1.11)."),
        ServiceInfo(SVC_CAMERA_INFO_BASIC, "Legacy advert service", "furble/lib/furble/FujifilmBasic.cpp:13; libfuji/lib/bluetooth.c:46",
                    "Not in ad14d4."),
    ]
}

C = CharInfo
CHARACTERISTICS: dict[str, CharInfo] = {
    c.uuid: c
    for c in [
        # --- Generic Access / Generic Attribute / Device Information (Bluetooth SIG) ---
        C(_sig("2a00"), "Device Name", _sig("1800"), ("read",), 0x14, "utf8", f"{Y}:6; {LFB}:99-100,545-547"),
        C(_sig("2a01"), "Appearance", _sig("1800"), ("read",), 0x2, "u16", f"{Y}:11"),
        C(_sig("2a05"), "Service Changed", _sig("1801"), ("read",), 0x4, "hex", f"{Y}:19"),
        C(_sig("2a29"), "Manufacturer Name", _sig("180a"), ("read",), 0xC, "utf8", f"{Y}:27"),
        C(_sig("2a24"), "Model Number", _sig("180a"), ("read",), 0x1E, "utf8", f"{Y}:32"),
        C(_sig("2a25"), "Serial Number", _sig("180a"), ("read",), 0x12, "utf8", f"{Y}:37"),
        C(_sig("2a27"), "Hardware Revision", _sig("180a"), ("read",), 0x1E, "utf8", f"{Y}:42"),
        C(_sig("2a26"), "Firmware Revision", _sig("180a"), ("read",), 0x1E, "utf8", f"{Y}:47; {LFB}:549-552",
          "Firmware decides the GATT profile: 1.11 = basic 76ab62, 1.31+ = secure ad14d4 (gatt-profiles-map.csv:5-6)."),
        C(_sig("2a28"), "Software Revision", _sig("180a"), ("read",), 0x1E, "utf8", f"{Y}:52"),
        # --- a9d2b304 secure pairing advert service: all unnamed ---
        C("9c72c205-5740-4f17-9949-0d3fadf2f67a", "unknown-9c72c205", SVC_SECURE_PAIRING_ADVERT, ("read",), 0x2, "hex", f"{Y}:60"),
        C("4bf16f6d-7264-4e76-b0d2-52cde16d2c7d", "unknown-4bf16f6d", SVC_SECURE_PAIRING_ADVERT, ("read",), 0x4, "hex", f"{Y}:65"),
        C("389363e4-712e-4cf2-a72e-bfcf7fb6adc1", "unknown-389363e4", SVC_SECURE_PAIRING_ADVERT, ("read",), 0x2, "hex", f"{Y}:70"),
        C("cae8c738-4bb6-4605-98c1-58331c87f3b6", "unknown-cae8c738", SVC_SECURE_PAIRING_ADVERT, ("read",), 0x1, "hex", f"{Y}:75"),
        C("27870478-94a9-4345-849b-efa3bf37887f", "unknown-27870478", SVC_SECURE_PAIRING_ADVERT, ("read",), 0x1E, "text", f"{Y}:80"),
        C("e8e40d50-a625-4f1d-96ed-8cec034f5690", "unknown-e8e40d50", SVC_SECURE_PAIRING_ADVERT, ("read",), 0xA, "text", f"{Y}:85"),
        C("49a12959-dfaa-4eb2-89ce-62548ad948f3", "unknown-49a12959", SVC_SECURE_PAIRING_ADVERT, ("read",), 0x11, "text",
          f"{Y}:90; {LFB}:46-47", "libfuji lists it under service 117c4142 on older bodies."),
        # --- Lens ---
        C("68887a7a-10a7-4a4a-aadd-6f9db1abaa0e", "LENS_NAME", "15ca59fe-620c-464d-a987-223fab660cde", ("read",), 0x40, "utf8",
          f"{Y}:98; {LFB}:62"),
        C("621a98d8-6314-4c3e-a683-eea1d6166606", "LENS_FW_VERSION", "15ca59fe-620c-464d-a987-223fab660cde", ("read",), 0x5, "text",
          f"{Y}:103; {LFB}:63"),
        C("df287e0c-c23f-4f80-afdd-c2b570288cdb", "unknown-df287e0c", "15ca59fe-620c-464d-a987-223fab660cde", ("read",), 0xA, "text",
          f"{Y}:108"),
        # --- 123d8f06 pairing (secure) ---
        C("85b9163e-62d1-49ff-a6f5-054b4630d4a1", "CONNECTED_DEVICE_NAME (client name)", "123d8f06-62a1-4935-9322-833c531ee225",
          ("write",), 0x1E, "utf8", f"{Y}:116; {FBS}:23-24,194; {LFB}:59,386-403; furble/lib/furble/FujifilmSecure.cpp:135-141",
          "Write the client name (UTF-8). The same name is reused as the Wi-Fi init name (fuji-bridge docs/DEVELOPMENT.md:132)."),
        C("a80be3f8-8bcb-4add-a725-170b7a53adc9", "unknown-a80be3f8", "123d8f06-62a1-4935-9322-833c531ee225", ("write",), 0x1, "hex", f"{Y}:121"),
        C("7ede1988-b27e-43fc-80f4-6fec994f0552", "unknown-7ede1988", "123d8f06-62a1-4935-9322-833c531ee225", ("read", "write"), 0x2, "hex",
          f"{Y}:126"),
        C("aba356eb-9633-4e60-b73f-f52516dbd671", "PAIRING_TOKEN (basic)", "123d8f06-62a1-4935-9322-833c531ee225", ("write",), 0x4, "hex",
          f"{Y}:132; {FBS}:20-22; {LFB}:56-57; {FUB}:39-40",
          "Basic bodies: write the 4-byte token from the pairing advert. On ad14d4 it sits in the secure pairing service."),
        C("763514e8-c627-4b9e-b7e8-89074ad3ccc7", "unknown-763514e8", "123d8f06-62a1-4935-9322-833c531ee225", ("write",), 0x2, "hex", f"{Y}:137"),
        C("eb4166b0-9cca-445e-a4e4-75b3817fd57a", "unknown-eb4166b0", "123d8f06-62a1-4935-9322-833c531ee225", ("write",), 0x2, "hex",
          f"{Y}:142; {LFB}:9-10", "libfuji: 'unknown', handle 0x4062."),
        C("f557d96b-8284-4667-8793-b971c1deca2a", "SECURE_STATUS", "123d8f06-62a1-4935-9322-833c531ee225", ("read", "write"), 0x4,
          "secure_status", f"{Y}:147; {FBS}:17-19,185-189,255-260; {FUH}:73; furble/lib/furble/FujifilmSecure.cpp:117-132; {LFB}:453-472",
          "Read 4 bytes, write them back with byte 3 = 0x20 (07 96 00 00 -> 07 96 00 20). The first encrypted read starts OS pairing."),
        # --- 4e941240 Wi-Fi / notifications ---
        C("bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4", "WIFI_SSID", "4e941240-d01d-46b9-a5ea-67636806830b", ("read", "write", "notify"), 0x20,
          "utf8", f"{Y}:156; {FBS}:37; {LFB}:18; {FUH}:91 (NOT4)"),
        C("e809256a-915c-4967-92e8-53b7d4cad213", "WIFI_PASSWORD", "4e941240-d01d-46b9-a5ea-67636806830b", ("read",), 0x14, "utf8",
          f"{Y}:163; {FBS}:38; {LFB}:19", "Absent on the basic profile (DOC §3.3).", secret=True),
        C("bd45f887-a6be-4cb7-8565-390df38bf5bf", "unknown-bd45f887", "4e941240-d01d-46b9-a5ea-67636806830b", ("read", "write", "notify"), 0x2,
          "hex", f"{Y}:168"),
        C("8814441b-1d7b-4046-891d-d8f80864cc8e", "unknown-8814441b", "4e941240-d01d-46b9-a5ea-67636806830b", ("read",), 0x2, "hex", f"{Y}:175"),
        C("aab609c4-94dd-4d89-bc60-665d5090b828", "NOTIFICATION_7", "4e941240-d01d-46b9-a5ea-67636806830b", ("read", "write", "notify"), 0x2,
          "hex", f"{Y}:180; {FBS}:40; {LFB}:23-24", "libfuji comment: '01 00'."),
        C("c95d91ae-b247-4d6d-8661-7dd5d6a0f85b", "GEOTAG_SYNC_INTERVAL", "4e941240-d01d-46b9-a5ea-67636806830b", ("read", "write", "notify"),
          0x2, "u16_seconds", f"{Y}:187; {FBS}:44; {LFB}:28; {FUB}:61-62; furble/lib/furble/FujifilmSecure.cpp:186-192",
          "furble writes u16 10 after subscribing."),
        C("75823784-fbb7-4b71-abae-cd9a34072e3c", "NOTIFICATION_5", "4e941240-d01d-46b9-a5ea-67636806830b", ("read", "write", "notify"), 0xD,
          "hex", f"{Y}:194; {FBS}:39; {LFB}:22"),
        C("caedb497-83bf-482c-91ef-91cf6f1216ff", "unknown-caedb497", "4e941240-d01d-46b9-a5ea-67636806830b", ("read", "write", "notify"), 0x1,
          "hex", f"{Y}:201"),
        C("98934b2c-756c-4632-aa2f-dcba1bfec824", "UNKNOWN_0 (SVC_READ)", "4e941240-d01d-46b9-a5ea-67636806830b", ("read", "write", "notify"),
          0x4, "hex", f"{Y}:208; {LFB}:20-21; {FUH}:83-84"),
        C("82a9f452-c5ce-4ef5-8203-3fc9a47f8171", "NOTIFICATION_9", "4e941240-d01d-46b9-a5ea-67636806830b", ("read", "write", "notify"), 0x1,
          "hex", f"{Y}:215; {FBS}:42; {LFB}:26"),
        C("2a125640-706d-4dd1-b420-c0f4ab93c361", "NOTIFICATION_8", "4e941240-d01d-46b9-a5ea-67636806830b", ("notify",), None, "hex",
          f"{FBS}:41; {LFB}:25; {FUH}:94", "Subscribed by libfuji/furble/fuji-bridge but NOT in ad14d4: expect it missing on X100VI 1.31+."),
        C("deef7187-3f43-4364-9e22-11a8c8a15951", "NOTIFICATION_10", "4e941240-d01d-46b9-a5ea-67636806830b", ("notify",), None, "hex",
          f"{FBS}:43; {LFB}:27; {FUH}:96", "Subscribed by libfuji/furble/fuji-bridge but NOT in ad14d4: expect it missing on X100VI 1.31+."),
        # --- 4c0020fe camera state ---
        C("a68e3f66-0fcc-4395-8d4c-aa980b5877fa", "AP_STATE (indication 1)", "4c0020fe-f3b6-40de-acc9-77d129067b14", ("read", "indicate"), 0x2,
          "ap_state", f"{Y}:225; {FBS}:27-28,210-225; {LFB}:80-81,366-376", "After FUNCTION_LAUNCH: 01 = Wi-Fi access point up, 00 = camera busy."),
        C("bd17ba04-b76b-4892-a545-b73ba1f74dae", "INDICATION_2", "4c0020fe-f3b6-40de-acc9-77d129067b14", ("read", "indicate"), 0x2, "hex",
          f"{Y}:231; {FBS}:29; {LFB}:82-83"),
        C("f9150137-5d40-4801-a8dc-f7fc5b01da50", "TIME_SYNC_REQUEST (notification 1)", "4c0020fe-f3b6-40de-acc9-77d129067b14",
          ("read", "notify"), 0x2, "not1", f"{Y}:237; {FBS}:30; {LFB}:84-85,272-285; furble/lib/furble/Fujifilm.cpp:24-27",
          "libfuji answers it by writing the time to b9bfd37f. furble: 02 00 = 'configured'."),
        C("ad06c7b7-f41a-46f4-a29a-712055319122", "GEOTAG_REQUEST (notification 2)", "4c0020fe-f3b6-40de-acc9-77d129067b14",
          ("read", "notify"), 0x2, "geotag_request", f"{Y}:243; {FBS}:31; {LFB}:87-88; furble/lib/furble/Fujifilm.cpp:28-31",
          "01 00 = camera asks for a location (furble then writes 0f36ec14)."),
        C("049ec406-ef75-4205-a390-08fe209c51f0", "INDICATION_3", "4c0020fe-f3b6-40de-acc9-77d129067b14", ("read", "indicate"), 0x2, "hex",
          f"{Y}:249; {LFB}:86; {FUB}:53"),
        C("2f6cb772-1d69-448e-8819-fe6b5c20b094", "unknown-2f6cb772", "4c0020fe-f3b6-40de-acc9-77d129067b14", ("read", "indicate"), 0x2, "hex",
          f"{Y}:255", "Camera-log transfer state (not restore)."),
        C("e6692c5c-b7cd-44f4-95fc-eda07ce32560", "NOTIFICATION_6", "4c0020fe-f3b6-40de-acc9-77d129067b14", ("read", "notify"), 0x2, "hex",
          f"{Y}:261; {FBS}:32; {LFB}:78-79"),
        C("11438c83-cfb0-4511-841b-759e0d2321c8", "BACKUP_STATE", "4c0020fe-f3b6-40de-acc9-77d129067b14", ("read", "indicate"), 0x2,
          "backup_state", f"{Y}:267; {FBS}:65; {FBK}:8,45-46", "After BACKUP_REQUEST: 1 = transferable, 0 = busy."),
        C("4b3a413c-230f-42bc-b3ed-b1db2eadee82", "unknown-4b3a413c", "4c0020fe-f3b6-40de-acc9-77d129067b14", ("read", "indicate"), 0x2, "hex",
          f"{Y}:273", "Restore state: u16 after the restore request, 1 = ready to receive, 0 = busy (DOC §3.7)."),
        C("34d8c8de-e2a9-43ff-822c-7d945dd8d8e1", "unknown-34d8c8de", "4c0020fe-f3b6-40de-acc9-77d129067b14", ("read",), 0x2, "hex", f"{Y}:279"),
        C("20ea1fac-19d8-48a8-a80c-535d34300958", "unknown-20ea1fac", "4c0020fe-f3b6-40de-acc9-77d129067b14", ("read",), 0x1D, "text",
          f"{Y}:284"),
        C("1587b102-0b6d-4b63-9226-66fcc6d17387", "CONF_UNKNOWN_1", "4c0020fe-f3b6-40de-acc9-77d129067b14", ("read",), 0x2, "hex",
          f"{Y}:289; {LFB}:77"),
        # --- 6514eb81 control ---
        C("600655e6-3637-42f1-8fb2-44efc5c63b13", "FUNCTION_LAUNCH_REQUEST", "6514eb81-4e8f-458d-aa2a-e691336cdfac", ("write",), 0x2,
          "function_launch", f"{Y}:297; {FBS}:47-54; {LFB}:93,324-337",
          "u16 LE: 1 ImportImage, 3 InCameraViewing, 4 RemoteShooting, 5 UpdateFirmware. Starts the camera's Wi-Fi AP."),
        C("fb15c357-364f-49d3-b5c5-1e32c0ded038", "unknown-fb15c357", "6514eb81-4e8f-458d-aa2a-e691336cdfac", ("write",), 0x1, "hex",
          f"{Y}:302", "Access-point launch; not needed by any flow here (FUNCTION_LAUNCH starts the AP). Don't write."),
        C("7fcf49c6-4ff0-4777-a03d-1a79166af7a8", "SHUTTER", "6514eb81-4e8f-458d-aa2a-e691336cdfac", ("write",), 0x2, "shutter",
          f"{Y}:307; {LFB}:92,107-110,191-207; {FUB}:55-56,101-104", "01 00 then 02 00 press / 03 00 half-press / 00 00 release."),
        C("b1307521-7ac5-4199-aaee-9d094781ce69", "unknown-b1307521", "6514eb81-4e8f-458d-aa2a-e691336cdfac", ("write",), 0x5C, "hex",
          f"{Y}:312", "Firmware-update request (92 bytes). NEVER write."),
        C("861442ab-b94e-4935-90d9-41e291d91374", "unknown-861442ab", "6514eb81-4e8f-458d-aa2a-e691336cdfac", ("write",), 0x2, "hex",
          f"{Y}:317", "Movie record request. Don't write."),
        C("43070f6c-51e0-4887-86a7-5f762bda5791", "unknown-43070f6c", "6514eb81-4e8f-458d-aa2a-e691336cdfac", ("write",), 0x2, "hex",
          f"{Y}:322", "Power control (u16; can switch the camera off). Don't write."),
        C("2674f0b0-f909-4e73-8656-338e9c74457f", "unknown-2674f0b0", "6514eb81-4e8f-458d-aa2a-e691336cdfac", ("write",), 0x2, "hex",
          f"{Y}:327", "Camera-log transfer request. Don't write."),
        C("f14e7a88-6f57-4872-a69b-b47ef3295c9b", "BACKUP_REQUEST", "6514eb81-4e8f-458d-aa2a-e691336cdfac", ("write",), 0x2, "hex",
          f"{Y}:332; {FBS}:61,64; {FBK}:7,43; fuji-bridge/docs/DEVELOPMENT.md:146", "u16 LE: 1 = settings backup, 2 = IPTC."),
        C("f1897eb9-a9aa-40f0-8ce6-2fa7915bc459", "unknown-f1897eb9", "6514eb81-4e8f-458d-aa2a-e691336cdfac", ("write",), 0x2, "hex",
          f"{Y}:337", "Restore request: u16 LE 1 = settings restore, 2 = IPTC. Answered on 4b3a413c (DOC §3.7)."),
        # --- e872b11f time ---
        C("b9bfd37f-ccad-4d36-a1ee-018e792b3edf", "TIME", "e872b11f-d526-4ae1-9bb4-89a99d48fa59", ("write",), 0x7, "time",
          f"{Y}:345; {LFB}:51-52,144-151,272-285", "u16 year, u8 month, day, hour, minute, second."),
        C("c52edbce-1fe2-4ecc-9483-907e6592be9e", "unknown-c52edbce", "e872b11f-d526-4ae1-9bb4-89a99d48fa59", ("write",), 0xC, "hex",
          f"{Y}:350; {LFB}:50"),
        # --- 3b46ec2b geotag ---
        C("0f36ec14-29e5-411a-a1b6-64ee8383f090", "GEOTAG", "3b46ec2b-48ba-41fd-b1b8-ed860b60d22b", ("write",), 0x17, "hex",
          f"{Y}:358; {LFB}:96-97,153-162; {FUB}:83-92", "i32 lat*1e7, i32 lon*1e7, i32 alt, 4 pad, time (23 bytes)."),
        # --- af854c2e file transfer ---
        C("e3fbbfcf-f326-4b0f-82cf-b00ae1b107a2", "FILE_UNKNOWN_1", "af854c2e-b214-458e-97e2-912c4ecf2cb8", ("read",), 0x4, "hex",
          f"{Y}:366; {LFB}:67"),
        C("051dd980-df9d-4472-a2e1-35811dd24ee1", "FILE_TRANSFER_INDEX", "af854c2e-b214-458e-97e2-912c4ecf2cb8", ("write",), 0x4, "u32",
          f"{Y}:371; {FBS}:66; {FBK}:9,48", "Backup writes u32 0 to start the transfer."),
        C("c922ac69-9480-4348-8f4b-9ee29bc30d1d", "FILE_INFORMATION", "af854c2e-b214-458e-97e2-912c4ecf2cb8", ("read", "write"), 0x2C,
          "file_information", f"{Y}:376; {FBS}:68; {FBK}:12,79-85; {LFB}:32-39", "char name[40] + u32 size. libfuji saw 'backup.dat', 33404."),
        C("7f3400fe-17e7-4b80-8a0e-81b0343c1b49", "FILE_PARTIAL_SIZE", "af854c2e-b214-458e-97e2-912c4ecf2cb8", ("read", "write"), 0x4, "u32",
          f"{Y}:382; {FBS}:67; {FBK}:9,47", "Backup writes u32 120."),
        C("ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea", "FILE_PARTIAL_DATA", "af854c2e-b214-458e-97e2-912c4ecf2cb8", ("read", "write"), 0xF8,
          "file_partial_data", f"{Y}:388; {FBS}:69; {FBK}:10-11,59-71,99-107; {LFB}:42",
          "u16 seq, u32 len, data. seq 0xFFFF = last chunk, ending with a u16 sum of all data bytes. Writable (restore?)."),
        C("68052e8a-fb91-404f-8847-0eb4be24308c", "FILE_TRANSFER_RESULT", "af854c2e-b214-458e-97e2-912c4ecf2cb8", ("write",), 0x2, "hex",
          f"{Y}:394; {FBS}:71; {FBK}:13,75,86,94; {LFB}:40-41", "03 00 = finished OK, 00 00 = error/abort."),
        C("2e27ed9f-5506-41cd-ba48-dac06669ad95", "FILE_TRANSACTION_STATE", "af854c2e-b214-458e-97e2-912c4ecf2cb8", ("notify",), 0x4,
          "transaction_state", f"{Y}:399; {FBS}:70; {FBK}:10-12,53-91; {LFB}:43-44",
          "u16 state (+2 bytes): 1/2 = a chunk is ready, 3 = file finished. libfuji captured '05 00 ff ff' (meaning unknown)."),
        # --- 804daa8e reconnect / notification 3 ---
        C("f90f7d3a-3b64-45c6-ab21-933900184837", "unknown-f90f7d3a", SVC_RECONNECT_ADVERT, ("read", "notify"), 0x2, "hex", f"{Y}:407"),
        C("7170fd5a-56d9-4c19-b043-7a7047d8e1a0", "NOTIFICATION_3", SVC_RECONNECT_ADVERT, ("read", "write", "notify"), 0x2, "hex",
          f"{Y}:413; {FBS}:33-34; {LFB}:13-14"),
    ]
}
del C

# --------------------------------------------------------------------------------------------
# Dial In labels: one name per service and characteristic, in our own words. They replace the "unknown-xxxxxxxx"
# placeholders and the open-source projects' labels; the earlier label is kept in `notes` so existing logs still read.
# Meanings come from the interoperability work described in docs/FUJIFILM-PROTOCOL.md (Provenance).
# --------------------------------------------------------------------------------------------

#: Source strings: our label (appended to every row), and rows that no published project lists.
LABEL_SOURCE = "Dial In label (DOC §3.3)"
STUDY = "Dial In interoperability study (DOC §3.3)"

SERVICE_LABELS: dict[str, str] = {
    "117c4142-edd4-4c77-8696-dd18eebb770a": "camera info (basic)",
    SVC_SECURE_PAIRING_ADVERT: "camera info (secure)",
    "91f1de68-dff6-466e-8b65-ff13b0f16fb8": "client registration (basic: pairing key, client name)",
    "123d8f06-62a1-4935-9322-833c531ee225": "client registration (secure: id number, client name)",
    "4e941240-d01d-46b9-a5ea-67636806830b": "camera settings (Wi-Fi SSID/passphrase, location sync, transfer settings)",
    "4c0020fe-f3b6-40de-acc9-77d129067b14": "camera state (AP, transfer, time/location requests, backup/restore state)",
    "6514eb81-4e8f-458d-aa2a-e691336cdfac": "camera control (function launch, shutter, backup/restore requests)",
    "e872b11f-d526-4ae1-9bb4-89a99d48fa59": "time",
    "3b46ec2b-48ba-41fd-b1b8-ed860b60d22b": "location",
    "af854c2e-b214-458e-97e2-912c4ecf2cb8": "file transfer (settings backup + restore)",
    SVC_RECONNECT_ADVERT: "standby (secure: power switch, remote power-on)",
    "731893f9-744e-4899-b7e3-174106ff2b82": "standby (basic: power switch, remote power-on)",
    "15ca59fe-620c-464d-a987-223fab660cde": "mounted lens",
    "eb894e6e-a8f8-4b3b-9a30-9b2bba546675": "camera info (other bodies)",
    "462426e1-d712-4a28-be62-61a786daa866": "file transfer (other bodies)",
    "cc74bd26-4abb-4911-ae72-9cd93109a772": "file transfer (other bodies, secure)",
}

CHAR_LABELS: dict[str, str] = {
    "9c72c205-5740-4f17-9949-0d3fadf2f67a": "wake-up mode",
    "4bf16f6d-7264-4e76-b0d2-52cde16d2c7d": "startup value",
    "389363e4-712e-4cf2-a72e-bfcf7fb6adc1": "camera protocol version",
    "cae8c738-4bb6-4605-98c1-58331c87f3b6": "movie button",
    "27870478-94a9-4345-849b-efa3bf37887f": "camera identity number",
    "e8e40d50-a625-4f1d-96ed-8cec034f5690": "camera serial",
    "49a12959-dfaa-4eb2-89ce-62548ad948f3": "camera Wi-Fi address (BSSID)",
    "68887a7a-10a7-4a4a-aadd-6f9db1abaa0e": "lens name",
    "621a98d8-6314-4c3e-a683-eea1d6166606": "lens firmware",
    "df287e0c-c23f-4f80-afdd-c2b570288cdb": "lens serial",
    "85b9163e-62d1-49ff-a6f5-054b4630d4a1": "client name",
    "a80be3f8-8bcb-4add-a725-170b7a53adc9": "client image-receive state",
    "7ede1988-b27e-43fc-80f4-6fec994f0552": "disconnect reason",
    "aba356eb-9633-4e60-b73f-f52516dbd671": "pairing key (basic)",
    "763514e8-c627-4b9e-b7e8-89074ad3ccc7": "client error state",
    "eb4166b0-9cca-445e-a4e4-75b3817fd57a": "client protocol version",
    "f557d96b-8284-4667-8793-b971c1deca2a": "client id number (secure)",
    "8b5ecf55-fc6b-40d0-b4c1-76f64e5453c7": "app identity (never written)",
    "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4": "Wi-Fi SSID",
    "e809256a-915c-4967-92e8-53b7d4cad213": "Wi-Fi passphrase",
    "bd45f887-a6be-4cb7-8565-390df38bf5bf": "transfer-after-shooting setting",
    "8814441b-1d7b-4046-891d-d8f80864cc8e": "paired phone count",
    "aab609c4-94dd-4d89-bc60-665d5090b828": "location sync on/off",
    "c95d91ae-b247-4d6d-8661-7dd5d6a0f85b": "location sync interval",
    "75823784-fbb7-4b71-abae-cd9a34072e3c": "logging setting",
    "caedb497-83bf-482c-91ef-91cf6f1216ff": "image transfer setting",
    "98934b2c-756c-4632-aa2f-dcba1bfec824": "image transfer setting 2",
    "82a9f452-c5ce-4ef5-8203-3fc9a47f8171": "image resize setting",
    "2a125640-706d-4dd1-b420-c0f4ab93c361": "image resize rate",
    "deef7187-3f43-4364-9e22-11a8c8a15951": "IPTC setting",
    "a68e3f66-0fcc-4395-8d4c-aa980b5877fa": "AP state",
    "bd17ba04-b76b-4892-a545-b73ba1f74dae": "transfer state",
    "f9150137-5d40-4801-a8dc-f7fc5b01da50": "time sync request",
    "ad06c7b7-f41a-46f4-a29a-712055319122": "location request",
    "049ec406-ef75-4205-a390-08fe209c51f0": "firmware update state",
    "2f6cb772-1d69-448e-8819-fe6b5c20b094": "log transfer state",
    "e6692c5c-b7cd-44f4-95fc-eda07ce32560": "camera status",
    "11438c83-cfb0-4511-841b-759e0d2321c8": "backup state",
    "4b3a413c-230f-42bc-b3ed-b1db2eadee82": "restore state",
    "34d8c8de-e2a9-43ff-822c-7d945dd8d8e1": "card state",
    "20ea1fac-19d8-48a8-a80c-535d34300958": "firmware file info",
    "1587b102-0b6d-4b63-9226-66fcc6d17387": "error details",
    "600655e6-3637-42f1-8fb2-44efc5c63b13": "function launch",
    "fb15c357-364f-49d3-b5c5-1e32c0ded038": "AP launch",
    "7fcf49c6-4ff0-4777-a03d-1a79166af7a8": "shutter",
    "b1307521-7ac5-4199-aaee-9d094781ce69": "firmware update request",
    "861442ab-b94e-4935-90d9-41e291d91374": "movie record request",
    "43070f6c-51e0-4887-86a7-5f762bda5791": "power control",
    "2674f0b0-f909-4e73-8656-338e9c74457f": "log transfer request",
    "f14e7a88-6f57-4872-a69b-b47ef3295c9b": "backup request",
    "f1897eb9-a9aa-40f0-8ce6-2fa7915bc459": "restore request",
    "b9bfd37f-ccad-4d36-a1ee-018e792b3edf": "local time",
    "c52edbce-1fe2-4ecc-9483-907e6592be9e": "UTC time and zone",
    "0f36ec14-29e5-411a-a1b6-64ee8383f090": "location fix",
    "e3fbbfcf-f326-4b0f-82cf-b00ae1b107a2": "file count",
    "051dd980-df9d-4472-a2e1-35811dd24ee1": "file index",
    "c922ac69-9480-4348-8f4b-9ee29bc30d1d": "file info",
    "7f3400fe-17e7-4b80-8a0e-81b0343c1b49": "chunk size",
    "ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea": "chunk data",
    "68052e8a-fb91-404f-8847-0eb4be24308c": "transfer result",
    "2e27ed9f-5506-41cd-ba48-dac06669ad95": "transfer progress",
    "f90f7d3a-3b64-45c6-ab21-933900184837": "power switch state",
    "7170fd5a-56d9-4c19-b043-7a7047d8e1a0": "remote power-on setting",
    "bc384197-9fb6-4400-8639-c23b61b26394": "instax print count (hybrid camera)",
    "8fbfde61-e535-44f5-89f4-915955f3a716": "instax print count (other)",
    "0e66288a-8b0f-45d4-afcc-9c75dabf8e15": "instax print count (printer)",
}

#: Characteristics newer bodies have that the ad14d4 table doesn't list. 8b5ecf55 is listed only so the client can
#: recognise and refuse it (NEVER_WRITE): newer bodies use it to identify the connecting app, and Dial In never writes it.
_EXTRA_CHARS = [
    ("8b5ecf55-fc6b-40d0-b4c1-76f64e5453c7", "123d8f06-62a1-4935-9322-833c531ee225", ("write",),
     "Identifies the connecting app on newer bodies. Dial In never writes it (see NEVER_WRITE)."),
    ("bc384197-9fb6-4400-8639-c23b61b26394", SVC_SECURE_PAIRING_ADVERT, ("read",), "instax print count (hybrid cameras)"),
    ("8fbfde61-e535-44f5-89f4-915955f3a716", SVC_SECURE_PAIRING_ADVERT, ("read",), "instax print count (others)"),
    ("0e66288a-8b0f-45d4-afcc-9c75dabf8e15", SVC_SECURE_PAIRING_ADVERT, ("read",), "instax print count (printer)"),
]


def _apply_labels() -> None:
    import dataclasses

    for u, label in SERVICE_LABELS.items():
        if u in SERVICES:
            s = SERVICES[u]
            SERVICES[u] = dataclasses.replace(s, name=label, source=f"{s.source}; {LABEL_SOURCE}",
                                              notes=(s.notes + " " if s.notes else "") + f"(earlier label: {s.name})")
        else:
            SERVICES[u] = ServiceInfo(u, label, STUDY)
    for u, svc, props, note in _EXTRA_CHARS:
        if u not in CHARACTERISTICS:
            CHARACTERISTICS[u] = CharInfo(u, CHAR_LABELS[u], svc, props, None, "hex", STUDY, note)
    for u, label in CHAR_LABELS.items():
        c = CHARACTERISTICS.get(u)
        if c is None or c.name == label:
            continue
        CHARACTERISTICS[u] = dataclasses.replace(
            c, name=label, source=f"{c.source}; {LABEL_SOURCE}",
            notes=(c.notes + " " if c.notes else "") + ("" if c.name.startswith("unknown-") else f"(earlier label: {c.name})"))


_apply_labels()

# Convenience names used by the client (all keys of CHARACTERISTICS).
DEVICE_NAME = _sig("2a00")
FIRMWARE_REVISION = _sig("2a26")
MODEL_NUMBER = _sig("2a24")
SECURE_STATUS = "f557d96b-8284-4667-8793-b971c1deca2a"
PAIRING_TOKEN = "aba356eb-9633-4e60-b73f-f52516dbd671"
CLIENT_NAME = "85b9163e-62d1-49ff-a6f5-054b4630d4a1"
GEOTAG_SYNC_INTERVAL = "c95d91ae-b247-4d6d-8661-7dd5d6a0f85b"
TIME_SYNC_REQUEST = "f9150137-5d40-4801-a8dc-f7fc5b01da50"
TIME = "b9bfd37f-ccad-4d36-a1ee-018e792b3edf"
AP_STATE = "a68e3f66-0fcc-4395-8d4c-aa980b5877fa"
FUNCTION_LAUNCH = "600655e6-3637-42f1-8fb2-44efc5c63b13"
SHUTTER = "7fcf49c6-4ff0-4777-a03d-1a79166af7a8"
GEOTAG = "0f36ec14-29e5-411a-a1b6-64ee8383f090"
BACKUP_REQUEST = "f14e7a88-6f57-4872-a69b-b47ef3295c9b"
BACKUP_STATE = "11438c83-cfb0-4511-841b-759e0d2321c8"
FILE_TRANSFER_INDEX = "051dd980-df9d-4472-a2e1-35811dd24ee1"
FILE_INFORMATION = "c922ac69-9480-4348-8f4b-9ee29bc30d1d"
FILE_PARTIAL_SIZE = "7f3400fe-17e7-4b80-8a0e-81b0343c1b49"
FILE_PARTIAL_DATA = "ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea"
FILE_TRANSFER_RESULT = "68052e8a-fb91-404f-8847-0eb4be24308c"
FILE_TRANSACTION_STATE = "2e27ed9f-5506-41cd-ba48-dac06669ad95"

#: What libfuji subscribes to on a secure body, in its order (libfuji/lib/bluetooth.c:483-501;
#: same list in fuji-bridge FujiBluetooth.swift:75-80, furble FujifilmSecure.cpp:144-172).
#: Two of these (2a125640, deef7187) are not in ad14d4, so on an X100VI 1.31+ they will be missing.
SECURE_SUBSCRIPTIONS: tuple[str, ...] = (
    AP_STATE,
    "bd17ba04-b76b-4892-a545-b73ba1f74dae",
    TIME_SYNC_REQUEST,
    "ad06c7b7-f41a-46f4-a29a-712055319122",
    "7170fd5a-56d9-4c19-b043-7a7047d8e1a0",
    "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4",
    "75823784-fbb7-4b71-abae-cd9a34072e3c",
    "e6692c5c-b7cd-44f4-95fc-eda07ce32560",
    "aab609c4-94dd-4d89-bc60-665d5090b828",
    "2a125640-706d-4dd1-b420-c0f4ab93c361",
    "82a9f452-c5ce-4ef5-8203-3fc9a47f8171",
    "deef7187-3f43-4364-9e22-11a8c8a15951",
    GEOTAG_SYNC_INTERVAL,
)

#: Historical: the write-only control chars and state indications we once suspected of being the restore
#: request/state. Settled since (DOC §3.7): RESTORE_REQUEST = f1897eb9, RESTORE_STATE = 4b3a413c; the others are AP
#: launch, firmware update, movie record, power control and log transfer (see CHAR_LABELS). Kept for old profiles/tests.
RESTORE_REQUEST_CANDIDATES: tuple[str, ...] = (
    "f1897eb9-a9aa-40f0-8ce6-2fa7915bc459",
    "2674f0b0-f909-4e73-8656-338e9c74457f",
    "43070f6c-51e0-4887-86a7-5f762bda5791",
    "861442ab-b94e-4935-90d9-41e291d91374",
    "fb15c357-364f-49d3-b5c5-1e32c0ded038",
    "b1307521-7ac5-4199-aaee-9d094781ce69",
)
RESTORE_STATE_CANDIDATES: tuple[str, ...] = (
    "2f6cb772-1d69-448e-8819-fe6b5c20b094",
    "4b3a413c-230f-42bc-b3ed-b1db2eadee82",
)

#: The ad14d4 (X100VI fw 1.31+) table: everything in CHARACTERISTICS that has a yaml length.
X100VI_AD14D4: frozenset[str] = frozenset(u for u, c in CHARACTERISTICS.items() if c.length is not None)

# More convenience constants, in Dial In's names. Aliases of the older names where both exist.
RESTORE_REQUEST = "f1897eb9-a9aa-40f0-8ce6-2fa7915bc459"
RESTORE_STATE = "4b3a413c-230f-42bc-b3ed-b1db2eadee82"
CLIENT_ID_NUMBER = SECURE_STATUS
PAIRING_KEY = PAIRING_TOKEN
SERIAL_NUMBER = _sig("2a25")
CAMERA_SERIAL = "e8e40d50-a625-4f1d-96ed-8cec034f5690"
CAMERA_IDENTITY_NUMBER = "27870478-94a9-4345-849b-efa3bf37887f"
CAMERA_WIFI_ADDRESS = "49a12959-dfaa-4eb2-89ce-62548ad948f3"
CAMERA_SSID = "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4"
CAMERA_PASSPHRASE = "e809256a-915c-4967-92e8-53b7d4cad213"
APP_IDENTITY_CHAR = "8b5ecf55-fc6b-40d0-b4c1-76f64e5453c7"
DISCONNECT_REASON = "7ede1988-b27e-43fc-80f4-6fec994f0552"
TRANSFER_STATE = "bd17ba04-b76b-4892-a545-b73ba1f74dae"
UTC_TIME_AND_ZONE = "c52edbce-1fe2-4ecc-9483-907e6592be9e"
LOCATION_REQUEST = "ad06c7b7-f41a-46f4-a29a-712055319122"
LOCATION_SYNC_SETTING = "aab609c4-94dd-4d89-bc60-665d5090b828"
LOCATION_SYNC_INTERVAL = GEOTAG_SYNC_INTERVAL
LOCATION_FIX = GEOTAG
FUNCTION_LAUNCH_REQUEST = FUNCTION_LAUNCH
REMOTE_POWER_ON = "7170fd5a-56d9-4c19-b043-7a7047d8e1a0"
CAMERA_STATUS = "e6692c5c-b7cd-44f4-95fc-eda07ce32560"
SVC_FILE_TRANSFER = "af854c2e-b214-458e-97e2-912c4ecf2cb8"
SVC_REGISTRATION_BASIC = "91f1de68-dff6-466e-8b65-ff13b0f16fb8"

#: Subscriptions after discovery, in two rounds (DOC §3.4), skipping any the body doesn't have. The union is
#: libfuji's list (SECURE_SUBSCRIPTIONS) in a different order.
FIRST_SUBSCRIPTION_ROUND: tuple[str, ...] = (AP_STATE, TRANSFER_STATE, TIME_SYNC_REQUEST, LOCATION_REQUEST)
SECOND_SUBSCRIPTION_ROUND: tuple[str, ...] = (
    REMOTE_POWER_ON, CAMERA_SSID, "75823784-fbb7-4b71-abae-cd9a34072e3c", CAMERA_STATUS, LOCATION_SYNC_SETTING,
    "2a125640-706d-4dd1-b420-c0f4ab93c361", "82a9f452-c5ce-4ef5-8203-3fc9a47f8171", "deef7187-3f43-4364-9e22-11a8c8a15951",
    LOCATION_SYNC_INTERVAL,
)

#: The basic GATT profile 76ab62 (fffw ffbt/cfg/gatt-76ab62.yaml, generated as text): X100VI fw 1.11 and the fw 1.10
#: body we tested (gatt-profiles-map.csv:6). (service, ((characteristic, properties, max length), ...)).
#: Differences from ad14d4 that matter: pairing chars live in 91f1de68 (PAIRING_KEY, no identification number),
#: camera info in 117c4142, NO Wi-Fi passphrase characteristic (the camera's AP is open), and it HAS
#: RESTORE_REQUEST f1897eb9 / RESTORE_STATE 4b3a413c (so the BLE restore exists on this firmware).
X100VI_76AB62: tuple = (
    ("00001800-0000-1000-8000-00805f9b34fb", (
        ("00002a00-0000-1000-8000-00805f9b34fb", ('read',), 0x14),
        ("00002a01-0000-1000-8000-00805f9b34fb", ('read',), 0x2),
    )),
    ("00001801-0000-1000-8000-00805f9b34fb", (
        ("00002a05-0000-1000-8000-00805f9b34fb", ('read',), 0x4),
    )),
    ("0000180a-0000-1000-8000-00805f9b34fb", (
        ("00002a29-0000-1000-8000-00805f9b34fb", ('read',), 0xc),
        ("00002a24-0000-1000-8000-00805f9b34fb", ('read',), 0x1e),
        ("00002a25-0000-1000-8000-00805f9b34fb", ('read',), 0x12),
        ("00002a27-0000-1000-8000-00805f9b34fb", ('read',), 0x1e),
        ("00002a26-0000-1000-8000-00805f9b34fb", ('read',), 0x1e),
        ("00002a28-0000-1000-8000-00805f9b34fb", ('read',), 0x1e),
    )),
    ("117c4142-edd4-4c77-8696-dd18eebb770a", (
        ("9c72c205-5740-4f17-9949-0d3fadf2f67a", ('read',), 0x2),
        ("4bf16f6d-7264-4e76-b0d2-52cde16d2c7d", ('read',), 0x4),
        ("389363e4-712e-4cf2-a72e-bfcf7fb6adc1", ('read',), 0x2),
        ("cae8c738-4bb6-4605-98c1-58331c87f3b6", ('read',), 0x1),
        ("27870478-94a9-4345-849b-efa3bf37887f", ('read',), 0x1e),
        ("e8e40d50-a625-4f1d-96ed-8cec034f5690", ('read',), 0xa),
        ("49a12959-dfaa-4eb2-89ce-62548ad948f3", ('read',), 0x11),
    )),
    ("15ca59fe-620c-464d-a987-223fab660cde", (
        ("68887a7a-10a7-4a4a-aadd-6f9db1abaa0e", ('read',), 0x40),
        ("621a98d8-6314-4c3e-a683-eea1d6166606", ('read',), 0x5),
        ("df287e0c-c23f-4f80-afdd-c2b570288cdb", ('read',), 0xa),
    )),
    ("91f1de68-dff6-466e-8b65-ff13b0f16fb8", (
        ("85b9163e-62d1-49ff-a6f5-054b4630d4a1", ('write',), 0x1e),
        ("a80be3f8-8bcb-4add-a725-170b7a53adc9", ('write',), 0x1),
        ("7ede1988-b27e-43fc-80f4-6fec994f0552", ('read', 'write'), 0x2),
        ("aba356eb-9633-4e60-b73f-f52516dbd671", ('write',), 0x4),
        ("763514e8-c627-4b9e-b7e8-89074ad3ccc7", ('write',), 0x2),
        ("eb4166b0-9cca-445e-a4e4-75b3817fd57a", ('write',), 0x2),
    )),
    ("4e941240-d01d-46b9-a5ea-67636806830b", (
        ("bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4", ('read', 'write', 'notify'), 0x20),
        ("bd45f887-a6be-4cb7-8565-390df38bf5bf", ('read', 'write', 'notify'), 0x2),
        ("8814441b-1d7b-4046-891d-d8f80864cc8e", ('read',), 0x2),
        ("aab609c4-94dd-4d89-bc60-665d5090b828", ('read', 'write', 'notify'), 0x2),
        ("c95d91ae-b247-4d6d-8661-7dd5d6a0f85b", ('read', 'write', 'notify'), 0x2),
        ("75823784-fbb7-4b71-abae-cd9a34072e3c", ('read', 'write', 'notify'), 0xd),
        ("caedb497-83bf-482c-91ef-91cf6f1216ff", ('read', 'write', 'notify'), 0x1),
        ("98934b2c-756c-4632-aa2f-dcba1bfec824", ('read', 'write', 'notify'), 0x4),
        ("82a9f452-c5ce-4ef5-8203-3fc9a47f8171", ('read', 'write', 'notify'), 0x1),
    )),
    ("4c0020fe-f3b6-40de-acc9-77d129067b14", (
        ("a68e3f66-0fcc-4395-8d4c-aa980b5877fa", ('read', 'indicate'), 0x2),
        ("bd17ba04-b76b-4892-a545-b73ba1f74dae", ('read', 'indicate'), 0x2),
        ("f9150137-5d40-4801-a8dc-f7fc5b01da50", ('read', 'notify'), 0x2),
        ("ad06c7b7-f41a-46f4-a29a-712055319122", ('read', 'notify'), 0x2),
        ("049ec406-ef75-4205-a390-08fe209c51f0", ('read', 'indicate'), 0x2),
        ("2f6cb772-1d69-448e-8819-fe6b5c20b094", ('read', 'indicate'), 0x2),
        ("e6692c5c-b7cd-44f4-95fc-eda07ce32560", ('read', 'notify'), 0x2),
        ("11438c83-cfb0-4511-841b-759e0d2321c8", ('read', 'indicate'), 0x2),
        ("4b3a413c-230f-42bc-b3ed-b1db2eadee82", ('read', 'indicate'), 0x2),
        ("34d8c8de-e2a9-43ff-822c-7d945dd8d8e1", ('read',), 0x2),
        ("20ea1fac-19d8-48a8-a80c-535d34300958", ('read',), 0x1d),
        ("1587b102-0b6d-4b63-9226-66fcc6d17387", ('read',), 0x2),
    )),
    ("6514eb81-4e8f-458d-aa2a-e691336cdfac", (
        ("600655e6-3637-42f1-8fb2-44efc5c63b13", ('write',), 0x2),
        ("fb15c357-364f-49d3-b5c5-1e32c0ded038", ('write',), 0x1),
        ("7fcf49c6-4ff0-4777-a03d-1a79166af7a8", ('write',), 0x2),
        ("b1307521-7ac5-4199-aaee-9d094781ce69", ('write',), 0x5c),
        ("861442ab-b94e-4935-90d9-41e291d91374", ('write',), 0x2),
        ("43070f6c-51e0-4887-86a7-5f762bda5791", ('write',), 0x2),
        ("2674f0b0-f909-4e73-8656-338e9c74457f", ('write',), 0x2),
        ("f14e7a88-6f57-4872-a69b-b47ef3295c9b", ('write',), 0x2),
        ("f1897eb9-a9aa-40f0-8ce6-2fa7915bc459", ('write',), 0x2),
    )),
    ("e872b11f-d526-4ae1-9bb4-89a99d48fa59", (
        ("b9bfd37f-ccad-4d36-a1ee-018e792b3edf", ('write',), 0x7),
        ("c52edbce-1fe2-4ecc-9483-907e6592be9e", ('write',), 0xc),
    )),
    ("3b46ec2b-48ba-41fd-b1b8-ed860b60d22b", (
        ("0f36ec14-29e5-411a-a1b6-64ee8383f090", ('write',), 0x17),
    )),
    ("af854c2e-b214-458e-97e2-912c4ecf2cb8", (
        ("e3fbbfcf-f326-4b0f-82cf-b00ae1b107a2", ('read',), 0x4),
        ("051dd980-df9d-4472-a2e1-35811dd24ee1", ('write',), 0x4),
        ("c922ac69-9480-4348-8f4b-9ee29bc30d1d", ('read', 'write'), 0x2c),
        ("7f3400fe-17e7-4b80-8a0e-81b0343c1b49", ('read', 'write'), 0x4),
        ("ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea", ('read', 'write'), 0xf8),
        ("68052e8a-fb91-404f-8847-0eb4be24308c", ('write',), 0x2),
        ("2e27ed9f-5506-41cd-ba48-dac06669ad95", ('notify',), 0x4),
    )),
    ("731893f9-744e-4899-b7e3-174106ff2b82", (
        ("f90f7d3a-3b64-45c6-ab21-933900184837", ('read', 'notify'), 0x2),
        ("7170fd5a-56d9-4c19-b043-7a7047d8e1a0", ('read', 'write', 'notify'), 0x2),
    )),
)
X100VI_76AB62_CHARS: frozenset[str] = frozenset(c for _, chars in X100VI_76AB62 for c, _, _ in chars)


def normalize_uuid(u: str) -> str:
    u = u.strip().lower()
    if len(u) == 4:
        return _sig(u)
    if len(u) == 8 and all(ch in "0123456789abcdef" for ch in u):
        # Short Fuji prefix ("f557d96b"): resolve against the map.
        matches = [k for k in CHARACTERISTICS if k.startswith(u)] + [k for k in SERVICES if k.startswith(u)]
        if len(matches) == 1:
            return matches[0]
        raise ValueError(f"'{u}' is ambiguous or unknown; give the full UUID")
    return u


def short_uuid(u: str) -> str:
    u = u.lower()
    if u.endswith("-0000-1000-8000-00805f9b34fb") and u.startswith("0000"):
        return u[4:8]
    return u[:8]


def char_info(u: str) -> Optional[CharInfo]:
    return CHARACTERISTICS.get(u.lower())


def char_label(u: str) -> str:
    info = char_info(u)
    return f"{short_uuid(u)} {info.name}" if info else f"{short_uuid(u)} (not in our map)"


def service_label(u: str) -> str:
    info = SERVICES.get(u.lower())
    return f"{short_uuid(u)} {info.name}" if info else f"{short_uuid(u)} (not in our map)"


# --------------------------------------------------------------------------------------------
# Advert decoding
# --------------------------------------------------------------------------------------------


@dataclass
class AdvertInfo:
    kind: str  # "secure-pairing" | "bonded" | "basic-pairing" | "fujifilm"
    type_byte: Optional[int]
    tag: str  # secure: ASCII serial tag ("1D7B8"); basic: token hex
    token: Optional[bytes]
    raw_hex: str  # manufacturer payload after the company id
    services: list[str] = field(default_factory=list)

    def describe(self) -> str:
        what = {
            "secure-pairing": "secure body in PAIRING REGISTRATION mode",
            "bonded": "secure body, already bonded to a phone/computer, waiting for it to reconnect",
            "basic-pairing": "older (basic) firmware in pairing mode, token in advert",
            "basic": "older (basic) firmware, not in pairing mode (reconnect with the saved pairing key)",
            "basic-off": "older (basic) firmware, camera switched OFF (Bluetooth standby); the advert carries the "
                         "REGISTERED pairing key and the power-switch state",
            "fujifilm": "Fujifilm advert, mode not recognised",
        }[self.kind]
        return what


def decode_advert(manufacturer_data: dict[int, bytes], service_uuids: list[str]) -> Optional[AdvertInfo]:
    """Decode a Fujifilm advert from bleak's AdvertisementData fields.

    bleak strips the 2-byte company id and keys the dict by it. Mirrors fuji-bridge FujiAdvert.parse
    (FujiBluetooth.swift:100-118), which is tested against real X100VI fw 1.32 bytes
    (Tests/BluetoothTests.swift:79-103).
    """
    services = [s.lower() for s in service_uuids]
    if FUJIFILM_COMPANY_ID not in manufacturer_data:
        if "af854c2e-b214-458e-97e2-912c4ecf2cb8" in services:
            # A registered basic body (not pairing) may advertise the file-transfer service with no manufacturer data.
            return AdvertInfo("basic", None, "", None, "", services)
        return None
    payload = bytes(manufacturer_data[FUJIFILM_COMPANY_ID])
    if not payload:
        kind = "basic" if "af854c2e-b214-458e-97e2-912c4ecf2cb8" in services else "fujifilm"
        return AdvertInfo(kind, None, "", None, "", services)
    type_byte = payload[0]
    rest = payload[1:]
    if type_byte == ADV_TYPE_BASIC_TOKEN and len(rest) >= 4 and SVC_BASIC_STARTUP in services:
        # The standby service (731893f9) marks the power-off advert: 02 + 4-byte pairing key + u8 power-switch state.
        # The key is the one stored at registration, so this IS the registered key (DOC §3.2).
        token = bytes(rest[:4])
        return AdvertInfo("basic-off", type_byte, token.hex(), token, payload.hex(), services)
    if type_byte == ADV_TYPE_BASIC_TOKEN and len(rest) >= 4:
        token = bytes(rest[:4])
        return AdvertInfo("basic-pairing", type_byte, token.hex(), token, payload.hex(), services)
    text = "".join(chr(b) for b in rest if 0x20 <= b < 0x7F)
    if "af854c2e-b214-458e-97e2-912c4ecf2cb8" in services:
        # A body advertising the file-transfer service is a basic-profile body
        # outside pairing mode it carries no token, so the saved one is used.
        return AdvertInfo("basic", type_byte, text, None, payload.hex(), services)
    if SVC_SECURE_PAIRING_ADVERT in services:
        kind = "secure-pairing"
    elif SVC_RECONNECT_ADVERT in services or "123d8f06-62a1-4935-9322-833c531ee225" in services:
        # fuji-bridge FujiBluetooth.swift:112-116: both seen from a bonded X100VI fw 1.32. NOTE (:495-497): an X100VI
        # in PAIRING REGISTRATION also keeps advertising 123d8f06; a9d2b304 only appears once connected.
        kind = "bonded"
    else:
        kind = "fujifilm"
    return AdvertInfo(kind, type_byte, text, None, payload.hex(), services)


# --------------------------------------------------------------------------------------------
# Byte helpers and value decoders
# --------------------------------------------------------------------------------------------


def u16le(n: int) -> bytes:
    return struct.pack("<H", n & 0xFFFF)


def u32le(n: int) -> bytes:
    return struct.pack("<I", n & 0xFFFFFFFF)


def hexs(b: bytes, limit: int = 0) -> str:
    b = bytes(b)
    if limit and len(b) > limit:
        return b[:limit].hex(" ") + f" ... (+{len(b) - limit} bytes)"
    return b.hex(" ")


def ack_secure_status(status: bytes) -> bytes:
    """STATUS goes back with its last byte set to 0x20 (fuji-bridge FujiBluetooth.swift:255-260,
    furble FujifilmSecure.cpp:122, libfuji bluetooth.c:467)."""
    if len(status) != 4:
        raise ValueError(f"secure status must be 4 bytes, got {len(status)}: {hexs(status)}")
    return bytes(status[:3]) + b"\x20"


def _utf8z(b: bytes) -> str:
    raw = bytes(b).split(b"\x00", 1)[0]
    return raw.decode("utf-8", errors="replace").strip()


def _u16(b: bytes) -> Optional[int]:
    return struct.unpack_from("<H", b)[0] if len(b) >= 2 else None


FUNCTION_CODES = {1: "ImportImage", 3: "InCameraViewing", 4: "RemoteShooting", 5: "UpdateFirmware"}  # FBS:47-50
SHUTTER_CODES = {0: "release", 1: "command prefix", 2: "press", 3: "half-press (focus)"}  # LFB:107-110
TRANSACTION_STATES = {  # DOC §3.6-3.7 (+ FBK:10-12,56-90; LFB:43). u16 state, then u16 seq.
    0: "error",
    1: "started (backup: first chunk ready; restore: send the first frame)",
    2: "sending (backup: next chunk ready; restore: frame accepted, send the next)",
    3: "file received (file complete)",
    4: "file processed",
    5: "finished (camera ended the transfer; libfuji saw it when idle)",
}


def decode_value(decoder: str, value: bytes) -> str:
    """Human-readable decoding. Never raises: unknown or short values fall back to hex."""
    v = bytes(value)
    try:
        if decoder == "utf8":
            return repr(_utf8z(v))
        if decoder == "text":
            s = _utf8z(v)
            return repr(s) if s and all(32 <= ord(ch) < 127 for ch in s) else hexs(v)
        if decoder == "u16":
            return str(_u16(v)) if len(v) >= 2 else hexs(v)
        if decoder == "u32":
            return str(struct.unpack_from("<I", v)[0]) if len(v) >= 4 else hexs(v)
        if decoder == "u16_seconds":
            return f"{_u16(v)} s" if len(v) >= 2 else hexs(v)
        if decoder == "secure_status":
            if len(v) != 4:
                return f"{hexs(v)} (expected 4 bytes)"
            acked = "acked (byte 3 = 0x20)" if v[3] == 0x20 else "not yet acked"
            return f"{hexs(v)} ({acked})"
        if decoder == "ap_state":
            n = _u16(v)
            if n is not None and n in AP_STATES:  # 0x8000.. (bytes 00 80 / 01 80 / 02 80 / 03 80), DOC §3.8
                return f"{n:#06x} {AP_STATES[n]}"
            return {0: "00 busy", 1: "01 access point up"}.get(v[0], hexs(v)) if v else hexs(v)
        if decoder == "backup_state":
            return {0: "0 busy", 1: "1 ready to transfer"}.get(v[0], hexs(v)) if v else hexs(v)
        if decoder == "not1":
            return f"{hexs(v)}" + (" (furble: 'configured')" if v[:2] == b"\x02\x00" else "")
        if decoder == "geotag_request":
            return f"{hexs(v)}" + (" (camera asks for a location)" if v[:2] == b"\x01\x00" else "")
        if decoder == "function_launch":
            n = _u16(v)
            return f"{n} {FUNCTION_CODES.get(n, '?')}" if n is not None else hexs(v)
        if decoder == "shutter":
            n = _u16(v)
            return f"{n} {SHUTTER_CODES.get(n, '?')}" if n is not None else hexs(v)
        if decoder == "transaction_state":
            st = parse_transaction_state(v)
            return f"state {st.state} ({TRANSACTION_STATES.get(st.state, 'unknown')}), aux {st.aux_hex}"
        if decoder == "file_information":
            name, size = parse_file_information(v)
            return f"name={name!r} size={size}"
        if decoder == "file_partial_data":
            ch = parse_partial_data(v)
            return f"seq={ch.seq:#06x} len={ch.length}{' LAST' if ch.last else ''} data={hexs(ch.payload, 16)}"
        if decoder == "time":
            if len(v) >= 7:
                y, mo, d, h, mi, s = struct.unpack_from("<HBBBBB", v)
                return f"{y:04d}-{mo:02d}-{d:02d} {h:02d}:{mi:02d}:{s:02d}"
    except Exception as exc:  # decoding must never break a dump
        return f"{hexs(v)} (decode error: {exc})"
    return hexs(v)


def decode_char(uuid: str, value: bytes, *, reveal_secrets: bool = False) -> str:
    info = char_info(uuid)
    if info is None:
        s = _utf8z(value)
        if len(s) >= 3 and all(32 <= ord(ch) < 127 for ch in s):
            return f"{hexs(value, 32)} ({s!r}?)"
        return hexs(value, 32)
    if info.secret and not reveal_secrets:
        return f"<{len(value)} bytes, redacted; pass --include-secrets to show>"
    return decode_value(info.decoder, value)


# --------------------------------------------------------------------------------------------
# File-service framing (settings backup)
# --------------------------------------------------------------------------------------------

#: 120-byte pieces (fuji-bridge FujiBackup.swift:9,47).
BACKUP_PARTIAL_SIZE = 120
#: FILE_PARTIAL_DATA max value length in ad14d4 (gatt-ad14d4.yaml:392 `l: 0xf8`) minus the 6-byte header.
MAX_CHUNK_PAYLOAD = 0xF8 - 6
LAST_SEQ = 0xFFFF
BACKUP_REQUEST_SETTINGS = u16le(1)  # FBK:7,43
TRANSFER_RESULT_OK = u16le(3)  # FBK:13,86
TRANSFER_RESULT_ERROR = u16le(0)  # FBK:13,75,94


class FramingError(ValueError):
    pass


@dataclass
class Chunk:
    seq: int
    length: int
    payload: bytes

    @property
    def last(self) -> bool:
        return self.seq == LAST_SEQ


def parse_partial_data(chunk: bytes) -> Chunk:
    """FILE_PARTIAL_DATA: u16 seq, u32 len, len bytes (fuji-bridge FujiBackup.swift:99-107)."""
    b = bytes(chunk)
    if len(b) < 6:
        raise FramingError(f"chunk shorter than its 6-byte header: {hexs(b)}")
    seq, length = struct.unpack_from("<HI", b)
    if 6 + length > len(b):
        raise FramingError(f"chunk says len={length} but only {len(b) - 6} data bytes arrived (seq {seq:#06x})")
    return Chunk(seq, length, b[6 : 6 + length])


def build_partial_data(seq: int, payload: bytes) -> bytes:
    return struct.pack("<HI", seq & 0xFFFF, len(payload)) + bytes(payload)


def byte_sum16(data: bytes) -> int:
    """u16 sum of all data bytes, as in the last chunk's trailer (FujiBackup.swift:10-11,62-67)."""
    return sum(data) & 0xFFFF


@dataclass
class TransactionState:
    state: int
    aux: bytes

    @property
    def aux_hex(self) -> str:
        return hexs(self.aux) if self.aux else "-"


def parse_transaction_state(value: bytes) -> TransactionState:
    """FILE_TRANSACTION_STATE notify: u16 state (FujiBackup.swift:53-56); the remaining 2 bytes are logged as `aux`
    (fuji-bridge's fake sends the chunk index there, Tests/RecipeBackupTests.swift:21; libfuji saw 'ff ff')."""
    v = bytes(value)
    if len(v) < 2:
        raise FramingError(f"transaction state shorter than 2 bytes: {hexs(v)}")
    return TransactionState(struct.unpack_from("<H", v)[0], v[2:])


def parse_file_information(value: bytes) -> tuple[str, int]:
    """FILE_INFORMATION: char name[40], u32 size (libfuji bluetooth.c:32-38, FujiBackup.swift:79-85)."""
    v = bytes(value)
    if len(v) < 44:
        raise FramingError(f"file information shorter than 44 bytes: {hexs(v)}")
    name = v[:40].split(b"\x00", 1)[0].decode("utf-8", errors="replace")
    (size,) = struct.unpack_from("<I", v, 40)
    return name, size


def build_file_information(name: str, size: int) -> bytes:
    raw = name.encode("utf-8")[:39]
    return raw + b"\x00" * (40 - len(raw)) + u32le(size)


class BackupAssembler:
    """Reassembles FILE_PARTIAL_DATA chunks exactly as fuji-bridge FujiBackup.run does (FujiBackup.swift:58-92),
    and additionally records the sequence numbers, so a run shows how the camera numbers them."""

    def __init__(self) -> None:
        self.data = bytearray()
        self.sum = 0
        self.expected_sum: Optional[int] = None
        self.seqs: list[int] = []
        self.finished_chunk = False

    def add(self, raw: bytes) -> Chunk:
        ch = parse_partial_data(raw)
        self.seqs.append(ch.seq)
        if ch.last:
            body, tail = ch.payload[:-2], ch.payload[-2:]
            self.data += body
            self.sum += sum(body)
            if len(tail) == 2:
                self.expected_sum = tail[0] | tail[1] << 8
            self.finished_chunk = True
        else:
            self.data += ch.payload
            self.sum += sum(ch.payload)
        return ch

    @property
    def sum16(self) -> int:
        return self.sum & 0xFFFF

    def checksum_ok(self) -> Optional[bool]:
        if self.expected_sum is None:
            return None
        return self.expected_sum == self.sum16

    def seq_report(self) -> str:
        """Plain-English summary of the seq numbers seen (gaps, ordering)."""
        if not self.seqs:
            return "no chunks"
        body = [s for s in self.seqs if s != LAST_SEQ]
        notes = [f"{len(self.seqs)} chunks"]
        if body:
            notes.append(f"seq {body[0]}..{body[-1]}")
            expected = list(range(body[0], body[0] + len(body)))
            if body != expected:
                gaps = sum(1 for a, b in zip(body, body[1:]) if b != a + 1)
                notes.append(f"NOT consecutive ({gaps} jumps)")
            else:
                notes.append("consecutive")
        notes.append("ended with 0xFFFF" if self.seqs[-1] == LAST_SEQ else "NO 0xFFFF terminator seen")
        return ", ".join(notes)


def plan_upload_frames(data: bytes, chunk_size: int = BACKUP_PARTIAL_SIZE) -> list[bytes]:
    """INFERRED (restore): mirror the download framing. Data split into `chunk_size` pieces, seq 0,1,2,...;
    the final frame has seq 0xFFFF and carries the last data bytes plus the u16 sum of every data byte.
    Superseded by restore_frames (DOC §3.7); kept for the capture-derived profile engine."""
    if not 1 <= chunk_size <= MAX_CHUNK_PAYLOAD:
        raise ValueError(f"chunk size must be 1..{MAX_CHUNK_PAYLOAD}")
    total = byte_sum16(data)
    frames: list[bytes] = []
    # The last frame carries data + 2 checksum bytes, so keep its data part <= chunk_size - 2.
    pieces: list[bytes] = []
    i = 0
    while i < len(data):
        pieces.append(bytes(data[i : i + chunk_size]))
        i += chunk_size
    if not pieces:
        pieces = [b""]
    if len(pieces[-1]) > chunk_size - 2:
        last = pieces.pop()
        pieces.append(last[: chunk_size - 2])
        pieces.append(last[chunk_size - 2 :])
    for n, piece in enumerate(pieces):
        if n == len(pieces) - 1:
            frames.append(build_partial_data(LAST_SEQ, piece + u16le(total)))
        else:
            frames.append(build_partial_data(n, piece))
    return frames


# --------------------------------------------------------------------------------------------
# Settings-file header sniff (just enough for a sanity line and the restore same-body guard;
# the real decoder is backupfile.py, written separately)
# --------------------------------------------------------------------------------------------

BACKUP_MAGIC = b"FUJIFILMX-BACKUP"


def sniff_backup_header(data: bytes) -> dict:
    """Header per helios nix/pkgs/helios/FUJI_BLOB_FORMAT.md:48-66 (magic @0, version @0x10, model @0x14,
    serial @0x34, payload start u32 @0x98, payload length u32 @0xA0). Checked against the real X-H1 and
    GFX100S files in vcam/bin/fuji/backups/."""
    d = bytes(data)
    out: dict = {"magic_ok": d[:16] == BACKUP_MAGIC, "size": len(d)}
    if not out["magic_ok"] or len(d) < 0xA8:
        return out
    out["version"] = d[0x10:0x14].decode("ascii", errors="replace")
    out["model"] = d[0x14:0x34].split(b"\x00", 1)[0].decode("ascii", errors="replace")
    out["serial"] = d[0x34:0x54].split(b"\x00", 1)[0].decode("ascii", errors="replace")
    payload_start, payload_len = struct.unpack_from("<I", d, 0x98)[0], struct.unpack_from("<I", d, 0xA0)[0]
    out["payload_start"] = payload_start
    out["payload_len"] = payload_len
    out["length_consistent"] = payload_start + payload_len == len(d)
    return out


def first_difference(a: bytes, b: bytes) -> Optional[dict]:
    """Where two backups differ (for the determinism check)."""
    if a == b:
        return None
    n = min(len(a), len(b))
    diffs = [i for i in range(n) if a[i] != b[i]]
    first = diffs[0] if diffs else n
    return {
        "first_offset": first,
        "first_offset_hex": f"{first:#06x}",
        "differing_bytes": len(diffs) + abs(len(a) - len(b)),
        "sizes": [len(a), len(b)],
        "offsets_hex": [f"{i:#06x}" for i in diffs[:64]],
    }




# --------------------------------------------------------------------------------------------
# Restore, registration, Wi-Fi launch and location/time encodings (docs/FUJIFILM-PROTOCOL.md §3.4-3.8).
# Pure functions; the flows live in client.py. Values were confirmed against our own camera where the doc says so.
# --------------------------------------------------------------------------------------------

#: Transfer progress (u16 state + u16 seq on FILE_TRANSACTION_STATE).
TS_ERROR, TS_START, TS_TRANSFERRING, TS_FILE_DONE, TS_FILE_PROCESS_DONE, TS_FINISHED = 0, 1, 2, 3, 4, 5
TRANSACTION_STATE_NAMES = {
    TS_ERROR: "error", TS_START: "started", TS_TRANSFERRING: "sending", TS_FILE_DONE: "file received",
    TS_FILE_PROCESS_DONE: "file processed", TS_FINISHED: "finished",
}
#: What the client writes to FILE_TRANSFER_RESULT (u16 LE): 0 fail, 1 success, 2 cancel, 3 end.
RESULT_FAIL, RESULT_SUCCESS, RESULT_CANCEL, RESULT_END = u16le(0), u16le(1), u16le(2), u16le(3)
#: u16 LE on RESTORE_REQUEST / BACKUP_REQUEST: 1 settings, 2 IPTC.
RESTORE_REQUEST_SETTINGS = u16le(1)
#: RESTORE_STATE / BACKUP_STATE: 1 ready to transfer, 0 busy.
STATE_TRANSFERABLE = 1
#: The FILE_INFORMATION name sent for a settings restore.
RESTORE_FILE_NAME = "backup.dat"
#: FILE_PARTIAL_SIZE, both directions.
RESTORE_CHUNK = 120
#: Timeouts (seconds): per write; for RESTORE_STATE and for every FILE_TRANSACTION_STATE during a restore; per state
#: during a backup. The MTU we ask for.
WRITE_TIMEOUT = 5.0
RESTORE_STATE_TIMEOUT = 10.0
RESTORE_ACK_TIMEOUT = 10.0
BACKUP_STATE_TIMEOUT = 20.0
PREFERRED_MTU = 185
#: A full restore frame is 6 + 120 + 2 = 128 bytes, so the ATT MTU must be at least 131.
RESTORE_MIN_MTU = 6 + RESTORE_CHUNK + 2 + 2 + 3
#: OR-ed into a secure body's identification number before it is written back (DOC §3.5).
CLIENT_ID_FLAG = 0x20000000
#: AP state (u16 LE on AP_STATE).
AP_STATES = {0x8000: "not started", 0x8001: "up", 0x8002: "starting", 0x8003: "up (queued transfer)"}
AP_LAUNCHED = 0x8001
#: u16 LE on FUNCTION_LAUNCH_REQUEST (fuji-bridge FujiBluetooth.swift:47-50).
FUNCTION_IMPORT, FUNCTION_VIEWING, FUNCTION_REMOTE, FUNCTION_FIRMWARE = 1, 3, 4, 5
#: u16 LE on LOCATION_SYNC_SETTING.
LOCATION_SYNC_OFF, LOCATION_SYNC_ON = 0, 1
#: Characteristics no Dial In flow may write. 8b5ecf55 identifies the connecting app on newer bodies; Dial In never
#: presents as another app, so Session.write refuses it.
NEVER_WRITE = frozenset({APP_IDENTITY_CHAR})


def encode_client_name(name: str, max_len: int = 0x1E) -> bytes:
    """The client name (85b9163e): UTF-8 plus one NUL (DOC §3.4 step 5). Trimmed on a character boundary to fit
    max_len with the NUL."""
    raw = name.encode("utf-8")
    while len(raw) + 1 > max_len:
        name = name[:-1]
        raw = name.encode("utf-8")
    return raw + b"\x00"


def client_id_number(read_value: bytes, stored: Optional[int] = None) -> int:
    """Secure bodies (DOC §3.5): the client's id is the u32 read from CLIENT_ID_NUMBER with CLIENT_ID_FLAG OR-ed in,
    unless one was saved at pairing (then that is reused). It goes back as u32 LE. 07 96 00 00 -> 07 96 00 20, the same
    bytes as the "byte 3 = 0x20" rule in fuji-bridge and furble."""
    if stored:
        return stored & 0xFFFFFFFF
    if len(read_value) != 4:
        raise ValueError(f"identification number must be 4 bytes, got {len(read_value)}: {hexs(read_value)}")
    return struct.unpack("<I", bytes(read_value))[0] | CLIENT_ID_FLAG


def build_restore_file_information(size: int, name: str = RESTORE_FILE_NAME) -> bytes:
    """FILE_INFORMATION for a restore (DOC §3.7): 44 bytes, UTF-8 name at 0 (zero padded), u32 LE size at 40."""
    raw = name.encode("utf-8")[:40]
    return raw + bytes(40 - len(raw)) + u32le(size)


def restore_frames(data: bytes, chunk: int = RESTORE_CHUNK) -> list[bytes]:
    """Restore frames as the camera accepts them (DOC §3.7):
        u16 seq | u32 size | data | u16 checksum
    * frames i = 0 .. ceil(len/chunk)-1; seq = i, except the last frame, whose seq is 0xFFFF (LAST_SEQ)
    * data = the next min(chunk, remaining) file bytes; on the last frame the u16 sum of EVERY file byte is appended
      inside the data, and size counts it (so the last frame's size is up to chunk + 2)
    * the trailing u16 checksum field is 0 on every frame except the last, where it repeats the sum
    So a full frame is 128 bytes (6 + 120 + 2), and the sum appears twice at the very end of the upload."""
    if chunk < 1:
        raise ValueError("chunk must be >= 1")
    d = bytes(data)
    count = -(-len(d) // chunk)
    total = byte_sum16(d)
    frames = []
    for i in range(count):
        piece = d[i * chunk : (i + 1) * chunk]
        if i == count - 1:
            body = piece + u16le(total)
            frames.append(struct.pack("<HI", LAST_SEQ, len(body)) + body + u16le(total))
        else:
            frames.append(struct.pack("<HI", i, len(piece)) + piece + u16le(0))
    return frames


@dataclass
class RestoreFrame:
    seq: int
    size: int
    data: bytes  # size bytes (the last frame's include the in-data sum)
    trailer: int

    @property
    def last(self) -> bool:
        return self.seq == LAST_SEQ

    @property
    def file_bytes(self) -> bytes:
        return self.data[:-2] if self.last else self.data


def parse_restore_frame(frame: bytes) -> RestoreFrame:
    """Inverse of one restore_frames() frame (used by the simulator and tests)."""
    b = bytes(frame)
    if len(b) < 8:
        raise FramingError(f"restore frame shorter than 8 bytes: {hexs(b)}")
    seq, size = struct.unpack_from("<HI", b)
    if len(b) != 6 + size + 2:
        raise FramingError(f"restore frame seq {seq:#06x} says size {size} but is {len(b)} bytes (want {6 + size + 2})")
    data = b[6 : 6 + size]
    trailer = struct.unpack_from("<H", b, 6 + size)[0]
    if seq == LAST_SEQ and size < 2:
        raise FramingError("last restore frame has no room for its sum")
    return RestoreFrame(seq, size, data, trailer)


def decode_ap_state(value: bytes) -> str:
    n = _u16(bytes(value))
    if n is None:
        return hexs(value)
    return f"{n:#06x} {AP_STATES.get(n, 'unknown')}"


def encode_location(lat: float, lon: float, *, alt_m: float = 0.0, speed_mps: float = 0.0, when_utc=None) -> bytes:
    """LOCATION_FIX (23 bytes, DOC §3.3):
    i32 round(lat*1e7), i32 round(lon*1e7), i32 round(altitude m), i32 round(speed m/s * 100),
    u16 year, u8 month, day, hour, minute, second of the fix time in UTC. All little-endian."""
    import datetime as _dt

    t = when_utc or _dt.datetime.now(_dt.timezone.utc)
    if t.tzinfo is not None:
        t = t.astimezone(_dt.timezone.utc)
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise ValueError(f"bad coordinates {lat}, {lon}")
    return struct.pack("<iiiiHBBBBB", round(lat * 1e7), round(lon * 1e7), round(alt_m), round(speed_mps * 100),
                       t.year, t.month, t.day, t.hour, t.minute, t.second)


def decode_location(value: bytes) -> dict:
    lat, lon, alt, spd, y, mo, d, h, mi, s = struct.unpack("<iiiiHBBBBB", bytes(value)[:23])
    return {"lat": lat / 1e7, "lon": lon / 1e7, "alt_m": alt, "speed_mps": spd / 100,
            "utc": f"{y:04d}-{mo:02d}-{d:02d}T{h:02d}:{mi:02d}:{s:02d}Z"}


def encode_date_time(local=None) -> bytes:
    """TIME (7 bytes): u16 year, u8 month, day, hour, minute, second, LOCAL time."""
    import datetime as _dt

    t = local or _dt.datetime.now()
    return struct.pack("<HBBBBB", t.year, t.month, t.day, t.hour, t.minute, t.second)


def timezone_offset_code(offset_seconds: int) -> int:
    """The zone field of UTC_TIME_AND_ZONE: the raw offset as hours*100, with :15/:30/:45 minutes as 25/50/75
    (sign follows the hours; hours truncate toward zero). +5:30 -> 550, -3:30 -> -350, -5:00 -> -500."""
    hours = int(offset_seconds / 3600)  # truncates toward zero
    minutes = abs(offset_seconds - hours * 3600) // 60
    sign = -1 if hours < 0 else 1  # the sign comes from the hours alone (so -0:30 encodes as +50)
    frac = {15: 25, 30: 50, 45: 75}.get(minutes, 0)
    return hours * 100 + sign * frac


def encode_utc_time_and_zone(utc=None, offset_seconds: int = 0, dst: bool = False) -> bytes:
    """UTC_TIME_AND_ZONE (12 bytes, used instead of TIME when the body has it): u16 year, u8 month, day, hour,
    minute, second in UTC, i32 LE timezone_offset_code(raw offset), u8 1 if daylight saving is in effect."""
    import datetime as _dt

    t = utc or _dt.datetime.now(_dt.timezone.utc)
    if t.tzinfo is not None:
        t = t.astimezone(_dt.timezone.utc)
    return struct.pack("<HBBBBBiB", t.year, t.month, t.day, t.hour, t.minute, t.second,
                       timezone_offset_code(offset_seconds), 1 if dst else 0)


def split_basic_name(name: str) -> tuple[str, str]:
    """A basic body's advertised name is the 4-character short serial followed by the
    model name (fffw db-paired.json: '08C6X-T5-08C6'). Returns (short_serial, rest)."""
    return (name[:4], name[4:]) if len(name) > 4 else (name, "")
