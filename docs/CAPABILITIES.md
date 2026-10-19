# What works today

Choose the smallest route that solves your task. Planning and photo review work without a camera. Start with `node scripts/dialin.mjs doctor <component>`; it checks local dependencies, not a device or provider.

This is the support summary. The linked records distinguish software checks, coding-agent trials, physical observations and photographic judgment. Hardware evidence through **2026-10-16** comes from **one X100VI on firmware 1.10 and one macOS 27 Mac**. It does not qualify another body, firmware or host.

| Task | Available route | Evidence and limits |
| --- | --- | --- |
| Plan looks | [Planner](../modules/planner/README.md), with your coding agent or optional explicit API mode | [Agent trials](FIRST-RUN-VALIDATION.md#actual-host-agent-trials) completed text and image briefs, saved answers and validation. Valid settings do not establish preferred photographs. No separate API key is needed for host-agent mode; the trials do not establish live API-provider execution. |
| Bring existing recipes | [Recipes](../modules/recipes/README.md) → offline [camera preparation](../modules/camera/README.md#start-offline) | [Book handoff trial](FIRST-RUN-VALIDATION.md#actual-host-agent-trials) preserved selected recipe IDs, destination order and protected slots. Preparation sends nothing to a camera and cannot authorize a write. |
| Write selected camera slots over USB | [Camera](../modules/camera/README.md#explicit-usb-use-from-the-computer): **X100VI 1.10 only** | [Supervised USB session](FIRST-RUN-VALIDATION.md#physical-camera-session-2026-10-15) and [public outcome fixture](../tests/fixtures/camera/X100VI-1.10.hardware.json): backup, C7 write/readback, exact restore and written-look restart persistence. The wrapper checks fresh identity, saves all seven slots and checks protected slots. Linux/Windows hardware and full-camera recovery are unqualified. |
| Write recipes over Bluetooth | **Production writes blocked** | [Experimental wireless session](FIRST-RUN-VALIDATION.md#wireless-session-2026-10-16): one C7 modification returned verified and the owner saw the name in the menu; the power-cycle check was **not performed**. `BLESlotWriter.wirelessWritesValidated` remains false. The lab result is not production support. |
| Retrieve photographs | SD-card/OS copy, or the optional [macOS import helper](../modules/import/README.md#optional-macos-helper) | [Wireless session](FIRST-RUN-VALIDATION.md#wireless-session-2026-10-16): `import-wifi --last 7` saved seven full-size, decodable JPEGs matching the camera's listed sizes. macOS 26+ and Swift 6.2+ are needed to build the helper. This does not qualify Wi-Fi RAF delivery, date-filtered import, reconnect recovery, secure firmware or the phone/Photos path. |
| Review a local shoot | [Photos](../modules/photos/README.md), JPEG/PNG folders and an agent with image tools | [Actual image-review trials](FIRST-RUN-VALIDATION.md#actual-host-agent-trials) produced validated selections with exact-byte exports. The agent must open images; fixture and metadata-only runs are not visual review. RAW/HEIF are reported as unsupported. |
| Read the recorded Fujifilm look | [Photos](../modules/photos/README.md) | [Seven real-file checks](FIRST-RUN-VALIDATION.md#wireless-session-2026-10-16) matched the known C-slot profiles. That small sample does not cover every setting or prove slot identity from EXIF alone. |
| Validate an existing selection | [Curation](../modules/curation/README.md), Python standard library | [Offline suite and handoff trials](FIRST-RUN-VALIDATION.md#automated-evidence) cover selection identities, constraints and sequence handoffs. Structural validity does not judge photographic quality. |
| Help add a camera | Read-only [`camera report`](ADD-YOUR-CAMERA.md) | [Report trial](FIRST-RUN-VALIDATION.md#physical-camera-session-2026-10-16) exercised the known X100VI; fake transports cover other report shapes. Unknown bodies stay unsupported for writes. A report can lead to a read-only profile; [qualification](ADD-YOUR-CAMERA.md#the-bar-for-writes-on-a-new-body) is separate. |

## Computer support

The [recorded source-candidate checks](FIRST-RUN-VALIDATION.md#minimum-versions-and-platforms) passed the full offline suite on Linux and macOS at Node 22.12.0 + Python 3.10 and Node 22 + Python 3.12. Windows passed the narrower smoke lane (dispatcher, setup checks, portable tests and fixture demo); the complete photo and camera workflows are unqualified there. The [workflow configuration](../.github/workflows/desktop.yml) describes what CI runs, not proof that every new revision has passed.

The native macOS helper is optional. No iPhone build is required for the desktop workflow. A passed `doctor`, a simulation or a previous release's CI result is not physical-device evidence or validation of a new release candidate.

## Before extending support

The executable USB write list is [`modules/camera/profiles.ts`](../modules/camera/profiles.ts); the production Bluetooth gate is in [`BLESlotWriter.swift`](../ios/DialInCamera/Sources/DialInCamera/SlotWrite/BLESlotWriter.swift). Documentation does not override either. See the [protocol reference](FUJIFILM-PROTOCOL.md#7-what-is-not-known) for unresolved questions and [fresh-user validation](FIRST-RUN-VALIDATION.md#remaining-physical-and-quality-checks) for unfinished acceptance checks.

Keep private backups, pairing identities, photographs and raw metadata with their owner. Publish only reviewed, sanitized outcomes. New evidence should update this summary, the relevant validation section and the component guide together.
