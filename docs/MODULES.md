# Independent components, one photography workflow

The desktop CLI is a dispatcher over small callable interfaces. There is no always-running service or mandatory iPhone app. Python curation works without Node packages; photo preparation adds Pillow. Node recipe/camera preparation works without a model account. Planning can use the host coding agent.

| Component | Callable boundary | File handoff | External effects |
| --- | --- | --- | --- |
| Recipes | `modules/recipes/index.ts`; guidance and optional catalog in `modules/recipes/knowledge.ts`; community-practice priors in `modules/recipes/space.ts` | Original/user recipe book and validated recipes; `dialin.recipe-space.v1` priors (`data/recipe-space/priors.json`, `DIALIN_RECIPE_SPACE=none` turns them off); optional private catalog named by `DIALIN_RECIPE_CATALOG` | None for local browsing/validation |
| Planner | `createPlan`, `prepareAgentPlan`, `finalizeAgentPlan` in `modules/planner/index.ts` | Request → answer → `dialin.planner.v1` (with informational `community_practice`), plus a readable `plan.md` beside a finalized plan | API only in explicit live mode |
| Camera | `prepareCamera` in `modules/camera/index.ts`; explicit CLI operation paths; read-only `camera report` and `camera profile` | `dialin.camera-preparation.v1`, `dialin.camera-report.v1`, `dialin.camera-profile-draft.v1` | Preparation none; execution commands explicitly operate a camera |
| Photos | `modules.photos.prepare`, `crops`, `finish`, `apply_review`, `export_selection`, `looks` | `dialin.photos.v1`, previews, `dialin.photo-crops.v1`, `review-sheet.json` (`dialin.photo-review/1`), `dialin.curation-input/1`, `dialin.photo-results.v1` (Best/Series/Sequence folders, local `index.html` gallery and bounded previews), export receipt | Local files only; originals not mutated |
| Curation | `modules.curation.curate` | `dialin.curation-input/1` → `dialin.curation/1` | Pure supplied-data decision/validation; CLI writes requested output |
| Camera import | Existing `PhotoSource`/`PhotoImporter` with a macOS CLI | Original files + import manifest | Explicit camera/network/file operations; physical qualification separate |

The `modules` command reports runtimes and entry points without loading device or model dependencies. `doctor <component>` checks just that component's prerequisites; `doctor` alone checks every component and reports the optional macOS import helper without requiring it. Doctor prints its JSON report on stdout and a short human summary on stderr. It does not establish hardware compatibility or provider credentials.

## Output and exit codes

Results are JSON on stdout, or a new file or folder with `--out`; an existing output is refused rather than replaced. Messages and errors go to stderr. Exit code `0` always means the requested operation completed; anything else means read stderr and do not treat the output as final.

| Command | Nonzero exit codes |
| --- | --- |
| dispatcher, `doctor`, `demo` | `1` unknown command, usage error, missing prerequisite or failed step |
| `recipes` | `1` invalid book or command error. `sources`, `knowledge` and `analyze` without a private catalog exit `0` with a one-line note on stderr |
| `plan` | `1` error (JSON on stderr); `2` finalization saved a reviewable plan that **needs revision**: read its `validation.warnings` |
| `camera` | `2` invalid input, or a partial `camera report` (the partial JSON is still written); `3` a physical write was **not verified**: inspect the result and the camera before anything else |
| `photos` | `1` error; `2` command-line usage error |
| `curate` | `2` invalid input or usage error (JSON on stderr) |

## Desktop defaults

Prefer ordinary source folders, a local `.venv`, JSON artifacts and the user's coding agent. The Swift camera package is an optional macOS helper (`dialin-cam`). They do not define the public user's installation or require creating a new app.

The root Node package remains private during release preparation. The TypeScript APIs are source imports run with the installed TS runtime, not separately published npm packages. Python modules are importable from the repository. Future package publication can follow demonstrated component usage; it is not needed to run this interface.

## Honest boundaries

`photos crops` takes a prepared workspace and a JSON map of labels to normalized EXIF-oriented `[x,y]` centers. It creates a new packet inside the workspace: labeled PNGs with 1:1 source pixels, their oriented source `box` and caption-free `image_box`, source/crop SHA-256 values, a workspace fingerprint and `visual_review: "NOT_RUN"`. The image tool must open those crops; generation is not inspection. Optional review-sheet `focus_checks` contain `group`, `keeper`, packet `{file, sha256}` references, all `seen` candidate labels and a comparison `note`. The photo adapters validate those references and reject stale evidence. Finished Best burst picks carry `focus_review.status` of `reviewer_reported` or `not_checked`; `results.json` preserves the supplied comparisons and CLI `focus_unchecked_groups` lists unverified groups. No claim of automatic detection, optical measurement or proof of viewing is made. See the [complete contract and example](../modules/photos/README.md#check-focus-before-choosing-a-burst-keeper).

An agent request has not generated a plan. A validated plan has not configured a camera. A prepared camera artifact has not written settings. A photo manifest has not visually reviewed images. A valid sequence has not been approved by a photographer. Keep those stages explicit in generated reports and integrations.

The connected demo uses original synthetic examples. A real photography session instead uses actual image review, a verified device operation when requested, and the photographer's judgment. Use the same interfaces, preserve their provenance, and avoid copying all private state into a public export.

The optional [Earth from orbit example](../examples/photos/earth-from-orbit/README.md) explicitly downloads pinned NASA images into a local workspace. It is separate from the offline fixture demo and routine tests. Replaying its saved review reproduces earlier editorial decisions; it does not perform a new visual review. A fresh agent review must open the images itself.

## Desktop native boundary

`modules/native-helper.mjs` implements explicit `native build`/`status`, serialized builds and source-fingerprint checks. Native camera commands never build automatically. `modules/import/cli.mjs` exposes `import wifi|usb|folder`: explicit range and destination, original-file preservation, JSON on stdout/new `--out`, helper diagnostics on stderr. Its `dialin.import.v1` receipt embeds the native `dialin.import-summary.v1` with saved/failed counts, folders and interruption state; it distinguishes `completed`, `planned`, `fixture_rehearsal`, `incomplete` and `failed`. A process success without a machine summary is not a completed import.

`modules/camera/bluetooth.mjs` exposes backup and the supervised single-slot trial as `camera bluetooth …`, returning `dialin.bluetooth.v1`. Artifacts live in a new private `--workspace`; `--out` is a separate new receipt file. `status` is offline and `apply` refuses. Trial flags are never inserted implicitly. `trial-check` compares a readback but requires separate owner confirmation of the physical restart. Production writes stay gated.

Wrapper exits: 0 completed operation (including offline blocked-status and synthetic rehearsal reports); 2 invalid input/setup error; 3 blocked or unverified outcome. Native nonzero operation codes are preserved (including 1 for connection/partial import failures); interruption returns 130/143. A failure never deletes completed imports or backup artifacts. Neither JSON receipt proves general compatibility or Wi-Fi restoration. [Workflow and limits](WIRELESS.md).
