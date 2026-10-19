# USB-C, Bluetooth and wireless photo import

The desktop toolkit contains all three transports. They do different jobs:

| Job | Command | Current support |
| --- | --- | --- |
| Load recipes over USB-C | `camera prepare` → `camera usb apply` | Supported on X100VI 1.10 and the tested Mac; backup, readback, restore and restart checks recorded |
| Retrieve photos wirelessly | `import wifi` | Bluetooth starts the camera's Wi-Fi; photos travel over Wi-Fi. Seven full-size JPEGs verified on X100VI 1.10 and one Mac |
| Back up settings over Bluetooth | `camera bluetooth backup` | Existing native backup route, now accessible from the desktop dispatcher |
| Test loading a recipe over Bluetooth | `camera bluetooth trial-*` | Experimental, one slot on X100VI 1.10; production recipe loading remains disabled |

The [capability table](CAPABILITIES.md) and [dated hardware evidence](FIRST-RUN-VALIDATION.md#wireless-session-2026-10-16) define the limits. Publishing a command does not qualify a new camera, firmware or host.

## Set up once on a Mac

```sh
npm ci --ignore-scripts
node scripts/dialin.mjs doctor import
node scripts/dialin.mjs native build
node scripts/dialin.mjs native status
```

The helper requires macOS 26+ and Swift 6.2+. This command builds the desktop executable under the shared build lock; no iPhone app, Swift editing, camera connection or pairing is involved. The generated helper stays under ignored `.dialin/native/`. After changing native source, build again: device commands refuse a stale helper and never build or download one implicitly. Setup checks and a successful build do not test a camera.

## Import over Wi-Fi

Ask the owner to confirm the camera and the photo range. Unplug the USB cable, turn the camera on, and enable Bluetooth. For the first registration on this Mac, enter the camera's pairing-registration screen and explicitly pass `--pair`:

```sh
node scripts/dialin.mjs import wifi --last 7 --dest .dialin/imported --pair --out .dialin/import-first.json
```

After registration, omit `--pair`. Older firmware may register without a six-digit code; confirm a code only if the camera and macOS request it. Grant Bluetooth and Local Network access to the terminal if macOS asks. The Mac temporarily joins the camera's Wi-Fi and loses its normal Wi-Fi internet connection. The helper attempts to return to the prior network when finished; interrupted-session recovery is not physically qualified.

The newest-file count includes RAF/JPEG entries separately before format filtering, so fewer files may be saved than requested. Choose exactly one of `--last N`, `--since YYYY-MM-DD` (also `today` or `yesterday`), or `--all`. JPEG/HEIF originals are included by default; `--include-raw` adds RAF, whose Wi-Fi delivery is not hardware-qualified. RAW and HEIF are not supported by the photo-review component. `--dry-run` copies no files but still connects to the real camera and can change the Mac's network. It is not an offline test.

The JSON receipt names dated photo folders in `summary.folders`, saved counts, failures and whether the run was interrupted. Diagnostics go to stderr. Keep both private. An incomplete run exits nonzero; completed originals and manifests remain in the destination, and rerunning can resume. Use a new `--out` receipt each time. If interrupted, check the Mac's Wi-Fi manually; the receipt never claims network restoration was verified.

Use a folder listed in the receipt as the input to `photos prepare`. Originals on the camera are never deleted. The existing alternatives are `import usb --last 7 --dest …` (camera in USB CARD READER mode), `import folder --from /path/to/DCIM --all --dest …`, or your usual SD-card/OS import.

Without a camera, explicitly rehearse the software path:

```sh
node scripts/dialin.mjs import wifi --rehearse --last 3 --dest .dialin/fake-import --out .dialin/fake-import.json
```

This starts a fake camera on loopback, exercises reconnect/resume, and creates synthetic files. It uses no Bluetooth and does not change Wi-Fi. The result is `fixture_rehearsal`, never physical import evidence or a photographic review.

## Bluetooth recipe trial

`camera bluetooth status` is offline. `camera bluetooth apply` always refuses before contacting a camera. The production gate stays closed until physical acceptance is complete. Do not patch it to make a trial pass.

The existing supervised trial is available from the same desktop dispatcher. Only use it when the owner is present, has confirmed X100VI firmware 1.10, and explicitly chooses the single slot that may be temporarily changed and restored. Do not infer any of those facts from these example commands. The examples use C7.

1. With USB unplugged, take a fresh private backup. Add `--pair` only for an explicitly requested first registration:

   ```sh
   node scripts/dialin.mjs camera bluetooth backup --workspace .dialin/ble-backup
   ```

2. Prepare a trial offline using one complete recipe JSON, then review `.dialin/ble-review/REVIEW.txt` and its settings changes:

   ```sh
   node scripts/dialin.mjs camera bluetooth trial-prepare --backup .dialin/ble-backup/settings.dat --recipe look.json --slot C7 --workspace .dialin/ble-review
   ```

3. Run the explicitly authorized experimental write. It checks the camera identity, preserves a fresh backup, requires all seven slots to match the review, limits edits to the selected slot, and reads back:

   ```sh
   node scripts/dialin.mjs camera bluetooth trial-write --review .dialin/ble-review --workspace .dialin/ble-write --lab-single-slot-trial --i-understand-this-is-experimental
   ```

4. Inspect the result. If verified, the owner confirms the look in the menu and switches the camera off and on. Then run the readback check:

   ```sh
   node scripts/dialin.mjs camera bluetooth trial-check --trial .dialin/ble-write --workspace .dialin/ble-check --lab-single-slot-trial
   ```

   The check compares the saved transmitted settings to a fresh readback. It cannot itself prove that the owner restarted the camera. Record that observation separately. On a failed or ambiguous write, preserve the workspace and inspect it before any further write.

5. Restore the original selected slot onto a fresh backup and verify it:

   ```sh
   node scripts/dialin.mjs camera bluetooth trial-restore --trial .dialin/ble-write --workspace .dialin/ble-restore --lab-single-slot-trial --i-understand-this-is-experimental
   ```

Every workspace must be new. It holds camera backups, identifiers and settings; never commit or attach it publicly. `--out` optionally saves a separate new JSON receipt. Raw whole-camera restore is not exposed as recipe loading. No command automatically promotes the production gate, and a single successful trial does not qualify multi-slot writes, other firmware or full-camera recovery.

## Remaining physical acceptance

The October 16 trial verified one modified C7 look in the current session; its restart check was not performed. Before enabling production Bluetooth loading, complete the supervised restart/readback and exact selected-slot restoration, verify protected slots and identity checks, and review recovery behavior and the supported settings/slot scope. Record only sanitized outcomes in the repository, then update the executable gate and capability documentation together. Repeat the public desktop Wi-Fi route on the camera; fake-camera tests remain software evidence.
