# Fresh-user validation

On 2026-10-15, separate coding-agent sessions tested independent components and their handoffs from isolated source copies. The target experience was a photographer using a coding agent or terminal on a computer. No iPhone build was needed for the desktop workflow.

For the current support summary, see [What works today](CAPABILITIES.md). The dated records below describe the revisions and environments actually exercised; they are not a test receipt for a later release candidate.

## Gallery and release preparation (2026-10-19)

The local gallery, real-photo example and updated support guides were exported through the reviewed positive file list. Two isolated validation copies installed dependencies afresh and passed `npm test`:

| Environment | Offline result |
| --- | --- |
| macOS, Node 25.8.1, Python 3.14.7, Pillow 13.0.0 | 215 Node component tests, 75 Python photo/curation tests, 20 offline photo-example tests, 299 planner tests and 24 exporter tests passed, plus encoding and fake-camera writer checks |
| macOS, Node 22.12.0, Python 3.10.21, Pillow 12.3.0 | Same checks and counts passed |

The exported macOS camera helper also passed 411 tests in 54 suites through the build lock. These are software checks using fake transports and local inputs. No new physical camera operation or live model API call was made. The connected demo completed as a fixture rehearsal: seven supplied looks, offline camera preparation and a five-frame edit from synthetic observations, with zero provider calls.

A host agent actually inspected a contact sheet and all eight individual previews of the [Earth from orbit example](../examples/photos/earth-from-orbit/README.md), then authored three Best choices, a three-picture Series and a five-picture Sequence. The source records, exact image hashes and saved editorial decisions are included; photographs download only on explicit request. A saved-review replay is labeled as replay and does not count as another visual review. Both paths preserved the original input and copied photograph bytes. The example's movable output retains NASA source credits.

An independent agent then followed the published download, preparation, replay and finish instructions from the exported copy on the minimum runtime. All commands succeeded without source edits. It verified the eight pinned source hashes, all eleven copied originals, the exact 3/3/5 selection order, source credits and all forty local gallery references/anchors. The separate two-recipe C2/C7 preparation also succeeded offline with the other slots protected. This was a repeatability check of the saved review, not another photographic judgment or a browser-rendering check.

Gallery tests cover relative asset links after relocation, validated order, hostile text/filenames, preview metadata removal, original hashes and failure cleanup. Automated browser inspection of the local page was blocked by the tool's security policy, so rendered layout, browser download behavior and visual acceptance remain unverified. This preparation pass does not claim new hosted CI, Windows photo-workflow qualification, photographer preference or public publication.

## Actual host-agent trials

| Trial | What was exercised | Result |
| --- | --- | --- |
| Text to a full-day palette | A newly authored rainy-portraits, wet-streets and evening-café brief; saved request; seven new looks; finalization; camera preparation and reinspection | Valid proposal and explicit C1–C7 placements; no device calls |
| Bring an existing book | A separately authored two-recipe book; validation; text search; exact recipe-ID selection into C2/C7; reinspection | Settings and order preserved; all other slots protected; unknown IDs refused |
| Use only one planning component | One-look request using a supplied book | Valid single-look proposal; no forced seven-look workflow |
| Image plus description | Actual image-tool inspection of an archive reference and its prepared JPEG; a hypothetical exhibit/portrait brief; three newly authored looks; finalization and preparation | Valid proposal; embedded image matched the inspected preview; C4–C7 protected; ownership, present location and lighting measurements were not invented |
| Make an edit from photographs | Actual image-tool inspection of eight public NASA archive photographs, using a contact sheet and all individual previews; separate five- and four-image editorial revisions | Both exports preserved exact original bytes and selected order; originals stayed untouched |
| Connect the file contracts | The documented offline demo through planning, camera preparation and curation | Reproducible fixture rehearsal, explicitly distinguished from the real host-agent trials above |

The archive images were temporary test inputs and are not bundled. These trials show that the image and file handoffs work and that an agent can supply reasoning. They do not establish that the proposed recipes produce preferred photographs, or that one person's sequence is objectively best. No external model CLI or paid model API was invoked by the tools. The coding-agent sessions themselves supplied the reasoning and used their own image tools.

## Friction corrected

- Recipe books now hand directly to camera preparation by stable ID and explicit destination slot.
- Output folders are created where appropriate; prior requests and edits cannot be silently replaced.
- Missing photographic reasoning is flagged for revision instead of appearing as a complete plan.
- A supplied image can be a scene or a reference. The prompt follows the photographer's description.
- Photo exports cannot be placed inside the original input tree, and skipped linked folders stay visible.
- Desktop shortcuts route through the same dispatcher. Starting help does not enter an older camera workflow.
- A logged-in external model CLI requires explicit local opt-in, including optional Studio startup checks.
- Public source preparation removes private identities, fixed personal defaults, signed configuration and raw research snapshots while retaining the component implementations.

## Recipe guidance follow-up

A later desk and software pass tested retrieval scenarios, per-look source comparisons and host-agent plans against a private recipe catalog. That catalog is private reference material and is not distributed; the public tools carry only the original guidance, and their tests use an invented fixture catalog. Explicit monochrome/warmth violations and false source claims have regression coverage. These are software and desk-reasoning checks; photographic acceptance remains separate.

## Automated evidence

The public-source validation copy installed Node dependencies into a new directory with a separate npm cache, created a new Python environment and installed the declared photo dependency. Before installation, the doctor correctly reported missing dependencies. Desktop checks, planner tests, release-export tests and the connected demo passed during preparation.

The optional macOS camera helper (`ios/DialInCamera`) was built through the build lock and its Swift suite passed: 411 tests in 54 suites, using fake transports and local software inputs. The Python Bluetooth suite completed 210 tests with five real-backup-dependent checks skipped; the remaining 205 passed after correcting an inconsistent synthetic-name transformation. Optional tests that return early or skip without private fixtures do not establish those private fixture checks.

