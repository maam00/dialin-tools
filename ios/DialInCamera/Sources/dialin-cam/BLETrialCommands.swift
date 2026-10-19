// dialin-cam ble-trial-*: ONE supervised Bluetooth single-slot settings write on an X100VI fw 1.10, for the physical
// evidence that `BLESlotWriter.wirelessWritesValidated` still lacks. Lab-only: each live command needs
// --lab-single-slot-trial, never flips the production gate, and refuses unless its preconditions hold.
//
//   ble-trial-prepare <ble-backup.dat> --slot N --recipe r.json --out <new dir>     OFFLINE: build + review the exact file
//   ble-trial-write  --review <dir> --out <new dir> --lab-single-slot-trial --i-understand-this-is-experimental
//   ble-trial-check  --trial <write dir> --out <new dir> --lab-single-slot-trial  (read-only, after a power cycle)
//   ble-trial-restore --trial <write dir> --out <new dir> --lab-single-slot-trial --i-understand-this-is-experimental
//
// The write binds to the review: the writer's fresh backup (same Bluetooth connection as the upload) must hold exactly
// the reviewed C1–C7 bytes, and the file about to go out must carry exactly the reviewed byte changes. Everything is
// kept (mode 600) in a new folder before anything is sent. No retry, no whole-file restore, no allowInferred.
#if os(macOS)
import DialInCamera
import Foundation
import IOKit
import Synchronization

@MainActor
enum BLETrialCLI {
    static let commands: Set<String> = ["ble-trial-prepare", "ble-trial-write", "ble-trial-check", "ble-trial-restore", "ble-trial-compare"]
    static let labFlag = "--lab-single-slot-trial"
    static let consentFlag = "--i-understand-this-is-experimental"

    static let usage = """
        dialin-cam ble-trial-prepare <ble-backup.dat> --slot N --recipe <recipe.json> --out <new dir>
            OFFLINE. Build the exact settings file a one-slot Bluetooth trial would send from that backup (the decoded
            .dat that ble-backup saved). Refuses anything outside C<N>'s record + the checksum's low half. Writes
            baseline.dat, prepared.dat, review.json, REVIEW.txt.
        dialin-cam ble-trial-write --review <dir> --out <new dir> \(labFlag) \(consentFlag) [--name "Dial In"]
            LIVE. USB must be unplugged. Fresh backup on the same Bluetooth connection, kept before anything is sent;
            its C1–C7 must equal the reviewed baseline; the file sent must equal the review. One upload + read-back.
        dialin-cam ble-trial-check --trial <write dir> --out <new dir> \(labFlag) [--name "Dial In"]
            LIVE, read-only. After switching the camera off and on: compare it with the exact transmitted file.
        dialin-cam ble-trial-restore --trial <write dir> --out <new dir> \(labFlag) \(consentFlag) [--name "Dial In"]
            LIVE. Put back C<N>'s exact bytes from that trial's safety backup, merged onto a fresh backup.
        dialin-cam ble-trial-compare <before.dat> <after.dat> [--slot N] [--cross-transport] [--out report.json]
            OFFLINE. Where two settings files differ: header, checksum halves, each slot, the frame counter, the
            changing span seen on 10/13, anything else. Exit 0 when only C<N> + checksum low half + those spans (and,
            with --cross-transport for a USB file vs a Bluetooth one, header byte 0x47) differ; 3 otherwise.
        Exit: 0 verified · 3 sent but not verified / nothing sent by the camera's answer · 1 refused or failed before sending.
        BLESlotWriter.wirelessWritesValidated stays false; this is evidence gathering, not support.
        """

    struct Args {
        var command = ""
        var positional: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        static let valued: Set<String> = ["--slot", "--recipe", "--out", "--review", "--trial", "--name"]

        init(_ argv: [String]) {
            var it = argv.makeIterator()
            while let a = it.next() {
                if Self.valued.contains(a) {
                    values[a] = it.next() ?? ""
                } else if a.hasPrefix("-") {
                    flags.insert(a)
                } else if command.isEmpty {
                    command = a
                } else {
                    positional.append(a)
                }
            }
        }

