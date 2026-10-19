// dialin-cam: bench tool for the X100VI on a Mac, using the same DialInCamera library the iPhone app ships.
// USB goes through ImageCaptureCore (ptpcamerad), so there is no `killall ptpcamerad` dance like the libusb tools.
//
//   dialin-cam info                      model, firmware, USB mode, whether slot editing is available
//   dialin-cam show                      print what's in C1–C7
//   dialin-cam backup [file]             save C1–C7 (same JSON as `npm run cam backup`) — do this before any write
//   dialin-cam write-test [--slot 7] [--recipe look.json]
//                                        back up C1–C7, then write one harmless test look into C7 and read it back
//   dialin-cam restore <file> [--slot N] put a slot backup back (all slots in the file, or just N)
//   dialin-cam settings-get [file]       download the whole-camera settings file (FUJIFILMX-BACKUP, ~33 KB)
//   dialin-cam settings-put <file> --i-understand-this-overwrites-every-setting   (--dry-run: show what it would send)
//   dialin-cam rename --slot 7 --name "TEST C7"   change ONLY a slot's name (for checksum experiments)
//   dialin-cam check <expected.json>     read C1–C7 and compare with the props in a slots JSON (e.g. apply-plan --expected)
//   dialin-cam map-codes --slot N [--dry-run]   map unconfirmed settings-file codes through one slot, put it back (MapCodesCommands.swift)
//   dialin-cam ble-scan [--seconds 15]   list Fujifilm bodies advertising over Bluetooth
//   dialin-cam ble-backup [--pair] [--name "Dial In"] [file]
//                                        download the settings file over Bluetooth
//   dialin-cam ble-restore <file> --i-understand-this-is-experimental [--profile p.json] [--no-verify-after]
//                                        EXPERIMENTAL: upload a settings file over Bluetooth (profile from a capture)
//   dialin-cam props --read [--all | --codes D001,…] [--json [file]]   READ-ONLY live-state probe (LiveCommands.swift)
//   dialin-cam look-live <recipe.json> [--only …] [--snapshot f] [--dry-run]   apply a look to the live state, C1–C7 untouched
//   dialin-cam look-restore <snapshot.json> [--dry-run]                         undo look-live
//   dialin-cam settings-patch <in.dat> --out <out.dat> --slot N --name "X"      OFFLINE settings-file edit + checksum
// Options: --verbose (log every PTP transaction / BLE step), --timeout <s> (wait for the camera, default 30),
//          --catalog <s> (wait for ImageCaptureCore's catalog, default 15), --backups <dir> (default ./backups)
#if os(macOS)
import CryptoKit
import DialInCamera
import Foundation

@MainActor
enum CLI {
    struct Options {
        var command = "help"
        var positional: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]

        init(_ args: [String]) {
            var it = args.makeIterator()
            var first = true
            let valued: Set<String> = [
                "--slot", "--seconds", "--name", "--timeout", "--backups", "--recipe", "--catalog", "--profile", "--only", "--out",
            ]
            while let a = it.next() {
                if valued.contains(a) {
                    values[a] = it.next() ?? ""
                } else if a.hasPrefix("-") {
                    flags.insert(a == "-v" ? "--verbose" : a)
                } else if first {
                    command = a
                    first = false
                } else {
                    positional.append(a)
                }
            }
        }

