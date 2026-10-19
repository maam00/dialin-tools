// `dialin-cam map-codes`: find the settings-file byte of every look value whose code isn't confirmed yet
// (ConfirmedCodes), on the real camera over USB, with its owner present. For each value: write it into ONE slot through the
// verified USB path (PTP slot props, FujiCamera.writeSlot, every prop read back), download the settings file, read
// that slot's byte. Then put the slot back exactly as it was and prove it. The result is JSON for
// `npm run codes -- merge`, which adds the codes to lib/cameras.ts, ConfirmedCodes.swift and the slot map.
//
// Safety, in order:
//   1 only an X100VI; C1–C7 (PTP) and the whole settings file are saved BEFORE anything is written, and the file must be
//     the fw 1.10 layout, or nothing is written
//   2 the first write is a baseline look made only of confirmed values, checked byte by byte against ConfirmedCodes
//     (a control): the wrong slot, a moved offset or another layout stops the sweep before any code is recorded
//   3 one value per probe, everything else held at the baseline; a B&W control (a confirmed mono sim) after the sims
//   4 always restore, also after an error mid-sweep: each WB-shift entry a probe touched gets its old value, a B&W
//     original gets its hidden colour values back, then the original look and name (FujiCamera.restore)
//   5 verify: the slot's props read back as backed up, and the settings file matches the first backup byte for byte
//     (the checksum and the frame counter aside)
import Foundation

public enum CodeMap {
    public static let kind = "dialin.codemap/1"
    /// The name the slot shows while probes are in it, so an interrupted run is obvious on the camera.
    public static let probeName = "Dial In map"
    /// Shifts written with a white-balance probe: one that sits in no entry of the slot yet, so the entry that takes it
    /// is the WB's entry.
    static let probeShifts: [(r: Int, b: Int)] = [(-7, 6), (6, -7), (-5, 8), (8, -5), (-8, -6)]
    static let entries = 14

    public enum Field: String, Codable, Sendable, CaseIterable {
        case filmSim = "film_sim", whiteBalance = "white_balance", color, noiseReduction = "noise_reduction"

        /// Where the byte sits, from the slot's anchor (ble/maps/x100vi-fw110.json).
        public var rel: Int {
            switch self {
            case .filmSim: 0x64
            case .whiteBalance: -0x0F
            case .color: 0x77
            case .noiseReduction: 0x2B
            }
        }

        /// The PTP slot prop that carries it.
        var prop: UInt16 {
            switch self {
            case .filmSim: FujiProp.filmSimulation
            case .whiteBalance: FujiProp.whiteBalance
            case .color: FujiProp.color
            case .noiseReduction: FujiProp.highISONR
            }
        }

        public var label: String {
            switch self {
            case .filmSim: "film simulation"
            case .whiteBalance: "white balance"
            case .color: "color"
            case .noiseReduction: "noise reduction"
            }
        }
    }

    /// One write: a look that differs from the baseline in one value.
    public struct Probe: Sendable, Hashable {
        public var field: Field
        /// "Astia", "Shade", "-2".
        public var value: String
        public var recipe: Recipe
        /// The PTP code of a film sim or white balance.
        public var ptp: Int?
        /// A control: the code this value must read as (it's confirmed).
        public var expect: Int?
        /// What the X-T5-derived map guesses (LookSlotMap), to say whether the guess was right.
        public var inferred: Int?
        public var inferredEntry: Int?

        public var isControl: Bool { expect != nil }
        public var title: String { (isControl ? "control: " : "") + "\(field.label) \(value)" }
    }

    // MARK: The plan

