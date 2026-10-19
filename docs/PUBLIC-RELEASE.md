# Reviewable source snapshot

The public repository is a set of open-source Fujifilm tools used from a terminal, Codex or Claude Code: recipe planning, camera-slot preparation and guarded USB writes, photo import, photo review (Best, Series, Sequence), shot-look checks, camera reports and the Bluetooth protocol bench. The owner's private iPhone app, Studio and finishing tools are not part of it.

## Reproduce and inspect the source snapshot

The source exporter uses `release/source-manifest.json`, an exact positive file list. It does not export Git history. Every selected file is hashed, every copy transformation is recorded, and every generated asset has a provenance entry. Unknown files do not enter the export automatically.

```sh
node --test tests/release/export.test.mjs
node scripts/public-release/export.mjs assemble --out .dialin/public-release/candidate
node scripts/public-release/export.mjs audit --out .dialin/public-release/candidate
```

Choose a new output directory for each assembly; existing destinations are refused. Python 3 is needed to regenerate synthetic protocol vectors. Output must be inside `.dialin/` or a separate real directory; symlinks and path traversal are refused. Assembly makes no network, model, camera, radio, Git or signing call.

The adjacent `candidate.source-export.json` records every public path, byte size, mode and SHA-256, plus source hashes and transform identifiers. Keep this receipt private when preparing a source snapshot from a personal working tree. The candidate itself includes an independent public selection manifest and `release/ASSET-PROVENANCE.json`.

The original preparation checkout may use a private copy policy at `release/copy-transforms.private.json`. It is excluded from publication. It removes personal names, paired identity examples, signing values, fixed local paths, private places and venues, and host network identifiers only in the staged copy. Its deny list makes assembly fail if any of those values reappear. Public snapshots reproduce themselves without that private policy.

The photographer's private recipe catalog (`data/recipe-knowledge/catalog.json` or `DIALIN_RECIPE_CATALOG`) is reference material and is never exported. When the private copy policy is in use, assembly and audit also load that catalog in memory and fail if any public file contains its source host, its publisher's name, a catalog reference ID or a catalog recipe title (Fujifilm film-simulation names excepted). The terms are never written or printed; a finding names only the file and the rule. Without the catalog, a private export is refused rather than unchecked. `--recipe-catalog PATH` selects another copy.

Run dependency installation and tests in a separate validation copy. `npm ci`, Python imports and native builds create files that are deliberately absent from the exact public manifest. Audit the untouched final candidate again before any separately authorized publication.

## Included and excluded material

- Source: desktop modules and planner code; the Node USB implementation; the macOS camera helper `ios/DialInCamera` (`dialin-cam`: USB, Bluetooth, Wi-Fi import); the Python Bluetooth protocol bench in `ble/`.
- Recipes: Dial In's original guidance only: 31 setting rules, 20 film-simulation profiles, the 10 original directions in `data/recipes/original-book.json` and the seven-entry rehearsal fixture. The guidance was written after studying widely shared community recipes; no third-party recipes, recipe catalog, research snapshot or catalog-building tool is included. Tests use an invented catalog in `tests/fixtures/recipe-catalog.fixture.json`. `data/recipe-space/priors.json` adds aggregate community-practice counts (each over at least 5 recipes, no recipe, name, link or identifier); it is rebuilt privately by `scripts/build-recipe-space.ts`, which refuses output that fails its reconstruction check, and the publisher-content audit scans it like every other file.
- Examples: original recipes, a generated synthetic photo shoot, synthetic metadata, a zero-filled synthetic compressed settings fixture and regenerated packet vectors. They do not establish photographic quality or hardware acceptance. The optional Earth from orbit example adds an explicit NASA image downloader, pinned source hashes and attribution, and a saved visual review. Original photograph binaries and complete generated galleries are not bundled. A reviewed GIF, MP4 and still in `docs/media/` show the workflow, including screenshots of that attributed NASA gallery; their exact bytes and hashes are allowlisted in `release/media-manifest.json`. [Media provenance](media/README.md) separates the agent plan, offline camera preparation and saved review replay. Downloading or replaying the photo example never runs during installation, export or routine tests; replaying saved choices is not a new visual review.
- Excluded: history; the private iPhone app, Darkroom, Post, Studio, finishing tools and phone web prototype; personal photographs and albums; camera backups and pairing data; logs and evidence; filled credentials and signing configurations; dependencies and build products; proprietary binaries; the private recipe catalog and its tooling.

`LICENSE` covers original source. `THIRD_PARTY_NOTICES.md` and `third_party/` preserve upstream notices and verification limits for shipped code; the exporter filters the pinned license records to shipped files. No license grants are invented for imported datasets or outside photographs.

## Software checks and physical boundaries

[Fresh-user validation](FIRST-RUN-VALIDATION.md) records the observed software checks, real host-agent trials and remaining physical and photographic limits.

The owner authorized the initial public alpha on October 19, 2026 based on the existing testing. Public changes now build on that reviewed snapshot; see [project history](PROJECT-HISTORY.md). Outside-photographer recruitment and repeat-use targets are optional [postlaunch learning](LAUNCH-FEEDBACK.md), not release prerequisites. An owner test does not expand the documented hardware support or establish demand.

```sh
npm ci --ignore-scripts
npm run check:desktop
npm run test:plan
python3 -B -m unittest discover -s ble/tests -v
```

Install the photo dependency described in `modules/photos/README.md` before `check:desktop`. Portable checks do not invoke a paid model or camera. Some optional research tests skip when externally supplied reference repositories or backups are absent; they are not physical acceptance evidence. All physical tests, native builds, signed-device installation, external model outcomes and aesthetic preference remain separate lanes.

Modified production Bluetooth recipe writes remain blocked. Offline preparation and synthetic packets are not a device-write receipt. The engineering tools also keep experimental whole-settings restore commands (`python3 -m fuji_ble restore`, `dialin-cam ble-restore`, `dialin-cam settings-put`). They require explicit experimental flags, replace every camera setting and accept edited files. A single experimental C7 write/readback/menu-confirmation result is recorded, but restart and complete recovery qualification remain unfinished; see [capabilities](CAPABILITIES.md) and the Bluetooth and camera guides. Actual USB operations still require explicit execution, fresh identity, a backup and readback. No public export step changes these gates.

## Optional macOS camera helper

`ios/DialInCamera` builds the `dialin-cam` macOS helper with Swift 6.2 on macOS 26 or later; despite the folder name, no iPhone app or Xcode project is involved. Build it through `scripts/with-build-lock.sh` as described in its README. A source review is not a claim that a native build or a camera operation has passed on your machine.

Publishing requires a separate deliberate action on this exact reviewed tree. Never make the personal checkout/history public or mirror its refs. After publishing, read back the remote file list and content independently against the receipt.