        func require(_ key: String) throws -> String {
            guard let v = values[key], !v.isEmpty else { throw CameraError.invalid("\(command) needs \(key)") }
            return v
        }

        func onlyKnown(_ flags: Set<String>, _ values: Set<String>) throws {
            let unknown = self.flags.subtracting(flags.union(["--verbose", "-v"])).union(Set(self.values.keys).subtracting(values))
            guard unknown.isEmpty else {
                throw CameraError.invalid("\(command): unknown option(s) \(unknown.sorted().joined(separator: ", ")); nothing was sent")
            }
        }
    }

    static func run(_ argv: [String]) async throws -> Int32 {
        let a = Args(argv)
        if a.flags.contains("--help") || a.flags.contains("-h") {
            print(usage)
            return 0
        }
        switch a.command {
        case "ble-trial-prepare": try prepare(a); return 0
        case "ble-trial-write": return try await write(a)
        case "ble-trial-check": return try await check(a)
        case "ble-trial-restore": return try await restore(a)
        case "ble-trial-compare": return try compare(a)
        default: throw CameraError.invalid("unknown command \(a.command)\n\n\(usage)")
        }
    }

    // MARK: prepare (offline)

    static func prepare(_ a: Args) throws {
        try a.onlyKnown([], ["--slot", "--recipe", "--out"])
        guard a.positional.count == 1, let input = a.positional.first else {
            throw CameraError.invalid("ble-trial-prepare needs exactly one decoded Bluetooth backup (.dat)")
        }
        guard let slot = Int(try a.require("--slot")) else { throw CameraError.invalid("--slot must be a number 1–7") }
        let baseline = try Data(contentsOf: URL(fileURLWithPath: input))
        let placement = try BLESlotTrialLab.placement(fromJSON: Data(contentsOf: URL(fileURLWithPath: try a.require("--recipe"))), slot: slot)
        let (file, review) = try BLESlotTrialLab.prepare(baseline: baseline, placement: placement)
        let out = try newPrivateDirectory(try a.require("--out"))
        try durable(baseline, out.appendingPathComponent("baseline.dat"))
        try durable(file, out.appendingPathComponent("prepared.dat"))
        try durable(try json(review), out.appendingPathComponent("review.json"))
        let text = reviewText(review)
        try durable(Data(text.utf8), out.appendingPathComponent("REVIEW.txt"))
        print(text)
        print("saved \(out.path) (offline; no camera contacted)")
    }

    static func reviewText(_ r: BLESlotTrialLab.Review) -> String {
        let region = String(format: "[0x%X, 0x%X)", r.slotRegion[0], r.slotRegion[1])
        var lines = [
            "ONE-SLOT BLUETOOTH TRIAL REVIEW (offline)",
            "camera \(r.model) ··\(r.serialSuffix) · slot C\(r.slot) · record \(region)",
            "look: \(r.recipe.slotName) — \(FujiSettingsFile.describe(r.recipe))",
            String(format: "checksum low half 0x%04X → 0x%04X (delta 0x%04X); high half, header, C1–C6 and every byte outside C%d unchanged",
                   r.checksumBefore, r.checksumAfter, r.checksumDelta, r.slot),
            "\(r.changes.count) changed byte(s), all inside C\(r.slot):",
        ]
        let anchor = r.slotRegion[0] + 0x80
        for c in r.changes {
            lines.append(String(format: "  0x%05X (C%d %@0x%03X)  %02X → %02X", c.offset, r.slot, c.offset >= anchor ? "+" : "-",
                                abs(c.offset - anchor), c.before, c.after))
        }
        lines.append("patch: " + r.patchLines.joined(separator: " | "))
        lines.append("baseline sha256 \(r.baselineSHA256)")
        lines.append("prepared sha256 \(r.preparedSHA256)")
        lines.append("production gate wirelessWritesValidated = \(r.wirelessWritesValidated)")
        return lines.joined(separator: "\n")
    }

    // MARK: compare (offline)

