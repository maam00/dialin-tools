# Changelog

## 0.1.0 — first public release (in preparation)

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
