# Optional native import interfaces

Use your normal SD-card or operating-system import to bring photographs to a local folder, then start `modules/photos/README.md`. A camera is unnecessary when you already have photographs.

Start from the desktop dispatcher: `node scripts/dialin.mjs native build`, then `node scripts/dialin.mjs import --help`. It exposes `import wifi`, `import usb` (USB-C) and `import folder` with explicit ranges/destinations and JSON receipts. Bluetooth handles pairing/Wi-Fi startup; **Wi-Fi carries the photo transfer**. See the [wireless setup guide](../../docs/WIRELESS.md) for first pairing and current hardware limits. Bluetooth settings backup and experimental recipe trials are separate `camera bluetooth` commands.

The lower-level macOS `dialin-cam` executable also includes `import-folder`, `import-usb`, `import-wifi` and `import-photos` commands. It requires macOS 26+ and Swift 6.2+. Build it explicitly through `scripts/with-build-lock.sh`; inspect `dialin-cam --help` before a device session. These interfaces preserve source photographs and expose local import/library metadata. A `--dry-run` can still contact a device and change Wi-Fi; it only prevents copying.

Wi-Fi code performs the Fujifilm access-point wake/join/PTP-IP flow. It requires explicit camera interaction and applicable macOS permissions; the Bluetooth wake refuses while a Fujifilm USB device is attached. Joining the camera temporarily takes the Mac off its usual Wi-Fi. The helper attempts to return to the previous network, but recovery from every interrupted session is not established. Keep command logs private because they can contain paths and network identities.

On [2026-10-16](../../docs/FIRST-RUN-VALIDATION.md#wireless-session-2026-10-16), one X100VI 1.10 and one macOS 27 Mac completed `import-wifi --last 7`, saving seven full-size, decodable JPEGs with lengths matching the camera listing. `--last N` alone chooses the newest N files without date filtering. Date-filtered transfers, Wi-Fi RAF, secure firmware, other bodies/hosts and integrated phone/Photos handoff remain unqualified. See [What works today](../../docs/CAPABILITIES.md) and the [desktop import guide](../../modules/import/README.md).

The desktop commands run the selected native route only when explicitly requested and report actual results, including partial transfers. No export, installation check or fixture demo contacts a camera. Review actual outputs and original-file identities after any separately authorized real import.
