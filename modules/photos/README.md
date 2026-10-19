# Work with a photo folder

Prepare labeled contact sheets and previews for Codex/Claude Code; your agent picks your Best, your strongest Series and the day's Sequence; one command validates them and copies the originals into folders. This is a desktop workflow with no iPhone, camera connection, native build or separate AI API account.

## Install and prepare

From the repository root:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r modules/photos/requirements.txt
node scripts/dialin.mjs doctor photos
node scripts/dialin.mjs photos prepare --input /path/to/photos --out .dialin/my-shoot --intent "A quiet travel story" --count 8
```

The direct Python equivalent is `.venv/bin/python modules/photos/cli.py prepare ...`; Node dependencies are optional. On Windows use `.venv\Scripts\python.exe`. The root CLI discovers that environment, or accepts `DIALIN_PYTHON`.

Open `.dialin/my-shoot/REVIEW.md` with your agent. The workspace contains contact sheets, JPEG previews, `review-sheet.json`, `curation-input.json` and a private original-file map. Contact sheets are numbered in recorded capture-time order (camera clocks and time zones are not reconciled), then undated files by folder/name; each tile shows its label, time and ID prefix, never the filename. Capture timestamps come from EXIF when present; a missing timezone stays unknown. No model is called by preparation. All observations begin explicitly unreviewed.

Ask: “Review this shoot. Give me my best 10, the best series of about 5, and the sequence of the day.” The agent looks at the images and fills `review-sheet.json` by contact-sheet label, so nobody copies 64-character IDs by hand. Only these fields change:

```json
"reviewer": "Claude Code",
"best": {"labels": ["12", "4", "18"], "title": "Best", "why": "Strongest single frames"},
"series": [{"title": "Gulls at the pier", "labels": ["3", "4", "5", "7", "9"], "why": "One moment, five beats"}],
"selection": {"labels": ["4", "12", "18"], "order": "input", "title": "Quiet harbor"},
"constraints": {"required": ["18"], "excluded": ["14"], "opener": "4", "closer": null, "allow_same_group": []},
"photos": {"4": {"seen": true, "note": "Boat against the low sun; calm opener.", "group": "harbor", "favorite": false, "file": "…", "captured_at": "…", "preview": "…"}}
```

- **Best**: the strongest single photographs, strongest first. One frame per burst `group`.
- **Series**: one or more sets that work together. A series may keep several frames of one moment.
- **Sequence** (`selection`): the day in order, opener to closer. The photographer's `required`, `opener` and `closer` apply here; `excluded` applies everywhere.

For big shoots the sheet also carries suggestions, never decisions: `moments` (M1, M2, … split where the recorded clock pauses longer than max(3 min, 3× the shoot's median interval), capped at 30 min, separately per time basis; undated photos in `undated`) and `suggested_groups` (B1, B2, … frames taken seconds apart whose tiny preview fingerprints match). Each photo lists its `moment` and `suggested_group`, and tiles read `M3 · B2? · film simulation`. The reviewer copies a suggestion into `group` only after checking it; nothing is grouped or excluded automatically. Exact-byte duplicates are still handled separately.

## Check focus before choosing a burst keeper

Contact sheets and 1600-pixel previews are useful for composition and expression, but they are not a 100% focus check. Before confidently preferring a burst frame for focus, the agent must inspect original-resolution crops of the relevant eye/subject in **every candidate**, including rejected alternates. The agent chooses regions; there is no automatic face/eye detection, optical sharpness score or automatic winner.

Save a regions file, for example `.dialin/my-shoot/regions-b1.json`:

```json
{"3": [0.50, 0.35], "4": [0.53, 0.36], "5": [0.56, 0.37]}
```

Each label maps to a normalized `[x, y]` center in the **EXIF-oriented** image: `[0,0]` is top left and `[1,1]` bottom right. Choose a different center when the subject moves. Then run:

```sh
node scripts/dialin.mjs photos crops --workspace .dialin/my-shoot --regions .dialin/my-shoot/regions-b1.json --size 512 --out .dialin/my-shoot/focus-b1
```

The new folder contains one labeled PNG per candidate, `crops.json` and viewing instructions. The command fully decodes the original, applies EXIF orientation and sRGB color conversion, and extracts the region **without spatial resizing**. Each crop pixel corresponds to one source pixel; a separate caption shows the photo label, identity prefix and source coordinates. `--size` is 128–768 source pixels (default 512); edges are clamped and small originals are never enlarged. A packet accepts up to 20 candidates; use multiple packets for a longer burst. Existing packets and originals are never overwritten. Source EXIF is omitted from crops.

Open each PNG individually with the host agent's image tool at original/native resolution. If the viewer downsizes it, request a smaller region; a scaled montage is not the focus evidence. Confirm that each region actually contains the intended subject. Consider focus alongside expression, motion and the photographer's intention. If the evidence is ambiguous, preserve an alternate and say so rather than asserting a sharpest frame.

After inspection, add a comparison to `review-sheet.json` (copy the `packet` reference and actual SHA-256 from the command output):

```json
"focus_checks": [{
  "group": "gull",
  "keeper": "4",
  "packets": [{"file": "focus-b1/crops.json", "sha256": "COPY_THE_RETURNED_HASH"}],
  "seen": ["3", "4", "5"],
  "note": "The eye detail is clearer in 4 than 3; 5 has a similar eye but a less useful wing position."
}]
```

All three photos must share the reviewer-confirmed `group: "gull"` and be marked `seen: true`. The comparison must cover every member of that group; keep additional packet references when needed. `finish` and `apply-review` reject stale packet hashes, altered crop files, wrong source/label/workspace identities, missing candidates and changed originals. `finish` also rejects a Best pick that contradicts the recorded keeper. Regenerate and inspect a new packet when evidence changes; don't merely update a hash to bypass a stale-record error.

These are **reviewer-reported comparisons**, not proof that a person or agent viewed an image or that a focus judgment is correct. The tools do not judge pixels. Ordinary selections and older sheets remain usable without `focus_checks`; a Best pick from a confirmed multi-frame group then says **Focus not checked** in the gallery, text summary and result record. Ungrouped single photographs do not need this extra step. Suggested groups alone never create a focus claim.

## Finish the edit

Every listed label must be marked `seen`, the sheet must belong to this workspace, and unknown labels or fields fail. Then one command validates all three and copies the originals:

```sh
node scripts/dialin.mjs photos finish --workspace .dialin/my-shoot --out .dialin/my-shoot-finished-v1
```

Open `index.html` in the new folder for a local results gallery: Best, each Series and the Sequence appear in their final validated order, with the agent's notes and section reasoning. Click a photograph to enlarge its preview, or **Original** to open/download the unchanged copy. The gallery works directly from a file, without a server, account, JavaScript or external assets. Keep the whole output folder together when moving it.

The folder also holds `Best/`, `Series-1-…/`, `Sequence/`, a readable `RESULTS.md`, and `results.json` with copy hashes, gallery details and the validated proposals. `gallery-previews/` contains one JPEG per unique selected photograph, reused across edits, at most 1600 pixels on its longest edge and 1.5 MB each. These previews are generated from the verified original copies, oriented, converted to sRGB and stripped of source metadata. The originals retain their original metadata. The command's JSON result includes `gallery` (the `index.html` path) and `gallery_previews` (the unique count).

Each proposal goes through the same validator as `curate`; if any conflicts with your constraints, nothing is written and the error names the labels. A copying or gallery-generation failure removes the incomplete export so a retry can use the same new output path. Existing output folders are never overwritten.

For a single edit, or a selection from another tool, use the separate steps:

```sh
node scripts/dialin.mjs photos apply-review --workspace .dialin/my-shoot --sheet .dialin/my-shoot/review-sheet.json --out .dialin/my-shoot/reviewed.json
node scripts/dialin.mjs curate --input .dialin/my-shoot/reviewed.json --out .dialin/my-shoot/edit.json
node scripts/dialin.mjs photos export --workspace .dialin/my-shoot --selection .dialin/my-shoot/edit.json --out .dialin/selects
```

`apply-review` writes an ordinary `dialin.curation-input/1` manifest for the Sequence with stable IDs and records only the reviewer's own seen/not-seen statement; it does not view or judge images. Other tools can skip it and write that manifest directly (see the curation guide). Curate results carry the contact-sheet `label` beside each ID.

Export copies full originals, in selected order, with numbered filenames and a hash receipt. It refuses changed/missing originals, unknown or duplicate selected IDs, and an existing output directory. EXIF in original copies remains intact. Previews omit source EXIF and convert embedded color profiles to sRGB. Unprofiled images explicitly record an assumed color basis; invalid profiles are reported instead of silently stripped. The tool never modifies, moves or deletes source photos.

Put exports in a new directory outside both the original photo folder and the review workspace, such as `.dialin/selects-v1`. `export.json` records each file's hash and the hash and title of the edit it came from. To compare another edit, copy the sheet to `review-sheet-v2.json`, apply it to `reviewed-v2.json`, validate it to `edit-v2.json`, and export to `.dialin/selects-v2`. Existing proposal files and export folders are preserved. Quote any path containing spaces or other shell characters, for example `--input "Photos/Weekend à Paris"`.

## Looks the camera recorded

A Fujifilm JPEG records the settings it was shot with in its maker note. `prepare` reads them (read-only) into each asset's `fuji_look` in `curation-input.json`, writes a one-line `look` per label in `review-sheet.json` (for example `Classic Chrome · DR200 · grain Weak Small · CC Weak/Off · Daylight R+1 B-1 · H-0.5 S+0.5 C-1 Sh-1 NR-4 Cl0`), and prints the film simulation under each contact-sheet tile. Files without a Fujifilm maker note, or with a damaged one, are prepared as usual and say why no look was recorded. A value outside the known encodings is shown raw (`raw:0x301`), never guessed. These are recorded settings, not a judgement of how the picture looks.

To check a shoot against the looks that were meant to be on the camera:

```sh
node scripts/dialin.mjs photos looks --workspace .dialin/my-shoot --against .dialin/camera-prepared.json
```

`--against` takes a `camera prepare` artifact (`dialin.camera-preparation.v1`) or a plan (`dialin.planner.v1`). Each photo is `exact` (its settings equal a slot's recipe), `differs` (the closest slot with the same film simulation, and every field that differs, for example a highlight changed after recalling the slot), `no_matching_slot`, or `no_look_recorded`; `slots` summarizes each slot. The JPEG does not record which C slot was selected, so matching is by settings: identical recipes in two slots both match. Exposure, ISO and focus are not recipe fields; a dynamic-range difference at an ISO below that setting's minimum is noted. Monochrome looks do not compare color, Color Chrome, FX Blue or WB shift. Without `--against`, the command lists the distinct looks in the shoot. Add `--out looks.json` to write a new file instead of printing.

For a single scene photograph used in planning, `node scripts/dialin.mjs photos scene --input /path/to/scene.jpg --out .dialin/scene.jpg` creates an oriented JPEG within the planner's size limits, strips source metadata and preserves the original. Pass the result to `plan --photo .dialin/scene.jpg`.

## Use from Python

```python
from modules.photos import prepare, crops, finish, apply_review, export_selection

