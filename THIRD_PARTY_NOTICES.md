# Third-party notices

Dial In's original code is under [MIT](LICENSE). Third-party notices and license terms remain in force for the corresponding material. This repository does not relicense other people's recipe collections or photographs.

## Camera and protocol work

| Project | Material used | License |
| --- | --- | --- |
| [FilmKit](https://github.com/eggricesoy/filmkit) by eggricesoy | Vendored TypeScript PTP/property/preset code in `lib/fuji/vendor/`; Swift property, slot and RAW-conversion adaptations in `ios/DialInCamera/` | [MIT](third_party/licenses/FilmKit.txt); original import recorded at `9e3bbcf` |
| [fuji-bridge](https://github.com/Th0rgal/fuji-bridge) by Thomas Marchand | USB/Bluetooth transport patterns, Wi-Fi/PTP import and associated tests in `ios/DialInCamera/` and `ble/` | [MIT](third_party/licenses/fuji-bridge.txt) |
| [libfuji](https://github.com/petabyt/libfuji) by Daniel Cook | PTP/settings-file and Bluetooth protocol implementation references and adaptations | [MIT](third_party/licenses/libfuji.txt) |
| [furble](https://github.com/gkoh/furble) by Guo-Rong Koh | Bluetooth pairing and characteristic protocol references and adaptations | [MIT](third_party/licenses/furble.txt) |
| [fffw](https://github.com/tiredboffin/fffw) by tiredboffin | GATT and protocol reference data used by Bluetooth code; no camera firmware is distributed | [MIT](third_party/licenses/fffw.txt); research revision `b084c998b02a60859288c9b6dc7204e6a94f2e13` |
| [helios](https://github.com/KyleOndy/dotfiles/tree/main/nix/pkgs/helios) by Kyle Ondy | Settings-file format and checksum references for `ble/fuji_ble/backupfile.py` and native settings support | [MIT](third_party/licenses/helios.txt) |

Full license texts travel with the source. [License source records](third_party/license-sources.json) pin the fetched license revisions and hashes. Those revisions identify the notice checked, not a claim that every older local adaptation came from that exact commit; unrecorded code-import revisions are identified explicitly. Existing source attribution comments are retained.

Package dependencies are installed from the lockfiles, rather than vendored here, and retain their own licenses. Protocol references do not imply that referenced firmware, applications, images or unlicensed source are redistributed.

Some Bluetooth characteristic identifiers, constants and message sequences were identified through interoperability work, including study of FUJIFILM's apps. Only functional identifiers, wire formats and observed sequences are used, under Dial In's own names. No FUJIFILM code, binaries or assets are included. The FilmKit preset encoding was itself derived from FUJIFILM X RAW Studio USB captures, as its upstream notice says.

## Online data services

The desktop CLI never contacts these services. `lib/plan/conditions.ts` can query them only when a host application passes a place name to the planner library.

| Service | Use | Terms |
| --- | --- | --- |
| [Open-Meteo](https://open-meteo.com/) | Sun and weather for a supplied place | API data under [CC BY 4.0](https://open-meteo.com/en/licence); "Weather data by Open-Meteo.com" |
| [OpenStreetMap](https://www.openstreetmap.org/copyright) Nominatim | Place lookup | Data © OpenStreetMap contributors, [ODbL](https://opendatacommons.org/licenses/odbl/); [Nominatim usage policy](https://operations.osmfoundation.org/policies/nominatim/) |

## Walkthrough diagram

The [seven-slot walkthrough figure](docs/media/README.md) uses [Anatomy](https://github.com/wheresryan22/anatomy) by Ryan, pinned to commit `1482e8469b0a9e0d8cc18ea2740a01423d29ae80`. The standalone `docs/media/anatomy.html` contains kit-generated SVG geometry and inlined kit CSS; the reproducible builder reads an explicitly supplied checkout, without bundling a kit JavaScript runtime. Anatomy is under [MIT, copyright 2026 Ryan](third_party/licenses/anatomy.txt). Its copyright and permission notice must remain with redistributed code and the standalone figure. Dial In's fictional seven-look model and explanatory copy are original additions. The diagram is an offline explanation, not a photographic rendering or camera-upload receipt; Anatomy does not endorse Dial In.

## Recipes, photos and branding

The bundled `data/recipes/original-book.json`, `examples/planner/recipes.original.json` and `examples/camera/own-recipes.json` are original illustrative settings and prose under this repository's MIT license. They are not claimed to be photographically validated. Original directions preserve links to their manufacturer facts and creative influences; these references do not make the numeric designs exact copies of creator recipes. Dial In's guidance was written after studying widely shared community recipes; no third-party recipes are included. `data/recipe-space/priors.json` holds only aggregate counts of how such recipes set each control (each count covers at least 5 recipes); it contains no recipe, name, link or identifier.

Source URLs in a user's local book are attribution, not permission to redistribute surrounding source material. User photographs, private recipe books, reference images and camera backups remain the user's files and are excluded from the public export.

The optional [Earth from orbit example](examples/photos/earth-from-orbit/README.md) downloads eight NASA archive photographs only when explicitly requested. Original photographs are not bundled or relicensed under MIT. The [walkthrough GIF and video](docs/media/README.md) include screenshots of the resulting gallery; those NASA image portions retain their source terms and are not relicensed under MIT. [The source manifest](examples/photos/earth-from-orbit/sources.json) records each archive page, credit, download hash and NASA's media usage policy. The example and walkthrough are informational and do not imply NASA endorsement. The saved editorial review is supplied by Codex, not NASA, and replaying it is not a new visual review.

Dial In is independent of FUJIFILM and of every recipe creator. None of them has reviewed or endorsed this project. Camera and film-simulation names identify compatibility; they belong to their owners and do not imply endorsement or sponsorship.
