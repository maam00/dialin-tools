# FUJIFILM X100VI protocol reference: custom slots, settings backup, Bluetooth and Wi-Fi

A developer reference for how a FUJIFILM X100VI exposes its custom-setting slots (C1–C7) over USB PTP, how its
Bluetooth LE service backs up, restores and launches Wi-Fi, and how its Wi-Fi PTP/IP gallery session behaves. It is
written for people working on open camera tooling (libgphoto2, libfuji, FilmKit, fuji-bridge, fujifilm-ptp-recipes,
furble, fffw and similar). Corrections and counter-observations are welcome, especially from other bodies and firmware.

**Hardware evidence through 2026-10-16.** Hardware observations come from **one X100VI on firmware 1.10** (the older "basic" Bluetooth
profile). Everything else is labelled with its actual evidence. Nothing here is endorsed by or affiliated with
FUJIFILM Corporation. FUJIFILM, X100VI and related names are FUJIFILM's trademarks.

For supported user routes, see [What works today](CAPABILITIES.md). A protocol observation is not automatically a production capability.

## Contents

- [Provenance](#provenance)
- [Evidence levels](#evidence-levels)
- [Conventions and safety](#conventions-and-safety)
- [1. Transports overview](#1-transports-overview)
- [2. USB PTP](#2-usb-ptp)
- [3. Bluetooth LE](#3-bluetooth-le)
- [4. The settings file (FUJIFILMX-BACKUP)](#4-the-settings-file-fujifilmx-backup)
- [5. Wi-Fi PTP/IP gallery session](#5-wi-fi-ptpip-gallery-session)
- [6. More than one body](#6-more-than-one-body)
- [7. What is not known](#7-what-is-not-known)
- [8. Sources](#8-sources)
- [Appendix A. Response codes seen or relied on](#appendix-a-response-codes-seen-or-relied-on)

## Provenance

The protocol details here come from interoperability work:

- observing traffic and file contents on our own camera (USB transactions, Bluetooth transfers, Wi-Fi sessions and the
  settings files they produced);
- controlled hardware tests on that camera, each recorded with its date;
- published open-source projects, credited inline with their licenses (section 8);
- study of FUJIFILM's own apps, to understand how they interoperate with the camera.

No FUJIFILM code, binaries, firmware or decompiled source are included. Behavior and wire formats are described in our
own words and tables. Camera identifiers (serial numbers, pairing keys, MAC addresses, network names) are replaced by
placeholders such as `FUJIFILM-X100VI-XXXX`.

## Evidence levels

Every claim carries one of these labels. A claim is never stated more strongly than its label allows.

| Label | Meaning |
|---|---|
| `VERIFIED-HW <date>` | Observed on a physical X100VI running firmware 1.10, on that date. One body, one firmware. |
| `CODE` | Implemented in this repository and exercised against fakes, simulators or recorded data. Not observed on hardware in the form stated. |
| `CITED <source> (<license>)` | From a named published source: an open-source project (license given) or FUJIFILM's public documentation. Their hardware and firmware, not ours, unless a `VERIFIED-HW` label is also given. |
| `HYPOTHESIS` | An inference, or a behavior seen only in study of FUJIFILM's app that we have neither implemented nor observed. Treat as unproven. |

When a row carries two labels, each applies to the part it names.

## Conventions and safety

- Integers are little-endian unless stated. Offsets are hexadecimal. Ranges are half-open: `[0xF71E, 0xF72A)`.
- "Slot" means a custom setting C1–C7. "Anchor" means the start of a slot's record in the settings file.
- PTP property codes are 16-bit hex without `0x` in tables (`D18C`). Bluetooth UUIDs are 128-bit; tables show the
  first 8 hex digits and section 3.3 gives the full form.
- Writing settings can leave a camera in a state you can only fix from its menus. Before any write: take a fresh
  backup, keep it outside your source tree, never upload a file taken from another body, and read back afterwards.
  One modified Bluetooth upload passed an experimental current-session trial on this X100VI; its power-cycle check
  was not performed. Production modified-settings writes remain blocked (section 3.7).

---

## 1. Transports overview

| Transport | What it carries on an X100VI | Reaches C1–C7? | Evidence |
|---|---|---|---|
| USB PTP, CONNECTION MODE = **USB RAW CONV./BACKUP RESTORE** | Per-slot properties (C1–C7), live "current look" properties, whole settings-file download, in-camera RAW conversion | Yes, property by property | `VERIFIED-HW 2026-10-09`, `VERIFIED-HW 2026-10-15` |
| USB PTP, same mode, settings-file upload | Whole-file restore (`SendObjectInfo` + `SendObject`) | Yes, whole file only | `CITED helios (MIT)` on an X-T5; `CODE`; not tested on an X100VI |
| USB, other modes | USB CARD READER, USB WEBCAM. The X100VI has no USB tether-shooting mode | No | `CITED FUJIFILM X100VI owner's manual` |
| Bluetooth LE | Registration, Wi-Fi launch, settings backup (download), settings restore (upload, whole file), time, location, shutter | Only by restoring an edited whole file | Backup and unchanged upload `VERIFIED-HW 2026-10-13`; one experimental C7 modification `VERIFIED-HW 2026-10-16`, restart unchecked; production writes blocked |
| Wi-Fi PTP/IP, camera as access point | Image browsing and import; remote shooting and live view | No property path known | Gallery session `VERIFIED-HW 2026-10-15`; seven full-size JPEG downloads `VERIFIED-HW 2026-10-16`; remote mode `CITED libfuji (MIT)` |
| Wireless tether, PC AutoSave | Camera joins a LAN; AutoSave reportedly removed from 2022 firmware | Untested | `CITED libfuji (MIT)` |

What no transport is known to do on the X100VI:

- write a single setting over Bluetooth (`HYPOTHESIS`: no characteristic for it exists in the observed GATT table);
- set ISO, shutter, aperture or exposure compensation over USB. These are not stored in slots, and remote exposure
  needs a tether mode the X100VI lacks (`CITED FUJIFILM X100VI owner's manual`; `CITED fujifilm-ptp-recipes (CC BY 4.0
  docs)` for "not in the slot block").

---

## 2. USB PTP

### 2.1 Device and session

| Fact | Detail | Evidence |
|---|---|---|
| USB IDs | VID `0x04CB`, PID `0x0305` | `VERIFIED-HW 2026-10-13` (host USB inventory); `CITED libgphoto2 (LGPL-2.1)` |
| Interface | Interface 0, one bulk OUT and one bulk IN endpoint (plus an optional interrupt endpoint, unused here) | `CODE`; claiming interface 0 `VERIFIED-HW 2026-10-15` |
| Container | ISO 15740 bulk container: `u32 length, u16 type (1 command, 2 data, 3 response, 4 event), u16 code, u32 transaction id, then up to five u32 params or the payload` | `VERIFIED-HW 2026-10-15` (every session uses it) |
| Open | `OpenSession(1)` sent with transaction id 0 | `CODE`; `VERIFIED-HW 2026-10-15` |
| Stale session | On `0x201E` SessionAlreadyOpen: `CloseSession`, reset the transaction counter to 0, `OpenSession(1)` again. On an X-T5 a retry with a non-zero id answers `0x2006` | `CODE`; `CITED fuji-cli (MIT)` for the X-T5 |
| Identity | `GetDeviceInfo` reports model `X100VI`, device version `1.10` and a serial string; `PropertiesSupported` includes `D18C` in this mode | `VERIFIED-HW 2026-10-15` |
| Mode property | `D16E` reads `6` in USB RAW CONV./BACKUP RESTORE | `VERIFIED-HW 2026-10-13` |
| Mode encoding | `D16E` values 5 (tether), 6 (RAW conversion + backup/restore), 8 (webcam) | `CITED libfuji (MIT)`. Reading it as a bitmask (1 tether, 2 RAW conversion, 4 backup/restore, 8 webcam) is `HYPOTHESIS` |
| No card | Object listing in this mode returned zero objects; the card is not exposed | `VERIFIED-HW 2026-10-13`; `CITED fuji-cli (MIT)` (X-T5: two virtual stores only) |
| Descriptors | `GetDevicePropDesc` answers `0x2002` with no data for every property in this mode on X-T5 and X-H2 | `CITED fuji-cli (MIT)`; untested on the X100VI. Our code never relies on descriptors (`CODE`) |
| Camera controls | Locked while USB is connected in this mode; menu use can drop the connection | `CITED grawji (GPL-3.0)`; `HYPOTHESIS` on the X100VI |
| Transfer sizing | 512 KiB bulk chunks, 5 s per transfer | `CODE` (`lib/fuji/usb.ts`) |
| Apple ImageCaptureCore | An alternative to raw USB on macOS and iOS: send vendor commands through the camera device object after control authorization. iOS refuses properties the camera did not advertise with `0x200A` | `CITED fuji-bridge (MIT)`; `CITED Junsudo/fuji-ptp-notes (no license stated)` |

### 2.2 macOS: the `ptpcamerad` claim

On macOS the system camera daemon `ptpcamerad` opens any PTP camera as soon as it appears and holds it exclusively.

| # | Observation (macOS 27.0.1, X100VI fw 1.10) | Evidence |
|---|---|---|
| 1 | Claiming interface 0 fails with `0xe00002c5` (IOKit exclusive access) while the daemon holds the device | `VERIFIED-HW 2026-10-15` |
| 2 | `killall ptpcamerad` exits 0, but the daemon keeps its process id and the claim still fails | `VERIFIED-HW 2026-10-15` |
| 3 | Sending SIGKILL to the current user's process named exactly `ptpcamerad` frees the device; the claim then succeeds | `VERIFIED-HW 2026-10-15` |
| 4 | launchd restarts the daemon, and it takes the camera again before the next program opens it. The release has to be repeated for every command | `VERIFIED-HW 2026-10-15` |
| 5 | When killed, the daemon can leave a PTP session open (next `OpenSession` gets `0x201E`); killing it also disconnects FUJIFILM's desktop RAW software | `CITED fuji-cli (MIT)` (X-T5) |
| 6 | Killing it interrupts any import Photos or Image Capture had in progress | `HYPOTHESIS` |

Our policy (`CODE`, `lib/fuji/claim.ts`):

- Never stop the daemon implicitly. The user opts in per command (`--release-macos-camera-daemon`).
- Try the claim once. Only after an exclusive-access refusal, and only on macOS: find the current user's
  `ptpcamerad` by exact name (`pgrep -x -U <uid> ptpcamerad`), SIGKILL it, wait 200 ms, retry the claim. Up to 5 tries.
- Otherwise fail with instructions (quit Photos and Image Capture; the kill command; the opt-in flag).
- Re-run with the opt-in on 2026-10-15: claim succeeded and slot writes verified (`VERIFIED-HW 2026-10-15`).

Linux: detach the kernel driver from interface 0 before claiming (`CODE`; no Linux host tested). Windows: untested.

### 2.3 Custom slot properties (C1–C7)

Slots are ordinary device properties, read with `GetDevicePropValue` (`0x1015`) and written with
`SetDevicePropValue` (`0x1016`). There is no vendor opcode. `D18C` chooses which slot the block `D18D`…`D1A4` refers
to. All values are 2 bytes except the name (`CITED FilmKit (MIT)`, `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)`).
Seven looks written into C1–C7 this way and read back clean: `VERIFIED-HW 2026-10-09`.

"×10" means the menu step times ten: Highlight +1.5 is sent as `15`.

| Code | Field | Type | Wire values | Our writer | Evidence |
|---|---|---|---|---|---|
| `D18C` | Edit cursor (slot select) | u16 | 1–7 | Written first, 100 ms settle, then read back; must equal the target before anything else is written | Select and read-back `VERIFIED-HW 2026-10-15`; settle time `CODE`, 100 ms as in `CITED FilmKit (MIT)` |
| `D18D` | Slot name | PTP string | u8 character count (including the terminating NUL), then UTF-16LE characters | Written right after the select; we cap names at 14 printable ASCII characters | Read back exact `VERIFIED-HW 2026-10-15`; 25-character names on fw 1.32 `CITED ctl0v0/omarchy-fujifilm-recipes (MIT)` |
| `D18E` | Image size | u16 | `7` = L 3:2 | Never written | Reads `7` on all seven slots `VERIFIED-HW 2026-10-09`; value table `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)` |
| `D18F` | Image quality | u16 | `4` RAW+FINE, `5` RAW+NORMAL | Never written | Both values `VERIFIED-HW 2026-10-13`; other values `HYPOTHESIS` |
| `D190` | Dynamic range | u16 | `100`, `200`, `400` | Written only after `D191` = 0 | `VERIFIED-HW 2026-10-09`. DR Auto reads `0xFFFF` on fw 1.32 `CITED ctl0v0 (MIT)`; writing Auto: unknown |
| `D191` | D-Range Priority | u16 | `0` Off, `1` Weak, `2` Strong, `0x8000` Auto | **Always written 0** | `0` `VERIFIED-HW 2026-10-15`; other values `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)` |
| `D192` | Film simulation | u16 | 1–20 (section 2.4) | First look property written | All 20 codes written and read back: 7 on `VERIFIED-HW 2026-10-09` (C1–C7), the other 13 on `VERIFIED-HW 2026-10-13` (each to C7, with Reala Ace and Acros+R as controls) |
| `D193` | Monochrome warm/cool | i16 | ×10, −180…+180, multiples of 10 | Not written | `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)` (X-H2) |
| `D194` | Monochrome magenta/green | i16 | as `D193` | Not written | as above |
| `D195` | Grain | u16 | Write: `1` Off, `2` Weak-Small, `3` Strong-Small, `4` Weak-Large, `5` Strong-Large. Read: also `6` Off-Small, `7` Off-Large | Writes `1` for Off; accepts 1, 6 or 7 on read-back | Wrote `1`, read `7` `VERIFIED-HW 2026-10-15`; `6` `CITED libgphoto2 (LGPL-2.1)` |
| `D196` | Color Chrome | u16 | `1` Off, `2` Weak, `3` Strong | Colour simulations only | `VERIFIED-HW 2026-10-09` |
| `D197` | Color Chrome FX Blue | u16 | `1`/`2`/`3` | Colour simulations only | `VERIFIED-HW 2026-10-09` |
| `D198` | Smooth Skin | u16 | `1` Off, `2` Weak, `3` Strong | **Always written 1 (Off)** | `1` `VERIFIED-HW 2026-10-15`; `2`/`3` `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)` |
| `D199` | White balance | u16 | `0x0002` Auto, `0x0004` Daylight, `0x8007` Kelvin; others in section 2.4 | Written | These three `VERIFIED-HW 2026-10-09`; others `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)` |
| `D19A` | WB shift red | i16 | −9…+9, **1:1, not ×10** | Colour simulations only | `VERIFIED-HW 2026-10-09` |
| `D19B` | WB shift blue | i16 | −9…+9 | Colour simulations only | `VERIFIED-HW 2026-10-09` |
| `D19C` | Colour temperature | u16 | Kelvin, 2500–10000 | Only when `D199` = `0x8007`, written immediately after it | 4350, 5200, 6300 `VERIFIED-HW 2026-10-09`; step-10 range `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)` |
| `D19D` | Highlight | i16 | ×10, −20…+40 in steps of 5 | Only with `D191` = 0 | Half steps included `VERIFIED-HW 2026-10-09` |
| `D19E` | Shadow | i16 | as `D19D` | Only with `D191` = 0 | `VERIFIED-HW 2026-10-09` |
| `D19F` | Color | i16 | ×10, −40…+40 | Colour simulations only | `VERIFIED-HW 2026-10-09`; refused under Acros `VERIFIED-HW 2026-10-13` |
| `D1A0` | Sharpness | i16 | ×10, −40…+40 | Written | `VERIFIED-HW 2026-10-13` |
| `D1A1` | High ISO NR | u16 | −4 `0x8000`, −3 `0x7000`, −2 `0x4000`, −1 `0x3000`, 0 `0x2000`, +1 `0x1000`, +2 `0x0000`, +3 `0x6000`, +4 `0x5000` | Written | −4 `VERIFIED-HW 2026-10-09`; table `CITED FilmKit (MIT)`, `CITED libgphoto2 (LGPL-2.1)` |
| `D1A2` | Clarity | i16 | ×10, −50…+50 | Written | `VERIFIED-HW 2026-10-09` |
| `D1A3` | Lens Modulation Optimizer | u16 | `1` On observed elsewhere | Never written | `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)` |
| `D1A4` | Colour space | u16 | `1` sRGB | Never written | `CITED FilmKit (MIT)` |
| `D1A5` | **Not slot data.** The live (current) image size | u16 | composite | Never touched as part of a slot | `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)` |

**Cursor behavior.**

- `D18C` is an edit cursor, not the slot the camera shoots with. It stays where it was left across sessions
  (`CITED Junsudo/fuji-ptp-notes (no license stated)`, GFX100RF). Consistent with this, our X100VI read `D18C = 7`
  at the start of a session in which no software had selected a slot (`VERIFIED-HW 2026-10-13`).
- Whether moving the cursor changes the shooting slot on the X100VI: `HYPOTHESIS` that it does not.
- Reading the slot block without writing `D18C` returns whatever slot the cursor points at. That is not the camera's
  current shooting state (`CITED fujifilm-ptp-recipes (CC BY 4.0 docs)`, X-H2).
- An accepted `D18C` write alone does not prove which slot is selected. Our writer reads `D18C` back and refuses to
  continue on a mismatch (`CODE`).

### 2.4 Value tables

**Film simulation** (`D192` slot, `D001` live), identical in libgphoto2, FilmKit and fujifilm-ptp-recipes
(`CITED libgphoto2 (LGPL-2.1)`, `CITED FilmKit (MIT)`):

| Code | Simulation | Code | Simulation |
|---|---|---|---|
| 1 | Provia | 11 | Classic Chrome |
| 2 | Velvia | 12 | Acros |
| 3 | Astia | 13 | Acros+Ye |
| 4 | Pro Neg Hi | 14 | Acros+R |
| 5 | Pro Neg Std | 15 | Acros+G |
| 6 | Monochrome | 16 | Eterna |
| 7 | Monochrome+Ye | 17 | Classic Neg |
| 8 | Monochrome+R | 18 | Eterna Bleach Bypass |
| 9 | Monochrome+G | 19 | Nostalgic Neg |
| 10 | Sepia | 20 | Reala Ace |

- Monochrome set for gating: {6, 7, 8, 9, 10, 12, 13, 14, 15}, Sepia included (`CITED fujifilm-ptp-recipes (CC BY 4.0
  docs)`; `CODE`).
- Conflict: one fujifilm-ptp-recipes EXIF table maps Acros+R to 13, against its own property table. Our files store
  13 and 14 under distinct bytes (section 4.4), but the on-screen label for each has not been checked against the
  menu (`HYPOTHESIS` that 13 = Acros+Ye).

**White balance** (`D199` slot, `5005` live; `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)`, three values
`VERIFIED-HW 2026-10-09` as marked above): `0x0002` Auto, `0x8020` Auto White Priority, `0x8021` Auto Ambience
Priority, `0x0004` Daylight, `0x0006` Incandescent, `0x0008` Underwater, `0x8001`–`0x8003` Fluorescent 1–3, `0x8006`
Shade, `0x8007` Kelvin, `0x8008`–`0x800A` Custom 1–3. An empty custom white balance may be refused
(`HYPOTHESIS` on the X100VI).

### 2.5 Write sequence

What our USB writer sends for one slot (`CODE`, `modules/camera/usb.ts`). This sequence wrote and verified slot C7 on
`VERIFIED-HW 2026-10-15`; the Swift writer (`SlotEncoder.swift`), which sends the same property order, did so on
`VERIFIED-HW 2026-10-13`.

1. Read all seven slots and save them to a durable private backup. Refuse to write if any slot is incomplete.
2. `D18C` = target slot. Wait 100 ms. Read `D18C`; stop unless it equals the target.
3. `D18D` = name.
4. Then, 20 ms apart, in this order: `D192`, `D191` (= 0), `D190`, `D195`, `D196`†, `D197`†, `D198` (= 1), `D199`,
   `D19C`‡, `D19A`†, `D19B`†, `D19D`, `D19E`, `D19F`†, `D1A0`, `D1A1`, `D1A2`.
   † skipped for monochrome simulations. ‡ only when white balance is Kelvin.
5. Stop at the first refused property. Report a partial write; do not continue to the next slot.
6. Read back every written property and the name. Compare byte for byte, except Grain Off (section 2.7).
7. Re-read the target slot's full block: properties outside the written set must not have changed.
8. Re-read every protected slot and compare it with the backup.

Other working orders exist and are reported to work on their bodies:

- name last (`CITED fujifilm-ptp-recipes (CC BY 4.0 docs)`, X-H2);
- Kelvin after the shifts, 20 ms between writes, name last (`CITED ctl0v0 (MIT)`, X100VI fw 1.32; our 20 ms gap
  comes from here);
- name first because names were otherwise corrupted (`CITED AlPeFe/fuji-ptp-android (MIT)`).

### 2.6 Gating, forcing and the monochrome skip set

| Rule | Detail | Evidence |
|---|---|---|
| D-Range Priority locks tone | While `D191` ≠ 0, the camera owns DR, Highlight and Shadow, and refuses `D190`/`D19D`/`D19E` with `0x201C` | `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)` (X-H2); `HYPOTHESIS` on the X100VI |
| D-Range Priority forced Off | Our writer always writes `D191` = 0 before `D190`, so a look's DR and tones always land. A look cannot express D-Range Priority | `CODE` |
| Smooth Skin forced Off | Our writer always writes `D198` = 1. A look cannot express Smooth Skin | `CODE` |
| Monochrome skip set | Under a monochrome simulation the writer skips `D196`, `D197`, `D19A`, `D19B` and `D19F`. A design choice: a monochrome look has no use for them, and skipping keeps the slot's stored values | `CODE` |
| What the camera refuses under monochrome | `D19F` (Color) was refused with Acros selected. `D196`, `D197`, `D19A` and `D19B` were accepted while a monochrome simulation was active | `VERIFIED-HW 2026-10-13` |
| Hidden colour values | The slot keeps its old colour-only values under a monochrome simulation. A slot holding a monochrome look read back Color +3 | `VERIFIED-HW 2026-10-09` |
| Restoring hidden values | Chrome and shifts can be written back directly. Color needs a colour simulation: select Provia temporarily, write Color, then reselect the saved monochrome simulation | `VERIFIED-HW 2026-10-13` |
| Kelvin gate | `D19C` only while `D199` = `0x8007`. When undoing, restore Kelvin before changing white balance away from Kelvin | `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)`; `CODE` |
| DR and ISO | DR200 needs ISO 250 or more, DR400 needs ISO 500 or more; reported for live writes | `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)`; slot behavior on the X100VI `HYPOTHESIS` |
| Clarity | Refused once mid-batch on an X-T5 but accepted alone (`CITED helios (MIT)`). Reported elsewhere to be refused outside single-frame drive (`HYPOTHESIS`). Never refused in our sessions | as stated |
| Never write | `D18E`, `D18F`, `D1A3`, `D1A4`, `D1A5` | `CODE` |

### 2.7 Read-back quirks

| Quirk | Detail | Evidence |
|---|---|---|
| OK is not applied | A write can answer `0x2001` without the value landing. Read every write back | `CITED fujifilm-ptp-recipes (CC BY 4.0 docs)`; `CODE` |
| Grain Off | Writing `1` reads back as `6` or `7`. A byte-exact verifier reports a false failure for every Grain-Off look; ours accepts 1, 6 or 7 when 1 was written, nothing else | Our first verifier failed this way `VERIFIED-HW 2026-10-15`; fix `CODE`, then verified `VERIFIED-HW 2026-10-15` |
| Why 6 or 7 | The settings file stores grain as separate strength and size bytes (section 4.3). Off keeps the previous size, so the read-back reports Off-Small or Off-Large | `HYPOTHESIS`, consistent with `VERIFIED-HW 2026-10-15` |
| Never write 6 or 7 | Writing a 6/7 read-back value back was refused on an X-T5 | `CITED helios (MIT)` |
| DR Auto | `D190` reads `0xFFFF` for a DR-Auto look or while D-Range Priority is active | `CITED ctl0v0 (MIT)` (X100VI fw 1.32) |
| Empty slot | An unset slot reads `0xFFFF` across the block | `CITED AlPeFe/fuji-ptp-core (no license stated)` |
| Signedness | 2-byte values decode as signed for the i16 fields; mask unsigned fields with `0xFFFF` | `CODE` |
| Hidden values | Colour-only properties keep reading their stored values under a monochrome simulation (section 2.6) | `VERIFIED-HW 2026-10-09` |
| Reading changes nothing | Enumerating all seven slots over USB left the downloaded settings file byte-identical | `VERIFIED-HW 2026-10-13` |

### 2.8 Persistence

| Question | Answer | Evidence |
|---|---|---|
| Does a USB slot write survive power-off? | Yes for the tested write: C7 written, camera switched off for about 5 s and on, all seven slots byte-identical by property read-back | `VERIFIED-HW 2026-10-15`. The AUTO UPDATE CUSTOM SETTING menu state was not recorded |
| Do property writes reach the settings file? | Yes: files downloaded after USB slot writes contain the written values | `VERIFIED-HW 2026-10-09`, `VERIFIED-HW 2026-10-13` |
| X-T5 "unsaved changes" flag | On an X-T5, slot writes with AUTO UPDATE CUSTOM SETTING off are left flagged unsaved | `CITED helios (MIT)`; not reproduced on the X100VI |
| `D307` | Refused with `0x200A` in this USB mode | `VERIFIED-HW 2026-10-13`. Its meaning (AUTO UPDATE CUSTOM SETTING) is `HYPOTHESIS` |

### 2.9 Live look properties (current shooting state)

The same look values have "live" codes that change what the camera shoots with now, without touching C1–C7.
fujifilm-ptp-recipes wrote, read back and restored all 23 on an X-H2 in this USB mode
(`CITED fujifilm-ptp-recipes (CC BY 4.0 docs)`). On the X100VI only `D001` has been exercised: Provia → Pro Neg Std →
Provia, accepted and read back, settings file unchanged afterwards (`VERIFIED-HW 2026-10-13`). Our live writer and
gate-aware undo: `CODE`.

| Slot | Live | Slot | Live | Slot | Live |
|---|---|---|---|---|---|
| `D18E` | `D1A5` | `D195` | `D023` | `D19C` | `D017` |
| `D18F` | `D018` | `D196` | `D029` | `D19D` | `D320` |
| `D190` | `D007` | `D197` | `D030` | `D19E` | `D321` |
| `D191` | `D02E` | `D198` | `D189` | `D19F` | `D008` |
| `D192` | `D001` | `D199` | `5005` | `D1A0` | `5015` |
| `D193` | `D104` | `D19A` | `D00B` | `D1A1` | `D01C` |
| `D194` | `D031` | `D19B` | `D00C` | `D1A2` | `D032` |
| | | | | `D1A3`, `D1A4` | `D34D`, `D00A` |

Whether live changes persist across power-off, and whether they fold into a selected C slot: unknown.

### 2.10 The settings file over USB

| Operation | Wire | Evidence |
|---|---|---|
| Download | `GetObjectInfo(0)`, then `GetObject(0)` (object handle 0, ObjectFormat `0x5000`). Returns the plain 70,524-byte file (not compressed) | `VERIFIED-HW 2026-10-09`, `VERIFIED-HW 2026-10-13`, `VERIFIED-HW 2026-10-15`; `CITED libfuji (MIT)` |
| Repeatability | Two back-to-back downloads are byte-identical | `VERIFIED-HW 2026-10-13` |
| Upload | `SendObjectInfo` with params `[0, 0]` and an ObjectInfo of **exactly 1076 bytes**: all zero except ObjectFormat `0x5000` at +4 and ObjectCompressedSize = file length at +8. Then `SendObject` with the file | `CITED helios (MIT)` (X-T5, hardware-confirmed there); `CODE`; **never sent to an X100VI** |
| Wrong ObjectInfo size | A 1088-byte ObjectInfo is refused with `0x200F` at the data phase | `CITED helios (MIT)` (X-T5) |
| Upload preconditions | Restore must be the first operation after power-on; a bad checksum, an unclean session or seven names totalling more than about 95 characters all give `0x200F`; power-cycle afterwards | `CITED helios (MIT)` (X-T5); `HYPOTHESIS` on the X100VI |
| Scope | An upload replaces every setting the file carries, not one slot | `CITED helios (MIT)` |

---

## 3. Bluetooth LE

### 3.1 Profiles and firmware

| X100VI firmware | Profile | Evidence |
|---|---|---|
| 1.10 | **Basic**: a 4-byte key taken from the pairing advert and presented on every connection; no OS bond; open Wi-Fi access point | `VERIFIED-HW 2026-10-13` |
| 1.11 | Basic, fffw GATT table `76ab62` | `CITED fffw (MIT)` |
| 1.30 and later | **Secure**: OS LE bonding with a 6-digit comparison, an identification-number handshake, a WPA2 access point whose passphrase is read over the encrypted link | `CITED fffw (MIT)`, `CITED furble (MIT)`, `CITED FUJIFILM firmware release notes` |

Detect the profile from the advertisement, never from the firmware string (`CODE`). Owners report bodies shipping with
factory firmware that is not listed on FUJIFILM's download page (`HYPOTHESIS`).

### 3.2 Advertisements

Manufacturer data uses company ID `0x04D8` (`CITED furble (MIT)`; `VERIFIED-HW 2026-10-09`). In the table, `kk` is
the 4-byte pairing key; real values are withheld.

| Camera state | What it advertises | Evidence |
|---|---|---|
| Basic, PAIRING REGISTRATION | Manufacturer data `D8 04 02 kk kk kk kk` | `VERIFIED-HW 2026-10-13` (registration completed with this key) |
| Basic, switched off with Bluetooth on (standby) | Manufacturer data `D8 04 02 kk kk kk kk pp` plus service `731893f9-…`. `kk` is the **registered** key; `pp` is one byte (power-key state per `HYPOTHESIS`) | `VERIFIED-HW 2026-10-09` |
| Basic, asleep | While only the standby advert was heard, no connection was possible; after a shutter half-press woke the camera, the client connected | `VERIFIED-HW 2026-10-13` |
| Basic, registered and awake | May carry no manufacturer data; lists the file-transfer service `af854c2e-…` | `HYPOTHESIS`; our scanner accepts it (`CODE`) |
| Local name | `<tag>X100VI-<tag>`, the same 4-character body-specific tag twice | Format `VERIFIED-HW 2026-10-09`; that the tag derives from the serial is `HYPOTHESIS` |
| Secure, pairing mode | 6-byte manufacturer data: `01` + a 5-character ASCII tag; service `a9d2b304-…` | `CITED fuji-bridge (MIT)` (X100VI fw 1.32) |
| Secure, bonded and looking for its client | Service `804daa8e-…`, later `123d8f06-…` | `CITED fuji-bridge (MIT)` (X100VI fw 1.32) |

Privacy note: a basic body in standby broadcasts its registered key in the clear (`VERIFIED-HW 2026-10-09`). On basic
firmware that key is the only credential a client presents (`HYPOTHESIS` that the camera checks nothing else).

### 3.3 Services and characteristics

About 70 characteristics were discovered on our fw 1.10 body and its firmware revision string read `01.10`
(`VERIFIED-HW 2026-10-13`). The rows below are the ones that matter for registration, backup, restore and Wi-Fi
launch. "Used" rows took part in a successful flow on hardware; flags and lengths are `CITED fffw (MIT)`.

| Service | Characteristic | Flags, length | Role | Evidence |
|---|---|---|---|---|
| `91f1de68-dff6-466e-8b65-ff13b0f16fb8` (basic) | `aba356eb-9633-4e60-b73f-f52516dbd671` | W 4 | Pairing key | Used `VERIFIED-HW 2026-10-13` |
| `91f1de68-…` (basic) / `123d8f06-62a1-4935-9322-833c531ee225` (secure) | `85b9163e-62d1-49ff-a6f5-054b4630d4a1` | W 30 | Client name, UTF-8 plus one NUL; the camera displays it | Used `VERIFIED-HW 2026-10-13` |
| `123d8f06-…` (secure) | `f557d96b-8284-4667-8793-b971c1deca2a` | R/W 4 | Identification number | `CITED furble (MIT)`, `CITED fuji-bridge (MIT)` |
| `4e941240-d01d-46b9-a5ea-67636806830b` | `bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4` | R/W/N 32 | Access-point SSID | Used `VERIFIED-HW 2026-10-15` |
| `4e941240-…` | `e809256a-915c-4967-92e8-53b7d4cad213` | R 20 | Access-point passphrase. **Absent on basic firmware** | Absence `VERIFIED-HW 2026-10-15` (open network); presence on secure `CITED fffw (MIT)` |
| camera information | `49a12959-dfaa-4eb2-89ce-62548ad948f3` | R | Camera Wi-Fi MAC, `-`-separated; usable as the BSSID to pin | `CODE`; meaning `HYPOTHESIS` |
| `4c0020fe-f3b6-40de-acc9-77d129067b14` | `a68e3f66-0fcc-4395-8d4c-aa980b5877fa` | R/Indicate 2 | Access-point state (section 3.7) | Used `VERIFIED-HW 2026-10-15` |
| `4c0020fe-…` | `11438c83-cfb0-4511-841b-759e0d2321c8` | R/Indicate 2 | Backup state: `01 00` ready, `00 00` busy | Used `VERIFIED-HW 2026-10-13` |
| `4c0020fe-…` | `4b3a413c-230f-42bc-b3ed-b1db2eadee82` | R/Indicate 2 | Restore state: `01 00` ready, `00 00` busy | Used `VERIFIED-HW 2026-10-13` |
| `6514eb81-4e8f-458d-aa2a-e691336cdfac` | `600655e6-3637-42f1-8fb2-44efc5c63b13` | W 2 | Function launch: u16 `3` image viewing, `4` remote shooting | `3` used `VERIFIED-HW 2026-10-15`; `4` `CITED libfuji (MIT)` |
| `6514eb81-…` | `f14e7a88-6f57-4872-a69b-b47ef3295c9b` | W 2 | Backup request: u16 `1` settings | Used `VERIFIED-HW 2026-10-13` |
| `6514eb81-…` | `f1897eb9-a9aa-40f0-8ce6-2fa7915bc459` | W 2 | Restore request: u16 `1` settings | Used `VERIFIED-HW 2026-10-13` |
| `6514eb81-…` | `7fcf49c6-4ff0-4777-a03d-1a79166af7a8` | W 2 | Shutter | `CITED furble (MIT)` |
| `af854c2e-b214-458e-97e2-912c4ecf2cb8` | `7f3400fe-17e7-4b80-8a0e-81b0343c1b49` | R/W 4 | Chunk size, u32 (we use 120) | Used `VERIFIED-HW 2026-10-13` |
| `af854c2e-…` | `051dd980-df9d-4472-a2e1-35811dd24ee1` | W 4 | File index, u32 (0) | Used `VERIFIED-HW 2026-10-13` |
| `af854c2e-…` | `c922ac69-9480-4348-8f4b-9ee29bc30d1d` | R/W 44 | File information: `name[40]` (UTF-8, zero padded) + u32 size | Used `VERIFIED-HW 2026-10-13` |
| `af854c2e-…` | `ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea` | R/W 248 | File chunk (read on download, written on upload) | Used `VERIFIED-HW 2026-10-13` |
| `af854c2e-…` | `68052e8a-fb91-404f-8847-0eb4be24308c` | W 2 | Transfer result: `00 00` fail, `02 00` cancel, `03 00` end | `03 00` used `VERIFIED-HW 2026-10-13` |
| `af854c2e-…` | `2e27ed9f-5506-41cd-ba48-dac06669ad95` | N 4 | Transaction state: u16 state + u16 sequence | Used `VERIFIED-HW 2026-10-13` |
| `e872b11f-…` | `b9bfd37f-ccad-4d36-a1ee-018e792b3edf` | W 7 | Date and time | `CITED furble (MIT)` |
| `3b46ec2b-…` | `0f36ec14-29e5-411a-a1b6-64ee8383f090` | W 23 | Location | `CITED furble (MIT)`, `CITED libfuji (MIT)` |
| `4c0020fe-…` | `f9150137-5d40-4801-a8dc-f7fc5b01da50`, `ad06c7b7-f41a-46f4-a29a-712055319122` | N | Camera asks for time / for a location | `CITED libfuji (MIT)` |
| Device Information | `2a24` model, `2a25` serial string, `2a26` firmware revision | R | Standard SIG characteristics | `2a26` `VERIFIED-HW 2026-10-13` |

Characteristics we never write (`CODE` refuses them): firmware update, power control, movie record, log transfer, and
`8b5ecf55-…` (newer bodies use it to identify the connecting app). Neither the Swift package nor the Python bench writes
`8b5ecf55`: both identify themselves only through the client name above, `Dial In` by default, and never present as
FUJIFILM's app (`CODE`).

### 3.4 Basic registration and reconnection (fw 1.10)

| # | Client action | Evidence |
|---|---|---|
| 1 | Camera: MENU › NETWORK/USB SETTING › Bluetooth/SMARTPHONE SETTING › PAIRING REGISTRATION. Scan for a `D8 04 02` advert carrying a 4-byte key | `VERIFIED-HW 2026-10-13` |
| 2 | Connect and discover services | `VERIFIED-HW 2026-10-13` |
| 3 | Read `2a25` (serial string) before the key | `CODE`; whether the camera requires it: `HYPOTHESIS` |
| 4 | Write the 4-byte key to `aba356eb`, with response | `VERIFIED-HW 2026-10-13` |
| 5 | Write the client name to `85b9163e` (UTF-8, one NUL, at most 30 bytes). The camera then shows it as connected | `VERIFIED-HW 2026-10-13` |
| 6 | Subscribe to access-point state, transfer state, date-sync and location-sync, then the remaining state characteristics. Wait for the OS to confirm each subscription before relying on it | `CODE` (the confirmation wait was added after a failed transfer on `VERIFIED-HW 2026-10-13`) |
| 7 | Wait 3 s before a backup or restore request | `CODE`; its necessity is `HYPOTHESIS` |

- **Reconnect:** repeat steps 2–7 with the saved key. No PAIRING REGISTRATION is needed. Worked on
  `VERIFIED-HW 2026-10-13` and, with the key saved two days earlier and power cycles in between, on
  `VERIFIED-HW 2026-10-15`.
- **No key, no backup:** a client that skipped the key never got a ready backup state (`VERIFIED-HW 2026-10-13`). Our
  client now refuses to continue without a saved 4-byte key (`CODE`).
- **Other clients:** whether registering a new client displaces an earlier one (for example a phone) is untested
  (`HYPOTHESIS` that it does).

### 3.5 Secure pairing (fw 1.30 and later)

Not tested by us; summarized from `CITED furble (MIT)` and `CITED fuji-bridge (MIT)` (X100VI fw 1.31/1.32):

1. The camera in pairing mode advertises `a9d2b304-…`. Connecting triggers OS LE bonding with a 6-digit comparison.
2. Encrypted reads fail with "encryption is insufficient" while the user compares codes. Keep the link and retry.
3. Read `f557d96b` (u32), write it back with byte 3 set to `0x20` (equivalently, OR `0x20000000`): `07 96 00 00` →
   `07 96 00 20`. Store and reuse the result (`CODE`).
4. Write the client name; subscribe as in 3.4.
5. The bond belongs to the operating system. If the camera forgets it (reset, deleted registration, firmware update),
   the OS still holds stale keys and the user must remove the device in system Bluetooth settings (`HYPOTHESIS`).

### 3.6 Settings backup (download)

Flow (`CITED fuji-bridge (MIT)`; `CODE`; `VERIFIED-HW 2026-10-13`, several runs):

1. Subscribe to transaction state `2e27ed9f` and backup state `11438c83`.
2. Write `01 00` to backup request `f14e7a88`.
3. Wait (up to 10 s) for backup state `01 00`. `00 00` means busy.
4. Write chunk size u32 `120` to `7f3400fe`, then file index u32 `0` to `051dd980`.
5. On each transaction-state notification with state 1 or 2, read `ac0c799a`:
   `u16 sequence | u32 length | data[length]`. The last chunk has sequence `0xFFFF`, and its data ends with a u16 sum
   of every preceding data byte. That sum is transport framing, not file data.
6. On state 3: check the sum, read file information `c922ac69`, write `03 00` to `68052e8a` (`00 00` on a sum
   mismatch).

What the X100VI fw 1.10 actually sends (`VERIFIED-HW 2026-10-13`):

| Observation | Detail |
|---|---|
| Payload is compressed | A zlib stream (header `78 9C`) of 1,461–1,463 bytes, expanding to the 70,524-byte settings file. Not gzip, despite the `.gz` name FUJIFILM's app gives its saved copy (`HYPOTHESIS` for that last part) |
| Size field disagrees | File information reports the **expanded** size (70,524), not the number of bytes sent |
| Transport sum | Computed over the compressed bytes actually sent |
| Shape and speed | 13 consecutive chunks, about 3.3–3.7 s |
| Compression level | Of zlib levels 0–9, only level 6 reproduces all six captures byte for byte (offline analysis of the captures) |
| Same file as USB | The expanded file equals the USB download except header byte `0x47`: the identity string at `0x34` is one character shorter over Bluetooth |
| Mode independence | Works with CONNECTION MODE left on USB RAW CONV./BACKUP RESTORE, as long as the cable is out |
| Busy with USB attached | With the USB cable still connected to a computer, backup state stayed `00 00` (busy); after unplugging, backups succeeded. On 2026-10-16, with the cable attached, Wi-Fi function launch was refused the same way (section 3.8). Causation is `HYPOTHESIS`; the CLI refuses Bluetooth backup and Wi-Fi wake while a Fujifilm USB device is attached |
| One bad run | Once, no ready notification arrived; reading chunks anyway produced a failed transport sum. Cause unresolved |

Another body's `backup.dat` was 33,404 bytes (`CITED libfuji (MIT)`); whether it was compressed is unknown.

### 3.7 Settings restore (upload)

The upload mirrors the download, one acknowledged frame at a time. The sequence comes from study of FUJIFILM's app,
is implemented here (`CODE`, `ios/DialInCamera/Sources/DialInCamera/BLE/`), and completed once on hardware with an
**unchanged** file: the camera's own fresh backup, sent back byte for byte (`VERIFIED-HW 2026-10-13`).

| # | Client | Camera | Failure handling (`CODE`) |
|---|---|---|---|
| 0 | Subscribe to transaction state `2e27ed9f` and restore state `4b3a413c` | | |
| 1 | Write `01 00` to restore request `f1897eb9` | | |
| 2 | | Indicates restore state | None within 10 s: write `02 00` (cancel) |
| 3 | Require `01 00` | | `00 00` means busy: write `02 00` |
| 4 | Write chunk size u32 `120` to `7f3400fe` | | |
| 5 | Write file index u32 `0` to `051dd980` | | |
| 6 | Write file information `c922ac69`: `backup.dat`, zero-padded to 40 bytes, then u32 size = **bytes on the wire** (the compressed length for a compressed body) | | |
| 7 | | Notifies transaction state 1 (start) | Missing or other: `02 00` |
| 8 | For each frame: write it to `ac0c799a` **with response** | Notifies transaction state after every frame | No notification within 10 s: `02 00` |
| 9 | State 2: send the next frame | | |
| 10 | After the last frame, state 3: write `03 00` to `68052e8a` with response | | State 3 before the last frame: treat as failure |
| 11 | State 0: write `00 00` | | Failure |

There is no pacing besides this stop-and-wait (`CODE`).

**Frame format** (all little-endian):

```
u16 sequence | u32 size | data[size] | u16 trailer
```

| Field | Intermediate frame `i` | Last frame |
|---|---|---|
| sequence | `i` (0, 1, 2 …) | `0xFFFF` |
| data | next 120 bytes of the file | the remaining 1–120 bytes, **followed by** the u16 sum of every file byte |
| size | 120 | remaining + 2 |
| trailer | `00 00` | the same u16 sum again |
| total length | 128 bytes | 6 + remaining + 4 (at most 130) |

- The sum is the byte-wise sum of the whole uploaded file (the wire bytes), modulo 65536 (`CODE`).
- A file whose length is a multiple of 120 still ends with a 120-byte data piece in the last frame (`CODE`).
- The largest frame is 130 bytes, so the link must accept 130-byte writes with response (ATT MTU at least 133)
  (`CODE`). 128-byte frames were accepted from macOS (`VERIFIED-HW 2026-10-13`).
- Worked example from the hardware run: a 1,463-byte compressed file → 12 frames of 128 bytes, then a last frame
  carrying 23 data bytes (33 bytes in total), 13 frames in all (`VERIFIED-HW 2026-10-13`).

What the unchanged upload showed (`VERIFIED-HW 2026-10-13`):

- restore state `01 00`; all 13 frames acknowledged; final transaction state bytes `03 00 FF FF`; the `03 00` result
  write acknowledged;
- an immediate Bluetooth re-download, expanded, was identical to the file sent;
- a later independent USB read preserved all seven slots and matched the earlier USB control apart from bytes in the
  known volatile span (section 4.5);
- the camera's screen was not watched and a power cycle in between was not confirmed.

**One edited-file trial** (`VERIFIED-HW 2026-10-16`, owner present): the experimental single-slot path changed C7,
returned `verified` after about 23 s, and the owner confirmed the new name in the camera menu. The trial recorded
C1–C6 unchanged. The power-cycle check was **not performed**. This is current-session evidence for one modification,
not completed acceptance of the production writer, all setting encodings, rollback or full-camera recovery.
`BLESlotWriter.wirelessWritesValidated` remains false (`CODE`). Lab writes require both
`--lab-single-slot-trial` and `--i-understand-this-is-experimental`; they do not enable production writes.

Not established: all the camera's edited-file validation rules, restart persistence of that trial, and how an edited
file refusal appears (`HYPOTHESIS`: a failed ATT write mid-upload, or state 0 at the end).
The second u16 of each transaction-state notification has not been traced per frame; do not enforce a guessed rule
for it.

**How we prepare an edited upload** (`CODE`; production disabled, one lab trial as above):

1. Take a fresh Bluetooth backup on the same link. Keep both the compressed wire bytes and the expanded file.
2. Patch only the target slot's record in the expanded file (section 4.7). Fix the checksum incrementally.
3. Recompress with zlib level 6, matching the camera's header bytes. Decompress the result again and compare.
4. Upload with the compressed length in file information and the sum over the compressed bytes.
5. Download again and compare every slot. Confirm independently over USB.
6. For an unchanged upload, send the camera's exact original wire bytes; never recompress.

### 3.8 Wi-Fi launch over Bluetooth

| # | Step | Evidence |
|---|---|---|
| 1 | Subscribe to access-point state `a68e3f66` | `CODE` |
| 2 | Read the SSID from `bf6dc9cf`; reject an empty one. Read the passphrase from `e809256a` if it exists; a basic body has no such characteristic and an open network. Optionally read the camera MAC from `49a12959` | `VERIFIED-HW 2026-10-15` (open network on basic) |
| 3 | Discard any access-point value already queued, then write function launch `600655e6` = `03 00` (image viewing) | `VERIFIED-HW 2026-10-15` |
| 4 | Wait for "launched". Busy answers: wait 200 ms and ask again. On 2026-10-15 the access point started after two busy answers. On 2026-10-16, with the USB cable attached (CONNECTION MODE USB RAW CONV./BACKUP RESTORE), every answer was busy (`00 80`), six of six over two runs, including one right after `ptpcamerad` was stopped | `VERIFIED-HW 2026-10-15`, `VERIFIED-HW 2026-10-16`; retry policy `CODE` |
| 5 | Join `FUJIFILM-X100VI-XXXX`, then open TCP `192.168.0.1:55740` (section 5) | `VERIFIED-HW 2026-10-15` |

Access-point state values: u16 `0x8000` not launched, `0x8001` launched, `0x8002` launching (keep waiting),
`0x8003` launched for a reserved transfer (`HYPOTHESIS` from study of FUJIFILM's app; `CODE`). Older one-byte readings
`01` up / `00` busy (`CITED fuji-bridge (MIT)`).

- After function launch `4` (remote shooting), an X100VI ignores an image-viewing client's PTP/IP init
  (`CITED fuji-bridge (MIT)`). Launch the function you will use.
- On secure firmware a Bluetooth-started access point hides its SSID and needs the passphrase
  (`CITED libfuji (MIT)`, `CITED fuji-bridge (MIT)`).

---

## 4. The settings file (FUJIFILMX-BACKUP)

Everything in this section describes the X100VI fw 1.10 file unless stated. The same file comes over USB (plain) and
Bluetooth (zlib). Our decoder and patcher: `ios/DialInCamera/Sources/DialInCamera/SettingsFile/` and `ble/fuji_ble/`
(`CODE`); slot map: `ble/maps/x100vi-fw110.json`.

### 4.1 Header

| Offset | Size | Content | Evidence |
|---|---|---|---|
| `0x00` | 16 | ASCII `FUJIFILMX-BACKUP` | `VERIFIED-HW 2026-10-09`; `CITED helios (MIT)` |
| `0x10` | 4 | ASCII version `0100` | `VERIFIED-HW 2026-10-09` |
| `0x14` | 32 | Model, NUL-padded ASCII: `X100VI` | `VERIFIED-HW 2026-10-09` |
| `0x34` | 32 | Body identity string (serial-like). **Private: zero it before sharing a file.** One character shorter in Bluetooth copies (ends at `0x47`) | `VERIFIED-HW 2026-10-13` |
| `0x98` | 4 | u32 payload start = `0xA8` | `VERIFIED-HW 2026-10-09` |
| `0xA0` | 4 | u32 payload length; start + length = file size | `VERIFIED-HW 2026-10-09` |
| `0xA8`… | | Payload | |

- File size: 70,524 bytes on every fw 1.10 capture (`VERIFIED-HW 2026-10-09`, `VERIFIED-HW 2026-10-13`,
  `VERIFIED-HW 2026-10-15`).
- About 59 KB of the payload is zeros, `[0x0EF8, 0xF6B8)` (`VERIFIED-HW 2026-10-09`).
- The payload starts with a table of u32 values that look like global menu settings (`HYPOTHESIS`).
- Files from other bodies carry paired-device names, SSIDs and lens serials in clear (`CITED vcam (LGPL-2.1)` sample
  files). Treat any settings file as private.

### 4.2 Slot layout

C1–C7 are the **last seven 0x400-aligned blocks** of the file. Some per-slot settings sit in a preamble just before
each anchor (negative offsets below). `VERIFIED-HW 2026-10-09`.

| Slot | Anchor | Slot | Anchor |
|---|---|---|---|
| C1 | `0xF800` | C5 | `0x10800` |
| C2 | `0xFC00` | C6 | `0x10C00` |
| C3 | `0x10000` | C7 | `0x11000`, file ends at C7 + `0x37C` |
| C4 | `0x10400` | | |

The X-T5 file has the same shape with different offsets (name at +`0x1CF`) (`CITED helios (MIT)`).

### 4.3 Per-slot fields

Offsets are relative to the anchor. "Located" fields were found by correlating a file with seven known looks written
over USB just before the download: 18 of 20 testable fields and all seven names matched the USB read-back exactly; the
two misses are explained by the white-balance-shift table (`VERIFIED-HW 2026-10-09`).

| Rel. offset | Field | Encoding | Evidence |
|---|---|---|---|
| −`0x74` | Kelvin | u16 | `VERIFIED-HW 2026-10-09` (4350, 5200, 6300) |
| −`0x0F` | White-balance mode | byte; section 4.4 | `0`, `3`, `0x0A` `VERIFIED-HW 2026-10-09`; rest `HYPOTHESIS` |
| −`0x0D` … +`0x2A` | **WB shift table**: 14 entries × 4 bytes; red at −`0x0D` + 4i, blue at −`0x0B` + 4i; value = 9 − raw | Each white-balance mode keeps its own shift; a look's shift lives in its mode's entry | Entries 0, 6, 7 `VERIFIED-HW 2026-10-09`; entry order otherwise `HYPOTHESIS` |
| +`0x2B` | High ISO NR | value = raw − 4 | −4 ↔ `0` `VERIFIED-HW 2026-10-09`; rest `HYPOTHESIS` |
| +`0x2E` | Clarity | value = raw − 6 | `VERIFIED-HW 2026-10-09` |
| +`0x2F` | Image size | `0` L (`1` M, `2` S) | Reads `0` on all seven slots while `D18E` reads L 3:2 (`VERIFIED-HW 2026-10-09`); the field's meaning and M/S `HYPOTHESIS` |
| +`0x31` | Aspect ratio | `1` 3:2 (`2` 16:9, `3` 1:1) | Reads `1` on all seven slots with L 3:2 (`VERIFIED-HW 2026-10-09`); the field's meaning and other values `HYPOTHESIS` |
| +`0x32` | Image quality | `2` Fine+RAW, `3` Normal+RAW (`0` Fine, `1` Normal, `4` RAW) | `2` and `3` `VERIFIED-HW 2026-10-13`; rest `HYPOTHESIS` |
| +`0x64` | Film simulation | byte; section 4.4 | 7 codes `VERIFIED-HW 2026-10-09`; rest `HYPOTHESIS` |
| +`0x6A` | Remembered monochrome variant | Changed `9` → `12` after the slot passed through Monochrome+G and back to Acros+Ye. Looks like the last-used Monochrome-family film byte | Change `VERIFIED-HW 2026-10-13`; meaning `HYPOTHESIS` |
| +`0x70` / +`0x72` | Monochrome magenta-green / warm-cool | value = raw − 18 | `HYPOTHESIS` |
| +`0x74` | Dynamic range | `1` DR100, `2` DR200, `3` DR400 (`0` Auto) | 1–3 `VERIFIED-HW 2026-10-09`; Auto `HYPOTHESIS` |
| +`0x76` | D-Range Priority | `4` Off (`3` Weak, `2` Strong, `0` Auto) | Off `VERIFIED-HW 2026-10-09`; rest `HYPOTHESIS` |
| +`0x77` | Color | −1 → `8`, 0 → `0`, +1 → `6`, +2 → `5`, +3 → `4` (+4 → `3`, −2 → `9`, −3 → `10`, −4 → `11`) | Listed values `VERIFIED-HW 2026-10-09`; bracketed `HYPOTHESIS`. Note 0 is stored as `0`, not `7` |
| +`0x79` | Sharpness | value = 4 − raw | `VERIFIED-HW 2026-10-09`, `VERIFIED-HW 2026-10-13` |
| +`0x7B` / +`0x7D` | Highlight / Shadow | value = raw / 2 − 2 | `VERIFIED-HW 2026-10-09` |
| +`0x7F` / +`0x80` | Color Chrome / CC FX Blue | `0` Off, `1` Weak, `2` Strong | `VERIFIED-HW 2026-10-09` |
| +`0x81` | Grain strength | `2` Off, `1` Weak, `0` Strong | `VERIFIED-HW 2026-10-09` |
| +`0x82` | Grain size | `0` Small, `1` Large | `VERIFIED-HW 2026-10-09` |
| +`0x83` | Smooth Skin | `0` Off, `1` Weak, `2` Strong | `HYPOTHESIS` |
| +`0x84`, +`0x88` | AF mode, AF "all" flag | X-T5 offsets moved by the X100VI shift | `HYPOTHESIS` |
| +`0x9E` | Self-timer | `0` off, `1` 2 s, `2` 10 s | `HYPOTHESIS` |
| +`0xAA` … +`0xB2` | AUTO ISO 1–3: default, maximum, minimum shutter | three bytes each | `HYPOTHESIS` |
| +`0x101` / +`0x103` | RAW compression / JPEG-HEIF | | `HYPOTHESIS` |
| +`0x1E5` | Name | 26-byte field, ASCII, NUL-padded, at most 25 characters | `VERIFIED-HW 2026-10-09`; one-character edits `VERIFIED-HW 2026-10-13` |

Not per slot (on the X-T5, and in the USB slot block): drive mode, image stabilization, exposure compensation and ISO
itself; only the AUTO ISO ranges are per slot (`CITED helios (MIT)`; `HYPOTHESIS` for the X100VI file).

### 4.4 Code tables used in the file

These are measured from our own files, not taken from any FUJIFILM software.

**Film simulation byte at +`0x64`** (PTP code → file byte):

| PTP | Simulation | Byte | Evidence | PTP | Simulation | Byte | Evidence |
|---|---|---|---|---|---|---|---|
| 1 | Provia | 1 | `HYPOTHESIS` | 11 | Classic Chrome | 15 | `VERIFIED-HW 2026-10-09` |
| 2 | Velvia | 4 | `VERIFIED-HW 2026-10-09` | 12 | Acros | 22 | `HYPOTHESIS` |
| 3 | Astia | 2 | `HYPOTHESIS` | 13 | Acros+Ye | 24 | `VERIFIED-HW 2026-10-09` |
| 4 | Pro Neg Hi | 14 | `HYPOTHESIS` | 14 | Acros+R | 23 | `VERIFIED-HW 2026-10-09` |
| 5 | Pro Neg Std | 13 | `VERIFIED-HW 2026-10-09` | 15 | Acros+G | 25 | `HYPOTHESIS` |
| 6 | Monochrome | 9 | `HYPOTHESIS` | 16 | Eterna | 19 | `HYPOTHESIS` |
| 7 | Monochrome+Ye | 11 | `HYPOTHESIS` | 17 | Classic Neg | 16 | `HYPOTHESIS` |
| 8 | Monochrome+R | 10 | `HYPOTHESIS` | 18 | Eterna Bleach Bypass | 20 | `HYPOTHESIS` |
| 9 | Monochrome+G | 12 | `HYPOTHESIS` | 19 | Nostalgic Neg | 17 | `VERIFIED-HW 2026-10-09` |
| 10 | Sepia | 6 | `HYPOTHESIS` | 20 | Reala Ace | 18 | `VERIFIED-HW 2026-10-09` |

The `HYPOTHESIS` rows follow the X-T5 table (`CITED helios (MIT)`) with the X100VI's observed shifts (Reala Ace and the
Acros filter codes differ from the X-T5). A USB sweep on 2026-10-13 wrote 15 simulations and downloaded the file after
each; its log reports bytes matching 13 of the inferred codes. That evidence has not been reviewed yet, so those rows
stay `HYPOTHESIS`.

**White-balance mode byte at −`0x0F`** and its shift-table entry:

| Mode | Byte | Shift entry | Evidence |
|---|---|---|---|
| Auto | `0` | 0 | `VERIFIED-HW 2026-10-09` |
| Auto White Priority | `1` | 1 | `HYPOTHESIS` |
| Auto Ambience Priority | `2` | 2 | `HYPOTHESIS` |
| Daylight | `3` | 7 | `VERIFIED-HW 2026-10-09` |
| Shade | `4` | 8 | `HYPOTHESIS` |
| Fluorescent 1–3 | `5`–`7` | 9–11 | `HYPOTHESIS` |
| Incandescent | `8` | 12 | `HYPOTHESIS` |
| Underwater | `9` | 13 | `HYPOTHESIS` |
| Kelvin | `0x0A` | 6 | `VERIFIED-HW 2026-10-09` |
| Custom | `0x0B` | 3–5 | `HYPOTHESIS` |

### 4.5 Volatile and unexplained regions

| Region | Behavior | Evidence |
|---|---|---|
| `[0xF71E, 0xF72A)` | Changes between downloads with no setting changed. After exactly one photograph, only `0xF71E`, `0xF724`, `0xF725`, `0xF728` changed | `VERIFIED-HW 2026-10-13` |
| `[0xF6BC, 0xF6C6)` | Changes between downloads with no setting changed (seen at `0xF6BC`, `0xF6BD`, `0xF6C4`) | `VERIFIED-HW 2026-10-13` |
| `0xEC`, `0xF0`, `0xF1` (once also `0x8D9`) | Changed alongside manual menu edits of a slot. `0xEC`, `0xF0` and `0xF1` did not revert when the edit was undone from the menu | `VERIFIED-HW 2026-10-13`; meaning unknown |
| `0x47` | Differs between Bluetooth and USB copies of the same state (identity-string length) | `VERIFIED-HW 2026-10-13` |
| `0xE8` | The X-T5's checksum field; here it holds an ordinary table value | `VERIFIED-HW 2026-10-09` |

Any comparison of two downloads must expect the first two rows to differ.

### 4.6 Checksum

> **HYPOTHESIS.** The checksum model below fits the controlled changes analyzed here; its exact exclusion boundaries
> remain unproven. One edited-file Bluetooth trial completed on 2026-10-16 (section 3.7), with current-session readback
> and menu confirmation. That single trial does not qualify arbitrary edits, restart persistence or full-camera recovery.

Observations (`VERIFIED-HW 2026-10-13` unless stated):

- The field is the u32 at `0x108`. Its low u16 changes with every edit we have made; its high u16 was 0 on all our
  captures. (On the X-T5 the high half is a counter; `CITED helios (MIT)`.)
- One-character name edits and ±1 sharpness edits made over USB changed only the edited byte and the low u16, and the
  low u16 moved by the same amount as the byte (both directions).
- A manual menu change of C7 sharpness +2 → +1 changed the sharpness byte, the low u16 by +1, and bytes in the
  `[0xF71E, 0xF72A)` span only.
- One photograph changed four bytes inside `[0xF71E, 0xF72A)` and left the checksum unchanged.
- A sum over the whole payload predicts the wrong value in these controls. A sum over the slot records alone fails
  whenever the global bytes of section 4.5 also changed.

Model that fits all of the above (`HYPOTHESIS`):

```
stored_low16 = ( Σ bytes in [0xA8, EOF)
                 excluding [0x108, 0x10C), [0xF6BC, 0xF6C6), [0xF71E, 0xF72A)
                 + K ) mod 65536
```

- `K` is a constant. It was the same across our body's USB controls under this exclusion model. We do not publish it:
  it may depend on body-specific data, and edits do not need it.
- Incremental update for an edit: `new = old + Σ(new bytes) − Σ(old bytes)` over the edited bytes. This is only
  correct if those bytes are covered and the sum is additive. Our patcher uses it (`CODE`).
- The exact exclusion boundaries are not proven, and they may differ by firmware.
- For comparison, the X-T5 (`CITED helios (MIT)`, hardware-confirmed there): sum over `[0xA8, EOF)` excluding
  `[0xE8, 0xEC)` and a lens block `[0x7B1E, 0x7B29)`, plus `0xF936`, stored in the low u16 at `0xE8`. A bad sum makes
  the USB restore fail with `0x200F`.
- Settings files moved by FUJIFILM's own apps appear to be passed through unchanged, which suggests the camera
  computes and validates this checksum itself (`HYPOTHESIS`).

### 4.7 Editing rules our tools follow

All `CODE` (`FujiSettingsFile.swift`, `SettingsLookPatch.swift`, `ble/fuji_ble/x100vi_settings.py`):

- Accept only a camera-made X100VI file: magic, version `0100`, model `X100VI`, payload start `0xA8`, consistent
  length, exactly 70,524 bytes.
- Never change the header, the checksum's high half, or any byte outside the target slot's record (its preamble
  included), apart from the checksum's low half.
- Names: 1–25 printable ASCII characters, zero-padded to 26 bytes. Refuse a file whose seven names total more than 95
  characters (the X-T5 limit, `CITED helios (MIT)`; assumed for the X100VI).
- Refuse values whose file code is `HYPOTHESIS` unless explicitly overridden.
- For monochrome looks, leave Color, Color Chrome, CC FX Blue and the shift entry untouched.
- After patching, re-parse, recompute the expected checksum, and confirm no byte outside the allowed set changed.

---

## 5. Wi-Fi PTP/IP gallery session

The camera runs its own access point. After Bluetooth starts it (section 3.8), the client joins, opens the command
socket, and puts the camera in image-viewing ("gallery") mode. Our implementation:
`ios/DialInCamera/Sources/DialInCamera/Import/` (`CODE`).

### 5.1 Network

| Fact | Detail | Evidence |
|---|---|---|
| SSID | `FUJIFILM-X100VI-XXXX` (4-character body-specific suffix) | `VERIFIED-HW 2026-10-15` |
| Security | Open network on basic fw 1.10 | `VERIFIED-HW 2026-10-15` |
| Addresses | Camera `192.168.0.1`; the client receives a `192.168.0.x` address by DHCP | `VERIFIED-HW 2026-10-15` |
| No internet | Pin sockets to the Wi-Fi interface; otherwise the OS may route around the camera network | `CITED fuji-bridge (MIT)`; `CODE` |
| Drifting away | After a socket timeout the computer was no longer on the camera network, and a 15 s re-join failed. The OS auto-joining a known network is the suspected cause | Event `VERIFIED-HW 2026-10-15`; cause `HYPOTHESIS` |

### 5.2 Ports

| Port | Role | Evidence |
|---|---|---|
| TCP 55740 | Commands | `VERIFIED-HW 2026-10-15` |
| TCP 55741 | Events; listens only after `InitiateOpenCapture` (`0x101C`) | `CITED libfuji (MIT)`, `CITED libgphoto2 (LGPL-2.1)` |
| TCP 55742 | Live-view JPEG stream; as 55741 | `CITED libfuji (MIT)` |

### 5.3 Handshake

**Init request, 82 bytes** (`CITED libfuji (MIT)`, `CITED fuji-bridge (MIT)`; `CODE`):

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | `52 00 00 00` | Length, 82 |
| 4 | `01 00 00 00` | Init command request |
| 8 | `F2 E4 53 8F` | Protocol version marker `0x8F53E4F2` |
| 12 | `AD A5 48 5D 87 B2 7F 0B D3 D5 DE D0` | Fixed client identifier, the same in every implementation we know |
| 24 | u32 | The client's own IPv4 address, as a little-endian u32 (bytes in reverse dotted order) |
| 28 | 54 bytes | Client name, UTF-16LE, zero-padded |

- Offset 24: libfuji and fuji-bridge send zeros, which fw 1.32 accepted (`CITED fuji-bridge (MIT)`). Our client sends
  its own address, which fw 1.10 accepted (`VERIFIED-HW 2026-10-15`). FUJIFILM's app is understood to send the
  address too (`HYPOTHESIS`).
- Offset 28: use the same client name you wrote over Bluetooth (`CITED fuji-bridge (MIT)`; `CODE`).

**Init acknowledgement, 68 bytes** (`0x44`):

| Offset | Content |
|---|---|
| 0 | u32 length `0x44` |
| 4 | u32 type 2 (acknowledge) |
| 8 | u32 (described as an event-pipe id or a version; vcam sends 0) |
| 12 | 16-byte responder marker `08 70 B0 61 0A 8B 45 93 B2 E7 93 57 DD 36 E0 50` |
| 28 | Camera name, UTF-16LE |

- The marker is a fixed protocol constant, not a per-camera identity (`CITED vcam (LGPL-2.1)`, which emulates it).
- Our client accepts only a 68-byte acknowledgement carrying this marker (`CODE`). The handshake with the real
  X100VI completed on `VERIFIED-HW 2026-10-15`.
- Bind the session to the camera you launched over Bluetooth; the marker does not identify it.

**Init fail, 12 bytes:** u32 length 12, u32 type 5, u32 reason. Bodies often fail the first init
(`CITED libgphoto2 (LGPL-2.1)`). On reason `0x2019` (busy) wait 500 ms and resend on the same socket, at most six
sends; any other reason ends the attempt (`CODE`; `HYPOTHESIS` that this matches FUJIFILM's app).

**After the acknowledgement:**

1. Wait at least 50 ms. An `OpenSession` inside that window gets no answer (`CITED fuji-bridge (MIT)`).
2. `OpenSession(1)` with **transaction id 1**; ids restart on every socket (`CITED libfuji (MIT)`;
   `VERIFIED-HW 2026-10-15`).
3. From here every packet is the USB container of section 2.1, carried over TCP. Send a command and its data phase in
   one write (`CODE`).
4. Every response and data packet must carry the transaction id (and data the opcode) of the pending request. Drop
   the socket on a mismatch rather than accept another request's bytes (`CODE`).

### 5.4 Gallery mode

| # | Step | Evidence |
|---|---|---|
| 1 | Poll `GetDevicePropValue D212` until camera state `DF00` is non-zero. `D212` returns `u16 n` then `n × (u16 code, u32 value)` | `CITED libfuji (MIT)`; `VERIFIED-HW 2026-10-15` |
| 2 | `DF00 = 0` means the camera is waiting for the user: press MENU/OK on the camera | `VERIFIED-HW 2026-10-15` |
| 3 | Read version properties `DF22`, `DF25`, `DF21`, `DF24` | `CITED libfuji (MIT)`; `CODE` |
| 4 | Write client state `DF01` = `20` (u16, image viewing). If refused, try `2` (view all) | `CITED fuji-bridge (MIT)`; `20` accepted `VERIFIED-HW 2026-10-15` |
| 5 | Read `DF28` (u32). Continue only if it is at most 3, and write the same 4 bytes back | `CODE`; accepted `VERIFIED-HW 2026-10-15`; the value limit is `HYPOTHESIS` |
| 6 | Write `D226` = 0 and `D227` = 0; send `0x9054` and `0x9055` with param `0x10000001`, `0x9050`; read `D22B`; send `0x9053(0, 30000)` | `CITED fuji-bridge (MIT)`, `CITED libfuji (MIT)`; `VERIFIED-HW 2026-10-15` (first connection) |
| 7 | Property-write busy (`0x2019`): retry up to 5 times, 100 ms apart | `CODE` |
| 8 | Originals: `D226` = 2 for the whole import, back to 0 at the end. Resized copies: `D22E` = rate, then `D226` = 1 | `CITED libfuji (MIT)`; `CODE`. Seven full-size JPEGs downloaded over Wi-Fi on 2026-10-16 via `--last 7` (section 5.6); other import paths remain unqualified |
| 9 | Real sizes: `D227` = 1 makes ObjectInfo report real sizes instead of a placeholder of about 100 KB; reset to 0 at the end | `CITED libfuji (MIT)`; `CODE` |

Do not confuse layers: `0x2019` is the PTP "device busy" response. A different number that FUJIFILM's app treats as
"busy" internally is an app-level status, not something the camera sends (`HYPOTHESIS`).

### 5.5 Listing photos, and the DateCreated placeholder

**Handles.** Read count `D620` and handle list `D621` (`u32 n` then `n × u32`). If the list is unavailable or
malformed, fall back to `GetObjectHandles`; never assume handles are `1…n` (`CITED libfuji (MIT)`; `CODE`). Handles
follow shooting order (`CITED fuji-bridge (MIT)`). A full list of more than a thousand handles came back, and the
highest handles were the newest files (`VERIFIED-HW 2026-10-15`). One handle per frame number was listed
(`VERIFIED-HW 2026-10-15`), so whether RAW files of RAW+JPEG frames are offered over Wi-Fi is unknown.

**Describing a file.** The fast path asks object properties with `GetObjectPropValue` (`0x9803`): ObjectSize
`DC04`, ObjectFileName `DC07`, DateCreated `DC08` (`CITED fuji-bridge (MIT)`, X100VI fw 1.32). The fallback is
`GetObjectInfo` in FUJIFILM's Wi-Fi variant: compressed size is the unaligned u32 at offset 13, the filename a PTP
string at offset 52 (`CITED libfuji (MIT)`).

**Finding: DateCreated is a placeholder.** On fw 1.10 over Wi-Fi:

| Observation | Evidence |
|---|---|
| `DateCreated` (`DC08`) returned the string `"2"` for every object | `VERIFIED-HW 2026-10-15` |
| Each object-property read took about 0.23–0.25 s (fuji-bridge reported about 10 ms on fw 1.32) | `VERIFIED-HW 2026-10-15`; `CITED fuji-bridge (MIT)` for the comparison |
| A newest-first walk that stopped at "older than the requested day" never saw a date, so it never stopped. 737 objects × 3 reads took about 510 s before the socket timed out | `VERIFIED-HW 2026-10-15` |

**Consequence: read each file's own EXIF, or request the newest files.** The date-filtered path below is `CODE`;
the `--last 7` path alone completed on hardware (`VERIFIED-HW 2026-10-16`):

1. Ask `DateCreated` once. If it does not parse as a date, stop asking.
2. For each file walked, read its capture time from its own EXIF with one `GetPartialObject`: the first 64 KiB of a
   JPEG, or the RAF header and then 64 KiB of the embedded JPEG it points to.
3. Walk newest first. Stop after 8 consecutive files older than the requested day, or after 8 consecutive files
   without a readable date.
4. Or skip dates entirely with `--last N`: take only the newest N handles, without date probing.
5. Expected listing cost for seven new photos using dates: roughly 15 objects × (2 property reads + 1 EXIF read), 10–20 s
   (`HYPOTHESIS`, not measured).

### 5.6 Downloading

| Rule | Detail | Evidence |
|---|---|---|
| Partial reads | `GetPartialObject` (`0x101B`: handle, offset, length) in 1 MiB windows | `CITED fuji-bridge (MIT)`; `CODE` |
| Alignment | Re-align the next offset down to a multiple of 512; unaligned reads were about 40 times slower | `CITED fuji-bridge (MIT)` (X100VI fw 1.32) |
| End of file | An empty window, or the same short answer at the same offset twice, ends the file; the camera may keep announcing the original's length for a resized copy | `CITED fuji-bridge (MIT)` |
| Size check | When an original was requested and its length is trusted, a shorter result is an error, not a complete file | `CODE` |
| Prime the handle | Send `GetObjectInfo` before `GetThumb` (`0x100A`) or `GetPartialObject` for that handle. Without it, both calls hung on the tested X100VI | `CITED libfuji (MIT)`; `CODE`; `VERIFIED-HW 2026-10-16` |
| Chunk hint | Property `D235` suggests a preferred chunk size | `HYPOTHESIS` |

With the handle primed and date probing skipped, `import-wifi --last 7` saved seven full-size JPEGs (about 37 MB in
21 s). Every file decoded and its length matched the camera's listing (`VERIFIED-HW 2026-10-16`). This does not
establish RAW delivery, date-filtered import, phone/Photos behavior or reliable reconnection after a failed session.

### 5.7 Teardown, keepalive and reconnection

- Close: `CloseSession`, then the 8 bytes `08 00 00 00 FF FF FF FF`, then close the socket (`CITED libfuji (MIT)`;
  `CODE`).
- Idle keepalive: one `GetDevicePropValue D212` after 3 s idle, never overlapping a real request (`CODE`).
- Our deadlines: 8 s connect, 10 s per answer, 30 s per transfer window (`CODE`). Others use 2.5–3 s socket timeouts
  (`CITED libgphoto2 (LGPL-2.1)`, `CITED libfuji (MIT)`).
- **Reconnecting inside one Bluetooth wake failed:** after the socket dropped and the computer re-joined, the camera
  answered `0x9054`/`0x9055` with `0x2009` (InvalidObjectHandle) and never answered `0x9050`
  (`VERIFIED-HW 2026-10-15`). Starting over with a fresh Bluetooth wake is the suspected remedy (`HYPOTHESIS`).

### 5.8 Remote shooting and live view (not tested here)

- Client state `DF01` = 5 (remote), version echo `DF24`, then `InitiateOpenCapture` and the event and live-view
  sockets (`CITED libfuji (MIT)`, `CITED libgphoto2 (LGPL-2.1)`).
- Live view on 55742: u32 total length, a short header, then JPEG data from `FF D8` (`CITED libfuji (MIT)`).
- Aperture, shutter and exposure compensation are relative steps (`0x902D`, `0x902C`, `0x902E`; param 1 up, 0 down)
  in the older remote protocol (`CITED fuji-cam-wifi-tool (Unlicense)`).
- No open project reads or writes the slot block (`D18C`–`D1A4`) over Wi-Fi; libgphoto2's Wi-Fi property list has
  none of them (`CITED libgphoto2 (LGPL-2.1)`). Weak evidence that slots are USB-only.
- Over USB, the Wi-Fi-only properties (`D212`, `DF00`–`DF28` and others) answer `0x200A` on fw 1.32
  (`CITED fuji-bridge (MIT)`).

---

## 6. More than one body

**Rule: never apply the X100VI fw 1.10 offsets, codes or checksum model to another model or firmware.** Our tools
refuse anything that is not exactly an X100VI on 1.10, for USB writes and for the settings-file decoder (`CODE`).

**Bluetooth table lineage** (`CITED fffw (MIT)`; fffw names tables by a hash of their contents):

| Table | Seen on | Change |
|---|---|---|
| `5dcb7a` | X100V 1.10, X-T4 1.01 (pre-2023 firmware) | No file-transfer service: no Bluetooth backup or restore |
| `efaafa` | 2023 app-era firmware (X100V 3.00, X-T4 2.00, …) | Adds the file service and the backup/restore request and state characteristics |
| `76ab62` | X100VI 1.11, X-T5 3.01, X-S20 2.01, X-T50 1.01 | Adds standby/remote-boot items and identity characteristics |
| `ad14d4` | X100VI 1.31, X-T5 4.30, X-S20 3.30, X-T50 1.31 | Secure profile: new pairing service, passphrase and identification number |
| `b3fbfe` | X-E5 1.10 | Adds `8b5ecf55` (connected-app information) |
| `a1f282` | GFX100RF 1.10 | Adds image-resize rate and IPTC items |

- The file-chunk, file-information, restore-request and restore-state characteristics are identical (flags and
  lengths) in every sampled table from `efaafa` on (`CITED fffw (MIT)`). That says nothing about whether each body
  accepts an edited file.
- Firmware that moved to the secure profile, per FUJIFILM's release notes (`CITED FUJIFILM firmware release notes`):
  X100VI 1.30, X-T5 4.30, X-S20 3.30, X-T50 1.30, X-M5 1.20 (July 2025); X-E5 1.10 (August 2025); X-H2 5.30 and
  X-H2S 7.30 (December 2025). X-Trans IV bodies received no such update.

**Settings-file families:**

| Body | Size | Slot records | Name | Checksum | Evidence |
|---|---|---|---|---|---|
| X100VI fw 1.10 | 70,524 B | last seven 0x400 blocks | +`0x1E5` | u32 at `0x108` (section 4.6) | `VERIFIED-HW 2026-10-09` |
| X-T5 | (helios's files) | last seven 0x400 blocks | +`0x1CF` | low u16 at `0xE8`, constant `0xF936`, lens block excluded | `CITED helios (MIT)` |
| X-H1 sample | 5,628 B | seven, 0x100 apart at `0xF00` | none stored | not solved | `CITED vcam (LGPL-2.1)` sample, our analysis |
| GFX100S sample | 13,948 B | seven, 0x400 apart near `0x1E00` | none stored | field near `0xD4` | `CITED vcam (LGPL-2.1)` sample, our analysis |
| X-T3 (Bluetooth capture) | 33,404 B | unknown | unknown | unknown | `CITED libfuji (MIT)` |

- The X100VI's film-simulation file codes differ from the X-T5's for Reala Ace and the Acros filters
  (`VERIFIED-HW 2026-10-09` against `CITED helios (MIT)`).
- Slot counts differ: C1–C7 on most bodies, C1–C4 on the X-S20, X-M5 and X-S10 (`CITED FUJIFILM owner's manuals`).
- USB slot properties work on the X-H2 and X-T5 and fail on the X-Pro3 (`CITED fujifilm-ptp-recipes (CC BY 4.0
  docs)`). On X-T3-era bodies the WB shift is stored per white-balance mode rather than per slot
  (`CITED fujifilm-ptp-recipes (CC BY 4.0 docs)`).

**Identity across transports** (one body, `VERIFIED-HW 2026-10-13`):

- Over Bluetooth, the standard Model Number String reads an internal code (`FF230003`), not `X100VI`.
- The serial-number characteristics do not match the USB serial. FUJIFILM's "Y number" characteristic does: it equals
  the serial string in USB `GetDeviceInfo`. Use that, not the model or serial strings, to confirm that a Bluetooth
  peer and a USB device are the same body.
- The settings-file identity string differs by one character between transports (section 4.5). Compare files from
  the same transport, or ignore `0x47`.

**Several clients, several bodies:**

- Each body keeps its own registration; store keys per body, keyed by the advert tag (`CODE`).
- On basic firmware, whether a second registered client displaces the first is untested (`HYPOTHESIS`).
- When a body moves from basic to secure firmware, its stored key stops working and its advert format changes; pair
  again (`HYPOTHESIS` from the release notes' description of the change).

---

## 7. What is not known

As of 2026-10-16, on the X100VI fw 1.10 unless stated.

**Writing through the settings file**

- The full validation rules for edited settings files (checksum, model, serial, firmware, name budget) and how a
  refusal shows up. One C7 modification was accepted over Bluetooth; an edited USB upload remains untested.
- Whether the experimental C7 Bluetooth modification survives a power cycle. Its name appeared in the menu during
  the session, but the planned restart check was not performed.
- Whether a USB `SendObject` restore works on the X100VI at all.
- The checksum: exact excluded ranges, whether `K` depends on the body or firmware, and the meaning of the two volatile
  spans.
- The meaning of global bytes `0xEC`, `0xF0`, `0xF1` and `0x8D9`, which changed with manual menu edits.
- Why the header identity string is one byte shorter over Bluetooth.
- The file layout on secure firmware (1.30 and later) and on factory-only firmware.
- Settings-file codes for 13 of the 20 film simulations were observed by the 2026-10-13 mapping run but are not
  promoted; USB property writes cover all 20.
- Confirmed file codes for most white-balance modes, Color outside −1…+3 and NR other than −4; and every per-slot
  non-look field (AF, self-timer, AUTO ISO, RAW compression, HEIF).
- The second u16 in transaction-state notifications during an upload.

**USB properties**

- Whether DR Auto can be written into a slot, and as `0` or `0xFFFF`.
- Whether D-Range Priority ≠ 0 locks DR and tones on the X100VI as on the X-H2.
- Mono toning (`D193`/`D194`) on the X100VI.
- Whether colour-only values written under a monochrome simulation take effect when the slot later switches to a
  colour simulation (they are accepted; `D19F` is refused).
- Whether `GetDevicePropDesc` is a stub on the X100VI as on the X-T5.
- Whether moving `D18C` ever changes the shooting slot.
- How AUTO UPDATE CUSTOM SETTING interacts with property writes on the X100VI.
- The live codes other than `D001`, whether live changes persist, and whether `D34C` recalls a slot.
- Linux and Windows hosts; the iPhone USB path (ImageCaptureCore) on fw 1.10.

**Bluetooth**

- Whether registering another client displaces an existing one.
- The secure-profile flow on an X100VI (we have only cited sources).
- Why one backup arrived without a ready notification and with a bad transport sum.
- Whether a USB connection is really what makes backup state and Wi-Fi launch report busy (consistent on 2026-10-13 and 2026-10-16, not isolated from other causes).

**Wi-Fi**

- Whether RAW files are offered over Wi-Fi for RAW+JPEG frames.
- Date-filtered Wi-Fi import, larger/mixed-format transfers and repeatability beyond the seven full-size JPEGs
  downloaded using `--last 7` on 2026-10-16.
- Why gallery setup failed after a reconnect inside one Bluetooth wake.
- Whether the DateCreated placeholder is specific to fw 1.10, to Wi-Fi, or to this card.
- Typical `DF28` values on fw 1.10, and the meaning of `D22B`.
- Behavior on secure firmware (hidden SSID, WPA2).

---

## 8. Sources

Open-source projects (license as stated by each project):

| Key | Project | License | Used for |
|---|---|---|---|
| FilmKit | eggricesoy/filmkit | MIT | USB slot properties on the X100VI, NR table, 100 ms settle |
| fujifilm-ptp-recipes | ILFforever/fujifilm-ptp-recipes | Docs CC BY 4.0, code MIT | Slot and live property tables, gating, X-H2 bench results, capability tables |
| ctl0v0 | ctl0v0/omarchy-fujifilm-recipes | MIT | X100VI fw 1.32 write order, 20 ms gap, 25-character names, DR Auto read-back |
| AlPeFe | AlPeFe/fuji-ptp-android, AlPeFe/fuji-ptp-core | MIT / no license stated | Name-first writes; empty slots read `0xFFFF` |
| helios | KyleOndy/dotfiles, `nix/pkgs/helios` | MIT | X-T5 settings-file format, checksum, USB restore, commit behavior |
| libfuji | petabyt/libfuji | MIT | PTP/IP framing, gallery and remote setup, Bluetooth backup capture, USB mode values |
| fuji-bridge | Th0rgal/fuji-bridge | MIT | X100VI fw 1.31/1.32 Bluetooth, Wi-Fi and import behavior |
| libgphoto2 | gphoto/libgphoto2 | LGPL-2.1 | USB IDs, property catalogue, grain read-backs, PTP/IP timing |
| vcam | petabyt/vcam | LGPL-2.1 | Camera-side PTP/IP emulation, sample settings files |
| fffw | tiredboffin/fffw | MIT | GATT tables per model and firmware |
| furble | gkoh/furble | MIT | Bluetooth adverts, pairing, shutter, time and location |
| fuji-cli | po4yka/fuji-cli | MIT | X-T5 USB audits, macOS daemon behavior, descriptor stubs |
| fuji-cam-wifi-tool | hkr/fuji-cam-wifi-tool | Unlicense | Older Wi-Fi remote protocol |
| grawji | p5k369/grawji | GPL-3.0 | Camera lock-out while connected |
| fuji-ptp-notes | Junsudo/fuji-ptp-notes | No license stated | Sticky edit cursor, ImageCaptureCore restrictions |

FUJIFILM public documentation: X100VI owner's manual (connection modes, pairing menus), owner's manuals of other
bodies (slot counts), firmware release notes and download pages (secure-profile changes), software compatibility
charts.

## Appendix A. Response codes seen or relied on

| Code | Standard name | Where it shows up |
|---|---|---|
| `0x2001` | OK | Success. Not proof a property value landed (section 2.7) |
| `0x2002` | GeneralError | `GetDevicePropDesc` stub (X-T5, X-H2) |
| `0x2006` | ParameterNotSupported | X-T5 `OpenSession` retry with a non-zero transaction id |
| `0x2009` | InvalidObjectHandle | Gallery setup after a Wi-Fi reconnect (`VERIFIED-HW 2026-10-15`) |
| `0x200A` | DevicePropNotSupported | Property absent in this mode or transport (`D307` over USB, `VERIFIED-HW 2026-10-13`) |
| `0x200F` | AccessDenied | X-T5 settings restore refused (bad checksum, unclean session, ObjectInfo size) |
| `0x2019` | DeviceBusy | PTP/IP init fail reason and property writes during mode changes |
| `0x201C` | InvalidDevicePropValue | Property exists but the value or a prerequisite is wrong (gating, section 2.6) |
| `0x201E` | SessionAlreadyOpen | Stale session, typically after the macOS daemon |
| `0xe00002c5` | IOKit exclusive access (not PTP) | macOS claim refused while `ptpcamerad` holds the camera (`VERIFIED-HW 2026-10-15`) |
