Vendored from FilmKit (https://github.com/eggricesoy/filmkit, MIT, commit 9e3bbcf, 2026-03-26):
PTP container packing, Fuji property IDs, film-sim/WB/grain enums, and the preset
property encoding (D18C–D1A5) reverse-engineered from Fujifilm X RAW Studio USB captures.
Local changes: import paths, and `GRAIN_MAP` in `preset-translate.ts` decodes the Grain Off readback values 6 and 7
(Off-Small/Off-Large, seen on X100VI 1.10) as Off. Writes still send 1. See LICENSE-filmkit.