    static func compare(_ a: Args) throws -> Int32 {
        try a.onlyKnown(["--cross-transport"], ["--slot", "--out"])
        guard a.positional.count == 2 else { throw CameraError.invalid("ble-trial-compare needs two settings files") }
        let slot = a.values["--slot"].flatMap(Int.init)
        let c = try BLESlotTrialLab.compare(Data(contentsOf: URL(fileURLWithPath: a.positional[0])),
                                            Data(contentsOf: URL(fileURLWithPath: a.positional[1])))
        func hex(_ o: [Int]) -> String { o.isEmpty ? "-" : o.prefix(12).map { String(format: "0x%X", $0) }.joined(separator: " ") + (o.count > 12 ? " …(\(o.count))" : "") }
        print("identical: \(c.identical)")
        print("header: \(hex(c.header))   checksum low: \(hex(c.checksumLow))   checksum high: \(hex(c.checksumHigh))")
        for s in 1...7 { print("C\(s): \(c.slots[String(s)]?.count ?? 0) byte(s) \(hex(c.slots[String(s)] ?? []))") }
        print("frame counter span: \(hex(c.frameCounter))   10/13 changing span: \(hex(c.observedChanging))")
        print("OTHER (unexplained): \(hex(c.other))")
        let ok = c.onlyExpected(slot: slot, crossTransport: a.flags.contains("--cross-transport"))
        print(ok ? "ONLY EXPECTED DIFFERENCES" + (slot.map { " (C\($0))" } ?? "") : "REVIEW: unexpected differences; stop the trial and preserve both files")
        if let path = a.values["--out"] {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try durable(try e.encode(c), URL(fileURLWithPath: path))
        }
        return ok ? 0 : 3
    }

    // MARK: write (live)

    static func write(_ a: Args) async throws -> Int32 {
        try a.onlyKnown([labFlag, consentFlag], ["--review", "--out", "--name"])
        try requireLab(a, consent: true)
        let reviewDir = URL(fileURLWithPath: try a.require("--review"))
        let review = try JSONDecoder().decode(BLESlotTrialLab.Review.self, from: Data(contentsOf: reviewDir.appendingPathComponent("review.json")))
        let baseline = try Data(contentsOf: reviewDir.appendingPathComponent("baseline.dat"))
        let reviewedPrepared = try Data(contentsOf: reviewDir.appendingPathComponent("prepared.dat"))
        try BLESlotTrialLab.revalidate(review: review, baseline: baseline, prepared: reviewedPrepared)
        try requireNoUSBCamera()
        let out = try newPrivateDirectory(try a.require("--out"))
        try durable(try json(review), out.appendingPathComponent("review.json"))
        let placement = FujiSettingsFile.LookPlacement(slot: review.slot, recipe: review.recipe)
        let protected = Set(1...7).subtracting([review.slot])
        print("trial: C\(review.slot) ← \"\(review.recipe.slotName)\" over Bluetooth; C\(protected.sorted().map(String.init).joined(separator: ",C")) protected; production gate stays \(BLESlotWriter.wirelessWritesValidated)")
        let fresh = Mutex<Data?>(nil)
        let stop = Mutex<String?>(nil)
        let link = FujiBluetoothLink(clientName: a.values["--name"] ?? "Dial In", log: { print("  · \($0)") })
        let t0 = ContinuousClock.now
        let outcome: BLESlotWriter.Outcome
        do {
            outcome = try await BLESlotWriter.writeExperimental(
                [placement], to: link, expectedIdentity: BackupIdentity(baseline), experimental: true,
                protectedSlots: protected, timing: .real,
                onSafetyBackup: { b0 in
                    try durable(b0.data, out.appendingPathComponent("safety-b0.dat"))
                    try durable(b0.wireData, out.appendingPathComponent("safety-b0.wire"))
                    do {
                        let outside = try BLESlotTrialLab.requireReviewedSlots(fresh: b0.data, reviewedBaseline: baseline)
                        print("  fresh backup kept (\(b0.data.count) bytes, wire \(b0.wireData.count)); C1–C7 equal the review; \(outside.count) byte(s) before C1 differ (carried as the camera has them now)")
                    } catch {
                        stop.withLock { $0 = "\(error)" }
                        throw error
                    }
                    fresh.withLock { $0 = b0.data }
                },
                onPrepared: { written in
                    try durable(written, out.appendingPathComponent("sent.dat"))
                    do {
                        guard let b0 = fresh.withLock({ $0 }) else { throw BLESlotTrialLab.Refusal("no fresh backup") }
                        try BLESlotTrialLab.requireMatchesReview(prepared: written, fresh: b0, review: review)
                        print("  the file about to be sent carries exactly the reviewed \(review.changes.count) byte change(s) + checksum")
                    } catch {
                        stop.withLock { $0 = "\(error)" }
                        throw error
                    }
                },
                onStep: { step in if case .uploading(let f, let n) = step, f == n || f % 4 == 0 { print("  upload \(f)/\(n) frames") } })
        } catch {
            link.disconnect()
            let why = stop.withLock { $0 }
            try? durable(Data(("NOT SENT\n" + (why ?? "\(error)") + "\n").utf8), out.appendingPathComponent("result.txt"))
            print("STOPPED BEFORE ANY RESTORE REQUEST: \(why ?? "\(error)")")
            return 1
        }
        link.disconnect()
        try record(outcome, seconds: ContinuousClock.now - t0, to: out)
        print("result: \(outcome.result) in \(CLI.ms(since: t0))")
        for v in outcome.verdicts { print("  C\(v.slot) \(v.name): \(v.verdict)") }
        print("""
            Saved \(out.path). Next: note the camera's screen; switch it OFF and ON; then
              dialin-cam ble-trial-check --trial \(out.path) --out \(out.path)-check \(labFlag)
            and the independent USB read-back from the runbook.
            """)
        return outcome.result == .verified ? 0 : 3
    }

