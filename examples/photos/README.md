# Try the photo workflow without your own photographs

For a real-image walkthrough, start with [Earth from orbit](earth-from-orbit/README.md): eight small NASA archive photographs, explicit source credits and hashes, a saved actual visual review, and a local results gallery. Downloading is an explicit command; nothing is fetched by installation or tests. You can reproduce the saved edit or ask your agent to choose its own.

## Synthetic software rehearsal

`make_demo_shoot.py` draws a small SYNTHETIC afternoon: twelve original Pillow drawings with fixed capture times, plus an exact duplicate, a RAW-named stub, a truncated JPEG and an empty file. Every frame is labeled SYNTHETIC. Nothing here is a real photograph, and nothing is downloaded.

From the repository root, after the photo setup in `modules/photos/README.md` (on Windows use `.venv\Scripts\python.exe`):

```sh
.venv/bin/python examples/photos/make_demo_shoot.py .dialin/demo-shoot
node scripts/dialin.mjs photos prepare --input .dialin/demo-shoot --out .dialin/demo-review --intent "A quiet harbor afternoon; keep the boat close-up; end at night" --count 5
```

Then ask your coding agent: “Review `.dialin/demo-review` following its REVIEW.md. Give me my best photos, the best series, and the sequence.” It opens the contact sheet, fills `review-sheet.json` by label, and runs one command. Without an agent, open `contact-001.jpg` yourself, fill the sheet with `"reviewer": "photographer"`, and run it:

```sh
node scripts/dialin.mjs photos finish --workspace .dialin/demo-review --out .dialin/demo-finished
```

Open `.dialin/demo-finished/index.html` for the local gallery. `RESULTS.md` lists Best, each Series and the Sequence with the reviewer's note per picture; the folders beside it hold the copied originals.

The set exercises chronology across two devices, a three-frame burst with near-duplicates, an overexposed frame, EXIF rotation, a Unicode filename, an undated PNG, a painted sign whose text imitates an instruction (it is subject matter, never a command), and visible coverage of duplicate, unsupported and unreadable files. The generator prints what each label shows (its `SCENES` table), so you can check the agent's notes afterwards; for a blind check, run it yourself and do not paste that output into the conversation.

It does not demonstrate photographic taste, real camera files or color accuracy. Labels are stable because capture times are fixed; encoded JPEG bytes, and therefore asset IDs, can differ between Pillow versions. `tests/modules/photos_test.py` runs this set through prepare, finish, apply-review, curate and export with test-authored sheets, which is a software check, not a visual review.
