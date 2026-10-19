// dialin-cam props / look-live / look-restore / settings-patch.
//   props --read     read-only probe of the live (C0) state: GetDeviceInfo lists + GetDevicePropValue per code
//                    (docs/FUJIFILM-PROTOCOL.md §2.9). Sends nothing but 0x1015 after connecting.
//   look-live        apply a recipe to the CURRENT shooting state (live codes), C1–C7 untouched; snapshot first.
//   look-restore     put a snapshot back.
//   settings-patch   offline: rename a slot (or set a per-slot field) in a settings backup, fix the checksum, re-check.
// The engine is DialInCamera (FujiCamera.readLive / applyLive / restoreLive, LiveLook, FujiSettingsFile); this file is
// argument parsing and printing.
#if os(macOS)
import DialInCamera
import Foundation

@MainActor
enum LiveCLI {
    static let commands: Set<String> = ["props", "look-live", "look-restore", "settings-patch"]

    static let usage = """
        dialin-cam props --read [--all | --codes D001,5005,…] [--json [file.json]]
            READ-ONLY. Camera: CONNECTION MODE › USB RAW CONV./BACKUP RESTORE. Prints model, firmware, D16E, what
            GetDeviceInfo advertises (properties + operations), whether a look can go live, then each prop's value
            decoded. Default: every advertised prop. --all: also every catalogued code the camera doesn't list (their
            refusal codes are the answer). --json: the same as a snapshot file (stdout when no file is given).
        dialin-cam look-live <recipe.json> [--only film_sim,white_balance,…] [--snapshot out.json] [--dry-run]
            Apply a look to the camera's CURRENT state (live codes D001, 5005, D017, …), C1–C7 untouched. Reads the
            live values first and saves them (default backups/live-before-<stamp>.json) BEFORE writing. Each write is
            read back. --dry-run prints the exact writes and contacts no camera.
            --only groups: film_sim white_balance wb_shift dynamic_range tones grain color_chrome cc_fx_blue
                           smooth_skin color sharpness noise_reduction clarity (or codes, e.g. D001,5005)
        dialin-cam look-restore <snapshot.json> [--dry-run]
            Put a look-live snapshot (or a props --read --json file) back; only the codes look-live wrote.
        dialin-cam settings-patch <in.dat> --out <out.dat> [--slot N --name "NEW NAME"] [--set N:key=value …] [--allow-hypothesis]
            OFFLINE. Edit a settings backup (FUJIFILMX-BACKUP, X100VI fw 1.10), fix the checksum incrementally, write
            it, read it back and check that only the edited bytes and the checksum changed. Refuses to overwrite.
        --rehearse (props, look-live, look-restore): run against a built-in pretend X100VI that enforces the live
                   gates; nothing leaves this Mac. Each run starts from the same pretend live look.
        options: --verbose  --timeout <s>  --catalog <s>  --backups <dir>
        """

    struct Args {
        var command = ""
        var positional: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var sets: [String] = []
        /// `--json` with no file after it.
        var jsonToStdout = false

        static let valued: Set<String> = [
            "--codes", "--snapshot", "--only", "--out", "--slot", "--name", "--timeout", "--catalog", "--backups",
        ]

        init(_ argv: [String]) {
            var i = 0
            while i < argv.count {
                let a = argv[i]
                if Self.valued.contains(a) {
                    values[a] = i + 1 < argv.count ? argv[i + 1] : ""
                    i += 1
                } else if a == "--set" {
                    if i + 1 < argv.count { sets.append(argv[i + 1]) }
                    i += 1
                } else if a == "--json" {
                    if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") {
                        values["--json"] = argv[i + 1]
                        i += 1
                    } else {
                        jsonToStdout = true
                    }
                } else if a.hasPrefix("-") {
                    flags.insert(a == "-v" ? "--verbose" : a)
                } else if command.isEmpty {
                    command = a
                } else {
                    positional.append(a)
                }
                i += 1
            }
        }