    // MARK: check (live, read-only)

    static func check(_ a: Args) async throws -> Int32 {
        try a.onlyKnown([labFlag], ["--trial", "--out", "--name"])
        try requireLab(a, consent: false)
        let trial = URL(fileURLWithPath: try a.require("--trial"))
        let review = try JSONDecoder().decode(BLESlotTrialLab.Review.self, from: Data(contentsOf: trial.appendingPathComponent("review.json")))
        let sent = try Data(contentsOf: trial.appendingPathComponent("sent.dat"))
        try requireNoUSBCamera()
        let out = try newPrivateDirectory(try a.require("--out"))
        let link = FujiBluetoothLink(clientName: a.values["--name"] ?? "Dial In", log: { print("  · \($0)") })
        let t0 = ContinuousClock.now
        let outcome = try await BLESlotWriter.checkExperimental(
            [.init(slot: review.slot, recipe: review.recipe)], on: link, expectedIdentity: BackupIdentity(sent), expected: sent,
            experimental: true, timing: .real)
        link.disconnect()
        try record(outcome, seconds: ContinuousClock.now - t0, to: out)
        print("check: \(outcome.result)")
        for v in outcome.verdicts { print("  C\(v.slot) \(v.name): \(v.verdict)") }
        return outcome.result == .verified ? 0 : 3
    }

    // MARK: restore (live)

