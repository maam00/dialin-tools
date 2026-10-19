# Changelog

## Unreleased

- Documentation: consistent USB-C, Bluetooth and Wi-Fi connection guides across the README, first-shoot walkthrough, capability table, module/native guides and export templates. Bluetooth settings backup/Wi-Fi setup are distinguished from experimental Bluetooth recipe loading.

- Desktop wireless: explicit `native build`/`status`, `import wifi|usb|folder` with JSON receipts and partial-transfer reporting, and `camera bluetooth` backup/supervised single-slot trials. Unknown import options and invalid ranges now fail before connecting; backups refuse overwrite. Production Bluetooth recipe writes remain gated pending physical acceptance.

- Discovery: a 30-second walkthrough, interactive Anatomy illustration and still/transcript, visible CI/license/release badges, clearer camera contribution instructions and an explanation of the initial public export. Reviewed media has an exact hash-pinned export allowlist; private inputs remain excluded.

## 0.1.0-alpha.2 — 2026-10-19

- Photos: labeled original-resolution crops for agent-directed burst focus comparisons. EXIF-oriented regions preserve source pixel resolution; optional review claims bind all candidates to source and crop hashes. Ordinary Best burst picks without a recorded comparison are marked Focus not checked. No automatic eye detection, sharpness scoring or camera operation.

## 0.1.0-alpha.1 — 2026-10-19

Open-source Fujifilm tools for a terminal, Claude Code or Codex. No package-registry release; run from this repository.

### Tools

- **Planner:** turns a scene description and/or photo into a validated seven-look plan for slots C1–C7. Your coding agent answers a saved request; finalization checks every setting against the camera profile, enforces your constraints (for example "no Classic Chrome" or "monochrome only"), and records which references inspired each look and what changed.
- **Recipes:** Dial In's original guidance (31 setting rules, 20 film-simulation profiles, 10 original directions) plus your own recipe books. No third-party recipes are included.
- **Camera:** offline slot preparation, then an explicit, guarded USB write: backup of all seven slots, write of the named slots only, readback of every property, and a check that untouched slots did not change. A read-only `camera report` helps add other bodies.
- **Import:** any SD-card or OS-import folder; an optional macOS helper (`dialin-cam`) for USB and Wi-Fi import.
- **Photos:** capture-ordered contact sheets grouped into moments, with burst hints and each photo's recorded Fujifilm look. Your agent fills a review sheet by label; `photos finish` validates Best, each Series and the Sequence, copies the originals into folders, and makes an offline browser gallery. `photos looks` compares shot looks with the slots meant to be on the camera.
- **First shoot:** three independent agent entry points and an optional, explicitly downloaded NASA photo example with attributed sources and file checksums. Installation and routine tests remain offline.
- **Support and feedback:** one capability table distinguishes supported operations, experiments and pending checks; an experience-report template captures first-use friction and repeat use.
- **Curation:** a deterministic validator for selections and sequences from any tool.
- **Protocol reference:** USB PTP slot properties, Bluetooth LE settings backup and Wi-Fi wake, and the Wi-Fi PTP/IP session, with an evidence level on every claim.

### Verified on hardware (one X100VI, firmware 1.10, macOS 27)

- USB: write one slot, read every property back, restore the original byte for byte, and the written look survived a power cycle. C1–C6 stayed byte-identical throughout.
- Found and fixed on that camera: Grain Off reads back as 6 or 7 (it was reported as a failed write), and macOS's `ptpcamerad` holds the camera (`--release-macos-camera-daemon` releases it on request).
- Wi-Fi: seven full-size JPEGs downloaded and decoded on October 16. The importer requests object information before file data and skips date probing for `--last N`.
- The look reader matched the recorded settings of those seven JPEGs against the expected profiles; JPEG metadata does not identify a custom-slot number.
- An experimental Bluetooth C7 write was read back and confirmed in the camera menu. Restart persistence and complete recovery remain pending for that trial; production Bluetooth recipe writes stay locked.
- Wi-Fi wake and Bluetooth backup now refuse while a Fujifilm USB device is attached, following busy responses observed with the cable connected.

### Not yet verified

- Complete Bluetooth write/restart/recovery qualification, Wi-Fi interruption recovery and RAW delivery, other camera bodies and firmware, and the camera and photo workflows on Windows.
- Whether the planned looks produce photographs you like: that needs your camera and your judgment.

### Requirements

Node.js 22.12+ and Python 3.10+ (Pillow for photo preparation). The offline suite passes in GitHub Actions on Linux and macOS at those minimum versions and at Node 22 + Python 3.12; Windows has a smoke test only.
