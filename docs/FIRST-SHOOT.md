# Your first useful result

Open this repository in Codex or Claude Code and choose the route that matches what you already have. Your agent can run the commands and write the JSON. A photograph folder needs no camera or shoot plan; your own recipes need no AI planning.

Every route starts with its read-only `doctor` check. Follow only the setup it says is missing. Use new output names when repeating a command: Dial In preserves previous work.

## I have photographs

Paste this into your agent, replacing the folder and your intention:

> Review my JPEG/PNG photographs in `/path/to/my-photos`. I want a quiet travel story: my best 10, a series of about 5, and an 8-photo sequence. Open the images before choosing. Keep the photograph I identify as important, explain the alternatives, and show me the local results gallery. Leave my originals untouched.

The agent starts here:

```sh
node scripts/dialin.mjs doctor photos
node scripts/dialin.mjs photos prepare --input "/path/to/my-photos" --out .dialin/first-review --intent "A quiet travel story" --count 8
```

If Pillow is missing, the [photo setup](../modules/photos/README.md#install-and-prepare) installs it in the repository's `.venv`. Your agent reads `.dialin/first-review/REVIEW.md`, opens the contact sheets and relevant individual previews, and fills the generated review sheet. Then:

```sh
node scripts/dialin.mjs photos finish --workspace .dialin/first-review --out .dialin/first-results
```

Open `.dialin/first-results/index.html` in a browser. Best, Series and Sequence each have pictures and the reviewer's reasons. `RESULTS.md` gives a text version; the adjacent folders hold copied originals. No server or gallery account is needed. Keep the output folder together when moving it. These results and source metadata are private unless you choose to share them.

**No photographs ready?** Try [Earth from orbit](../examples/photos/earth-from-orbit/README.md): eight small NASA archive photographs, an actual saved visual review, and a reproducible local gallery. Downloading is explicit; the photographs total less than 1 MB. You can replay the saved decisions or ask your agent to make its own edit.

## My photographs are still on the camera

For wireless import on the tested X100VI 1.10/Mac setup, Bluetooth starts the camera's Wi-Fi and **Wi-Fi transfers the photographs**. Unplug USB first. The optional helper needs macOS 26+ and Swift 6.2+:

```sh
node scripts/dialin.mjs doctor import
node scripts/dialin.mjs native build
node scripts/dialin.mjs import wifi --last 7 --dest .dialin/first-import --out .dialin/first-import.json
```

For the first registration, follow [the pairing steps](WIRELESS.md#import-over-wi-fi) and add `--pair` explicitly. The Mac temporarily leaves its usual Wi-Fi. Choose the photo range you want; the command above is a newest-files example. The receipt's `summary.folders` identifies folders containing originals. Continue with **I have photographs** above using one of those folders.

USB-C photo import is also implemented as `import usb`; use USB CARD READER mode and see [the import guide](../modules/import/README.md) for its separate evidence limits. An SD-card reader or OS-imported folder also works. No camera connection is needed once your JPEGs are on the computer.

## I want to plan my shoot

Paste this:

> Plan seven complementary looks for outdoor portraits, a walk in hard sun, and dinner indoors. Use agent mode and the original recipe guidance. Explain when I would use each look and the tradeoffs. Keep this offline; my camera is not connected.

The agent starts here:

```sh
node scripts/dialin.mjs doctor plan
node scripts/dialin.mjs plan --mode agent --text "Outdoor portraits, a walk in hard sun, and dinner indoors" --out .dialin/first-plan/request.json
```

If Node dependencies are missing, run `npm ci --ignore-scripts`. The agent reads `request.md`, supplies its own answer in `answer.json`, and finalizes it:

```sh
node scripts/dialin.mjs plan finalize --request .dialin/first-plan/request.json --answer .dialin/first-plan/answer.json --out .dialin/first-plan/plan.json
```

Your result is `.dialin/first-plan/plan.md` and a validated `plan.json`. A request alone is not a finished plan. Validation checks the proposal; whether you like the resulting photographs still needs a real shoot. No separate model API key is needed in agent mode. For a scene image or protected slots, follow the [planner guide](../modules/planner/README.md).

## I already have recipes

Paste this, supplying your own model, firmware and intended slots:

> Check my recipes in `/path/to/recipes.json` for an offline preparation. My camera is an X100VI on firmware 1.10; put the first recipe in C2 and the second in C7, preserving the other slots. Show me the exact placements and any blocked settings. My camera is not connected.

For a first look with Dial In's two original illustrative recipes:

```sh
node scripts/dialin.mjs doctor camera
node scripts/dialin.mjs camera prepare --in examples/camera/own-recipes.json --slots C2,C7 --model X100VI --firmware 1.10 --transport usb --out .dialin/first-camera.json
```

The result describes feasibility, exact slot placement and checks required at execution. It does not contact a camera and is not an upload receipt. The model and firmware in this command are an example profile, not a claim about your camera. For your own recipe book, the [camera guide](../modules/camera/README.md) explains stable recipe IDs and the separately authorized execution path. Check [camera support](CAPABILITIES.md) before connecting hardware. Never substitute guessed model, firmware or slot facts.

To load a prepared recipe, the supported path is **USB-C**: follow the [guarded USB write instructions](../modules/camera/README.md#explicit-usb-use-from-the-computer). Bluetooth settings backup and Wi-Fi setup are available too. **Bluetooth recipe loading is experimental**; its supervised single-slot [trial](WIRELESS.md#bluetooth-recipe-trial) is separate from the normal first-shoot path.

## I just want to check the whole installation

```sh
npm ci --ignore-scripts
npm run dialin -- demo --out .dialin/demo
```

Read `.dialin/demo/SUMMARY.md`. This is a **fixture rehearsal** of planning, offline camera preparation and supplied-observation curation. It does not generate a fresh plan, operate hardware or visually review real photographs. The [synthetic photo set](../examples/photos/README.md#synthetic-software-rehearsal) is another offline software exercise. Neither is a substitute for the real-image route above.

## Tell us what happened

After your first attempt, answer three questions in a local note or the repository's issue tracker:

1. Where did you get stuck, and what did you expect at that point?
2. Was the result useful? Name one selection, explanation or preparation detail you would keep or change.
3. Would you use it for your next shoot? When you do, what made you come back?

Include the component, operating system and the command or error with private details removed. Camera model and firmware help for camera issues. Leave out private photographs, full local paths, EXIF, backups, serial numbers, pairing information and keys. There is no automatic feedback upload. A second real use is more informative than a long feature wish list.
