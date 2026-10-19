// Fujifilm camera session: read and write the C1–C7 custom-setting slots over PTP.
// Port of lib/fuji/camera.ts with identical write semantics:
//   select D18C → settle 100 ms → name (D18D) first → props in SlotEncoder.writeOrder, 20 ms apart →
//   DR step-down on rejection → optional D-Range Priority re-apply → read back every written prop + the name.
// Slot protocol from FilmKit's X100VI work; see docs/FUJIFILM-PROTOCOL.md §2.3-2.8.
import Foundation

public actor FujiCamera {
    /// Delays the camera needs. Tests pass `.immediate`.
    public struct Timing: Sendable {
        /// After selecting a slot (D18C is an edit cursor; FilmKit/ILFforever wait 50–100 ms).
        public var slotSettle: Duration
        /// Before each slot prop write (ctl0v0 spaces X100VI writes 20 ms apart).
        public var writeGap: Duration

        public init(slotSettle: Duration = .milliseconds(100), writeGap: Duration = .milliseconds(20)) {
            self.slotSettle = slotSettle
            self.writeGap = writeGap
        }

        public static let camera = Timing()
        public static let immediate = Timing(slotSettle: .zero, writeGap: .zero)
    }

    /// Outcome of one slot write (camera.ts returns `{ rejected, mismatched }`).
    public struct WriteReport: Sendable, Equatable {
        public var slot: Int
        public var name: String
        /// Props the camera accepted.
        public var written: [PropWrite]
        /// How many props we tried.
        public var attempted: Int
        /// Human notes for props the camera refused (or stepped down).
        public var rejected: [String]
        /// Props that answered OK but read back different ("didn't stick").
        public var mismatched: [String]
        /// The same problems in plain words for the app ("clarity skipped (…)", "highlight didn't stick"), in order:
        /// refusals first, then read-back differences. Empty when the write is clean.
        public var hints: [String] = []

        public var isClean: Bool { rejected.isEmpty && mismatched.isEmpty }

        /// camera.ts log line: `C3 "Warm Gold": 16/16 written · … · DIDN'T STICK: …`
        public var line: String {
            "C\(slot) \"\(name)\": \(written.count)/\(attempted) written"
                + (rejected.isEmpty ? "" : " · " + rejected.joined(separator: " · "))
                + (mismatched.isEmpty ? "" : " · DIDN'T STICK: " + mismatched.joined(separator: ", "))
        }
    }

    /// camera.ts `REJECT_HINT`.
    static let rejectHint: [UInt16: String] = [
        FujiProp.clarity: "clarity skipped (camera must be in single-shot drive mode)",
        FujiProp.highISONR: "high-ISO NR not stored in slots",
    ]

    /// Plain-language note for a prop the camera refused.
    static func refusalHint(_ id: UInt16) -> String {
        rejectHint[id] ?? "\(FujiProp.label(id)) refused by the camera"
    }

    /// Read-backs that mean the same as what we wrote: grain Off is written as 1 but an X100VI can read it back as
    /// 6 (Off-Small) or 7 (Off-Large) (docs/FUJIFILM-PROTOCOL.md §2.7: "accept 1/6/7 on read, write 1").
    /// The same holds for the live grain code D023 (docs/FUJIFILM-PROTOCOL.md §2.9).
    static func equivalentReadBack(_ written: PropWrite, _ read: Data) -> Bool {
        guard written.propID == FujiProp.grain || written.propID == LiveProps.grain.code, written.bytes == PTPPack.u16(1) else { return false }
        return read == PTPPack.u16(6) || read == PTPPack.u16(7)
    }

    public let transport: any PTPTransport
    public let timing: Timing
    public private(set) var deviceInfo = PTPDeviceInfo()
    public private(set) var properties: Set<UInt16> = []
    public private(set) var isConnected = false
    /// Internal so the live-look orchestration (LiveControl.swift) logs through the same sink.
    let log: @Sendable (String) -> Void

    public var model: String { deviceInfo.model }
    public var firmware: String { deviceInfo.deviceVersion }
    public var canEditSlots: Bool { properties.contains(FujiProp.slot) }

    public init(transport: any PTPTransport, timing: Timing = .camera, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transport = transport
        self.timing = timing
        self.log = log
    }

    // MARK: Session

    /// Open the session and read GetDeviceInfo. Throws `CameraError.needsUSBMode` when the camera doesn't
    /// advertise slot editing (D18C), i.e. it isn't in USB RAW CONV./BACKUP RESTORE.
    public func connect(timeout: Duration = .seconds(30)) async throws {
        try await transport.open(timeout: timeout)
        let info: PTPResult
        do {
            info = try await transport.command(PTP.Op.getDeviceInfo)
        } catch {
            // Found, but it won't talk PTP: card-reader (mass storage) mode looks like this.
            throw CameraError.needsUSBMode("GetDeviceInfo failed: \(error)")
        }
        if info.isOK, let parsed = try? PTPDeviceInfo(parsing: info.data) {
            deviceInfo = parsed
            properties = Set(parsed.properties)
        }
        isConnected = true
        if !properties.isEmpty && !properties.contains(FujiProp.slot) {
            throw CameraError.needsUSBMode("\(model.isEmpty ? "Camera" : model) doesn't expose custom-slot editing over USB")
        }
    }

    public func disconnect() async {
        isConnected = false
        await transport.close()
    }

    // MARK: Props

    /// GetDevicePropValue. Nil when the camera refuses or sends no data (camera.ts `readProp`).
    public func readProp(_ id: UInt16) async throws -> RawProp? {
        let r = try await transport.command(PTP.Op.getDevicePropValue, [UInt32(id)])
        guard r.isOK, !r.data.isEmpty else { return nil }
        return RawProp(id: id, bytes: r.data)
    }

    /// SetDevicePropValue. True when the camera answered OK (camera.ts `writeProp`).
    @discardableResult
    public func writeProp(_ id: UInt16, _ bytes: Data) async throws -> Bool {
        let r = try await transport.command(PTP.Op.setDevicePropValue, [UInt32(id)], sending: bytes)
        if r.responseMissing { log("warning: no PTP response for \(hex16(id)); assuming OK, read-back will check") }
        return r.isOK
    }

    /// Point the slot edit cursor at C1–C7 and let it settle.
    public func selectSlot(_ slot: Int) async throws {
        guard (1...7).contains(slot) else { throw CameraError.invalid("Slot must be 1–7, got \(slot)") }
        guard try await writeProp(FujiProp.slot, PTPPack.u16(slot)) else {
            throw CameraError.refused("to select C\(slot)", code: PTP.Response.generalError)
        }
        try await Task.sleep(for: timing.slotSettle)
    }

    // MARK: Slots

    /// Name + D18E…D1A4 of one slot (D1A5 is live state, never read as slot data).
    public func readSlot(_ slot: Int) async throws -> SlotSnapshot {
        try await selectSlot(slot)
        guard let nameProp = try await readProp(FujiProp.name) else {
            throw CameraError.invalid("Could not read C\(slot)'s name. Nothing was written.")
        }
        var props: [RawProp] = []
        for id in FujiProp.slotBlock {
            if let p = try await readProp(id) { props.append(p) }
        }
        return SlotSnapshot(slot: slot, name: nameProp.stringValue ?? "", rawProps: props)
    }

    /// C1–C7 in order.
    public func readAll() async throws -> [SlotSnapshot] {
        var out: [SlotSnapshot] = []
        for s in 1...7 { out.append(try await readSlot(s)) }
        return out
    }

    /// C1–C7 as a backup file (same JSON as `npm run cam backup`).
    public func backup() async throws -> SlotBackup {
        SlotBackup(model: model, slots: try await readAll())
    }

    /// Write a recipe into a slot with the camera-safe name (`recipe.slotName`).
    @discardableResult
    public func writeSlot(_ slot: Int, recipe: Recipe, base: [RawProp]? = nil, verify: Bool = true) async throws -> WriteReport {
        try await writeSlot(slot, name: recipe.slotName, values: PresetValues(recipe: recipe), base: base, verify: verify)
    }

    /// camera.ts `writeSlot`: write a look into a slot in the camera's accepted order, then read every value back
    /// (a camera can answer OK and not apply). `base` is the slot's current props (read first when nil).
    /// `keepDrPriority` re-applies the slot's own D-Range Priority after the tones (used by `restore`).
    @discardableResult
    public func writeSlot(
        _ slot: Int, name: String, values: PresetValues, base: [RawProp]? = nil, verify: Bool = true,
        keepDrPriority: Bool = false
    ) async throws -> WriteReport {
        let baseProps: [RawProp]
        if let base { baseProps = base } else { baseProps = try await readSlot(slot).rawProps }
        let props = SlotEncoder.writes(for: values, base: baseProps)

        try await selectSlot(slot)
        // Name first: FilmKit (X100VI) and AlPeFe do this; AlPeFe saw corrupted names otherwise.
        guard try await writeProp(FujiProp.name, PTPPack.string(name)) else {
            throw CameraError.refused("the name for C\(slot)", code: PTP.Response.generalError)
        }
        var rejected: [String] = []
        var hints: [String] = []
        var written: [PropWrite] = []
        for p in props {
            try await Task.sleep(for: timing.writeGap)
            if try await writeProp(p.propID, p.bytes) {
                written.append(p)
                continue
            }
            // DR400/DR200 are refused when the camera's current ISO is below their minimum: step down.
            if p.propID == FujiProp.dynamicRange {
                let b = [UInt8](p.bytes)
                let want = b.count >= 2 ? Int(LE.u16(b, 0)) : 0
                var ok = 0
                for v in [200, 100] where v < want {
                    if try await writeProp(FujiProp.dynamicRange, PTPPack.u16(v)) { ok = v; break }
                }
                if ok != 0 {
                    written.append(PropWrite(propID: FujiProp.dynamicRange, bytes: PTPPack.u16(ok)))
                    rejected.append("DR stepped down to DR\(ok) (camera ISO too low for more)")
                    hints.append("DR stepped down to DR\(ok) (camera ISO too low for more)")
                    continue
                }
            }
            rejected.append(Self.rejectHint[p.propID] ?? "\(hex16(p.propID))=\(p.bytes.hexString)")
            hints.append(Self.refusalHint(p.propID))
        }

        if keepDrPriority, let drp = baseProps.first(where: { $0.id == FujiProp.dRangePriority }), drp.bytes.hexString != "0000" {
            try await writeProp(FujiProp.dRangePriority, drp.bytes)
        }

        var mismatched: [String] = []
        if verify {
            for p in written {
                guard let rb = try await readProp(p.propID) else {
                    mismatched.append("\(hex16(p.propID)) could not be read back")
                    hints.append("\(FujiProp.label(p.propID)) could not be verified")
                    continue
                }
                if rb.bytes != p.bytes, !Self.equivalentReadBack(p, rb.bytes) {
                    mismatched.append("\(hex16(p.propID)) wrote \(p.bytes.hexString) read \(rb.bytes.hexString)")
                    hints.append("\(FujiProp.label(p.propID)) didn't stick (camera kept a different value)")
                }
            }
            if let rbName = try await readProp(FujiProp.name) {
                if rbName.value != .string(name) {
                    let shown: String = switch rbName.value {
                    case .string(let s): s
                    case .int(let i): String(i)
                    case .hex(let h): h
                    }
                    mismatched.append("name wrote \"\(name)\" read \"\(shown)\"")
                    hints.append("name didn't stick (camera shows \"\(shown)\")")
                }
            } else {
                mismatched.append("name could not be read back")
                hints.append("name could not be verified")
            }
        }
        let report = WriteReport(
            slot: slot, name: name, written: written, attempted: props.count, rejected: rejected, mismatched: mismatched, hints: hints)
        log(report.line)
        return report
    }

    /// Change only a slot's name (D18C select, D18D write, read back). The smallest possible slot write: used to make
    /// two settings files that differ in one known field (checksum experiments, docs/FUJIFILM-PROTOCOL.md §4.6). Returns (old, new name
    /// as read back).
    @discardableResult
    public func renameSlot(_ slot: Int, to name: String) async throws -> (old: String, now: String) {
        guard !name.isEmpty, name.utf8.count <= 25, name.allSatisfy({ $0.isASCII && !$0.isNewline }) else {
            throw CameraError.invalid("slot name must be 1–25 plain ASCII characters")
        }
        try await selectSlot(slot)
        let old = try await readProp(FujiProp.name)?.stringValue ?? ""
        guard try await writeProp(FujiProp.name, PTPPack.string(name)) else {
            throw CameraError.refused("the name for C\(slot)", code: PTP.Response.generalError)
        }
        let now = try await readProp(FujiProp.name)?.stringValue ?? ""
        log("C\(slot) name \"\(old)\" → \"\(now)\"")
        return (old, now)
    }

    /// Put a slot backup back, including saved color values hidden by a monochrome simulation.
    /// Verify every recorded property, not only the subset a recipe encoder writes.
    @discardableResult
    public func restore(_ slots: [SlotSnapshot]) async throws -> [WriteReport] {
        var reports: [WriteReport] = []
        for s in slots {
            let props = s.rawProps
            var report = try await writeSlot(s.slot, name: s.name, values: PresetValues(props: props), base: props, keepDrPriority: true)
            if s.values.isMonochrome {
                try await restoreHiddenColor(s, report: &report)
            }
            for p in props {
                guard let got = try await readProp(p.id) else {
                    report.mismatched.append("\(hex16(p.id)) could not be read back after recovery")
                    report.hints.append("\(FujiProp.label(p.id)) could not be verified after recovery")
                    continue
                }
                let wanted = PropWrite(propID: p.id, bytes: p.bytes)
                if got.bytes != p.bytes, !Self.equivalentReadBack(wanted, got.bytes) {
                    report.mismatched.append("\(hex16(p.id)) was not restored to its saved value")
                    report.hints.append("\(FujiProp.label(p.id)) was not fully restored")
                }
            }
            log("recovery: " + report.line)
            reports.append(report)
        }
        return reports
    }

    /// X100VI 1.10 hardware observation: chrome and WB shifts accept raw recovery while monochrome is active;
    /// saturation (D19F) is refused until a color simulation is selected. A temporary Provia selection lets us
    /// restore that saved value, then we return to the saved monochrome simulation. No image-quality/size writes.
    private func restoreHiddenColor(_ slot: SlotSnapshot, report: inout WriteReport) async throws {
        let saved = Dictionary(slot.rawProps.map { ($0.id, $0.bytes) }, uniquingKeysWith: { _, last in last })
        for id in [FujiProp.colorChrome, FujiProp.colorChromeFxBlue, FujiProp.wbShiftR, FujiProp.wbShiftB, FujiProp.color] {
            guard let bytes = saved[id], try await readProp(id)?.bytes != bytes else { continue }
            if id == FujiProp.color {
                guard let originalSim = saved[FujiProp.filmSimulation] else {
                    report.mismatched.append("saved film simulation missing; hidden color was not restored")
                    report.hints.append("The saved film simulation is missing, so color could not be restored")
                    continue
                }
                // Always attempt to put the original simulation back after a temporary selection, including
                // after a transport/readback failure. Any uncertainty remains an error for the caller.
                do {
                    let enabled = try await restoreRaw(PropWrite(propID: FujiProp.filmSimulation, bytes: PTPPack.u16(FujiFilmSim.provia)), report: &report)
                    if enabled {
                        _ = try await restoreRaw(PropWrite(propID: id, bytes: bytes), report: &report)
                    }
                } catch {
                    _ = try? await writeProp(FujiProp.filmSimulation, originalSim)
                    throw error
                }
                _ = try await restoreRaw(PropWrite(propID: FujiProp.filmSimulation, bytes: originalSim), report: &report)
            } else {
                _ = try await restoreRaw(PropWrite(propID: id, bytes: bytes), report: &report)
            }
        }
    }

    private func restoreRaw(_ p: PropWrite, report: inout WriteReport) async throws -> Bool {
        report.attempted += 1
        try await Task.sleep(for: timing.writeGap)
        guard try await writeProp(p.propID, p.bytes) else {
            report.rejected.append("\(hex16(p.propID)) recovery refused")
            report.hints.append("\(FujiProp.label(p.propID)) could not be restored")
            return false
        }
        report.written.append(p)
        guard try await readProp(p.propID)?.bytes == p.bytes else {
            report.mismatched.append("\(hex16(p.propID)) recovery could not be verified")
            report.hints.append("\(FujiProp.label(p.propID)) could not be verified after recovery")
            return false
        }
        return true
    }

    // MARK: Whole-camera settings file (FUJIFILMX-BACKUP), the same file the camera sends over Bluetooth

    public static let settingsMagic = Data("FUJIFILMX-BACKUP".utf8)

    /// Download the settings backup: object handle 0, format 0x5000 (libfuji fuji_usb.c:173-241).
    public func getSettingsFile() async throws -> Data {
        let info = try await transport.command(PTP.Op.getObjectInfo, [0])
        guard info.isOK else { throw CameraError.refused("GetObjectInfo(0)", code: info.code) }
        let obj = try await transport.command(PTP.Op.getObject, [0], timeout: .seconds(60))
        guard obj.isOK else { throw CameraError.refused("GetObject(0)", code: obj.code) }
        return obj.data
    }

    /// The 1076-byte ObjectInfo the camera accepts for a settings restore (helios fuji_settings.py:111-121;
    /// libfuji's 1088 bytes gets 0x200F).
    public static func settingsObjectInfo(fileLength: Int) -> Data {
        var oi = Data(count: 1076)
        oi.replaceSubrange(0..<4, with: PTPPack.u32(0)) // StorageID
        oi.replaceSubrange(4..<6, with: PTPPack.u16(0x5000)) // ObjectFormat
        oi.replaceSubrange(6..<8, with: PTPPack.u16(0)) // ProtectionStatus
        oi.replaceSubrange(8..<12, with: PTPPack.u32(UInt32(truncatingIfNeeded: fileLength))) // ObjectCompressedSize
        return oi
    }

    /// Restore a settings backup. Overwrites EVERY camera setting, not one slot. Must be the first operation after a
    /// power cycle in RAW CONV./BACKUP RESTORE mode; power-cycle afterwards.
    public func putSettingsFile(_ file: Data) async throws {
        guard file.prefix(16) == Self.settingsMagic else { throw CameraError.invalid("Not a FUJIFILMX-BACKUP file") }
        guard file.count <= 100_000 else { throw CameraError.invalid("Backup file is suspiciously large") }
        let r1 = try await transport.command(PTP.Op.sendObjectInfo, [0, 0], sending: Self.settingsObjectInfo(fileLength: file.count))
        guard r1.isOK else { throw CameraError.refused("SendObjectInfo", code: r1.code) }
        let r2 = try await transport.command(PTP.Op.sendObject, [], sending: file, timeout: .seconds(60))
        guard r2.isOK else {
            throw CameraError.refused(
                "SendObject (0x200F = bad checksum, or not a clean session: power-cycle and make restore the first thing you do)",
                code: r2.code)
        }
        log("restored \(file.count)-byte settings file — power-cycle the camera so every setting takes effect")
    }

    // MARK: Live (C0) props: the current shooting state, no slot cursor (docs/FUJIFILM-PROTOCOL.md §2.9)

    /// GetDevicePropValue for each code, in order (duplicates dropped). Only 0x1015 goes out: nothing is written and
    /// the slot cursor (D18C) doesn't move. A refusal is collected with its response code; a transport error on one
    /// code (ImageCaptureCore refusing an unadvertised prop) is collected too. A timeout or an unplug still throws.
    public func readLive(_ codes: [UInt16]) async throws -> LiveReadResult {
        var seen = Set<UInt16>()
        var result = LiveReadResult(order: codes.filter { seen.insert($0).inserted })
        for c in result.order {
            do {
                let r = try await transport.command(PTP.Op.getDevicePropValue, [UInt32(c)])
                if r.isOK && !r.data.isEmpty { result.values[c] = r.data } else { result.refused[c] = r.code }
            } catch CameraError.transport(let why) {
                result.failed[c] = why
            }
        }
        return result
    }

    /// SetDevicePropValue on live look codes, each read back right after its write. Never writes D18C/D18D (no slot
    /// steps). Only `LiveLook.writableCodes` are accepted; anything else throws before a single command goes out.
    /// DR refused (ISO below the DR's floor) steps down 400 → 200 → 100, as `writeSlot` does.
    public func writeLive(_ writes: [PropWrite]) async throws -> LiveWriteReport {
        let foreign = writes.filter { !LiveLook.writableCodes.contains($0.propID) }
        guard foreign.isEmpty else {
            throw CameraError.invalid("not a live look code, refusing to write: " + foreign.map { LiveHex.code($0.propID) }.joined(separator: " "))
        }
        var entries: [LiveWriteEntry] = []
        for w in writes {
            try await Task.sleep(for: timing.writeGap)
            var r = try await transport.command(PTP.Op.setDevicePropValue, [UInt32(w.propID)], sending: w.bytes)
            if r.responseMissing { log("warning: no PTP response for \(LiveHex.code(w.propID)); assuming OK, read-back will check") }
            var landed: Data? = r.isOK ? w.bytes : nil
            var note: String?
            if !r.isOK, w.propID == LiveProps.dynamicRange.code, let want = try? LiveCodec.decode(w.bytes, as: .uint16),
               [200, 400, 800].contains(want) {
                let first = r.code
                for v in [400, 200, 100] where v < want {
                    let r2 = try await transport.command(PTP.Op.setDevicePropValue, [UInt32(w.propID)], sending: PTPPack.u16(v))
                    if r2.isOK {
                        landed = PTPPack.u16(v)
                        note = "DR stepped down to DR\(v): DR\(want) refused (\(PTP.Response.name(first))), camera ISO too low for it"
                        r = r2
                        break
                    }
                }
            }
            var readBack: Data?
            if landed != nil {
                let rb = try await transport.command(PTP.Op.getDevicePropValue, [UInt32(w.propID)])
                if rb.isOK && !rb.data.isEmpty { readBack = rb.data }
            }
            entries.append(LiveWriteEntry(code: w.propID, sent: w.bytes, landed: landed, response: r.code, readBack: readBack, note: note))
        }
        let report = LiveWriteReport(entries: entries)
        if !writes.isEmpty { log(report.line) }
        return report
    }

    // MARK: Extras

    /// PC connection mode (D16E): 5 tether, 6 RAW CONV./BACKUP RESTORE, 8 webcam. Nil if unreadable.
    public func usbMode() async throws -> Int? {
        try await readProp(FujiProp.usbMode)?.intValue
    }
}
