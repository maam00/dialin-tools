# Bring your own recipes to the camera

Open this repo in Codex or Claude Code, give it your recipe JSON, and ask it to prepare the exact slots you want. This component works independently of the planner, recipe catalog, photo tools, and AI providers. You do not need an iPhone app, Xcode project, API key, or generated recipe.

The computer CLI prepares recipes offline, loads recipes over **USB-C**, and exposes **Bluetooth settings backup and a supervised recipe trial** through `camera bluetooth`. **Bluetooth recipe loading remains experimental and blocked in the production writer.** For wireless photo import, Bluetooth starts Wi-Fi and Wi-Fi transfers the photos; use the separate [import component](../import/README.md). Preparing a Bluetooth artifact makes its write limitation visible; it does not bypass it. See [What works today](../../docs/CAPABILITIES.md) for the shared support summary and dated evidence.

## Start offline

From the repository root, with Node.js 22.12+:

```sh
npm ci --ignore-scripts
npm run dialin -- doctor camera
npm run dialin -- camera --help
npm run dialin -- camera prepare --in examples/camera/own-recipes.json --slots C2,C7 --model X100VI --firmware 1.10 --transport usb --out .dialin/camera/preparation.json
npm run dialin -- camera inspect --in .dialin/camera/preparation.json
```

`prepare` prints one line on stderr, for example `camera: valid · prepared C2 ← "Window color", C7 ← "Quiet street" · protected C1, C3–C6 · usb: needs the device checks of camera usb apply (identity, backup, readback) · nothing was sent to a camera → …/preparation.json`; an invalid input prints each issue instead. `--transport` defaults to `usb`, the only supported production write path; `--transport bluetooth` is accepted and reports its blocked gate. Without `--firmware 1.10` the preparation is valid but USB application stays blocked. Use a new output filename on each run; the CLI creates missing parent folders and refuses to overwrite files. `.dialin/` is ignored by Git. The example contains two original, synthetic recipes, without camera backups or copied creator descriptions. These settings have not been judged from photographs.

For an agent, a useful request is:

> Read my recipe file and modules/camera/README.md. Prepare the recipes for C2 and C7 on my X100VI, firmware 1.10, and explain validation errors or changed-control warnings. Keep the other slots protected. Do not contact the camera or run USB apply until I explicitly request the write.

There is no model call in `camera prepare`. The coding agent can help translate your existing recipe document into the JSON fields below, but it should ask you about missing settings and preserve the source values. The validator will reject unsupported fields and values instead of silently substituting them.

## Input and explicit slots

Copy [the original example](../../examples/camera/own-recipes.json), replace its settings with your own, and supply `--slots` in the same order as the `recipes` array. A bare recipe or recipe array also works. Alternatively, include the mapping in the file:

```json
{
  "placements": [
    {"slot": 2, "recipe": {"...": "all recipe fields from the example"}}
  ],
  "protected_slots": [1, 3, 4, 5, 6, 7]
}
```

The abbreviated object above documents the envelope; it is not a valid recipe by itself. Do not combine embedded placements with `--slots`. All untargeted slots are protected automatically; `--protect C1,C3` can add explicit protection. A protected target, duplicate slot, absent mapping, extra recipe, or slot outside C1–C7 is an error.

The recipe contract uses these fields:

| Fields | Rules |
|---|---|
| `name` | Explicit printable ASCII name, 1–14 characters. No silent truncation. |
| `film_sim`, `grain`, `color_chrome`, `color_chrome_fx_blue`, `white_balance`, `dynamic_range` | Exact enum names from the existing [recipe model](../../lib/fuji/recipe.ts). A wrong value's error lists the allowed names and, for a near miss such as `"Classic Negative"`, the likely one. |
| `kelvin` | A supported temperature when WB is `Kelvin`; explicit `0` otherwise. |
| `wb_shift_r`, `wb_shift_b` | Integers from −9 to +9. |
| `highlight`, `shadow` | Native half steps in the existing camera profile, −2 through +4. |
| `color`, `sharpness`, `noise_reduction` | Integers −4 through +4. |
| `clarity` | Integer −5 through +5. |
| `why` | Optional explanatory text; never sent as a camera property. |

Over USB on the X100VI 1.10, every film simulation, Auto, Daylight and Kelvin white balance, and NR −4 have been written and read back on hardware. Other white balances and NR values use encodings cited from open-source projects; `prepare --transport usb` accepts them with a warning per slot, and the apply's strict readback is their only check. The [planner](../planner/README.md) proposes only the hardware-verified values.