    /// A look made only of confirmed values: Reala Ace (or the first confirmed colour sim), grain off, color chrome off,
    /// Auto WB without shift, DR100, tones 0, color 0, NR at a confirmed value, clarity 0.
    public static func baseline(_ codes: ConfirmedCodes = .x100vi) throws -> Recipe {
        let colour = codes.confirmedFilmSims.filter { !$0.isMonochrome }
        let wbs = WhiteBalance.allCases.filter { codes.isConfirmed($0) && $0 != .kelvin }
        guard let sim = colour.contains(.realaAce) ? .realaAce : colour.first,
              let wb = wbs.contains(.auto) ? .auto : wbs.first,
              let color = codes.colors[0] != nil ? 0 : codes.colors.keys.min(by: { abs($0) < abs($1) }),
              let nr = codes.noiseReductions.keys.min(by: { abs($0) < abs($1) }) else {
            throw CameraError.invalid("map-codes needs a confirmed colour film sim, white balance, color and NR to check the slot with")
        }
        return Recipe(name: probeName, filmSim: sim, whiteBalance: wb, dynamicRange: .dr100, color: color, noiseReduction: nr,
                      why: "dialin-cam map-codes")
    }

    /// Every probe, in order: the baseline (a control), each unconfirmed film sim, a B&W control, each unconfirmed white
    /// balance, color and NR. `only` limits the sweep to some fields (the baseline always runs).
    public static func probes(codes: ConfirmedCodes = .x100vi, only: Set<Field>? = nil) throws -> [Probe] {
        let base = try baseline(codes)
        func wanted(_ f: Field) -> Bool { only?.contains(f) ?? true }
        func simGuess(_ s: FilmSimulation) -> Int? { LookSlotMap.filmSimCodes[s].flatMap { LookSlotMap.filmSimGuesses[String($0)] } }
        var out = [Probe(field: .filmSim, value: base.filmSim.rawValue, recipe: base, ptp: base.filmSim.code,
                         expect: codes.filmSims[base.filmSim.rawValue], inferred: simGuess(base.filmSim))]
        if wanted(.filmSim) {
            for s in FilmSimulation.allCases where !codes.isConfirmed(s) {
                var r = base
                r.filmSim = s
                out.append(Probe(field: .filmSim, value: s.rawValue, recipe: r, ptp: s.code, inferred: simGuess(s)))
            }
            if let mono = [FilmSimulation.acrosR, .acrosYe].first(where: codes.isConfirmed) ?? codes.confirmedFilmSims.first(where: \.isMonochrome) {
                var r = base
                r.filmSim = mono
                out.append(Probe(field: .filmSim, value: mono.rawValue, recipe: r, ptp: mono.code, expect: codes.filmSims[mono.rawValue],
                                 inferred: simGuess(mono)))
            }
        }
        if wanted(.whiteBalance) {
            for w in WhiteBalance.allCases where !codes.isConfirmed(w) {
                var r = base
                r.whiteBalance = w
                r.kelvin = w == .kelvin ? 5500 : 0
                let ptp = LookSlotMap.wbCodes[w] ?? w.code
                out.append(Probe(field: .whiteBalance, value: w.rawValue, recipe: r, ptp: ptp,
                                 inferred: LookSlotMap.wbGuesses[String(ptp)], inferredEntry: LookSlotMap.wbIndexGuesses[ptp]))
            }
        }
        if wanted(.color) {
            for v in -4...4 where codes.colors[v] == nil {
                var r = base
                r.color = v
                out.append(Probe(field: .color, value: "\(v)", recipe: r, inferred: LookSlotMap.colorGuesses["\(Double(v))"]))
            }
        }
        if wanted(.noiseReduction) {
            for v in -4...4 where codes.noiseReductions[v] == nil {
                var r = base
                r.noiseReduction = v
                out.append(Probe(field: .noiseReduction, value: "\(v)", recipe: r, inferred: v + 4))
            }
        }
        return out
    }

    /// "film_sim,white_balance" → fields; nil for an empty list. Throws on a name it doesn't know.
    public static func parseFields(_ list: String) throws -> Set<Field> {
        var out = Set<Field>()
        for raw in list.split(separator: ",") {
            let k = raw.trimmingCharacters(in: .whitespaces)
            let aliases: [String: Field] = ["sim": .filmSim, "film": .filmSim, "wb": .whiteBalance, "nr": .noiseReduction]
            guard let f = Field(rawValue: k) ?? aliases[k] else {
                throw CameraError.invalid("--only: \(k)? Use film_sim, white_balance, color, noise_reduction")
            }
            out.insert(f)
        }
        return out
    }

