# Dial In

Open-source Fujifilm tools for your terminal and your coding agent (Claude Code or Codex). They do the three jobs around a shoot that photographers would rather not do by hand:

1. **Find the right looks for the light you'll shoot in.** Describe the day, optionally with a scene photo; your agent proposes seven complementary film-simulation recipes, and every setting is checked against what Dial In has written and read back on an X100VI over USB: all 20 film simulations, Auto/Daylight/Kelvin white balance, Color −1 to +3 and noise reduction −4.
2. **Put them on the camera without menus.** Recipes go into the custom slots you name (C1–C7) over USB, after a backup of all seven slots, with every value read back.
3. **Get your best photos out of the shoot.** Your agent looks at labeled contact sheets and picks your Best, a Series and a Sequence. One command checks those picks against your own choices, copies the originals into folders, and makes a local gallery you can open in your browser. Originals are never modified.

Each tool works on its own, from ordinary JSON files and folders. No app, account or separate AI API key is needed. Camera writes are supported only on the X100VI, firmware 1.10, over USB on the tested Mac setup. Planning and photo-folder review need no connected camera. Check the [capability table](docs/CAPABILITIES.md) before choosing a camera operation.

## Try it in a minute

Needs Node.js 22.12+ and Python 3.10+. No camera, account or API key.

```sh
npm ci --ignore-scripts
npm run dialin -- demo --out .dialin/demo
```

Then read `.dialin/demo/SUMMARY.md`: a seven-look plan run through the real planner engine, its offline camera-slot preparation, and a validated photo sequence. It is a rehearsal with bundled fixture data: no AI planning, camera write or photo review happens, and the summary says so.

For a real visual review, follow [Your first shoot](docs/FIRST-SHOOT.md). It includes a small, explicitly downloaded NASA photograph set, or you can bring your own folder. Your agent opens the photographs, makes an edit and produces a local `index.html` gallery with Best, Series and Sequence.

## Use it with your coding agent

Open the repository in Codex or Claude Code and ask, for example:

> “Plan seven complementary looks for tomorrow: outdoor portraits, a walk in hard sun, and dinner indoors. Use my scene photo too. Show me the reasoning before preparing the camera.”

> “I already have my recipes in this JSON file. Check whether I can put them in C2 and C7 on my X100VI. Keep the other slots.”

> “Here's today's shoot folder. Give me my best 10, the strongest series of about 5, and the sequence of the day. Keep the boat close-up.”

Your agent supplies the visual and editorial judgment; the tools validate settings, preserve photo identities, enforce your constraints and save results as ordinary files. [Agent instructions](docs/AGENT-WORKFLOW.md) list the exact commands and handoffs.