    static func restore(_ a: Args) async throws -> Int32 {
        try a.onlyKnown([labFlag, consentFlag], ["--trial", "--out", "--name"])
        try requireLab(a, consent: true)
        let trial = URL(fileURLWithPath: try a.require("--trial"))
        let review = try JSONDecoder().decode(BLESlotTrialLab.Review.self, from: Data(contentsOf: trial.appendingPathComponent("review.json")))
        let old = try Data(contentsOf: trial.appendingPathComponent("safety-b0.dat"))
        try requireNoUSBCamera()
        let out = try newPrivateDirectory(try a.require("--out"))
        let link = FujiBluetoothLink(clientName: a.values["--name"] ?? "Dial In", log: { print("  · \($0)") })
        let t0 = ContinuousClock.now
        let result: BLESlotWriter.RestoreOutcome
        do {
            result = try await BLESlotWriter.restoreExperimental(
                old, slots: [review.slot], to: link, experimental: true, backupFirmware: "1.10",
                protectedSlots: Set(1...7).subtracting([review.slot]), timing: .real,
                onSafetyBackup: { fresh in
                    try durable(fresh.data, out.appendingPathComponent("safety-fresh.dat"))
                    try durable(fresh.wireData, out.appendingPathComponent("safety-fresh.wire"))
                })
        } catch {
            link.disconnect()
            print("STOPPED: \(error)")
            return 1
        }
        link.disconnect()
        if let w = result.written { try durable(w, out.appendingPathComponent("sent.dat")) }
        if let after = result.after { try durable(after, out.appendingPathComponent("after.dat")) }
        let summary: [String: Any] = [
            "result": "\(result.result)", "slots": result.slots, "seconds": Double((ContinuousClock.now - t0).components.seconds),
            "lines": result.lines, "wireless_writes_validated": BLESlotWriter.wirelessWritesValidated,
        ]
        try durable(try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), out.appendingPathComponent("result.json"))
        print("restore: \(result.result)")
        switch result.result {
        case .verified, .alreadyThere: return 0
        default: return 3
        }
    }

    // MARK: Guards and evidence

    static func requireLab(_ a: Args, consent: Bool) throws {
        guard a.flags.contains(labFlag) else {
            throw CameraError.invalid("\(a.command) is a supervised lab trial: add \(labFlag) (production Bluetooth writes stay disabled)")
        }
        if consent && !a.flags.contains(consentFlag) {
            throw CameraError.invalid("\(a.command) sends a modified settings file: add \(consentFlag)")
        }
        guard !BLESlotWriter.wirelessWritesValidated else { throw CameraError.invalid("unexpected production gate state") }
    }

    /// 2026-10-13: with the camera's USB cable still attached, the camera answered every Bluetooth backup with
    /// BACKUP_STATE 0000 (busy). Refuse up front; also fail closed if the USB registry can't be read.
    static func requireNoUSBCamera() throws {
        guard let attached = fujifilmUSBAttached() else { throw CameraError.invalid("couldn't check USB devices; nothing was sent") }
        if attached {
            throw CameraError.invalid("a Fujifilm USB device is attached. Unplug the cable from the camera first; nothing was sent")
        }
    }

    /// Whether a Fujifilm (USB vendor 0x04CB) device is attached; nil when the USB registry can't be read.
    /// 2026-10-16: with the cable attached, an X100VI 1.10 also answered every Wi-Fi FUNCTION_LAUNCH with AP state 00 80
    /// (busy), six times over two runs, including right after ptpcamerad was stopped.
    static func fujifilmUSBAttached() -> Bool? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while true {
            let s = IOIteratorNext(it)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            if let v = IORegistryEntryCreateCFProperty(s, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
               v == 0x04CB {
                return true
            }
        }
        return false
    }

    static func record(_ o: BLESlotWriter.Outcome, seconds: Duration, to out: URL) throws {
        if let after = o.after { try durable(after, out.appendingPathComponent("after.dat")) }
        let summary: [String: Any] = [
            "result": "\(o.result)", "model": o.model, "firmware": o.firmware ?? "?",
            "seconds": Double(seconds.components.seconds),
            "backup_sha256": BLESlotTrialLab.sha256(o.backup),
            "sent_sha256": o.written.map(BLESlotTrialLab.sha256) ?? NSNull(),
            "after_sha256": o.after.map(BLESlotTrialLab.sha256) ?? NSNull(),
            "after_equals_sent": o.after != nil && o.after == o.written,
            "verdicts": o.verdicts.map { "C\($0.slot) \($0.name): \($0.verdict)" },
            "lines": o.lines,
            "wireless_writes_validated": BLESlotWriter.wirelessWritesValidated,
        ]
        try durable(try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), out.appendingPathComponent("result.json"))
    }

    static func json(_ r: BLESlotTrialLab.Review) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(r)
    }

    /// A new folder only (never reused), mode 700.
    static func newPrivateDirectory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CameraError.invalid("\(url.path) already exists; use a new folder (nothing is overwritten)")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// New file, mode 600, flushed and read back identical, or throw.
    nonisolated static func durable(_ data: Data, _ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CameraError.invalid("\(url.lastPathComponent) already exists") }
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CameraError.invalid("couldn't write \(url.path)")
        }
        let h = try FileHandle(forWritingTo: url)
        try h.synchronize()
        try h.close()
        guard try Data(contentsOf: url) == data else { throw CameraError.invalid("\(url.lastPathComponent) read back differently") }
    }
}
#endif
