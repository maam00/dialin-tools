# Add your camera

Dial In writes recipes to one body today: the **X100VI on firmware 1.10**. That path was proven on the owner's camera with a supervised write, readback, exact restore and restart check. Every other body and firmware is unsupported for writes, even when it looks similar: slot counts, property codes and value encodings differ between bodies.

That qualification covers the guarded **USB** route on one macOS host. [What works today](CAPABILITIES.md) separates it from the experimental Bluetooth result and the optional Wi-Fi importer. A read-only report cannot qualify any of those write or transfer paths.

If you own another Fujifilm body (X-T5, X-T50, X-E5, X-S20, X100V, X-Pro3, GFX…), a read-only report from it is the most useful first contribution. It takes a few minutes and changes nothing on the camera.

## 1. Set up

```sh
npm ci --ignore-scripts
npm run dialin -- doctor camera
```

`doctor` checks Node and the command runtime. The USB driver is an optional package; if the report says it is missing, run `npm ci --include=optional --ignore-scripts`.

## 2. Make the report

1. Turn the camera on and connect a data cable. In the menu, set CONNECTION SETTING → PC CONNECTION MODE → **USB RAW CONV./BACKUP RESTORE** (names vary a little by body).
2. Quit Photos, Image Capture, X RAW Studio and anything else that talks to the camera.
3. Run:

```sh
npm run dialin -- camera report --out my-camera-report.json
```

On macOS the system camera daemon usually holds the camera. Add `--release-macos-camera-daemon` to let this one command stop it; launchd restarts it ([details](../modules/camera/README.md#explicit-usb-use-from-the-computer)).

You'll see a short summary such as *Your X-T5 4.31 report is ready; nothing on the camera was changed; attach my-camera-report.json to a 'Camera report' issue.*

**What it reads:** model, firmware, USB mode, the PTP operations and property codes the body supports, and the raw values of every custom slot's settings (film simulation, grain, white balance, tones and so on, as bytes).

**What it never does:** write a recipe, slot name or setting; take or restore a backup; send a file; touch your photos.

**The edit cursor.** Reading C2 over USB needs the camera's slot *edit cursor* (property D18C) pointed at C2; there is no other way to read a slot. The cursor tells USB tools which slot they're looking at. It isn't the C bank you shoot with, and moving it writes no recipe value. The report reads the slot the cursor is already on, visits the others, ends back where it started, then reads the first slot again to confirm nothing changed. Every move is listed in the JSON. To avoid moving it at all, add `--current-slot-only`; you'll share one slot instead of all of them.

**What it leaves out:** serial number, Y-number, MAC address, owner name and copyright text. Slot names are included only with `--include-slot-names`, because they can be personal. If the file would contain the camera's serial, the command refuses to write it.

Open the JSON before you share it. It's plain text.

## 3. Open an issue

Open a new issue with the **Camera report** template, attach the file and fill in the body and firmware shown in the camera menu. Don't attach camera backups: `camera usb backup` files contain your serial.

A report is evidence about reading, not permission to write. Your camera stays unsupported for writes after you share it.

## For maintainers: report → draft profile

```sh
npm run dialin -- camera profile --in my-camera-report.json --out draft.json
```

The draft is a `dialin.camera-profile.v1` profile with `write_status: "read_only"`, plus a diff against the verified X100VI 1.10 map: missing or extra slot property codes, byte lengths other than 2, values outside the X100VI encoding (a film simulation code it doesn't know, for example), refused properties and missing operations. Observed values are only what that camera holds today. When a body answers property descriptors, their enums are its own list.

A reviewed draft can go into `PROFILES` in `modules/camera/profiles.ts` as `read_only`. That changes no write behavior: `camera prepare` and `camera usb apply` refuse everything except a verified profile for the exact model and firmware.

Keep the contribution small: attach the reviewed report, describe its model/firmware and host, and add fake-transport coverage for any new slot count or encoding shape. Keep unobserved properties unknown. Do not copy the X100VI write order or mark a reported value as a proven writable value. Link the profile's source to the report issue so another maintainer can inspect the evidence.

## The bar for writes on a new body

A body and firmware become `verified` only after a supervised session on that exact body and firmware:

1. A fresh private backup of all slots, before anything else.
2. A write to one slot, read back property by property.
3. An exact restore of the original slot, after which every slot matches the backup byte for byte.
4. A camera restart, after which the slots read back as expected again.

Record the outcome in `tests/fixtures/camera/<MODEL>-<FIRMWARE>.hardware.json` (outcomes only: no serials, pairing data or raw slot bytes; see the X100VI fixture) and point the profile's `evidence.fixture` at it. The tests reject a verified profile unless its fixture records every check as passed.

This qualification applies to the USB profile and the tested host. It does not unlock Bluetooth, qualify Wi-Fi import or prove full-camera recovery. After review, update [the support summary](CAPABILITIES.md), [the dated validation record](FIRST-RUN-VALIDATION.md) and the component guide together; keep unknown firmware and platforms explicitly unqualified.

**Who runs it:** only the camera's owner, voluntarily, after taking that backup, using a test branch a maintainer prepared for that body. Don't patch the write guard yourself. A failed or partial write can change the camera; the backup is the way back.
