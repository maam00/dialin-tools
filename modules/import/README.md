# Retrieve photographs on your computer

You can use your usual SD-card reader, Image Capture, XApp transfer, or file sync, then point `photos prepare` at the resulting JPEG folder. The planning and editing tools do not require Dial In to perform the import.

See [What works today](../../docs/CAPABILITIES.md) for supported routes and their evidence. Already have JPEG/PNG files? Start with the [photo component](../photos/README.md) instead.

For an SD card, copy its `DCIM` folder (or that day's files) to your computer first, then prepare the copy. Preparation only reads the source, but export later needs the same originals present and unchanged; a removed card makes export stop with a "missing or changed" message. Subfolders such as `100_FUJI` are included, RAW/HEIF files are listed as unsupported, and the selected JPEGs are what export copies.

The repository also contains a camera import engine in `ios/DialInCamera`. Despite the historical folder name, its `dialin-cam` executable is a **macOS desktop tool**. It supports folder, USB, Wi-Fi and Photos-library sources; the Photos-library route looks only for X100VI files. Using the executable does not require building an iPhone app or writing Swift.

## Optional macOS helper

This existing helper requires macOS 26+ and a Swift 6.2+ toolchain. It is an advanced setup path while portable packaging is being improved. From the root:

```sh
node scripts/dialin.mjs doctor import
scripts/with-build-lock.sh -- swift build --package-path ios/DialInCamera
swift build --package-path ios/DialInCamera --show-bin-path
```

The last command prints the directory containing `dialin-cam`. Run `dialin-cam import-folder --help` before choosing an operation; it prints the usage for every import route (`import-folder`, `import-usb`, `import-wifi`, `import-photos`). Defaults matter: each route takes only **today's** photos unless you pass `--since YYYY-MM-DD`, `--all` or `--last N`, and writes to `~/Pictures/Dial In/<date>/` unless you pass `--dest <dir>`. `--last N` selects the newest N files regardless of date when used alone; RAF and JPEG count separately when the source offers both. The importer can copy RAF files (`--no-raw` skips them), but Wi-Fi RAF delivery is not physically qualified. `--dry-run` shows the plan without copying; for device routes it still contacts the camera and Wi-Fi may still change the Mac's network.

The day folder holds original-byte copies, a `manifest.json` and hidden camera thumbnails in `.thumbs/`. Pass that day folder to `photos prepare`: hidden thumbnails are ignored, and `manifest.json` and RAF files appear in the coverage report as unsupported files.

### Wi-Fi evidence and limits

On [2026-10-16](../../docs/FIRST-RUN-VALIDATION.md#wireless-session-2026-10-16), one X100VI on firmware 1.10 and one macOS 27 Mac completed `import-wifi --last 7`: seven full-size JPEGs, about 37 MB in 21 seconds. Every file decoded and matched the camera's listed size. The fixes prime each file with `GetObjectInfo` before thumbnail/partial reads and avoid date probing for `--last N`; see [protocol details](../../docs/FUJIFILM-PROTOCOL.md#56-downloading).

The default wireless route wakes the camera over Bluetooth and joins its access point, temporarily taking this Mac off its usual Wi-Fi. It requires an explicitly requested device session, a paired camera (or explicit pairing), applicable macOS permissions and the USB cable removed. The helper refuses the Bluetooth wake while a Fujifilm USB device is attached. It attempts to return to the previous network; the single successful import does not establish recovery from every interrupted session. Keep command logs private: they can contain local paths and network identities.

Date-filtered transfers, larger/mixed-format cards, Wi-Fi RAW delivery, secure-profile firmware, other bodies/hosts and the integrated phone/Photos path remain unqualified. Wi-Fi retrieval and Bluetooth settings upload are different operations: production modified Bluetooth recipe writes remain blocked despite one experimental single-slot trial.

For developers embedding the import engine, the actual public interfaces are `PhotoSource`, `PhotoImporter.run`, `ImportLibrary`, and `ImportOptions`. They are optional lower-level APIs. See the source and [existing import notes](../../ios/DialInCamera/IMPORT.md); older operational notes contain maintainer-specific paths and are not the desktop onboarding instructions.