    /// What a run would do, step by step, for --dry-run. Contacts nothing.
    public static func plan(slot: Int, probes: [Probe], backups: String = "backups") -> [String] {
        let writes = probes.count
        let wbs = probes.filter { $0.field == .whiteBalance && !$0.isControl }.count
        var lines = [
            "DRY RUN: no camera contacted, nothing written.",
            "Camera: X100VI, CONNECTION MODE = USB RAW CONV./BACKUP RESTORE, on the cable. Slot C\(slot) is borrowed and put back.",
            "1. Back up C1–C7 (PTP, \(backups)/slots-<time>-map-codes.json) and the whole settings file",
            "   (\(backups)/settings-<time>-map-codes-before.dat). Nothing is written before both are saved.",
            "2. Write \(writes) look(s) into C\(slot) (shown as \"\(probeName)\"), one value each over the USB PTP slot props, each read back;",
            "   after each, download the settings file and read C\(slot)'s byte:",
        ]
        for (i, p) in probes.enumerated() {
            let what = p.isControl ? "must read \(p.expect.map(String.init) ?? "?")" : "record the byte" + (p.inferred.map { " (X-T5 guess \($0))" } ?? "")
            lines.append("   \(String(format: "%2d", i + 1)). \(p.title): \(what)")
        }
        lines += [
            "3. Put C\(slot) back: the WB-shift entries the probes touched (up to \(wbs + 1) writes), the hidden colour values if its look is B&W,",
            "   then its own look and name from the backup.",
            "4. Verify: C\(slot) reads back as backed up (PTP), and a fresh settings file matches the first one byte for byte.",
            "5. Save the codes as JSON (\(backups)/codes-<time>.json) for: npm run codes -- merge <file> --write",
            String(format: "About %.0f–%.0f minutes on the camera.", Double(writes) * 4 / 60 + 0.5, Double(writes) * 7 / 60 + 1),
        ]
        return lines
    }

    // MARK: The report (JSON, snake_case)

    public struct Code: Codable, Sendable, Equatable {
        public var field: String
        public var value: String
        public var ptp: Int?
        /// The byte the camera stored in the settings file.
        public var file: Int?
        /// A white balance's WB-shift table entry.
        public var shiftEntry: Int?
        public var inferred: Int?
        public var inferredEntry: Int?
        /// The X-T5 guess was right (nil: no guess).
        public var agrees: Bool?
        /// "clean", or the writer's notes (merge skips anything not clean).
        public var write: String
        /// Slot bytes this write changed (against the file the previous write left), the name aside.
        public var changed: [String]
    }

    public struct Control: Codable, Sendable, Equatable {
        public var what: String
        public var expected: Int
        public var got: Int?
        public var ok: Bool
    }

    public struct Skip: Codable, Sendable, Equatable {
        public var field: String
        public var value: String
        public var why: String
    }

    public struct Restore: Codable, Sendable, Equatable {
        /// One line for the runbook: "C7 restored: identical …" or "C7 NOT restored: … Put it back with: …".
        public var verdict: String
        public var ptp: String
        public var settingsFile: String
        public var differences: [String]
        public var ok: Bool
    }

    public struct Backups: Codable, Sendable, Equatable {
        public var slots: String
        public var settings: String
        public var after: String?
    }

    public struct Report: Codable, Sendable, Equatable {
        public var kind = CodeMap.kind
        public var tool = "dialin-cam map-codes"
        public var model: String
        public var firmware: String
        public var settingsSize: Int
        public var slot: Int
        public var at: String
        public var rehearsal: Bool
        public var backups: Backups
        public var controls: [Control]
        public var codes: [Code]
        public var skipped: [Skip]
        /// Why the sweep stopped early (a failed control, an error), nil when every probe ran.
        public var aborted: String?
        public var restore: Restore
        public var seconds: Int
        public var lines: [String]