The observed environment was macOS 27.0.1, Node 25.8.1, Python 3.14.7 with Pillow 12.3.0, and Swift 6.4. Linux/macOS CI configuration is included; a local macOS pass is not a claim that those remote jobs or Windows have run. App signing and iPhone installation were not part of these checks.

## Minimum versions and platforms

The 0.1.0 source candidate was copied into fresh directories and run with `npm ci --ignore-scripts`, a new `.venv` with the declared Pillow range, and `npm test` (desktop checks, planner, exporter, encoding and writer checks), plus the connected demo:

| Environment | Result |
| --- | --- |
| macOS 27.0.1 arm64, Node 25.8.1, Python 3.14.7 | All passed: 190 Node module tests, 59 Python tests, 299 planner tests, 20 exporter tests; demo completed; `npm audit` found 0 vulnerabilities |
| macOS 27.0.1 arm64, official Node 22.12.0 build, Python 3.10.21 | All passed with the same counts |
| GitHub Actions: ubuntu-latest and macos-latest, each at Node 22.12.0 + Python 3.10 and Node 22 + Python 3.12 | All four jobs passed `npm test` and the demo on the 0.1.0 source |
| GitHub Actions: windows-latest smoke job | Passed: dispatcher, setup checks, portable tests and demo |

Windows runs only the smoke job; the full suite, camera and photo workflows have not run there. Some module and exporter tests skip POSIX-only checks on Windows.

## Physical camera session (2026-10-15)

One X100VI on firmware 1.10, connected by USB to a Mac running macOS 27.0.1, with its owner present:

| Check | Result |
| --- | --- |
| `camera usb info` | Failed until macOS's `ptpcamerad` released the camera; `killall` did not release it. Fixed with the opt-in `--release-macos-camera-daemon`, then passed |
| Write one original recipe to C7 | The camera stored every value, but Grain Off read back as 7 rather than the 1 written, so the first run reported `not_verified`. After the fix (Off reads back as 1, 6 or 7): `verified_current_session`, C1–C6 byte-identical |
| Restore the original C7 recipe | `verified_current_session`; all seven slots byte-identical to the backup taken before the session |
| Power cycle | The written C7 look and the other six slots were byte-identical after the camera was switched off and on |
| Wi-Fi import | Bluetooth woke the camera's Wi-Fi, the Mac joined it and the photo session opened. The listing then timed out on a 1,336-photo card before any download. This session established no completed transfer; the [next day's wireless session](#wireless-session-2026-10-16) did |

## Physical camera session (2026-10-16)

The same X100VI (firmware 1.10), on USB to the same Mac, unattended. The commands ran from a fresh install of the exact 0.1.0 source candidate, not the development checkout:

| Check | Result |
| --- | --- |
| `camera usb info --release-macos-camera-daemon` | Passed; the daemon notice printed once |
| `camera report` | Passed; it wrote nothing, the edit cursor ended where it started, and the file had no serial or slot names |
| `camera usb backup` | Passed; all seven slots went to a private file |
| Write a different look to C7, then write the previous look back | Both returned `verified_current_session` with C1–C6 protected; afterwards C1–C6 and every C7 property matched the session-start backup, except Grain Off read back as Off-Small rather than Off-Large (the documented equivalence) |
| Wi-Fi wake with the USB cable attached | Refused: every function-launch answer was busy, six of six over two runs. Wi-Fi import and Bluetooth backup now refuse at once while a Fujifilm USB device is attached and say to unplug the cable |

## Wireless session (2026-10-16)

Later that day, the owner was present with the same X100VI 1.10, the same macOS host and the USB cable removed. This session exercised later development fixes; the earlier source candidate above did not contain them.

| Check | Result |
| --- | --- |
| Full-size Wi-Fi JPEG import | After adding `GetObjectInfo` before a handle's thumbnail or partial reads and making `--last N` skip date probing, `import-wifi --last 7` saved seven full-size JPEGs, about 37 MB in 21 seconds. Every file decoded and its size matched the camera's listing |
| Fujifilm look reader on the imported files | Seven of seven recorded looks matched the known C-slot profiles used for those photographs (four distinct slots). This checks this sample of settings; it does not identify every future photo's slot or qualify every maker-note value |
| Experimental Bluetooth C7 write | The lab trial returned `verified` after about 23 seconds; the owner confirmed the new slot name in the camera menu. The trial recorded C1–C6 unchanged. Production `BLESlotWriter.wirelessWritesValidated` stayed false |
| Bluetooth restart persistence | **Not performed.** The session stopped before the trial's power-cycle check. No full-camera recovery or completed multi-trial acceptance sequence is claimed |

The JPEG transfer verifies that particular newest-files route. Date-filtered import, RAF delivery, reconnect/recovery behavior, secure-profile firmware and an integrated phone/Photos handoff remain separate checks. See [protocol download details](FUJIFILM-PROTOCOL.md#56-downloading) and [Bluetooth trial limits](FUJIFILM-PROTOCOL.md#37-settings-restore-upload).

## Remaining physical and quality checks

Bluetooth modified-settings writes remain locked in production: one experimental current-session result is not completed physical acceptance. Its restart check is pending. Other bodies and firmware, Linux/Windows hardware, full-camera recovery, Wi-Fi paths beyond the observed newest-JPEG transfer, broader look-reader coverage, API-provider execution, photographer preference and comparative recipe quality remain unverified. A prepared file or fake transport cannot qualify those operations.

The private preparation receipts pin source snapshots, test outputs and export hashes. Re-run [the release checks](PUBLIC-RELEASE.md) against the exact source candidate before publication; do not publish private receipts, input images or the development checkout's history.