        var backupsDir: String { values["--backups"] ?? "backups" }
        var rehearsal: FakeLiveCamera? { flags.contains("--rehearse") ? FakeLiveCamera() : nil }
    }

    static func run(_ argv: [String]) async throws {
        let a = Args(argv)
        if a.flags.contains("--help") || a.flags.contains("-h") { print(usage); return }
        switch a.command {
        case "props": try await props(a, argv)
        case "look-live": try await lookLive(a, argv)
        case "look-restore": try await lookRestore(a, argv)
        case "settings-patch": try settingsPatch(a)
        default: print(usage)
        }
    }

    // MARK: props --read

    static func props(_ a: Args, _ argv: [String]) async throws {
        guard a.flags.contains("--read") else {
            throw CameraError.invalid("props only reads for now: dialin-cam props --read [--all | --codes …] [--json [file]]")
        }
        let scope: LiveProbe.Scope
        if let list = a.values["--codes"] {
            guard let codes = LiveHex.codes(list) else { throw CameraError.invalid("--codes: comma-separated hex codes, e.g. D001,5005,D017") }
            scope = .codes(codes)
        } else {
            scope = a.flags.contains("--all") ? .all : .advertised
        }
        let quiet = a.jsonToStdout   // keep stdout pure JSON
        try await CLI.withCamera(CLI.Options(argv), quiet: quiet, transport: a.rehearsal) { cam in
            let info = await cam.deviceInfo
            let caps = LiveCapabilities(deviceInfo: info)
            let codes = LiveProbe.codes(scope, advertised: info.properties)
            let t = ContinuousClock.now
            let read = try await cam.readLive(codes)
            let mode = read.values[LiveProps.usbMode.code].flatMap { try? LiveCodec.decode($0, as: .uint16) }
            let snapshot = LiveSnapshot(model: info.model, firmware: info.deviceVersion, read: read, advertised: info.properties,
                                        operations: info.operations, redactingSerial: info.serialNumber)
            if quiet {
                print(String(decoding: try snapshot.jsonData(), as: UTF8.self))
                return
            }
            LiveProbe.summary(model: info.model, firmware: info.deviceVersion, usbMode: mode, caps: caps).forEach { print($0) }
            LiveProbe.listLines("properties advertised", info.properties).forEach { print($0) }
            LiveProbe.listLines("operations advertised", info.operations).forEach { print($0) }
            print("values (\(read.values.count) read, \(read.refused.count) refused, \(read.failed.count) failed, \(CLI.ms(since: t))):")
            LiveProbe.valueLines(read, advertised: Set(info.properties), serial: info.serialNumber).forEach { print($0) }
            if let path = a.values["--json"] {
                try CLI.makeParent(path)
                try snapshot.jsonData().write(to: URL(fileURLWithPath: path))
                print("saved \(path) (usable as a look-restore snapshot)")
            }
            print("read-only: only GetDeviceInfo and GetDevicePropValue were sent; nothing on the camera changed.")
        }
    }

    // MARK: look-live / look-restore

    static func lookLive(_ a: Args, _ argv: [String]) async throws {
        guard let file = a.positional.first else { throw CameraError.invalid("look-live needs a recipe .json\n\n\(usage)") }
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let only = try a.values["--only"].map(LiveLook.codes(forOnly:))
        let plan = LiveLook.plan(for: recipe, only: only)
        guard !plan.isEmpty else { throw CameraError.invalid("nothing to write: --only matched none of this look's codes") }
        print("look \"\(recipe.name)\": \(recipe.filmSim.rawValue), WB \(recipe.whiteBalance.rawValue)"
            + (recipe.whiteBalance == .kelvin ? " \(recipe.kelvin)K" : "") + ", \(recipe.dynamicRange.rawValue)"
            + (only == nil ? "" : " · only \(a.values["--only"] ?? "")"))
        print("live writes (\(plan.count) SetDevicePropValue, each read back; no D18C/D18D, C1–C7 untouched):")
        LiveLook.describe(plan).forEach { print("  " + $0) }
        if a.flags.contains("--dry-run") {
            print("DRY RUN: no camera contacted, nothing written.")
            return
        }
        let rehearsal = a.rehearsal
        let snapPath = a.values["--snapshot"]
            ?? "\(a.backupsDir)/live-\(rehearsal == nil ? "before" : "REHEARSAL")-\(SlotBackup.fileStamp()).json"
        guard !FileManager.default.fileExists(atPath: snapPath) else {
            throw CameraError.invalid("\(snapPath) exists; refusing to overwrite an undo file (pick another --snapshot)")
        }
        try CLI.makeParent(snapPath)
        try await CLI.withCamera(CLI.Options(argv), transport: rehearsal) { cam in
            let t = ContinuousClock.now
            let report = try await cam.applyLive(plan) { snap in
                try snap.jsonData().write(to: URL(fileURLWithPath: snapPath))
                print("snapshot of the live look saved BEFORE writing: \(snapPath)")
            }
            if let auto = report.autoUpdate {
                print("AUTO UPDATE CUSTOM SETTING (D307) reads \(auto.hexString): if it is ON and a C slot is selected, these writes may be saved into that slot")
            }
            print("applied in \(CLI.ms(since: t)): " + (report.isClean ? "CLEAN, every write read back identical" : "WITH NOTES"))
            report.lines.forEach { print("  " + $0) }
            print("""

                Check the camera's screen (unplug to see it, or look at the rear LCD): film simulation / WB icons.
                Undo: dialin-cam look-restore \(snapPath)
                """)
        }
    }

    static func lookRestore(_ a: Args, _ argv: [String]) async throws {
        guard let file = a.positional.first else { throw CameraError.invalid("look-restore needs a snapshot .json") }
        let snap = try LiveSnapshot.decode(Data(contentsOf: URL(fileURLWithPath: file)))
        let plan = LiveLook.restorePlan(snap)
        print("snapshot \(file): \(snap.model) fw \(snap.firmware), taken \(snap.at)"
            + (snap.touched.map { ", look-live wrote \($0.joined(separator: " "))" } ?? ", every look code in it"))
        print("restore writes (gate order; codes already at their snapshot value are skipped on the camera):")
        LiveLook.describe(plan).forEach { print("  " + $0) }
        if let k = snap.rawValues[LiveProps.colorTemperature.code], snap.touchedCodes?.contains(LiveProps.colorTemperature.code) ?? true,
           !plan.contains(where: { $0.propID == LiveProps.colorTemperature.code }) {
            print("  (+ D017 Kelvin \(LiveProbe.describe(LiveProps.colorTemperature.code, k)) first, if the camera is on Kelvin WB now)")
        }
        guard !plan.isEmpty else { print("nothing to restore"); return }
        if a.flags.contains("--dry-run") {
            print("DRY RUN: no camera contacted, nothing written.")
            return
        }
        try await CLI.withCamera(CLI.Options(argv), transport: a.rehearsal) { cam in
            let r = try await cam.restoreLive(snap)
            print("already right: \(r.alreadyRight.count) · " + r.write.line + (r.retry.map { " · second pass: " + $0.line } ?? ""))
            (r.write.hints + (r.retry?.hints ?? [])).forEach { print("  " + $0) }
            print(r.isClean ? "restored: every code matches the snapshot" : "STILL DIFFERENT:\n  " + r.differences.joined(separator: "\n  "))
            if !r.isClean { print("Manual fallback: set the listed items in the camera menu (IMAGE QUALITY SETTING).") }
        }
    }

    // MARK: settings-patch (offline)

    static func settingsPatch(_ a: Args) throws {
        guard let input = a.positional.first, let out = a.values["--out"], !out.isEmpty else {
            throw CameraError.invalid("settings-patch <in.dat> --out <out.dat> [--slot N --name \"NAME\"] [--set N:key=value …]")
        }
        var edits: [FujiSettingsFile.Edit] = []
        if let name = a.values["--name"] {
            guard let slot = a.values["--slot"].flatMap(Int.init) else { throw CameraError.invalid("--name needs --slot 1–7") }
            edits.append(.name(slot: slot, name))
        }
        edits += try a.sets.map(FujiSettingsFile.parseSet)
        guard !edits.isEmpty else { throw CameraError.invalid("nothing to change: --slot N --name NAME and/or --set N:key=value") }
        guard !FileManager.default.fileExists(atPath: out) else { throw CameraError.invalid("\(out) exists; refusing to overwrite") }

        let original = try FujiSettingsFile(Data(contentsOf: URL(fileURLWithPath: input)))
        print("\(input): \(FujiSettingsFile.model) settings file v\(original.version), \(original.bytes.count) bytes · "
            + String(format: "checksum 0x%04X, K = 0x%04X", original.storedChecksum, original.checksumConstant))
        print("names before: " + original.names.enumerated().map { "C\($0.offset + 1) \"\($0.element)\"" }.joined(separator: " · "))
        let r = try original.patched(edits, allowHypothesis: a.flags.contains("--allow-hypothesis"))
        r.lines.forEach { print("  " + $0) }

        // Write beside the target, read it back from disk, check, then move into place.
        let partial = out + ".partial"
        try CLI.makeParent(out)
        try r.file.data.write(to: URL(fileURLWithPath: partial))
        let problems = FujiSettingsFile.roundTripProblems(original: original, written: try Data(contentsOf: URL(fileURLWithPath: partial)), result: r)
        guard problems.isEmpty else {
            try? FileManager.default.removeItem(atPath: partial)   // our own temp file
            throw CameraError.invalid("round-trip check failed, nothing written: " + problems.joined(separator: "; "))
        }
        try FileManager.default.moveItem(atPath: partial, toPath: out)
        print("names after:  " + r.file.names.enumerated().map { "C\($0.offset + 1) \"\($0.element)\"" }.joined(separator: " · "))
        print(String(format: "round trip OK: only the edited bytes and the checksum differ; K 0x%04X unchanged. Wrote %@", r.file.checksumConstant, out))
        print("next: dialin-cam settings-put \(out) --dry-run   (then the real restore as the FIRST command after a power-cycle)")
    }
}
#endif