        public func jsonData() throws -> Data {
            let e = JSONEncoder()
            e.keyEncodingStrategy = .convertToSnakeCase
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try e.encode(self)
        }

        public static func decode(_ data: Data) throws -> Report {
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            return try d.decode(Report.self, from: data)
        }
    }

    /// Where the backups go (the CLI writes files; tests keep them in memory). Each returns the path it saved to.
    public struct Savers: Sendable {
        public var slots: @Sendable (SlotBackup) throws -> String
        /// (file, "before" | "after")
        public var settings: @Sendable (Data, String) throws -> String
        public init(slots: @escaping @Sendable (SlotBackup) throws -> String, settings: @escaping @Sendable (Data, String) throws -> String) {
            self.slots = slots
            self.settings = settings
        }
    }

    // MARK: Run

    /// The sweep on a connected camera. Throws only before the first write (wrong body, a backup that failed, an unknown
    /// layout); after that every problem is in the report, and the slot is always put back.
    public static func run(
        _ cam: FujiCamera, slot: Int, probes: [Probe], codes: ConfirmedCodes = .x100vi, rehearsal: Bool = false,
        save: Savers, now: Date = Date(), log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Report {
        let t0 = ContinuousClock.now
        guard (1...7).contains(slot) else { throw CameraError.invalid("--slot must be 1–7") }
        guard let first = probes.first, first.isControl, first.field == .filmSim else {
            throw CameraError.invalid("the first probe must be the baseline control")
        }
        let baseRecipe = first.recipe
        let model = await cam.model
        guard model.isEmpty || model == codes.model else {
            throw CameraError.invalid("map-codes knows the \(codes.model)'s settings file; this camera is a \(model). Nothing was written.")
        }
        let rawFirmware = await cam.firmware
        let firmware = BLESlotWriter.normalizeFirmware(rawFirmware) ?? rawFirmware
        var lines: [String] = []
        func say(_ s: String) { lines.append(s); log(s) }

        // 1. Backups, before anything is written.
        let slotsBackup = try await cam.backup()
        let slotsPath = try save.slots(slotsBackup)
        say("backed up C1–C7 → \(slotsPath)")
        let b0Data = try await cam.getSettingsFile()
        let settingsPath = try save.settings(b0Data, "before")
        say("backed up the settings file (\(b0Data.count) bytes) → \(settingsPath)")
        let b0: FujiSettingsFile
        do {
            b0 = try FujiSettingsFile(b0Data)
        } catch {
            throw CameraError.invalid("the camera's settings file isn't the fw 1.10 layout map-codes reads (\(error)). Nothing was written.")
        }
        guard let original = slotsBackup.slots.first(where: { $0.slot == slot }) else {
            throw CameraError.invalid("the backup has no C\(slot). Nothing was written.")
        }
        say("C\(slot) now: \(original.line)")
        say("If this stops before the end (Ctrl-C, unplugged): dialin-cam restore \(slotsPath) --slot \(slot) puts C\(slot) back.")
        let anchor = b0.anchors[slot - 1]

        // 2–3. The probes.
        var controls: [Control] = []
        var found: [Code] = []
        var skipped: [Skip] = []
        var touched: [Int: WhiteBalance] = [:]
        var measuredColors: [Int: Int] = [:]
        var aborted: String?
        var wrote = false
        /// The file as the last probe left it: what each write is compared with.
        var prev: FujiSettingsFile?
        // Every probe writes the baseline's shift (0, 0) into its WB's entry: put that entry back at the end too.
        if let wb = codes.whiteBalances[baseRecipe.whiteBalance.rawValue] { touched[wb.shiftEntry] = baseRecipe.whiteBalance }
        do {
            probing: for (i, p) in probes.enumerated() {
                var recipe = p.recipe
                var shift: (r: Int, b: Int)?
                if p.field == .whiteBalance, !p.isControl, let base = prev {
                    let held = (0..<entries).compactMap { entryShift(base, anchor, $0) }
                    let pick = probeShifts.first { s in !held.contains { $0.r == s.r && $0.b == s.b } } ?? probeShifts[0]
                    shift = pick
                    recipe.wbShiftR = pick.r
                    recipe.wbShiftB = pick.b
                }
                say("[\(i + 1)/\(probes.count)] \(p.title)")
                wrote = true
                let rep = try await cam.writeSlot(slot, name: probeName, values: PresetValues(recipe: recipe), base: original.rawProps)
                guard rep.written.contains(where: { $0.propID == p.field.prop }) else {
                    let why = "the camera refused it" + (rep.rejected.isEmpty ? "" : ": " + rep.rejected.joined(separator: "; "))
                    if p.isControl { aborted = "control \(p.title): \(why)"; say("  STOP: \(aborted ?? "")"); break probing }
                    skipped.append(Skip(field: p.field.rawValue, value: p.value, why: why))
                    say("  skipped: \(why)")
                    continue
                }
                let fk = try FujiSettingsFile(try await cam.getSettingsFile())
                let base = prev ?? b0
                prev = fk
                let raw = Int(fk.bytes[anchor + p.field.rel])
                if p.isControl {
                    var checks = [(p.title, p.expect ?? -1, raw)]
                    if i == 0 {
                        // The whole baseline must read as ConfirmedCodes says, or the offsets/slot/layout are wrong.
                        if let wb = codes.whiteBalances[baseRecipe.whiteBalance.rawValue] {
                            checks.append(("control: white balance \(baseRecipe.whiteBalance.rawValue)", wb.code, Int(fk.bytes[anchor + Field.whiteBalance.rel])))
                        }
                        if let c = codes.colors[baseRecipe.color] {
                            checks.append(("control: color \(baseRecipe.color)", c, Int(fk.bytes[anchor + Field.color.rel])))
                        }
                        if let n = codes.noiseReductions[baseRecipe.noiseReduction] {
                            checks.append(("control: noise reduction \(baseRecipe.noiseReduction)", n, Int(fk.bytes[anchor + Field.noiseReduction.rel])))
                        }
                        checks.append(("control: name", 1, fk.name(slot: slot) == probeName ? 1 : 0))
                    }
                    for (what, want, got) in checks { controls.append(Control(what: what, expected: want, got: got, ok: want == got)) }
                    let bad = checks.filter { $0.1 != $0.2 }
                    if !bad.isEmpty {
                        aborted = "control failed (\(bad.map { "\($0.0): byte \($0.2), expected \($0.1)" }.joined(separator: "; "))): "
                            + "the settings file doesn't read the way the confirmed codes say, so nothing was recorded"
                        say("  STOP: \(aborted ?? "")")
                        break probing
                    }
                    say("  ok (byte \(raw))")
                    continue
                }
                var entry: Int?
                if p.field == .whiteBalance, let s = shift {
                    entry = entryHolding(s, before: base, after: fk, anchor: anchor)
                    if let e = entry, let w = WhiteBalance(rawValue: p.value) { touched[e] = w }
                }
                if p.field == .color, let v = Int(p.value) { measuredColors[v] = raw }
                let agrees = p.inferred.map { $0 == raw && (p.field != .whiteBalance || entry == p.inferredEntry) }
                found.append(Code(
                    field: p.field.rawValue, value: p.value, ptp: p.ptp, file: raw, shiftEntry: entry, inferred: p.inferred,
                    inferredEntry: p.inferredEntry, agrees: agrees, write: rep.isClean ? "clean" : (rep.rejected + rep.mismatched).joined(separator: "; "),
                    changed: changedLabels(base, fk, slot: slot)))
                say("  byte \(raw)" + (entry.map { ", WB-shift entry \($0)" } ?? (p.field == .whiteBalance ? ", WB-shift entry NOT found" : ""))
                    + (agrees == false ? " (the X-T5 guess said \(p.inferred.map(String.init) ?? "?")\(p.inferredEntry.map { ", entry \($0)" } ?? ""))" : "")
                    + (rep.isClean ? "" : " · write notes: \(rep.line)"))
            }
        } catch {
            aborted = "stopped by an error: \(error)"
            say("  STOP: \(aborted ?? "")")
        }

        // 4–5. Put the slot back and prove it.
        var restore = Restore(verdict: "C\(slot) untouched (nothing was written)", ptp: "untouched", settingsFile: "untouched", differences: [], ok: true)
        var afterPath: String?
        if wrote {
            do {
                (restore, afterPath) = try await putBack(cam, slot: slot, original: original, b0: b0, baseline: baseRecipe, touched: touched,
                                                         colors: measuredColors, codes: codes, save: save, slotsPath: slotsPath,
                                                         settingsPath: settingsPath, say: say)
            } catch {
                restore = Restore(verdict: "C\(slot) NOT restored (\(error)). Put it back with: dialin-cam restore \(slotsPath) --slot \(slot)",
                                  ptp: "unknown", settingsFile: "unknown", differences: [], ok: false)
            }
            say(restore.verdict)
        }
        let d = ContinuousClock.now - t0
        return Report(
            model: model.isEmpty ? codes.model : model, firmware: firmware, settingsSize: b0Data.count, slot: slot,
            at: ISO8601DateFormatter().string(from: now), rehearsal: rehearsal,
            backups: Backups(slots: slotsPath, settings: settingsPath, after: afterPath), controls: controls, codes: found,
            skipped: skipped, aborted: aborted, restore: restore, seconds: Int(d.components.seconds), lines: lines)
    }

    /// Restore C`slot` to `original` and check it two ways. Returns the restore record and where the after-file went.
    static func putBack(
        _ cam: FujiCamera, slot: Int, original: SlotSnapshot, b0: FujiSettingsFile, baseline: Recipe, touched: [Int: WhiteBalance],
        colors: [Int: Int], codes: ConfirmedCodes, save: Savers, slotsPath: String, settingsPath: String, say: (String) -> Void
    ) async throws -> (Restore, String?) {
        let anchor = b0.anchors[slot - 1]
        var notes: [String] = []
        // a. Every WB-shift entry a probe wrote gets its old shift back (written under a colour look in that mode).
        for (entry, wb) in touched.sorted(by: { $0.key < $1.key }) {
            guard let s = entryShift(b0, anchor, entry) else {
                notes.append("WB-shift entry \(entry) didn't hold a shift value before; left as the probe set it")
                continue
            }
            var r = baseline
            r.whiteBalance = wb
            r.kelvin = wb == .kelvin ? 5500 : 0
            r.wbShiftR = s.r
            r.wbShiftB = s.b
            let rep = try await cam.writeSlot(slot, name: probeName, values: PresetValues(recipe: r), base: original.rawProps)
            say("put back the \(wb.rawValue) shift (entry \(entry)): R\(s.r) B\(s.b)" + (rep.isClean ? "" : " · \(rep.line)"))
        }
        // b. A B&W look keeps colour values it doesn't use; they go back under a colour sim first, as the file stored them.
        let originalValues = PresetValues(props: original.rawProps)
        if originalValues.isMonochrome {
            var v = originalValues
            v.filmSimulation = baseline.filmSim.code
            let colorRaw = Int(b0.bytes[anchor + Field.color.rel])
            let known = colors.merging(codes.colors) { _, confirmed in confirmed }
            if let c = known.first(where: { $0.value == colorRaw })?.key ?? (colorRaw == 7 ? 0 : nil) {
                v.color = Double(c)
            } else {
                notes.append("the hidden color byte (\(colorRaw)) has no known value; left as the probes set it")
            }
            let cc = Int(b0.bytes[anchor + 0x7F]), ccb = Int(b0.bytes[anchor + 0x80])
            if (0...2).contains(cc) { v.colorChrome = cc }
            if (0...2).contains(ccb) { v.colorChromeFxBlue = ccb }
            let measured = touched.first { LookSlotMap.wbCodes[$0.value] == v.whiteBalance }?.key
            if let e = measured ?? LookSlotMap.wbIndexByPTP[v.whiteBalance], let s = entryShift(b0, anchor, e) {
                v.wbShiftR = s.r
                v.wbShiftB = s.b
            }
            let rep = try await cam.writeSlot(slot, name: original.name, values: v, base: original.rawProps)
            say("put back C\(slot)'s hidden colour values (its B&W look doesn't use them)" + (rep.isClean ? "" : " · \(rep.line)"))
        }
        // c. Its own look and name.
        let reports = try await cam.restore([original])
        say("restored C\(slot) from the backup: " + (reports.allSatisfy(\.isClean) ? "clean" : reports.map(\.line).joined(separator: "; ")))
        // d. Prove it.
        let after = try await cam.readSlot(slot)
        let ptpDiffs = ptpDifferences(original, after)
        let endData = try await cam.getSettingsFile()
        let endPath = try? save.settings(endData, "after")
        let end = try FujiSettingsFile(endData)
        let fileDiffs = fileDifferences(b0, end, slot: slot)
        let ptp = ptpDiffs.isEmpty ? "identical" : "differs: " + ptpDiffs.joined(separator: "; ")
        let file = fileDiffs.isEmpty ? "identical" : "\(fileDiffs.count) byte(s) differ"
        let verdict: String
        if ptpDiffs.isEmpty && fileDiffs.isEmpty && reports.allSatisfy(\.isClean) {
            verdict = "C\(slot) restored: identical visible properties and checked settings bytes (checksum and frame-counter bytes excluded)"
        } else if ptpDiffs.isEmpty && fileDiffs.isEmpty {
            verdict = "C\(slot) recovery needs review: checked settings bytes match, but recovery reported failures: "
                + reports.filter { !$0.isClean }.map(\.line).joined(separator: "; ")
        } else if ptpDiffs.isEmpty {
            verdict = "C\(slot) recovery incomplete: visible properties match, but the settings file still differs in "
                + "\(fileDiffs.count) hidden byte(s): \(fileDiffs.prefix(4).joined(separator: "; "))"
                + ". These differences need investigation before recovery can be confirmed. "
                + "Keep \(settingsPath): it is the exact copy."
        } else {
            verdict = "C\(slot) NOT fully restored: \(ptpDiffs.joined(separator: "; ")). Put it back with: dialin-cam restore \(slotsPath) --slot \(slot)"
        }
        return (Restore(verdict: verdict, ptp: ptp, settingsFile: file, differences: notes + fileDiffs,
                        ok: ptpDiffs.isEmpty && fileDiffs.isEmpty && reports.allSatisfy(\.isClean)), endPath)
    }

    // MARK: Reading the file

    /// The shift in entry `e` of a slot's WB-shift table, nil when the bytes aren't a shift (−9…+9).
    static func entryShift(_ f: FujiSettingsFile, _ anchor: Int, _ e: Int) -> (r: Int, b: Int)? {
        let r = 9 - Int(f.bytes[anchor - 0x0D + 4 * e]), b = 9 - Int(f.bytes[anchor - 0x0B + 4 * e])
        return (-9...9).contains(r) && (-9...9).contains(b) ? (r, b) : nil
    }

    /// The one entry that took `s` (it holds `s` now and didn't before); nil when none or several did.
    static func entryHolding(_ s: (r: Int, b: Int), before: FujiSettingsFile, after: FujiSettingsFile, anchor: Int) -> Int? {
        let hits = (0..<entries).filter { e in
            guard let now = entryShift(after, anchor, e), now.r == s.r, now.b == s.b else { return false }
            guard let was = entryShift(before, anchor, e) else { return true }
            return !(was.r == s.r && was.b == s.b)
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// What a byte at `rel` from the anchor is.
    public static func label(rel: Int) -> String {
        let hex = rel < 0 ? String(format: "-0x%X", -rel) : String(format: "+0x%X", rel)
        let tableStart = -0x0D
        if (tableStart..<tableStart + 4 * entries).contains(rel) {
            let e = (rel - tableStart) / 4, part = (rel - tableStart) % 4
            return (part == 0 ? "WB shift R, entry \(e)" : part == 2 ? "WB shift B, entry \(e)" : "WB-shift table, entry \(e)") + " (\(hex))"
        }
        if (FujiSettingsFile.nameRel..<FujiSettingsFile.nameRel + FujiSettingsFile.nameFieldLength).contains(rel) { return "name (\(hex))" }
        if let f = LookSlotMap.fields.first(where: { f in
            if case .wbTable = f.encoding { return false }
            return rel >= f.rel && rel < f.rel + (f.interp == .u16le ? 2 : 1)
        }) { return "\(f.label) (\(hex))" }
        return "slot byte \(hex)"
    }

    /// Slot bytes (the name aside) that differ between two files, as labels.
    static func changedLabels(_ a: FujiSettingsFile, _ b: FujiSettingsFile, slot: Int) -> [String] {
        let anchor = a.anchors[slot - 1]
        let name = (anchor + FujiSettingsFile.nameRel)..<(anchor + FujiSettingsFile.nameRel + FujiSettingsFile.nameFieldLength)
        return a.slotRegion(slot).filter { a.bytes[$0] != b.bytes[$0] && !name.contains($0) }.map { label(rel: $0 - anchor) }
    }

    /// Every byte of the payload that differs (the checksum field and the frame counter aside), in words.
    static func fileDifferences(_ a: FujiSettingsFile, _ b: FujiSettingsFile, slot: Int) -> [String] {
        guard a.bytes.count == b.bytes.count else { return ["the file changed size: \(a.bytes.count) → \(b.bytes.count) bytes"] }
        let anchor = a.anchors[slot - 1]
        let region = a.slotRegion(slot)
        let skip = FujiSettingsFile.checksumOffset..<FujiSettingsFile.checksumOffset + 4
        return (a.payloadStart..<a.bytes.count).compactMap { i in
            guard a.bytes[i] != b.bytes[i], !skip.contains(i), !FujiSettingsFile.frameCounterBlock.contains(i) else { return nil }
            let place = region.contains(i) ? "C\(slot) \(label(rel: i - anchor))" : String(format: "file offset 0x%X (outside C\(slot))", i)
            return "\(place): \(a.bytes[i]) → \(b.bytes[i])"
        }
    }

    /// Props of the original that don't read back the same (colour-only props of a B&W look aside: the file check covers
    /// those; grain Off may read 1, 6 or 7).
    static func ptpDifferences(_ original: SlotSnapshot, _ after: SlotSnapshot) -> [String] {
        var out: [String] = []
        if original.name != after.name { out.append("name \"\(after.name)\" (backed up \"\(original.name)\")") }
        let mono = PresetValues(props: original.rawProps).isMonochrome
        let have = Dictionary(after.rawProps.map { ($0.id, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        let off: Set<Data> = [PTPPack.u16(1), PTPPack.u16(6), PTPPack.u16(7)]
        for p in original.rawProps where !(mono && FujiProp.colorOnly.contains(p.id)) && p.id != FujiProp.liveImageSize {
            guard let now = have[p.id] else { out.append("\(FujiProp.label(p.id)) no longer reads"); continue }
            if now == p.bytes || (p.id == FujiProp.grain && off.contains(now) && off.contains(p.bytes)) { continue }
            out.append("\(FujiProp.label(p.id)) reads \(now.hexString) (backed up \(p.bytes.hexString))")
        }
        return out
    }
}