prepare("/path/to/photos", ".dialin/my-shoot", intent="A quiet travel story", count=8)
# For a burst: crops(workspace, regions_json, new_packet_dir), then inspect each PNG.
# The agent visually reviews images and records any focus_checks in review-sheet.json.
finish(".dialin/my-shoot", ".dialin/my-shoot/review-sheet.json", ".dialin/my-shoot-finished-v1")
# Or one edit at a time:
apply_review(".dialin/my-shoot", ".dialin/my-shoot/review-sheet.json", ".dialin/my-shoot/reviewed.json")
# The curation module validates the edit into edit.json.
export_selection(".dialin/my-shoot", ".dialin/my-shoot/edit.json", ".dialin/selects")
```

JPEG and PNG are supported. RAW/HEIF and other formats are reported, never silently interpreted; export copies only the selected JPEG/PNG, not a RAW file beside it. Empty, truncated or corrupt images are reported with a named reason; exact-byte duplicates share an identity and preserve aliases. Near-duplicates and bursts are left to the reviewer, who can group them. Asset IDs are SHA-256 content hashes: they survive renaming and re-preparation, and change if software rewrites the file. Symlinks to files or folders are not followed and appear in the coverage report. Hidden files and folders are ignored. The default 500-photo limit fails explicitly instead of hiding overflow; raise `--limit` up to 5000 or choose a smaller shoot.

To try all of this without your own photographs, see [the synthetic demo shoot](../../examples/photos/README.md).

These are private local workspaces. Source paths, image content and capture metadata belong to the photographer. Keep them out of public Git. Opening previews in Codex/Claude Code uses the host agent's image processing; no separate model provider is invoked by these tools.
