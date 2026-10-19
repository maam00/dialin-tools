# Add your camera

Dial In writes recipes to one body today: the **X100VI on firmware 1.10**. That path was proven on the owner's camera with a supervised write, readback, exact restore and restart check. Every other body and firmware is unsupported for writes, even when it looks similar: slot counts, property codes and value encodings differ between bodies.

That qualification covers the guarded **USB** route on one macOS host. [What works today](CAPABILITIES.md) separates it from the experimental Bluetooth result and the optional Wi-Fi importer. A read-only report cannot qualify any of those write or transfer paths.

## You can use Dial In before your camera is supported

You do not need a supported camera to [plan a shoot with your agent](../modules/planner/README.md), [organize your own recipes](../modules/recipes/README.md), or [review a folder of JPEG/PNG photographs](../modules/photos/README.md). Planning uses the settings Dial In currently represents; it is not a compatibility promise for your body. Photo review needs an agent with image tools, not a camera connection.

For a first look without a camera, photographs or an API key, use Node.js 22.12+ and Python 3.10+:

```sh
npm ci --ignore-scripts
npm run dialin -- demo --out .dialin/camera-contributor-demo
```

Read the generated `SUMMARY.md`. This is a fixture rehearsal, not a camera test or an AI assessment of photographs. Use a new output directory if you run it again. [Contributing](../CONTRIBUTING.md) describes useful fixes that need no camera.

## Help with another body or firmware

An owner of another Fujifilm body, or an X100VI on another firmware, can contribute a **current-slot-only report**. It reads device information and the currently selected edit slot without moving the edit cursor or writing recipe values. The report command has physical evidence on the known X100VI only; another body or host may refuse it or return a partial report. Reporting that result is useful too.

Before testing, search [existing camera reports](https://github.com/maam00/dialin-tools/issues?q=is%3Aissue+label%3A%22camera+report%22) for your exact model and firmware. Add new evidence to a matching report instead of opening a duplicate. A report helps identify differences; it does not make a body supported or commit a maintainer to adding it.

## 1. Set up

```sh
npm ci --ignore-scripts
npm run dialin -- doctor camera
```

Use Node.js 22.12 or later. `doctor` checks local dependencies; it does not contact the camera or prove the host can use USB. The USB driver is an optional package; if the report says it is missing, run `npm ci --include=optional --ignore-scripts`. Native USB availability and permissions depend on the host. Do not bypass a missing driver or change a write guard to obtain a report.

## 2. Make the report

1. Record the exact model and firmware shown in the camera menu, plus your OS/version, processor architecture, Node version and Dial In release or commit. Use `node --version` and, for a Git checkout, `git rev-parse HEAD`. Do not share a serial number or an unredacted system-information screenshot.
2. Turn the camera on and connect one camera with a data cable. In the menu, select **USB RAW CONV./BACKUP RESTORE** if your body offers that mode (menu names vary). This is a user-selected connection mode; the report does not set it. If it is absent, report that rather than guessing another mode.
3. Quit Photos, Image Capture, X RAW Studio and anything else that talks to the camera.
4. Run:

```sh
npm run dialin -- camera report --current-slot-only --out .dialin/reports/my-camera-report.json
```

The command creates the parent folder and refuses to overwrite an existing output. Keep reports under ignored `.dialin/` until reviewed. If macOS reports that the camera cannot be claimed after other apps are closed, the optional `--release-macos-camera-daemon` flag lets this command stop the current user's camera daemon; launchd restarts it. This affects the computer's camera service and is separate from the device report ([details](../modules/camera/README.md#explicit-usb-use-from-the-computer)).

Read the command summary and the JSON's `complete`, `errors`, `slots.notes` and `cursor` fields. A partial report or connection failure is not a successful compatibility test. If no file was produced, report the sanitized error and exact command; do not try a write command to investigate.

**What this command reads:** model, firmware, USB mode, advertised PTP operations/property codes and descriptors, and the current edit slot's setting values (film simulation, grain, white balance, tones and so on, as bytes). An advertised code or descriptor is not proof that Dial In can write it correctly.

**What it never does:** write a recipe, slot name or setting; take or restore a backup; send a file; touch your photos.

**Optional broader report.** Omitting `--current-slot-only` visits other slots by moving the slot *edit cursor* (property D18C). This is not the C bank you shoot with and does not write recipe values, but it is a device operation. The command attempts to return the cursor and reread the first slot; a timeout can leave the cursor's state unknown. Start with the command above. If a maintainer asks for more coverage, review that difference before choosing an all-slot report, and include any cursor-return failure in the issue. Neither mode backs up, restores or transfers photographs.

**What the saved report leaves out:** serial number, Y-number, MAC address, owner name and copyright text. Leave `--include-slot-names` off: names and text values can be personal. The command checks for known serial representations and MAC-like strings and refuses a report when those checks find a match. That check does not replace your review of the file and any error text.

Open the JSON before you share it. It is plain text, not a raw USB dump. Do not attach camera backups, pairing data, raw device logs, private photographs, full EXIF, home-directory paths or credentials. `camera usb backup` files contain a serial number. If you cannot safely share an output, describe the failure without attaching it.

## 3. Open an issue

Open a [Camera report issue](https://github.com/maam00/dialin-tools/issues/new?template=camera_report.yml), or add to a matching report. Include:

- Exact model and camera-menu firmware, OS/version and processor architecture, Node version, and Dial In release/commit.
- The exact command and selected USB mode; whether the macOS daemon flag was used.
- The reviewed report, or a sanitized error if no report was produced. Keep partial/refused results visible rather than describing the body as working.

No public backup or photograph is needed. You can contribute this evidence without writing code.

A report is evidence about reading, not permission to write. Your camera stays unsupported for writes after you share it.

## For maintainers: report → draft profile

```sh
npm run dialin -- camera profile --in .dialin/reports/my-camera-report.json --out .dialin/reports/draft.json
```

The draft contains a `dialin.camera-profile.v1` profile with `write_status: "read_only"`, plus a diff against the verified X100VI 1.10 map: missing or extra slot property codes, byte lengths other than 2, values outside the X100VI encoding (a film simulation code it doesn't know, for example), refused properties and missing operations. Observed values are only what that camera holds today. A current-slot-only report does not establish the body's full slot count or the values in unvisited slots. When a body answers property descriptors, their enums are reported evidence, not qualification of writes.

A reviewed draft can go into `PROFILES` in `modules/camera/profiles.ts` as `read_only`. That does not enable writes: `camera usb apply` still requires a verified profile for the exact model and firmware. An offline `camera prepare` result is not device support or write authorization.

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
