# Contributing

Start with the smallest component that solves a photographer's task. Read [AGENTS.md](AGENTS.md) for working rules and [the module contracts](docs/MODULES.md) for file handoffs and exit codes.

## Set up and run the checks

Node.js 22.12+ and Python 3.10+. From the repository root:

```sh
npm ci --ignore-scripts
python3 -m venv .venv
.venv/bin/python -m pip install -r modules/photos/requirements.txt
npm test
```

On Windows use `python -m venv .venv` and `.venv\Scripts\python.exe -m pip install ...`. `DIALIN_PYTHON` overrides the Python executable everywhere.

`npm test` runs every offline suite. You can run them separately:

| Script | Covers |
| --- | --- |
| `npm run check:desktop` | TypeScript, Node module tests (`tests/modules/*.test.*`), Python photo/curation tests and offline download/replay example checks |
| `npm run test:plan` | Planner engine (`tests/plan/`) |
| `npm run test:release` | Public source exporter (`tests/release/`) |
| `npm run test:encoding`, `npm run test:writer` | Camera property encoding and the slot writer against a fake camera |

None of these operate a camera or radio, start a logged-in model CLI, or call a paid model. CI runs the same checks on Linux and macOS at the minimum (Node 22.12.0, Python 3.10) and current (Node 22, Python 3.12) versions.

## Where things live

| Path | What it is |
| --- | --- |
| `scripts/dialin.mjs` | The desktop dispatcher behind `npm run dialin -- <command>` |
| `modules/<component>/` | Independent entry points: `recipes`, `planner`, `camera`, `photos`, `curation`, plus `import` docs |
| `modules/doctor.mjs`, `catalog.mjs`, `demo.mjs` | Setup checks, component discovery, connected demo |
| `lib/` | Existing planner engine, recipe library and Fujifilm encoding reused by the modules |
| `data/` | Original recipe directions (no third-party recipe catalog is distributed) |
| `examples/` | Original fixture inputs and an explicit NASA photo download example with source credits |
| `tests/` | `modules/` (desktop components), `plan/` (engine), `release/` (exporter) |
| `ios/DialInCamera/`, `ble/` | macOS camera helper (`dialin-cam`: USB, Bluetooth, Wi-Fi import) and the Python Bluetooth protocol bench; separate requirements |
| `release/` | Exact public file list and export policy |

## Conventions

- Results are JSON on stdout or a new file via `--out`; messages and errors go to stderr. Never overwrite an existing output or modify an original photograph.
- Keep new commands discoverable: update `--help`, the module README and, for a new component, `modules/catalog.mjs`.
- Add a focused regression for each behavior change and a reproducible example where it helps. Use synthetic camera identities and original or permission-cleared images.
- New publishable files (code, docs, tests, examples) must be added to `release/source-manifest.json`; the public export is an exact file list.
- Recipe content changes need source and permission information. Keep full third-party notices with adapted code and record the upstream revision.
- Never commit API keys, signed configuration, personal photo paths, EXIF, camera serials, pairing bytes or backups. `.dialin/` is ignored and is the default place for working files.

## Report evidence by lane

Describe software tests, coding-agent trials, live API runs, physical camera operations and photographic preference separately. A valid recipe or synthetic transport test does not show that a camera accepted it or that the photographs look good. The pull request template lists the lanes.

[What works today](docs/CAPABILITIES.md) is the support summary. When capability evidence changes, update that page, the dated validation record and the affected component guide together. Keep implementation, a single observed result and broader support separate.

For a useful first contribution, try one component on your own task and open a **First-use experience** issue. Report your first result, elapsed time, blockers and whether you used it again; no private photographs or logs are needed. The [launch feedback guide](docs/LAUNCH-FEEDBACK.md) contains a five-person pilot plan and three scoped contributor issue drafts. Use the existing **Bug report** template for reproducible failures and **Camera report** for sanitized read-only device reports.

## Platforms

macOS and Linux run the full offline suite (CI configuration above). The [2026-10-15 source candidate](docs/FIRST-RUN-VALIDATION.md#minimum-versions-and-platforms) passed the Windows smoke job: dispatcher, setup checks, portable tests and fixture demo. That is narrower than full Windows support: camera hardware and the complete photo workflow are unqualified, and some module tests assume POSIX symlinks and file modes. The Windows lane remains non-blocking in CI.

## Optional and maintainer scripts

| Script | Notes |
| --- | --- |
| `npm run codes -- check` | Confirms camera code tables agree across TypeScript, Swift and the Python slot map (also covered by `test:plan`) |
| `npm run release:prepare`, `release:audit` | Public source export; read [docs/PUBLIC-RELEASE.md](docs/PUBLIC-RELEASE.md) first |

Native builds are optional, have their own compiler/platform requirements, and must run through `scripts/with-build-lock.sh`. Invoking a logged-in model CLI requires the explicit local setting `DIALIN_MODEL_TRANSPORT=cli` and is disabled in deployed mode; the normal host-agent route needs neither that setting nor an API key.
