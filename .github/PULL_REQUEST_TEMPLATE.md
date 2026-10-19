## What changes for the photographer or integrator

<!-- One or two sentences. Name the component(s): recipes, plan, camera, photos, curate, import, demo, dispatcher, docs. -->

## Evidence

<!-- Keep the lanes separate. Write "not run" rather than leaving a lane implied. -->

- Software checks (`npm test`, or the focused suites you ran, with counts):
- Coding-agent trial (host-agent planning or photo review), if any:
- Optional live API run, if any:
- Physical camera operation, if any (body, firmware, transport; no serials):
- Photographic result or preference, if any:

## Checklist

- [ ] Focused regression test for changed behavior
- [ ] Docs and `--help` text match the actual flags
- [ ] Outputs still refuse to overwrite existing files; originals stay untouched
- [ ] No private photos, EXIF, camera backups, serials, pairing data, API keys or personal paths
- [ ] New publishable files are listed in `release/source-manifest.json`
- [ ] Recipe content changes include source and permission information
- [ ] No camera, radio or paid model call in routine tests; Bluetooth writes stay blocked