For close burst decisions, the agent can generate [labeled 100% crops from the originals](modules/photos/README.md#check-focus-before-choosing-a-burst-keeper), inspect the relevant eye/subject in each candidate, and record its comparison before claiming focus checked. Region selection and judgment come from the agent; the tool does not automatically detect eyes or score sharpness.

## Pick a component

Each component works on its own. Run `npm run dialin -- doctor <component>` first: it checks only that component's prerequisites, makes no network, model or camera call, and tells you the fix for anything missing.

| I want to… | Guide | Needs |
| --- | --- | --- |
| Plan the looks for a shoot from a description and/or scene photo | [Planner](modules/planner/README.md) | Node.js and your coding agent (API key optional) |
| Explore the recipe guidance or check my own recipe book | [Recipes](modules/recipes/README.md) | Node.js |
| Put recipes into chosen camera slots | [Camera](modules/camera/README.md) | Node.js; an X100VI on firmware 1.10 for the USB write |
| Get photographs off the camera | [Import](modules/import/README.md) | An SD-card reader, or the optional macOS helper |
| Get my Best, Series and Sequence from a photo folder, and see which look each photo was shot with | [Photos](modules/photos/README.md) | Python + Pillow and your agent's image viewing |
| Validate a selection and sequence from another tool | [Curation](modules/curation/README.md) | Python standard library |
| Try the photo workflow without my own photos | [Synthetic demo shoot](examples/photos/README.md) | Python + Pillow; original drawings labeled SYNTHETIC |
| Help support another Fujifilm body | [Add your camera](docs/ADD-YOUR-CAMERA.md) | Node.js and the camera on USB; read-only |

First commands, from the repository root:

```sh
npm run dialin -- plan --mode agent --text "Morning portraits, a market, dinner indoors" --out .dialin/my-shoot/request.json
npm run dialin -- camera prepare --in examples/camera/own-recipes.json --slots C2,C7 --model X100VI --firmware 1.10 --transport usb --out .dialin/my-camera.json
npm run dialin -- photos prepare --input /path/to/photos --out .dialin/my-photos --intent "A quiet travel story" --count 8
npm run dialin -- photos finish --workspace .dialin/my-photos --out .dialin/my-photos-finished
npm run dialin -- recipes knowledge --query "portraits in open shade"
```

`plan` writes a request your agent answers; `photos finish` runs after your agent has filled the review sheet that `photos prepare` creates. Open the resulting `index.html` to see the selections and their explanations; the result folder works offline and can be moved with its contents. Results are JSON on stdout, or new files with `--out`; existing files are never overwritten and original photographs are never modified. `npm run recipes|plan|cam|photos|curate -- …` are shortcuts for the same commands. `npm run dialin -- --help` lists everything.

## Setup details

- **Node.js 22.12+** runs the CLI; `npm ci --ignore-scripts` installs its dependencies. `--help` and `doctor` work before installation.
- **Python 3.10+** runs curation with no packages. Photo preparation also needs Pillow in a local environment:

  ```sh
  python3 -m venv .venv
  .venv/bin/python -m pip install -r modules/photos/requirements.txt
  npm run dialin -- doctor photos
  ```

  On Windows: `python -m venv .venv`, then `.venv\Scripts\python.exe -m pip install -r modules/photos/requirements.txt`. The CLI finds the repository's `.venv` automatically; `DIALIN_PYTHON` selects another interpreter.
- Photo review sends nothing to a separate model service. When your coding agent opens the previews, its normal image processing applies.

## How the pieces connect

```text
Scene description / photo / both
           ↓
Your agent + Dial In guidance → validated seven-look plan     ← or bring your own recipes
           ↓
Offline camera preparation → guarded USB write (backup, readback) → shoot
           ↓
SD card, or the macOS helper (USB / Wi-Fi) → local photo folder
           ↓
Contact sheets with moments, burst hints and each photo's look → your agent picks
           ↓
Best / Series / Sequence validated → originals copied into folders
```

Every boundary is inspectable JSON and ordinary files, so other tools can enter or leave at any step. See [module contracts](docs/MODULES.md).

## For developers

- [Fujifilm protocol reference](docs/FUJIFILM-PROTOCOL.md): how the X100VI exposes custom slots C1–C7 over USB PTP, its Bluetooth LE settings backup and Wi-Fi wake, and the Wi-Fi PTP/IP photo session. Every claim is labeled as verified on hardware, implemented, cited from another open-source project, or a hypothesis.
- [Module contracts](docs/MODULES.md): the JSON schemas and exit codes at each boundary, so other tools can enter or leave anywhere.
- [Add your camera](docs/ADD-YOUR-CAMERA.md): the read-only `camera report`, and the bar a new body must clear before writes are enabled.

## What is and is not established

| Area | Status |
| --- | --- |
| Operating systems | The offline test suite passes in GitHub Actions on Linux and macOS, at Node 22.12.0 + Python 3.10 and at Node 22 + Python 3.12. On Windows, CI runs a smoke test only (the CLI, setup checks and demo); camera and photo workflows are untested there. |
| Cameras | **X100VI 1.10, USB, one macOS setup:** slot write/readback, original-slot restore and restart persistence observed. Other bodies, firmware and camera hosts are not qualified. An experimental Bluetooth C7 write was read back and confirmed in the camera menu on October 16; its restart check remains pending and **production Bluetooth recipe writes stay locked**. Preparation is offline and is not an upload receipt. [Exact support and evidence](docs/CAPABILITIES.md). |
| Import | Use an SD-card or OS-imported JPEG/PNG folder, or the optional macOS helper. Seven full-size JPEGs were downloaded over Wi-Fi from one X100VI 1.10 on October 16 and each decoded successfully. RAW-over-Wi-Fi, interrupted-transfer recovery and an iPhone workflow remain unverified. [Import guide](modules/import/README.md). |
| Photos | JPEG and PNG; RAW and HEIF are reported as unsupported. A finished edit includes a local gallery and unchanged original copies. Moments, burst hints and recorded looks are suggestions for your agent. The look reader matched the settings of seven real X100VI JPEGs in the October 16 sample; that does not establish a JPEG's C-slot identity or broad format coverage. Your agent must actually open images before claiming visual judgment. |
| Recipe guidance | The planner is guided by Dial In's original setting rules (31), film-simulation profiles (20) and recipe directions (10), plus your coding agent's own photographic knowledge. You can bring your own recipe book. The guidance was written after studying widely shared community recipes; no third-party recipes are included, and no model was trained. The directions are unrendered hypotheses, not photographed comparisons. Seven is the default palette size, not a library limit. See [Recipes](modules/recipes/README.md). |
| Community practice | `data/recipe-space/priors.json` holds aggregate counts of how widely shared community recipes set each control for each film simulation. Every count covers at least 5 recipes; no recipe, name, link or identifier is included, and a check shows no source recipe can be reconstructed from it. The planner uses it only for an informational note per look; common is not the same as good. |
| Planning quality | Plans are validated for settings, slots and stated constraints. Whether they produce photographs you like needs your camera and your judgment. |

[Fresh-user validation](docs/FIRST-RUN-VALIDATION.md) records what has been tested, by whom and how. Report software tests, coding-agent results, live API results, physical-camera results and photographic preference separately.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md); `npm test` runs every offline check. Tell us about your [first real use](docs/LAUNCH-FEEDBACK.md), or help qualify another camera through a read-only report. Public source releases are exported from an exact file list ([details](docs/PUBLIC-RELEASE.md)). Original code and examples are [MIT licensed](LICENSE); externally downloaded example photographs retain their stated source terms. [Third-party notices](THIRD_PARTY_NOTICES.md) keep upstream licenses. Security and private-data reports: [SECURITY.md](SECURITY.md).
