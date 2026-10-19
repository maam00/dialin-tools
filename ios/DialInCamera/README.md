# Optional native camera library

`DialInCamera` contains USB/PTP, Bluetooth, Wi-Fi retrieval, slot encoding, backup/readback/recovery, mock transports and the `dialin-cam` executable. It supports Swift 6.2 on macOS/iOS 26. Existing TypeScript USB and Python protocol tools remain independent.

Run software checks from the repository root using the shared build lock:

```sh
scripts/with-build-lock.sh swift test --package-path ios/DialInCamera
```

Tests use synthetic transports/metadata. Optional private-file checks skip when their locally supplied fixtures are absent. No backup or paired identity is distributed. `release/ASSET-PROVENANCE.json` records generated fixtures, and `THIRD_PARTY_NOTICES.md` records ported implementation credits.

Read `modules/camera/README.md` for desktop preparation and guarded USB execution, and [What works today](../../docs/CAPABILITIES.md) for the shared support summary. The admitted USB write target is X100VI firmware 1.10, physically exercised on one macOS host. Broader bodies/firmware are research or discovery targets, not demonstrated write support.

Modified production Bluetooth writes remain blocked; the export preserves `BLESlotWriter.wirelessWritesValidated = false`. One [experimental C7 trial](../../docs/FIRST-RUN-VALIDATION.md#wireless-session-2026-10-16) returned verified with owner menu confirmation on 2026-10-16. Its power-cycle check was not performed. The lab write requires both `--lab-single-slot-trial` and `--i-understand-this-is-experimental` and does not enable production writes.

The engineering commands `dialin-cam ble-restore` and `dialin-cam settings-put` are separate whole-file operations. Bluetooth `ble-restore` requires `--i-understand-this-is-experimental`; USB `settings-put` requires `--i-understand-this-overwrites-every-setting` for a real upload (`--dry-run` sends nothing). They replace every camera setting, not only selected slots. A successful experimental C7 modification is not acceptance of arbitrary edited files or full-camera recovery. Fresh backup, checked identity, readback and a same-body recovery plan are required around explicitly requested real writes.

See [import interfaces](IMPORT.md) for USB, Wi-Fi and folder retrieval. Seven full-size JPEGs were imported on the same X100VI 1.10/Mac in the dated session above; this does not qualify RAW, date-filtered import, reconnection recovery or phone/Photos behavior. A passing package test is software evidence only.
