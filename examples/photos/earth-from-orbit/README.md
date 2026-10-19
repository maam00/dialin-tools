# Earth from orbit: a real photo example

Eight NASA archive photographs make a small, reproducible exercise in choosing a Best set, a Series and a Sequence. They total **759,716 bytes** and show water, sand, mountains and the atmosphere. They come from different dates and expeditions; this is an editorial collection, not one shoot or a chronological flight record.

On 2026-10-19, Codex opened the prepared contact sheet and **all eight individual previews**, then authored the notes and decisions in [saved-review.json](saved-review.json). This is an actual visual review by the host agent. The saved result is one subjective edit; no photographer preference study, camera operation, image generation or separate model API was involved.

## Download and prepare

From the repository root, run the read-only setup check. If it names a missing dependency, follow the [photo setup](../../../modules/photos/README.md#install-and-prepare).

```sh
node scripts/dialin.mjs doctor photos
python3 examples/photos/fetch_example.py --out .dialin/earth
node scripts/dialin.mjs photos prepare --input .dialin/earth/photos --out .dialin/earth-review --intent "Build a five-image visual journey from daylight to night: water, land, mountains, the horizon and city lights. Give me the three strongest individual images and a three-image series about the boundary between Earth and sky. This is an editorial sequence of archive images from different dates, not a chronological flight record." --count 5
```

On Windows, use `python` instead of `python3` if that is your installed interpreter. Download and replay use only Python's standard library. The photo commands and example finishing step also need Pillow. The finish commands below use `.venv/bin/python` (Windows: `.venv\Scripts\python.exe`), matching the normal photo setup. If you configured another interpreter through `DIALIN_PYTHON`, invoke `finish_example.py` with that interpreter instead. Node dependencies are not needed for this route.

The download command makes eight explicit HTTPS requests to NASA's image archive. It verifies each file's exact byte count and SHA-256 from [sources.json](sources.json), writes `photos/` plus `SOURCES.json`, and refuses an existing destination. A failed or changed download removes only the new incomplete folder. Nothing downloads during installation, the fixture demo, tests or source export. If NASA changes an image, verification stops instead of silently replacing the reviewed source.

Preparation should report eight photographs, no duplicates, no unreadable or skipped files, and `visual_review: NOT_RUN`. These medium JPEGs contain no EXIF. Their dates and Fujifilm settings are therefore unknown to the photo workspace. Labels follow filenames, not the archive's historical chronology. The previews use an explicitly assumed sRGB basis.

## Choose your route

**Make your own edit with an agent.** Paste:

> Review `.dialin/earth-review` following its REVIEW.md and saved brief. Open the contact sheet and all eight previews. Give me three Best photographs, a three-image Series and a five-image Sequence. Use your own visual judgment; don't read the saved example review first. Explain useful alternatives, then use `examples/photos/finish_example.py` to finish into `.dialin/earth-my-results` with source credits and show me index.html.

The agent fills the existing review sheet and runs:

```sh
.venv/bin/python examples/photos/finish_example.py --workspace .dialin/earth-review --out .dialin/earth-my-results
```

**Or reproduce the saved example immediately.** On the untouched prepared workspace:

```sh
python3 examples/photos/replay_review.py --workspace .dialin/earth-review --out .dialin/earth-review/saved-review.json
.venv/bin/python examples/photos/finish_example.py --workspace .dialin/earth-review --sheet .dialin/earth-review/saved-review.json --out .dialin/earth-example-results
```

Open `.dialin/earth-example-results/index.html` in your browser. The gallery shows three Best photographs, the three-picture Series “The thin edge,” and a five-picture Sequence. It works from local files; keep its folder together. `RESULTS.md` records the same decisions and `results.json` holds validated proposals and export receipts. `CREDITS.md` and `SOURCES.json` travel with the gallery, which visibly acknowledges NASA and links to the credits.

The example finishing script verifies the exact pinned input images, then calls the normal `photos finish` implementation and adds source acknowledgment to its new output. It preserves the reviewer label and decisions, refuses existing destinations, and removes an incomplete new output if attribution cannot be written. Use ordinary `photos finish` for your own photographs; this wrapper is only for the NASA example. It makes no network or model call.

Replay maps the saved decisions to exact content hashes and writes a new sheet. It does **not** run a fresh visual review or call a model. The reviewer name in the results explicitly says it is a replay of Codex's 2026-10-19 visual review. It refuses different images, a changed brief or count, photographer constraints, and a sheet with existing editorial work. Use a new workspace to compare versions.

## What the saved edit decided

Best, in order:

| Photograph | Why it works alone |
| --- | --- |
| `iss039e012272` | A turquoise crescent against deep blue gives a clear central shape. |
| `iss023e057948` | A narrow orange horizon reads strongly against blue and black. |
| `iss022e005258` | Repeated sand ridges give a quiet, almost abstract rhythm. |

The Sequence goes **water → sand → dim mountain ridges → warm horizon → city lights**. The darker mountain frame earns its place by connecting daylight textures to the thin horizon. The noisy night frame stays because it gives the story an inhabited ending. The wider water view and cloud-covered mountain frame remain useful alternatives; neither was labeled a burst duplicate or deleted.

The Series uses `iss007e08259`, `iss023e057948` and `iss039e009160` to compare three boundaries between Earth and sky. Its broad daylight frame is useful in a series even though it did not make Best. These choices illustrate why the three outputs answer different questions.

## Sources and use

The original photograph bytes are downloaded unchanged from NASA; no images are bundled in this source repository. [sources.json](sources.json) records each official source page, metadata endpoint, credit, exact URL, size and hash, checked on 2026-10-19.

| Archive ID | Source credit |
| --- | --- |
| [iss039e012272](https://images.nasa.gov/details/iss039e012272) | NASA / Steve Swanson |
| [iss036e032513](https://images.nasa.gov/details/iss036e032513) | NASA / Karen Nyberg |
| [iss007e08259](https://images.nasa.gov/details/iss007e08259) | NASA |
| [iss039e012534](https://images.nasa.gov/details/iss039e012534) | NASA / Steve Swanson |
| [iss037e026714](https://images.nasa.gov/details/iss037e026714) | NASA / Karen Nyberg |
| [iss039e009160](https://images.nasa.gov/details/iss039e009160) | NASA / Rick Mastracchio |
| [iss023e057948](https://images.nasa.gov/details/iss023e057948) | NASA |
| [iss022e005258](https://images.nasa.gov/details/iss022e005258) | NASA / Jeffrey Williams |

NASA's [media usage guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/) permit factual educational and informational uses with source acknowledgment and without implying endorsement. These eight source records show NASA provenance and no third-party copyright notice. The selected frames contain no identifiable people or NASA logos. NASA imagery is not relicensed under this repository's MIT license. Preserve source credits when sharing this example. This is an informational workflow example, not NASA endorsement or approval of Dial In.

The editorial notes and decisions are AI-generated text by Codex and are **not NASA statements**. NASA is not responsible for their accuracy. No pixels were AI-generated or retouched. Preparation makes normal local previews; finished folders retain exact copies of the downloaded JPEGs. These medium archive files demonstrate review and file handling, not original-resolution print assessment, calibrated color, a Fujifilm rendering or the results of a real Dial In shoot.