Only the X100VI profile is currently implemented. The recipe contract does not represent every native camera control. Unknown fields are refused, including a supplied native control the current writer cannot honor. Exposure, aperture, shutter, ISO, and focus are not recipe-bank settings. The current writer forces D Range Priority and Smooth Skin Off. For monochrome recipes, inactive color/Color Chrome/WB-shift memories and monochrome tint are not claimed to match a complete recipe-bank definition. Review those warnings before applying.

A `dialin.planner.v1` artifact is another supported input. The module matches `plan.write.slots` to the same `day_looks[].slot`, requires each target to be a known new recipe, and honors `plan.protected_slots`. It does not assign slots from array position or rewrite kept looks.

A validated `dialin.recipes.v1` recipe book can go directly to camera preparation. Use `--ids` to select entries by their stable identifiers, then supply `--slots` in the same order. For example, `--ids recipe-a,recipe-b --slots C2,C7` puts recipe-a in C2 and recipe-b in C7. If `--ids` is omitted, every entry needs an explicit slot and the book must contain at most seven recipes. Unknown or duplicate IDs fail validation. Book descriptions, references and authorship stay in the book; only the selected settings become placements.

## What the artifact means

The JSON schema version is `dialin.camera-preparation.v1`. It contains:

- `placements`: validated recipes with explicit destinations.
- `protected_slots`: every slot the operation must leave unchanged.
- `validation`: errors and native-control limitations.
- `encoding`: per slot, the values the USB writer would send (`usb_preset_preview[].values`) and the fields it does not write (`not_written`: for a monochrome look, Color Chrome, FX Blue, WB shift and Color keep the slot's stored values; mono toning and exposure are never written), plus the separately confirmed Bluetooth settings-file mappings.
- `readiness`: separate USB, Bluetooth, and Wi-Fi status with reasons.
- `execution`: zero camera/provider/network calls, with backup/upload/readback `NOT_RUN`.
- `transfer_authorized: false`: a file cannot authorize a later write.

A valid recipe can still have blocked Bluetooth readiness. A known settings-file byte mapping is not evidence that a wireless upload was accepted. `camera inspect` revalidates recipes and recomputes readiness; it does not trust claimed success or authorization in imported JSON.

Programmatic reuse is also available, without loading native USB:

```ts
import { prepareCamera } from './modules/camera/index.js';
const artifact = prepareCamera(myRecipes, {
  slots: [2, 7], model: 'X100VI', firmware: '1.10', transport: 'usb'
});
// Inspect artifact.validation and artifact.readiness; no device operation happened.
```

## Explicit USB use from the computer

The USB adapter uses the existing Node PTP transport and recipe encoder, and its guarded workflow is tested against fake transports. Physical evidence comes from **one X100VI 1.10 on one macOS 27 Mac**, supervised. The first session observed `info`, `backup`, a write to C7 with readback and an exact restore of the original C7, and found a false `not_verified` on every Grain Off recipe. After the readback rule below fixed that, a re-run on the same camera (macOS 27.0.1) passed: `usb info --release-macos-camera-daemon` exited 0 and printed its notice; applying "Window color" to C7 returned `verified_current_session` with no issues and protected C1–C6 checked; restoring the decoded original C7 also returned `verified_current_session`; the final readback of all seven slots matched the morning backup byte for byte. A later write of "Window color" to C7 survived a power cycle: after the camera was switched off and on, all seven slots read back byte-identical to the snapshot taken before it. This does not qualify other bodies, firmware, desktops or drivers. Photographic preference and Linux/Windows hardware remain untested. The separate [2026-10-16 wireless trial](../../docs/FIRST-RUN-VALIDATION.md#wireless-session-2026-10-16) does not qualify production Bluetooth writes.

The `usb` dependency is optional for offline work. A normal `npm ci --ignore-scripts` includes optional packages when supported; if your install omitted them, use `npm ci --include=optional --ignore-scripts`. Missing native support must be resolved before physical commands. macOS and Linux have transport code; Windows is not qualified by this workflow. No Swift or iOS build is required for these Node commands.

When you deliberately want to connect, attach one X100VI with a data cable, set **CONNECTION MODE → USB RAW CONV./BACKUP RESTORE**, and close apps that already control the camera. Only X100VI firmware **1.10** is admitted by this wrapper. The USB edit cursor can move during slot reads; backup does not change recipe values.

On macOS, the system daemon `ptpcamerad` (LaunchAgent `com.apple.ptpcamerad`) usually holds the camera, and the command fails with `claimInterface … exclusive access (0xe00002c5)`. Quit Photos and Image Capture first. On macOS 27, `killall ptpcamerad` returned 0 but left the daemon running. Stopping it immediately before the command worked:

```sh
kill -9 $(pgrep -x -U "$(id -u)" ptpcamerad); npm run dialin -- camera usb info
```

launchd restarts the daemon, and it takes the camera again before the next command, so repeat this before every USB command. Alternatively, add `--release-macos-camera-daemon` to a `camera usb` command. Only after a refused claim, and only on macOS, it sends SIGKILL to your user's `ptpcamerad` and retries the claim for about one second. This stops a system daemon that restarts on its own and interrupts any import it was serving from another device. It never runs without the flag.

```sh
# These commands contact the attached camera only when you explicitly run them.
npm run dialin -- camera usb info
npm run dialin -- camera usb backup --backup "$HOME/.dialin-private/before-inspection.json"

# This command changes the explicitly listed recipe slots.
npm run dialin -- camera usb apply --in .dialin/camera/preparation.json --backup "$HOME/.dialin-private/before-apply.json" --confirm-write --out .dialin/camera/result.json
```

Each backup destination must be new and outside the repository. The wrapper writes raw snapshots of **all seven custom slots** to a private mode-600 file, flushes the file and directory, and reads it back before any recipe name/property mutation. The backup contains the camera's serial and raw slot bytes; keep it private. Public command output contains a path/hash receipt, not that raw content or serial. This slot backup is not a full-camera settings file.

Grain Off is written as `1`; the X100VI 1.10 reads it back as `6` or `7` (Off-Small/Off-Large). Readback accepts exactly that equivalence for Grain Off. Every other property, the name and all protected slots must match byte for byte.

Before writing, the wrapper checks the connected model, exact firmware, serial presence, slot-edit capability, every slot's edit-cursor readback, complete raw slot snapshots, and unchanged camera identity. It uses the shared encoder, verifies the target cursor again before writing, and requires every write acknowledgement. A refused property stops the write sequence; a refused DR is not silently lowered. Every required property and name needs independent readback, followed by final target and protected-slot snapshot comparison and another identity check.

`verified_current_session` means those current-session checks passed. It does not claim restart persistence, successful photographs, Bluetooth acceptance, or a verified full-camera recovery. A partial write can change the camera: `not_verified` retains the backup, reports attempted slots, exits 3, and stops subsequent targets after an immediate failure. It does not automatically retry or restore. Inspect the camera and recovery path before trying again. Whole-settings restore is a different, much broader operation and is not exposed here as one-slot undo.

## Another body? Share a read-only report

Writes stay limited to verified profiles in [`profiles.ts`](profiles.ts): today only X100VI 1.10. `camera prepare` and `camera usb apply` refuse every other body or firmware, exactly as before. Owners of other bodies can help with a report that changes nothing ([guide](../../docs/ADD-YOUR-CAMERA.md)):

```sh
npm run dialin -- camera report --out my-camera-report.json   # add --release-macos-camera-daemon on macOS if needed
npm run dialin -- camera profile --in my-camera-report.json    # maintainers: read-only draft profile + diff against X100VI 1.10
```

The report (`dialin.camera-report.v1`) records model, firmware, USB mode, supported PTP operation and property codes, and each custom slot's raw values. It omits the serial, Y-number, MAC address, owner and copyright text, and slot names unless `--include-slot-names` is given, and refuses to write a file that would contain the serial. It works on unknown bodies and says that writes stay unsupported there. Every command goes through a read-only guard: PTP reads, plus the slot edit cursor D18C set to C1–C7. **Reading slots does move that cursor**, because a slot can only be read with the cursor on it. The cursor is a USB edit pointer, not the active shooting bank, and moving it writes no recipe value (the same moves `usb backup` makes; the X100VI 1.10 backups and readbacks above matched byte for byte). The report visits the slots so that its last move returns the cursor to where it started, and re-reads that slot to show nothing changed. `--current-slot-only` sends no property write at all and reads one slot. A refused property is recorded and skipped; an unanswered one (10 s) ends the session with a partial report and no further commands, so the cursor may stay moved.

## Transport status

| Path | Available implementation | Public desktop behavior | Evidence boundary |
|---|---|---|---|
| USB-C | Node PTP transport, shared recipe encoder, guarded preparation/apply wrapper | `camera usb info`, `backup`, `apply`; explicit confirmation and fresh private backup required | [Supervised runs](../../docs/FIRST-RUN-VALIDATION.md#physical-camera-session-2026-10-15) on one X100VI 1.10 / macOS 27: write to C7 and exact restore both `verified_current_session`; the written look survived a power cycle. Photographic preference and Linux/Windows hardware not checked. X100VI 1.10 only. |
| Bluetooth | Python protocol tools and native protected settings-file writer | `camera bluetooth backup` and supervised `trial-*`; `camera prepare --transport bluetooth` reports blocked production readiness, and `camera bluetooth apply` refuses | `BLESlotWriter.wirelessWritesValidated` is false. [One experimental C7 trial](../../docs/FIRST-RUN-VALIDATION.md#wireless-session-2026-10-16) returned verified with owner menu confirmation; its power-cycle check was not performed. |
| Wi-Fi | Existing BLE handoff and native PTP/IP photo import | `import wifi`; Bluetooth wakes the connection, then Wi-Fi transfers photographs. See the [photo import component](../import/README.md) | [Seven full-size JPEGs](../../docs/FIRST-RUN-VALIDATION.md#wireless-session-2026-10-16) imported on the same body/firmware/Mac. Photo return is separate from recipe transfer; RAW, phone/Photos and recovery checks are not inferred. |

The research Python CLI in `ble/` is still present. It requires Python and `ble/requirements.txt` (`bleak`), with OS Bluetooth permissions. Its scan/capture paths can print or save pairing material; they are not wrapped as public JSON commands here. Do not paste their unredacted output into issues. No Bluetooth scan, pairing, restore, or camera test runs during installation, preparation, help, or demo.

## Lower-level native package appendix

Contributors working on the existing native transport can use the local Swift package at `ios/DialInCamera` (Swift 6.2, macOS 26 / iOS 26). This is not required for the computer workflow above.

In an existing package, add `.package(path: "path/to/dialin/ios/DialInCamera")` and the `DialInCamera` product. `import DialInCamera` exposes `FujiSettingsFile.LookPlacement`; its `{slot, recipe}` JSON shape is the same as the preparation artifact. Decode the artifact's `placements` and `protected_slots`, then use the protected overload:

```swift
import DialInCamera

// In an explicitly invoked operation with validated placements and protected slots:
let link = CameraLink.usb()
let report = try await link.load(
    placements: placements,
    protectedSlots: Set(protectedSlots),
    onBackup: persistFreshPrivateBackupOrThrow
)
await link.disconnect()
```

`persistFreshPrivateBackupOrThrow` must durably save the supplied `SlotBackup` before returning; a persistence error must throw. Always disconnect on error as well. Do not replace this overload with positional `load(looks:)`, whose slot assignment and older backup behavior differ. The existing `dialin-cam load` command also expects a different positional format; a preparation artifact is not a drop-in input for it.

The protected wireless API is `BLESlotWriter.write(placements, to: camera, allowInferred: false, protectedSlots: ..., onBackup: ...)`. Its production gate remains in effect. Do not enable `allowInferred`, use a fake camera flag with real hardware, or substitute whole-file Python restore to claim the gate passed.

## Verify without hardware

```sh
node --import tsx --test tests/modules/camera*.test.ts
npm run typecheck
```

The tests use original synthetic recipes, synthetic camera identities, fake ports, and temporary private backup files. `camera-report.test.ts` drives the report against fake X-T5-like, 4-slot and X100VI bodies that record every PTP command, and checks that only edit-cursor moves are sent, the cursor returns, the slots are unchanged and the JSON holds no serial, MAC, owner or copyright text. They cover validation, slot intent, tampered artifact claims, identity changes, incomplete backups, cursor mismatches, refused acknowledgements, missing readbacks, interrupted writes, protected-slot changes, output refusal, and exact preparation semantics. They make no network or camera calls.

## Desktop Bluetooth tools

`node scripts/dialin.mjs camera bluetooth --help` exposes the existing native backup and supervised single-slot trial through the desktop dispatcher. Build the helper explicitly with `node scripts/dialin.mjs native build`. See [the wireless guide](../../docs/WIRELESS.md) for preparation, experimental write, post-restart check and restoration. `camera bluetooth status` is offline; `camera bluetooth apply` refuses before device access. Production recipe writes remain gated. The trial requires a new private workspace and explicit lab flags and does not qualify other bodies, firmware or multi-slot writes.
