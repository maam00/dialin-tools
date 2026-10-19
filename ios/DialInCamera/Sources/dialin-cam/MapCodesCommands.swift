// dialin-cam map-codes: measure the settings-file codes that aren't confirmed yet, on the real camera over USB.
// Run it only with the camera's owner present. The engine and every safety step are DialInCamera CodeMap (CodeMap.swift);
// this file is arguments, files and printing.
#if os(macOS)
import DialInCamera
import Foundation

@MainActor
enum MapCodesCLI {
    static let usage = """
        dialin-cam map-codes --slot N [--dry-run] [--only film_sim,white_balance,color,noise_reduction] [--out codes.json] [--rehearse]
            Camera: CONNECTION MODE › USB RAW CONV./BACKUP RESTORE, on the cable. Borrows C<N> and puts it back.
            1. backs up C1–C7 and the settings file (backups/), before anything is written
            2. writes a confirmed baseline look into C<N> and checks it against the confirmed codes (stops if it's off)
            3. for each film simulation / white balance / color / NR value whose code isn't confirmed: writes it into
               C<N> over the USB slot props (read back), downloads the settings file, records C<N>'s byte
            4. puts C<N> back (its look, its name, the hidden WB-shift and colour bytes) and verifies it twice:
               PTP read-back, and the settings file byte for byte against the first backup
            5. saves the codes as JSON (default backups/codes-<time>.json) for: npm run codes -- merge <file> [--write]
            --dry-run prints the plan and contacts no camera. --rehearse runs against a pretend X100VI in this process
            (files go to backups/rehearsal/). Unknown options are refused before anything happens.
        """

    static func run(_ argv: [String]) async throws {
        let o = CLI.Options(argv)
        if o.flags.contains("--help") || o.flags.contains("-h") { print(usage); return }
        try CLI.rejectUnknownFlags(o, allowed: ["--slot", "--dry-run", "--rehearse", "--only", "--out"])
        guard o.positional.isEmpty else {
            throw CameraError.invalid("map-codes takes no file argument (got \(o.positional.joined(separator: " "))); nothing was written")
        }
        guard let s = o.values["--slot"], let slot = Int(s), (1...7).contains(slot) else {
            throw CameraError.invalid("map-codes needs --slot 1–7 (the slot it borrows and puts back); nothing was written")
        }
        let only = try o.values["--only"].map(CodeMap.parseFields)
        let probes = try CodeMap.probes(only: only)
        let toMap = probes.filter { !$0.isControl }
        if o.flags.contains("--dry-run") {
            CodeMap.plan(slot: slot, probes: probes, backups: o.backupsDir).forEach { print($0) }
            if toMap.isEmpty { print("Every value in scope is confirmed already: a run would only check the controls.") }
            return
        }
        guard !toMap.isEmpty else {
            print("Every value in scope already has a confirmed code. Nothing to map; nothing was written.")
            return
        }
        let rehearse = o.flags.contains("--rehearse")
        let dir = rehearse ? "\(o.backupsDir)/rehearsal" : o.backupsDir
        let stamp = SlotBackup.fileStamp()
        let savers = CodeMap.Savers(
            slots: { b in
                let path = "\(dir)/slots-\(stamp)-map-codes.json"
                try CLI.makeParentSync(path)
                try b.jsonData().write(to: URL(fileURLWithPath: path))
                return path
            },
            settings: { data, label in
                let path = "\(dir)/settings-\(stamp)-map-codes-\(label).dat"
                try CLI.makeParentSync(path)
                try data.write(to: URL(fileURLWithPath: path))
                return path
            })
        print("map-codes: \(toMap.count) value(s) to map in C\(slot), plus \(probes.count - toMap.count) control(s)")
        let report = try await CLI.withCamera(o, transport: rehearse ? RehearsalSlotCamera() : nil) { cam in
            try await CodeMap.run(cam, slot: slot, probes: probes, rehearsal: rehearse, save: savers, log: { print($0) })
        }
        let out = o.values["--out"] ?? "\(dir)/codes-\(stamp).json"
        try CLI.makeParent(out)
        try report.jsonData().write(to: URL(fileURLWithPath: out))
        print("")
        for c in report.codes {
            let guess = c.agrees.map { $0 ? "the X-T5 guess was right" : "the X-T5 guess said \(c.inferred.map(String.init) ?? "?")" } ?? ""
            print("  \(c.field) \(c.value) → \(c.file.map(String.init) ?? "?")" + (c.shiftEntry.map { ", shift entry \($0)" } ?? "")
                + (guess.isEmpty ? "" : " (\(guess))") + (c.write == "clean" ? "" : " · NOT CLEAN: \(c.write)"))
        }
        for k in report.skipped { print("  skipped \(k.field) \(k.value): \(k.why)") }
        if let why = report.aborted { print("STOPPED EARLY: \(why)") }
        print("controls: " + (report.controls.allSatisfy(\.ok) ? "all ok" : report.controls.filter { !$0.ok }.map(\.what).joined(separator: ", ")))
        print(report.restore.verdict)
        print("saved \(out) (\(report.codes.count) code(s), \(report.seconds) s)")
        if !report.codes.isEmpty && !rehearse { print("next: npm run codes -- merge \(out)    (shows what it adds; then --write)") }
        guard report.restore.ok else { throw CameraError.invalid("C\(slot) wasn't fully restored; see the line above") }
    }
}
#endif
