# Python Bluetooth protocol bench

This engineering component preserves independently usable GATT, backup decoder, transfer framing, restore guards, capture parsing, synthetic camera and field-map tools. It is separate from the portable desktop photo workflow.

Install `ble/requirements.txt` in a local virtual environment if using Bluetooth. Routine tests use synthetic transports and do not need radios:

```sh
python3 -B -m unittest discover -s ble/tests -v
```

Some optional cross-checks skip without externally supplied upstream references or real local backups. No captured backup, paired identity or capture file is shipped. Test-only bytes and regenerated vector origins are recorded in `release/ASSET-PROVENANCE.json`.

Use `python3 -m fuji_ble --help` from this directory to inspect the available commands. Reading help and preparing offline are distinct from explicit radio/device operations. Do not use engineering commands to bypass the desktop/native production Bluetooth write gate. A supervised real session must freshly check the intended body, firmware, slot scope, backup and readback.

`restore` is an experimental whole-settings Bluetooth restore, not selected-slot recipe loading. It prints a plan by default. With `--no-dry-run --i-understand-this-is-experimental` it takes a safety backup and then sends the supplied file, which replaces every camera setting. That includes a file edited with `python3 -m fuji_ble.x100vi_settings patch`, so this bench can perform a modified Bluetooth write outside the production gate. No physical acceptance receipt exists for it. `--allow-other-body` skips the same-camera check; don't use it.

Upstream code and protocol references are credited in `THIRD_PARTY_NOTICES.md` at repository root. The X100VI 1.10 map records observed versus inferred fields; inference is not device acceptance or broader firmware support.