        var verbose: Bool { flags.contains("--verbose") }
        var timeout: Duration { .seconds(Int(values["--timeout"] ?? "") ?? 30) }
        var backupsDir: String { values["--backups"] ?? "backups" }
        /// How long to let ImageCaptureCore list the camera after opening the session (default 15 s).
        var catalog: Duration { .seconds(Int(values["--catalog"] ?? "") ?? 15) }
    }

    /// Commands that write to the camera refuse flags they don't know, so a typo or a flag another command takes
    /// (e.g. `load plan.json --dry-run` before load had one) can never turn into a real write.
    static func rejectUnknownFlags(_ o: Options, allowed: Set<String>) throws {
        let common: Set<String> = ["--verbose", "--timeout", "--catalog", "--backups"]
        let unknown = o.flags.subtracting(allowed).subtracting(common)
            .union(Set(o.values.keys).subtracting(allowed).subtracting(common))
        if !unknown.isEmpty {
            throw CameraError.invalid("\(o.command): unknown option(s) \(unknown.sorted().joined(separator: ", ")); nothing was written")
        }
    }

    /// Distinctive but harmless: DR100 (no ISO floor), clarity 0 (no save pause), plain tones you can check in the
    /// camera's menu. Restore with the backup taken just before.
    static let testLook = Recipe(
        name: "DialIn Test", filmSim: .classicChrome, grain: .weakSmall, colorChrome: .weak, colorChromeFxBlue: .off,
        whiteBalance: .daylight, kelvin: 0, wbShiftR: 2, wbShiftB: -3, dynamicRange: .dr100, highlight: -0.5, shadow: 1,
        color: 1, sharpness: -1, noiseReduction: -2, clarity: 0, why: "dialin-cam write-test")

    static func run(_ args: [String]) async -> Int32 {
        let o = Options(args)
        do {
            switch o.command {
            case "info": try await info(o)
            case "show", "backup": try await showOrBackup(o)
            case "write-test": try await writeTest(o)
            case "load": try await load(o)
            case "restore": try await restore(o)
            case "settings-get": try await settingsGet(o)
            case "settings-put": try await settingsPut(o)
            case "rename": try await rename(o)
            case "check": return try await check(o) ? 0 : 3
            case "map-codes": try await MapCodesCLI.run(args)                                   // MapCodesCommands.swift
            case "ble-scan": try await bleScan(o)
            case "ble-backup": try await bleBackup(o)
            case "ble-restore": try await bleRestore(o)
            case _ where ImportCLI.commands.contains(o.command): try await ImportCLI.run(args)   // ImportCommands.swift
            case _ where RawConvCLI.commands.contains(o.command): try await RawConvCLI.run(args) // RawConvCommands.swift
            case _ where LiveCLI.commands.contains(o.command): try await LiveCLI.run(args)       // LiveCommands.swift
            case _ where BLETrialCLI.commands.contains(o.command): return try await BLETrialCLI.run(args) // BLETrialCommands.swift
            case "help", "-h", "--help":
                print(usage)
            default:
                print("unknown command \(o.command)\n\n\(usage)")
                return 2
            }
            return 0
        } catch let e as CameraError {
            print("error: \(e.description)")
        } catch let e as FujiBLEError {
            print("error: \(e.description)")
        } catch {
            print("error: \(error)")
        }
        return 1
    }

    static let usage = """
        dialin-cam <command> [options]
          info                       model, firmware, USB mode, slot editing yes/no
          show                       print C1–C7
          backup [file]              save C1–C7 as JSON (default backups/slots-<stamp>.json)
          write-test [--slot 7] [--recipe look.json]
                                     back up C1–C7, write a test look into C7, read it back
          load <plan.json>           back up C1–C7, then write the plan's looks into C1… in one session
          restore <file> [--slot N]  put a slot backup back
          settings-get [file]        download the whole-camera settings file (FUJIFILMX-BACKUP)
          settings-put <file> --i-understand-this-overwrites-every-setting   [--dry-run: show, send nothing]
          rename --slot N --name "X"  change only C<N>'s name (prints the undo command)
          check <expected.json>      compare C1–C7 with a slots JSON (exit 3 on any difference)
          map-codes --slot N [--dry-run] [--only film_sim,white_balance,color,noise_reduction] [--out f.json] [--rehearse]
                                     back up, then map the settings-file codes that aren't confirmed yet through C<N>
                                     (USB slot props), put C<N> back and verify (map-codes --help)
          ble-scan [--seconds 15]    list Fujifilm bodies advertising over Bluetooth
          ble-backup [--pair] [--name "Dial In"] [file]
                                     download the settings file over Bluetooth
          ble-restore <file> --i-understand-this-is-experimental [--profile p.json] [--pair] [--no-verify-after]
                                     (the standard Bluetooth restore unless --profile; docs/FUJIFILM-PROTOCOL.md §3.7)
                                     EXPERIMENTAL Bluetooth restore (profile: python -m fuji_ble.restore_profile)
          import-usb | import-wifi | import-folder | import-photos
                                     copy today's photos to ~/Pictures/Dial In (dialin-cam import-usb --help; IMPORT.md)
          rawconv <file.RAF> [--unchanged] [--recipe r.json | --variants v.json] [--out dir]
                                     re-render a RAF in the camera with other looks (D185 only, never C1–C7; rawconv --help)
          props --read [--all | --codes D001,5005] [--json [file]]
                                     READ-ONLY: what the camera advertises and every live prop's value, decoded
          look-live <recipe.json> [--only film_sim,white_balance] [--snapshot f.json] [--dry-run]
                                     apply a look to the CURRENT shooting state (live codes), C1–C7 untouched
          look-restore <snapshot.json> [--dry-run]
                                     undo look-live from its snapshot
          settings-patch <in.dat> --out <out.dat> [--slot N --name "X"] [--set N:key=value] [--allow-hypothesis]
                                     OFFLINE: edit a settings backup, fix its checksum, check the round trip
          ble-trial-prepare | ble-trial-write | ble-trial-check | ble-trial-restore
                                     LAB ONLY: one reviewed Bluetooth single-slot write (ble-trial-write --help);
                                     production Bluetooth writes stay disabled
        options: --verbose  --timeout <s>  --catalog <s>  --backups <dir>
        """

    // MARK: USB

    /// Connect, run `body`, always close the session. `quiet` sends the progress lines to stderr (stdout stays data).
    /// `transport` replaces USB (the `--rehearse` fakes).
    static func withCamera<T>(_ o: Options, quiet: Bool = false, transport injected: (any PTPTransport)? = nil,
                              _ body: (FujiCamera) async throws -> T) async throws -> T {
        let say: @Sendable (String) -> Void
        if quiet {
            say = { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        } else {
            say = { line in print(line) }
        }
        let transport: any PTPTransport
        if let injected {
            transport = injected
            say("REHEARSAL: a pretend X100VI in this process; nothing leaves this Mac")
        } else {
            let usb = ImageCaptureTransport(catalogTimeout: o.catalog)
            if o.verbose { usb.trace = { say("  · \($0)") } }
            transport = usb
            say("looking for the camera on USB (up to \(o.timeout))…")
        }
        let cam = FujiCamera(transport: transport, timing: injected == nil ? .camera : .immediate, log: { say("  \($0)") })
        let t0 = ContinuousClock.now
        do {
            try await cam.connect(timeout: o.timeout)
        } catch {
            await cam.disconnect()
            throw error
        }
        say("\(await cam.model) connected in \(ms(since: t0))")
        do {
            let result = try await body(cam)
            await cam.disconnect()
            return result
        } catch {
            await cam.disconnect()
            throw error
        }
    }

    static func info(_ o: Options) async throws {
        try await withCamera(o) { cam in
            let info = await cam.deviceInfo
            let props = Set(info.properties)
            print("manufacturer \(info.manufacturer) · model \(info.model) · firmware \(info.deviceVersion) · serial \(info.serialNumber.isEmpty ? "?" : "…" + info.serialNumber.suffix(4))")
            print("slot editing: \(props.contains(FujiProp.slot) ? "yes" : "no") · \(props.count) properties · \(info.operations.count) operations")
            if let mode = try await cam.usbMode() {
                let label = [5: "USB TETHER SHOOTING", 6: "USB RAW CONV./BACKUP RESTORE", 8: "webcam"][mode] ?? "unknown"
                print("USB mode (D16E): \(mode) = \(label)")
            } else {
                print("USB mode (D16E): not readable")
            }
            for id in [FujiProp.tetherCondition, FujiProp.compatibilityCode] {
                if let p = try await cam.readProp(id) {
                    let shown = p.stringValue ?? p.bytes.hexString
                    print("\(String(format: "%04X", id)): \(shown)")
                }
            }
            let block = Array(0xD18C...0xD1A5).map { UInt16($0) }
            let missing = block.filter { !props.contains($0) }
            print("slot block D18C–D1A5 advertised: \(block.count - missing.count)/\(block.count)"
                + (missing.isEmpty ? "" : " (missing: \(missing.map { String(format: "%04X", $0) }.joined(separator: " ")))"))
        }
    }

    static func showOrBackup(_ o: Options) async throws {
        let backup = try await withCamera(o) { cam -> SlotBackup in
            let t = ContinuousClock.now
            let b = try await cam.backup()
            print("read 7 slots in \(ms(since: t))")
            return b
        }
        for s in backup.slots { print(s.line) }
        if o.command == "backup" {
            let path = try save(backup, to: o.positional.first, o)
            print("saved \(path)")
        }
    }

    static func writeTest(_ o: Options) async throws {
        try rejectUnknownFlags(o, allowed: ["--slot", "--recipe", "--name"])
        let slot = Int(o.values["--slot"] ?? "7") ?? 7
        guard (1...7).contains(slot) else { throw CameraError.invalid("--slot must be 1–7") }
        var look = testLook
        if let file = o.values["--recipe"] {
            look = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        }
        print("test look for C\(slot): \"\(look.slotName)\" — \(look.filmSim.rawValue), \(look.dynamicRange.rawValue), WB \(look.whiteBalance.rawValue) R\(look.wbShiftR) B\(look.wbShiftB), H\(look.highlight) S\(look.shadow) C\(look.color)")
        try await withCamera(o) { cam in
            // 1. Safety net first: every slot, saved before anything changes.
            let t = ContinuousClock.now
            let backup = try await cam.backup()
            let path = try save(backup, to: nil, o)
            print("backed up C1–C7 in \(ms(since: t)) → \(path)")
            let before = backup.slots[slot - 1]
            print("before: \(before.line)")
            // 2. Write.
            let plan = SlotEncoder.plan(slot: slot, recipe: look, base: before.rawProps)
            print("plan (\(plan.count) SetDevicePropValue): " + plan.map(\.description).joined(separator: " "))
            let tw = ContinuousClock.now
            let report = try await cam.writeSlot(slot, recipe: look, base: before.rawProps)
            print("wrote in \(ms(since: tw)): " + (report.isClean
                ? "CLEAN, every prop read back identical"
                : "WITH NOTES (\(report.rejected.count) refused, \(report.mismatched.count) didn't stick; see the line above)"))
            // 3. Read back what the camera now holds.
            let after = try await cam.readSlot(slot)
            print("after:  \(after.line)")
            print("""

                Next: unplug, press Q / turn to C\(slot), check the name and values in the menu; power-cycle and check again
                (does it stick? does C\(slot) show as modified/unsaved?).
                Undo: dialin-cam restore \(path) --slot \(slot)
                """)
        }
    }

    /// Write a whole day plan ({"plan":{"looks":[…]}}, a {"looks":[…]} object, or a bare array of recipes) into C1…CN.
    static func load(_ o: Options) async throws {
        try rejectUnknownFlags(o, allowed: ["--dry-run"])
        guard let file = o.positional.first else { throw CameraError.invalid("load needs a plan .json") }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file)))
        let lookObjects: [Any]
        if let arr = json as? [Any] { lookObjects = arr }
        else if let obj = json as? [String: Any], let plan = obj["plan"] as? [String: Any], let arr = plan["looks"] as? [Any] { lookObjects = arr }
        else if let obj = json as? [String: Any], let arr = obj["looks"] as? [Any] { lookObjects = arr }
        else { throw CameraError.invalid("no looks found in \(file)") }
        let looks = try lookObjects.prefix(7).map { try JSONDecoder().decode(Recipe.self, from: JSONSerialization.data(withJSONObject: $0)) }
        guard !looks.isEmpty else { throw CameraError.invalid("plan has no looks") }
        for (i, l) in looks.enumerated() {
            print("C\(i + 1) \"\(l.slotName)\" — \(l.filmSim.rawValue), \(l.dynamicRange.rawValue), WB \(l.whiteBalance.rawValue) R\(l.wbShiftR) B\(l.wbShiftB), H\(l.highlight) S\(l.shadow) C\(l.color)")
        }
        if o.flags.contains("--dry-run") {
            print("dry run: would back up C1–C7, then write C1–C\(looks.count). No camera contacted.")
            return
        }
        try await withCamera(o) { cam in
            let t = ContinuousClock.now
            let backup = try await cam.backup()
            let path = try save(backup, to: nil, o)
            print("backed up C1–C7 in \(ms(since: t)) → \(path)")
            let tw = ContinuousClock.now
            var clean = 0
            for (i, look) in looks.enumerated() {
                let slot = i + 1
                let report = try await cam.writeSlot(slot, recipe: look, base: backup.slots[i].rawProps)
                if report.isClean { clean += 1 }
                print("C\(slot) \(report.isClean ? "OK" : "NOTES: " + (report.rejected + report.mismatched).joined(separator: "; "))")
            }
            print("wrote \(looks.count) slots in \(ms(since: tw)) · \(clean)/\(looks.count) clean")
            print("\nUnplug, press Q, turn through C1–C\(looks.count). Undo everything: dialin-cam restore \(path)")
        }
    }

    static func restore(_ o: Options) async throws {
        try rejectUnknownFlags(o, allowed: ["--slot"])
        guard let file = o.positional.first else { throw CameraError.invalid("restore needs a backup file") }
        var backup = try SlotBackup.decode(Data(contentsOf: URL(fileURLWithPath: file)))
        if let only = o.values["--slot"].flatMap(Int.init) { backup.slots = backup.slots.filter { $0.slot == only } }
        guard !backup.slots.isEmpty else { throw CameraError.invalid("no matching slots in \(file)") }
        print("restoring \(backup.slots.map { "C\($0.slot)" }.joined(separator: ", ")) from \(file) (\(backup.model), \(backup.at))")
        try await withCamera(o) { cam in
            let reports = try await cam.restore(backup.slots)
            print(reports.allSatisfy(\.isClean) ? "restored cleanly" : "restored with notes (see above)")
        }
    }

    static func settingsGet(_ o: Options) async throws {
        try await withCamera(o) { cam in
            let t = ContinuousClock.now
            let file = try await cam.getSettingsFile()
            let header = SettingsFileHeader(file)
            let path = o.positional.first ?? "\(o.backupsDir)/settings-\(SlotBackup.fileStamp()).dat"
            try makeParent(path)
            try file.write(to: URL(fileURLWithPath: path))
            let magic = String(decoding: file.prefix(16), as: UTF8.self)
            print("\(file.count) bytes in \(ms(since: t)) · magic \"\(magic)\" · model \"\(header.model)\""
                + (header.magicOK ? " · payload 0x\(String(header.payloadStart, radix: 16))+\(header.payloadLength) (\(header.lengthConsistent ? "consistent" : "INCONSISTENT"))" : ""))
            print("saved \(path)")
        }
    }

    static func settingsPut(_ o: Options) async throws {
        guard let file = o.positional.first else { throw CameraError.invalid("settings-put needs a .dat file") }
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let h = SettingsFileHeader(data)
        guard h.magicOK else { throw CameraError.invalid("\(file) is not a FUJIFILMX-BACKUP file") }
        guard h.lengthConsistent else {
            throw CameraError.invalid("\(file): header payload length doesn't match the file size (truncated or not a settings file)")
        }
        print("\(file): \(data.count) bytes · sha256 \(sha256Hex(data).prefix(16))… · \(h.model) serial …\(h.serial.suffix(4)) · v\(h.version)")
        let names = SettingsFileNames.read(data)
        if !names.isEmpty { print("slot names in the file: " + names.enumerated().map { "C\($0.offset + 1) \"\($0.element)\"" }.joined(separator: " · ")) }
        if o.flags.contains("--dry-run") {
            print("DRY RUN: nothing sent. Power-cycle the camera, USB RAW CONV./BACKUP RESTORE, then re-run without --dry-run as the FIRST thing.")
            return
        }
        guard o.flags.contains("--i-understand-this-overwrites-every-setting") else {
            throw CameraError.invalid("This replaces EVERY camera setting. Power-cycle the camera, then re-run with --i-understand-this-overwrites-every-setting")
        }
        try await withCamera(o) { cam in
            let model = await cam.model
            guard model.isEmpty || model == h.model else {
                throw CameraError.invalid("this file is from a \(h.model) but the camera is a \(model)")
            }
            let t = ContinuousClock.now
            try await cam.putSettingsFile(data)
            print("camera accepted the file in \(ms(since: t)). Power-cycle it, then: dialin-cam show (and settings-get to diff).")
        }
    }

    /// Change only one slot's name: two settings files that differ in exactly one known field pin the checksum.
    static func rename(_ o: Options) async throws {
        guard let slot = o.values["--slot"].flatMap(Int.init), (1...7).contains(slot) else { throw CameraError.invalid("rename needs --slot 1–7") }
        guard let name = o.values["--name"] else { throw CameraError.invalid("rename needs --name \"New name\"") }
        if name.count > 14 { print("note: \(name.count) characters; the PTP writer keeps names ≤14 (the camera allows up to 25)") }
        try await withCamera(o) { cam in
            let (old, now) = try await cam.renameSlot(slot, to: name)
            print(now == name ? "C\(slot): \"\(old)\" → \"\(now)\" (read back OK)" : "C\(slot): wrote \"\(name)\" but it reads back \"\(now)\"")
            print("undo: dialin-cam rename --slot \(slot) --name \"\(old)\"")
        }
    }

    /// Compare the camera's C1–C7 with a slots JSON (only the props the JSON lists; grain 1 = 6/7 = Off).
    static func check(_ o: Options) async throws -> Bool {
        guard let file = o.positional.first else { throw CameraError.invalid("check needs an expected slots .json") }
        let expected = try SlotBackup.decode(Data(contentsOf: URL(fileURLWithPath: file)))
        let actual = try await withCamera(o) { cam in try await cam.readAll() }
        var allOK = true
        for want in expected.slots {
            guard let got = actual.first(where: { $0.slot == want.slot }) else { continue }
            var diffs: [String] = []
            if !want.name.isEmpty && want.name != got.name { diffs.append("name \"\(got.name)\" (want \"\(want.name)\")") }
            let have = Dictionary(got.props.map { ($0.id, $0.hex) }, uniquingKeysWith: { a, _ in a })
            for p in want.props {
                guard let h = have[p.id] else { diffs.append(String(format: "%04X missing", p.id)); continue }
                let grainOff = p.id == Int(FujiProp.grain) && p.hex == "0100" && ["0600", "0700"].contains(h)
                if h != p.hex && !grainOff { diffs.append(String(format: "%04X ", p.id) + "\(h) (want \(p.hex))") }
            }
            allOK = allOK && diffs.isEmpty
            print("C\(want.slot) \"\(got.name)\": " + (diffs.isEmpty ? "OK (\(want.props.count) props)" : "DIFFERS: " + diffs.joined(separator: ", ")))
        }
        print(allOK ? "every listed prop matches" : "differences above")
        return allOK
    }

    // MARK: BLE

    static func bleScan(_ o: Options) async throws {
        let seconds = Int(o.values["--seconds"] ?? "15") ?? 15
        let link = FujiBluetoothLink(log: { line in if o.verbose { print("  · \(line)") } })
        print("scanning \(seconds) s for Fujifilm bodies (company 0x04D8)…")
        let found = try await link.scan(for: .seconds(seconds))
        if found.isEmpty {
            print("none heard. Camera on, Bluetooth ON (MENU › NETWORK/USB SETTING › Bluetooth settings)? A body connected to FUJIFILM's app on a phone doesn't advertise.")
        }
        for s in found {
            print("\(s.name)  rssi \(s.rssi) dBm  \(s.advert.kind.rawValue)  tag \(s.advert.tag)\(s.advert.token.map { "  token \($0.hexString)" } ?? "")  id \(s.id)")
        }
    }

    static func bleBackup(_ o: Options) async throws {
        if BLETrialCLI.fujifilmUSBAttached() == true {
            throw CameraError.invalid("a Fujifilm camera is attached over USB; with its cable in, the camera answers Bluetooth backups busy. Unplug the cable from the camera, then run this again")
        }
        let link = FujiBluetoothLink(clientName: o.values["--name"] ?? "Dial In", log: { print("  · \($0)") })
        let pairing = o.flags.contains("--pair")
        if pairing {
            print("pairing: open camera MENU › NETWORK/USB SETTING › Bluetooth/SMARTPHONE SETTING › PAIRING REGISTRATION and leave it open. Older firmware registers without a six-digit code; confirm a code only if the camera and macOS request it.")
        }
        let reg = try await link.connect(pairing: pairing)
        let id = await link.identity()
        print("registered (\(reg.mode)) · \(id["device_name"] ?? "?") model \(id["model"] ?? "?") firmware \(id["firmware"] ?? "?") · \(reg.subscribed.count) notifications")
        let t = ContinuousClock.now
        let result = try await link.backupSettings { bytes in
            if bytes % 4096 < 120 { print("  \(bytes) bytes…") }
        }
        let path = o.positional.first ?? "\(o.backupsDir)/ble-settings-\(SlotBackup.fileStamp()).dat"
        try makeParent(path)
        try result.data.write(to: URL(fileURLWithPath: path))
        if result.compressed {
            try result.wireData.write(to: URL(fileURLWithPath: path + ".wire.zlib"))
            print("preserved compressed wire file: \(path).wire.zlib (\(result.wireData.count) bytes; transport checksum applies to these bytes)")
        }
        let h = result.header
        print("""
            \(result.name): \(result.data.count) bytes (camera said \(result.reportedSize.map(String.init) ?? "?")) in \(ms(since: t))
              transfer checksum \(result.checksumOK == true ? "OK" : result.checksumOK == false ? "BAD" : "not sent"), \(result.chunks) chunks (\(result.seqReport))
              header: \(h.magicOK ? "FUJIFILMX-BACKUP v\(h.version) model \(h.model) payload 0x\(String(h.payloadStart, radix: 16))+\(h.payloadLength) (\(h.lengthConsistent ? "consistent" : "INCONSISTENT"))" : "no FUJIFILMX-BACKUP magic (first bytes \(result.data.prefix(16).hexString))")
            saved \(path)
            Compare with the USB copy: cmp \(path) <settings-get file>
            """)
    }

    static func bleRestore(_ o: Options) async throws {
        guard let file = o.positional.first else { throw CameraError.invalid("ble-restore needs a settings .dat file") }
        guard o.flags.contains("--i-understand-this-is-experimental") else {
            throw CameraError.invalid("Bluetooth restore is EXPERIMENTAL and replaces every setting. Re-run with --i-understand-this-is-experimental")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        var profile: FujiBLEFlows.RestoreProfile?
        if let profilePath = o.values["--profile"] {
            let p = try FujiBLEFlows.RestoreProfile.decode(Data(contentsOf: URL(fileURLWithPath: profilePath)))
            print("profile: \(p.source)\(p.captured ? " [CAPTURED]" : " [INFERRED]")")
            print("file: \(data.count) bytes, sha256 \(sha256Hex(data).prefix(16))…, \(p.frames(data).count) frames of \(p.chunkSize) bytes")
            profile = p
        } else {
            print("protocol: standard Bluetooth restore (RESTORE_REQUEST f1897eb9, 128-byte frames, each acknowledged)")
            print("file: \(data.count) bytes, sha256 \(sha256Hex(data).prefix(16))…, \(FujiBLE.restoreFrames(data).count) frames")
        }
        let link = FujiBluetoothLink(clientName: o.values["--name"] ?? "Dial In", log: { print("  · \($0)") })
        if o.flags.contains("--pair") { try await link.connect(pairing: true) }
        let dir = o.backupsDir
        let t = ContinuousClock.now
        let result = try await link.restoreSettings(
            data, profile: profile, experimental: true, verifyAfter: !o.flags.contains("--no-verify-after"),
            onSafetyBackup: { safety in
                let path = "\(dir)/ble-safety-\(SlotBackup.fileStamp()).dat"
                try CLI.makeParentSync(path)
                try safety.write(to: URL(fileURLWithPath: path))
                print("safety backup saved: \(path) (\(safety.count) bytes)")
            },
            progress: { done, total in if done % 50 == 0 || done == total { print("  \(done)/\(total) frames") } })
        print("sent \(result.framesSent) frames in \(ms(since: t)); final state \(result.finalState?.hexString ?? "none (assume NOT applied)")"
            + (result.verifiedIdentical.map { $0 ? "; the camera now serves exactly this file" : "; the camera's file differs (see log)" } ?? ""))
        print("Prove it: power-cycle the camera; check C1–C7; over USB: dialin-cam settings-get, then correlate diff.")
    }

    // MARK: Helpers

    nonisolated static func makeParentSync(_ path: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func save(_ backup: SlotBackup, to file: String?, _ o: Options) throws -> String {
        let path = file ?? "\(o.backupsDir)/slots-\(SlotBackup.fileStamp()).json"
        try makeParent(path)
        try backup.jsonData().write(to: URL(fileURLWithPath: path))
        return path
    }

    static func makeParent(_ path: String) throws {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func ms(since start: ContinuousClock.Instant) -> String {
        let d = ContinuousClock.now - start
        return "\(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)ms"
    }
}

// ImageCaptureCore delivers its callbacks through the main run loop, so keep it spinning and run the async CLI on
// the main actor (whose jobs the run loop also drains).
Task { @MainActor in
    let code = await CLI.run(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
CFRunLoopRun()
#else
print("dialin-cam runs on macOS only")
#endif
