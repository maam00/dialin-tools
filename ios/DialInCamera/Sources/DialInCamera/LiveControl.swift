// Live (C0) camera control over USB PTP in USB RAW CONV./BACKUP RESTORE: read the current look, apply a recipe to the
// current shooting state without touching C1–C7, and undo it from a snapshot.
//
// The codes, gates and the recipe → writes planner are in LiveProps.swift (docs/FUJIFILM-PROTOCOL.md §2.9). This file adds
// the I/O orchestration on top of FujiCamera.readLive / writeLive, the snapshot file shared by
// `dialin-cam props --read --json`, `look-live --snapshot` and `look-restore`, and the probe's printing helpers.
// Nothing here writes D18C/D18D: the slot cursor never moves, and only the 19 look codes can be written at all.
import Foundation
import Synchronization

// MARK: - Hex codes

/// "D001" ⇄ 0xD001. Four uppercase hex digits, the way the docs write property codes.
public enum LiveHex {
    public static func code(_ c: UInt16) -> String { String(format: "%04X", c) }

    /// "D001", "d001", "0xD001" → 0xD001.
    public static func parseCode(_ s: String) -> UInt16? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("0x") { t = String(t.dropFirst(2)) }
        guard (1...4).contains(t.count) else { return nil }
        return UInt16(t, radix: 16)
    }

    public static func codes(_ list: String) -> [UInt16]? {
        let parts = list.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        let parsed = parts.compactMap(parseCode)
        return parsed.count == parts.count && !parsed.isEmpty ? parsed : nil
    }
}

// MARK: - Results

/// What `FujiCamera.readLive` got back.
public struct LiveReadResult: Sendable, Equatable {
    /// Code → raw bytes, for every code the camera answered OK with data.
    public var values: [UInt16: Data] = [:]
    /// Code → PTP response code for every refusal (0x200A not in this mode, 0x2002 …; 0x2001 = OK but no data).
    public var refused: [UInt16: UInt16] = [:]
    /// Code → transport error text (ImageCaptureCore refusing to send it at all).
    public var failed: [UInt16: String] = [:]
    /// The codes, in the order they were read.
    public var order: [UInt16]

    public init(order: [UInt16], values: [UInt16: Data] = [:], refused: [UInt16: UInt16] = [:], failed: [UInt16: String] = [:]) {
        self.order = order
        self.values = values
        self.refused = refused
        self.failed = failed
    }
}

/// One live write, as `FujiCamera.writeLive` did it.
public struct LiveWriteEntry: Sendable, Equatable {
    public var code: UInt16
    /// What we asked for.
    public var sent: Data
    /// What the camera accepted: `sent`, or the stepped-down DR, or nil when it refused.
    public var landed: Data?
    /// Response to the (last) SetDevicePropValue.
    public var response: UInt16
    /// GetDevicePropValue right after the write (nil when refused or unreadable).
    public var readBack: Data?
    public var note: String?

    public init(code: UInt16, sent: Data, landed: Data?, response: UInt16, readBack: Data?, note: String? = nil) {
        self.code = code
        self.sent = sent
        self.landed = landed
        self.response = response
        self.readBack = readBack
        self.note = note
    }

    public var accepted: Bool { landed != nil }

    /// Accepted and read back as written (grain Off = 1 reading 6/7 counts).
    public var stuck: Bool {
        guard let landed, let readBack else { return false }
        return LiveLook.sameValue(code, readBack, landed)
    }

    public var isClean: Bool { stuck && landed == sent }
}

/// Outcome of `FujiCamera.writeLive`.
public struct LiveWriteReport: Sendable, Equatable {
    public var entries: [LiveWriteEntry]

    public init(entries: [LiveWriteEntry]) { self.entries = entries }

    public var attempted: Int { entries.count }
    public var written: [PropWrite] { entries.compactMap { e in e.landed.map { PropWrite(propID: e.code, bytes: $0) } } }
    public var refused: [UInt16: UInt16] {
        Dictionary(uniqueKeysWithValues: entries.filter { !$0.accepted }.map { ($0.code, $0.response) })
    }
    /// Accepted but read back different ("didn't stick").
    public var mismatched: [String] {
        entries.filter { $0.accepted && !$0.stuck }.map { e in
            "\(LiveHex.code(e.code)) wrote \(e.landed?.hexString ?? "") read \(e.readBack?.hexString ?? "nothing")"
        }
    }

    public var isClean: Bool { entries.allSatisfy(\.isClean) }

    /// Plain words for the app and the CLI: refusals and step-downs first, then read-back differences.
    public var hints: [String] {
        var out: [String] = []
        for e in entries where !e.accepted { out.append(LiveLook.refusalHint(e.code, response: e.response)) }
        for e in entries { if let n = e.note { out.append(n) } }
        for e in entries where e.accepted && !e.stuck { out.append("\(LiveProbe.label(e.code)) didn't stick (camera kept a different value)") }
        return out
    }

    /// `live: 15/17 written · refused: D032 (InvalidDevicePropValue) · DIDN'T STICK: …`
    public var line: String {
        let refusals = entries.filter { !$0.accepted }.map { "\(LiveHex.code($0.code)) \(PTP.Response.name($0.response))" }
        let notes = entries.compactMap(\.note)
        return "live: \(written.count)/\(attempted) written"
            + (refusals.isEmpty ? "" : " · refused: " + refusals.joined(separator: ", "))
            + (notes.isEmpty ? "" : " · " + notes.joined(separator: " · "))
            + (mismatched.isEmpty ? "" : " · DIDN'T STICK: " + mismatched.joined(separator: ", "))
    }
}

// MARK: - Snapshot file

/// The live state as read from the camera. One JSON shape for three commands: `props --read --json` (every
/// advertised prop), `look-live --snapshot` (the look codes, plus `touched`), and `look-restore` (reads either).
/// Codes are four hex digits ("D001"), values the raw little-endian bytes as hex ("0b00"). Never holds the serial.
public struct LiveSnapshot: Codable, Sendable, Equatable {
    public static let schemaID = "dialin.live-props/1"

    public var schema: String
    public var model: String
    public var firmware: String
    /// D16E, when read (6 = USB RAW CONV./BACKUP RESTORE).
    public var usbMode: Int?
    public var at: String
    /// GetDeviceInfo's property and operation lists (probe files only).
    public var advertised: [String]?
    public var operations: [String]?
    public var values: [String: String]
    /// Human readings of `values`, for people reading the file. Ignored on restore.
    public var decoded: [String: String]?
    /// Code → response code ("0x201C") for every refusal.
    public var refused: [String: String]?
    /// look-live: the codes it then wrote. `look-restore` writes back only these; without it, every look code present.
    public var touched: [String]?

    enum CodingKeys: String, CodingKey {
        case schema, model, firmware, usbMode = "usb_mode", at, advertised, operations, values, decoded, refused, touched
    }

    public init(
        model: String, firmware: String, usbMode: Int? = nil, values: [UInt16: Data], refused: [UInt16: UInt16] = [:],
        advertised: [UInt16]? = nil, operations: [UInt16]? = nil, touched: [UInt16]? = nil, redactingSerial serial: String = "",
        at: String = SlotBackup.timestamp()
    ) {
        schema = Self.schemaID
        self.model = model
        self.firmware = firmware
        self.usbMode = usbMode
        self.at = at
        self.advertised = advertised.map { $0.map(LiveHex.code) }
        self.operations = operations.map { $0.map(LiveHex.code) }
        var v: [String: String] = [:]
        var d: [String: String] = [:]
        for (code, bytes) in values {
            if LiveProbe.containsSerial(bytes, serial) {
                v[LiveHex.code(code)] = LiveProbe.redacted
                d[LiveHex.code(code)] = LiveProbe.redacted
            } else {
                v[LiveHex.code(code)] = bytes.hexString
                d[LiveHex.code(code)] = LiveProbe.describe(code, bytes)
            }
        }
        self.values = v
        decoded = d
        self.refused = refused.isEmpty ? nil : Dictionary(uniqueKeysWithValues: refused.map { (LiveHex.code($0.key), String(format: "0x%04X", $0.value)) })
        self.touched = touched.map { $0.map(LiveHex.code) }
    }

    /// From a `readLive` result.
    public init(model: String, firmware: String, read: LiveReadResult, advertised: [UInt16]? = nil, operations: [UInt16]? = nil,
                touched: [UInt16]? = nil, redactingSerial serial: String = "") {
        let mode = read.values[LiveProps.usbMode.code].flatMap { try? LiveCodec.decode($0, as: .uint16) }
        self.init(model: model, firmware: firmware, usbMode: mode, values: read.values, refused: read.refused,
                  advertised: advertised, operations: operations, touched: touched, redactingSerial: serial)
    }

    /// Code → bytes (redacted or malformed entries dropped).
    public var rawValues: [UInt16: Data] {
        var out: [UInt16: Data] = [:]
        for (k, v) in values {
            if let code = LiveHex.parseCode(k), let bytes = Data(hexString: v) { out[code] = bytes }
        }
        return out
    }

    public var touchedCodes: Set<UInt16>? { touched.map { Set($0.compactMap(LiveHex.parseCode)) } }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> LiveSnapshot {
        let s: LiveSnapshot
        do {
            s = try JSONDecoder().decode(LiveSnapshot.self, from: data)
        } catch {
            throw CameraError.invalid("not a live snapshot (props --read --json / look-live --snapshot): \(error)")
        }
        guard s.schema == schemaID else { throw CameraError.invalid("unknown snapshot schema \"\(s.schema)\" (want \(schemaID))") }
        return s
    }
}

/// Outcome of applying a look live.
public struct LiveLookReport: Sendable, Equatable {
    /// The live state before anything was written: the undo.
    public var before: LiveSnapshot
    /// What the recipe asked for, in camera order.
    public var planned: [PropWrite]
    /// Planned codes not written because GetDeviceInfo doesn't list them in this mode.
    public var skipped: [UInt16]
    public var write: LiveWriteReport
    /// The look codes as read after the writes.
    public var after: [UInt16: Data]
    /// D307 AUTO UPDATE CUSTOM SETTING, when the camera exposes it (values unmapped).
    public var autoUpdate: Data?

    public init(before: LiveSnapshot, planned: [PropWrite], skipped: [UInt16], write: LiveWriteReport, after: [UInt16: Data], autoUpdate: Data? = nil) {
        self.before = before
        self.planned = planned
        self.skipped = skipped
        self.write = write
        self.after = after
        self.autoUpdate = autoUpdate
    }

    public var isClean: Bool { write.isClean && skipped.isEmpty }

    /// "D001 film simulation: Classic Chrome (11) → Velvia (2)" for each planned code, plus notes.
    public var lines: [String] {
        let old = before.rawValues
        var out = planned.map { w -> String in
            let from = old[w.propID].map { LiveProbe.describe(w.propID, $0) } ?? "?"
            let to = after[w.propID].map { LiveProbe.describe(w.propID, $0) } ?? "unreadable"
            return "\(LiveHex.code(w.propID)) \(LiveProbe.label(w.propID)): \(from) → \(to)"
        }
        out += skipped.map { "\(LiveHex.code($0)) \(LiveProbe.label($0)): not advertised by the camera in this mode, skipped" }
        out += write.hints
        return out
    }
}

/// Outcome of putting a live snapshot back.
public struct LiveRestoreReport: Sendable, Equatable {
    /// Every restore write the snapshot calls for, in gate order.
    public var planned: [PropWrite]
    /// Codes already at the snapshot value: not written.
    public var alreadyRight: [UInt16]
    public var write: LiveWriteReport
    /// A second pass for codes that still differed after the first (a film-sim change can move others).
    public var retry: LiveWriteReport?
    public var after: [UInt16: Data]
    /// Codes that still don't match the snapshot.
    public var differences: [String]

    public init(planned: [PropWrite], alreadyRight: [UInt16], write: LiveWriteReport, retry: LiveWriteReport?, after: [UInt16: Data], differences: [String]) {
        self.planned = planned
        self.alreadyRight = alreadyRight
        self.write = write
        self.retry = retry
        self.after = after
        self.differences = differences
    }

    public var isClean: Bool { differences.isEmpty }
}

// MARK: - Planner additions

extension LiveLook {
    /// The only codes `FujiCamera.writeLive` will send: the look's live codes. No slot codes, no image size/quality,
    /// LMO or colour space, nothing from the exposure/drive/capture/session groups.
    public static let writableCodes: Set<UInt16> = Set(snapshotCodes)

    /// Named parts of a look for `--only`. Film sim carries mono toning; tones carry D-Range Priority (their gate).
    public static let groups: [(key: String, codes: [UInt16])] = [
        ("film_sim", [LiveProps.filmSimulation.code, LiveProps.monoWarmCool.code, LiveProps.monoMagentaGreen.code]),
        ("white_balance", [LiveProps.whiteBalance.code, LiveProps.colorTemperature.code]),
        ("wb_shift", [LiveProps.wbShiftR.code, LiveProps.wbShiftB.code]),
        ("dynamic_range", [LiveProps.dRangePriority.code, LiveProps.dynamicRange.code]),
        ("tones", [LiveProps.dRangePriority.code, LiveProps.highlight.code, LiveProps.shadow.code]),
        ("grain", [LiveProps.grain.code]),
        ("color_chrome", [LiveProps.colorChrome.code]),
        ("cc_fx_blue", [LiveProps.colorChromeFxBlue.code]),
        ("smooth_skin", [LiveProps.smoothSkin.code]),
        ("color", [LiveProps.color.code]),
        ("sharpness", [LiveProps.sharpness.code]),
        ("noise_reduction", [LiveProps.noiseReduction.code]),
        ("clarity", [LiveProps.clarity.code]),
    ]

    static let groupAliases: [String: String] = [
        "film": "film_sim", "filmsim": "film_sim", "sim": "film_sim", "wb": "white_balance", "kelvin": "white_balance",
        "shift": "wb_shift", "dr": "dynamic_range", "tone": "tones", "highlight": "tones", "shadow": "tones",
        "cc": "color_chrome", "nr": "noise_reduction",
    ]

    /// "film_sim,white_balance" or "D001,5005" (mixable) → codes. Throws on anything unknown.
    public static func codes(forOnly spec: String) throws -> Set<UInt16> {
        var out = Set<UInt16>()
        for raw in spec.split(whereSeparator: { $0 == "," || $0 == " " }).map({ String($0).lowercased() }) {
            let key = groupAliases[raw] ?? raw
            if let g = groups.first(where: { $0.key == key }) {
                out.formUnion(g.codes)
            } else if let c = LiveHex.parseCode(raw), writableCodes.contains(c) {
                out.insert(c)
            } else {
                throw CameraError.invalid("--only: \"\(raw)\" isn't one of \(groups.map(\.key).joined(separator: ", ")) or a live look code")
            }
        }
        guard !out.isEmpty else { throw CameraError.invalid("--only: nothing selected") }
        return out
    }

    /// The live writes for a recipe, optionally limited to some codes (camera order kept).
    public static func plan(for recipe: Recipe, only: Set<UInt16>? = nil) -> [PropWrite] {
        writes(for: recipe).filter { only?.contains($0.propID) ?? true }
    }

    /// What `look-restore` writes: `restoreWrites(from:)` on the snapshot (its gates decided on everything it read),
    /// then kept to the codes the apply touched when the snapshot lists them. `current` (the camera's values now) adds
    /// one write: Kelvin is only accepted while WB is Kelvin, so when the snapshot's WB wasn't Kelvin but the camera's
    /// is (the look set it), the stored Kelvin goes back first, before WB leaves Kelvin.
    public static func restorePlan(_ snapshot: LiveSnapshot, current: [UInt16: Data] = [:]) -> [PropWrite] {
        let v = snapshot.rawValues
        var all = restoreWrites(from: v).filter { writableCodes.contains($0.propID) }
        let kelvinWB = PTPPack.u16(Int(LiveWB.kelvin.rawValue))
        let k = LiveProps.colorTemperature.code, wb = LiveProps.whiteBalance.code
        if let stored = v[k], v[wb] != nil, v[wb] != kelvinWB, current[wb] == kelvinWB, !all.contains(where: { $0.propID == k }) {
            all.insert(PropWrite(propID: k, bytes: stored), at: 0)
        }
        guard let touched = snapshot.touchedCodes else { return all }
        return all.filter { touched.contains($0.propID) }
    }

    /// Same setting: equal bytes, or grain Off either way (1 written, 6/7 read).
    public static func sameValue(_ code: UInt16, _ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        guard code == LiveProps.grain.code || code == FujiProp.grain else { return false }
        let off: Set<Int> = [1, 6, 7]
        guard let x = try? LiveCodec.decode(a, as: .uint16), let y = try? LiveCodec.decode(b, as: .uint16) else { return false }
        return off.contains(x) && off.contains(y)
    }

    /// Plain words for a refused live write.
    public static func refusalHint(_ code: UInt16, response: UInt16) -> String {
        let name = LiveProbe.label(code)
        switch response {
        case PTP.Response.devicePropNotSupported:
            return "\(name) isn't available in this USB mode (0x200A)"
        case PTP.Response.deviceBusy:
            return "\(name): camera busy (0x2019); leave menus/playback and retry"
        case PTP.Response.invalidDevicePropValue:
            let why: String = switch code {
            case LiveProps.clarity.code: "set drive to S; clarity is off in burst, HDR and HEIF"
            case LiveProps.colorTemperature.code: "white balance has to be Kelvin first"
            case LiveProps.dynamicRange.code: "ISO too low for this DR, or D-Range Priority is on"
            case LiveProps.highlight.code, LiveProps.shadow.code: "D-Range Priority has to be Off"
            case LiveProps.monoWarmCool.code, LiveProps.monoMagentaGreen.code: "needs a B&W film simulation"
            case LiveProps.color.code, LiveProps.colorChrome.code, LiveProps.colorChromeFxBlue.code, LiveProps.wbShiftR.code,
                 LiveProps.wbShiftB.code: "colour film simulations only"
            default: "the camera's current state blocks it"
            }
            return "\(name) refused (0x201C: \(why))"
        default:
            return "\(name) refused by the camera (\(PTP.Response.name(response)))"
        }
    }

    /// Dry-run lines: "D001 film simulation        = 0200  Velvia (2)".
    public static func describe(_ writes: [PropWrite]) -> [String] {
        writes.map { w in
            let label = LiveProbe.label(w.propID).padding(toLength: 22, withPad: " ", startingAt: 0)
            return "\(LiveHex.code(w.propID)) \(label) = \(w.bytes.hexString.padding(toLength: 8, withPad: " ", startingAt: 0)) \(LiveProbe.describe(w.propID, w.bytes))"
        }
    }
}

// MARK: - Read-only probe helpers (`dialin-cam props --read`)

public enum LiveProbe {
    public enum Scope: Sendable, Equatable {
        /// Every prop GetDeviceInfo lists: the catalog's probe order first, then the rest ascending.
        case advertised
        /// Also every catalogued code the camera doesn't list (their refusal codes are the answer).
        case all
        /// Exactly these.
        case codes([UInt16])
    }

    /// Not read unless asked for by code: the release button and the clean/format/reset trigger. A read is harmless
    /// by PTP's definition; there is just nothing to learn from these.
    public static let neverProbed: Set<UInt16> = [LiveProps.release.code, 0xD17F]

    /// The codes whose presence in GetDeviceInfo answers open questions (custom-setting ops, priority, release, dials,
    /// exposure, drive, focus, IS, change list).
    public static let watchList: [UInt16] = [
        0xD307, 0xD34C, 0xD260, 0xD261, 0xD262, 0xD037, 0xD207, 0xD208, 0xD230, 0xD033, 0xD034, 0xD035, 0xD036,
        0x500F, 0x500D, 0x5007, 0x5010, 0xD201, 0x500A, 0xD020, 0xD351, 0xD212,
    ]

    static let redacted = "<redacted: contains the serial>"

    public static func codes(_ scope: Scope, advertised: [UInt16]) -> [UInt16] {
        var seen = Set<UInt16>()
        func unique(_ l: [UInt16]) -> [UInt16] { l.filter { seen.insert($0).inserted } }
        let adv = Set(advertised)
        switch scope {
        case .codes(let list):
            return unique(list)
        case .advertised:
            let first = LiveProps.probeReadOrder.filter(adv.contains)
            return unique(first + advertised.sorted()).filter { !neverProbed.contains($0) }
        case .all:
            return unique(LiveProps.probeReadOrder + advertised.sorted()).filter { !neverProbed.contains($0) }
        }
    }

    static let housekeeping: [UInt16: String] = [
        0xD183: "start RAW conversion", 0xD184: "IOP code", 0xD185: "RAW conversion profile", 0xD186: "tether condition code",
        0xD187: "compatibility code", 0xD36A: "battery (u32)", 0xD36B: "battery", 0xD17B: "RAW conversion state?",
        0xD17F: "clean sensor/format/reset", 0xD16E: "PC connection mode",
    ]

    /// Catalog name, else the slot block's or a housekeeping name, else "".
    public static func label(_ code: UInt16) -> String {
        if let p = LiveProps.prop(code) { return p.name }
        if code == FujiProp.slot || code == FujiProp.name || FujiProp.slotBlock.contains(code) || code == FujiProp.liveImageSize {
            return "slot " + FujiProp.label(code)
        }
        return housekeeping[code] ?? ""
    }

    /// A read value in words: catalog decode where we have one, else string / integer / hex.
    public static func describe(_ code: UInt16, _ data: Data) -> String {
        if let p = LiveProps.prop(code) { return LiveCodec.describe(data, for: p) }
        switch RawProp(id: code, bytes: data).value {
        case .string(let s): return "\"\(s)\""
        case .int(let i): return "\(i)"
        case .hex(let h): return "0x" + (h.count > 64 ? String(h.prefix(64)) + "… (\(data.count) bytes)" : h)
        }
    }

    static func containsSerial(_ data: Data, _ serial: String) -> Bool {
        let s = serial.trimmingCharacters(in: .whitespaces)
        guard s.count >= 4 else { return false }
        if case .string(let text) = RawProp(id: 0, bytes: data).value, text.contains(s) { return true }
        return String(decoding: data, as: UTF8.self).contains(s)
    }

    /// The header block: identity, capability verdicts, the watch list.
    public static func summary(model: String, firmware: String, usbMode: Int?, caps: LiveCapabilities) -> [String] {
        var out: [String] = []
        let mode = usbMode.map { "\($0) = \(LiveUSBMode.label($0) ?? "unknown")" } ?? "not readable"
        out.append("model \(model.isEmpty ? "?" : model) · firmware \(firmware.isEmpty ? "?" : firmware) · USB mode (D16E) \(mode)")
        out.append("GetDeviceInfo: \(caps.advertised.count) properties, \(caps.operations.count) operations")
        let lookCount = LiveProps.lookBlock.filter(caps.has).count
        out.append("live look block: \(lookCount)/\(LiveProps.lookBlock.count) codes advertised · "
            + (caps.canApplyLookLive
                ? "all \(LiveCapabilities.coreLook.count) core look codes present: a look can be applied live, C1–C7 untouched"
                : "missing core look codes: " + caps.missingLook.map { "\(LiveHex.code($0.code)) \($0.name)" }.joined(separator: ", ")))
        let exposure = [LiveProps.sensitivity, LiveProps.shutterSpeed, LiveProps.fNumber, LiveProps.exposureBias].filter(caps.has)
        out.append("capture 0x100E: \(caps.canCapture ? "yes" : "no") · live view 0x101C: \(caps.canLiveView ? "yes" : "no") · exposure codes: "
            + (exposure.isEmpty ? "none advertised" : exposure.map { "\(LiveHex.code($0.code)) \($0.name)" }.joined(separator: ", ")))
        let watched = watchList.map { "\(LiveHex.code($0)) \(caps.advertised.contains($0) ? "yes" : "no")" }
        out.append("watch list (advertised?): " + watched.joined(separator: " · "))
        return out
    }

    /// GetDeviceInfo's lists, 16 codes a line.
    public static func listLines(_ title: String, _ codes: [UInt16]) -> [String] {
        let hex = codes.sorted().map(LiveHex.code)
        var out = ["\(title) (\(hex.count)):"]
        stride(from: 0, to: hex.count, by: 16).forEach { out.append("  " + hex[$0..<min($0 + 16, hex.count)].joined(separator: " ")) }
        return out
    }

    /// One line per code read: code, name, raw hex, decoded value, or the refusal.
    public static func valueLines(_ read: LiveReadResult, advertised: Set<UInt16>, serial: String = "") -> [String] {
        read.order.map { c in
            let name = label(c).padding(toLength: 28, withPad: " ", startingAt: 0)
            let tag = advertised.isEmpty || advertised.contains(c) ? "" : "  (not advertised)"
            if let v = read.values[c] {
                if containsSerial(v, serial) { return "  \(LiveHex.code(c))  \(name) \(redacted)\(tag)" }
                let raw = v.count > 8 ? v.prefix(8).hexString + "…" : v.hexString
                return "  \(LiveHex.code(c))  \(name) \(raw.padding(toLength: 18, withPad: " ", startingAt: 0)) \(describe(c, v))\(tag)"
            }
            if let code = read.refused[c] {
                let why = code == PTP.Response.ok ? "OK but no data" : "refused \(String(format: "0x%04X", code)) \(PTP.Response.name(code))"
                return "  \(LiveHex.code(c))  \(name) \(why)\(tag)"
            }
            return "  \(LiveHex.code(c))  \(name) transport error: \(read.failed[c] ?? "?")\(tag)"
        }
    }
}

/// D16E read as a bitmask: 1 tether, 2 RAW conversion, 4 backup/restore, 8 webcam (so 5, 6, 8).
public enum LiveUSBMode {
    public static func label(_ v: Int) -> String? {
        switch v {
        case 5: return "USB TETHER SHOOTING (tether + backup/restore)"
        case 6: return "USB RAW CONV./BACKUP RESTORE"
        case 8: return "USB WEBCAM"
        default:
            let bits = [(1, "tether"), (2, "RAW conversion"), (4, "backup/restore"), (8, "webcam")].filter { v & $0.0 != 0 }.map(\.1)
            return (1...15).contains(v) ? bits.joined(separator: " + ") : nil
        }
    }
}

// MARK: - Apply and undo, on the camera

extension FujiCamera {
    /// Apply live writes as a look: read the look codes (the undo snapshot), hand the snapshot to `onSnapshot` BEFORE
    /// writing anything (persist it there; a throw stops here with nothing written), skip codes GetDeviceInfo doesn't
    /// list, write the rest with read-back, then read the look codes again. C1–C7 and D18C are never touched.
    public func applyLive(_ plan: [PropWrite], onSnapshot: @Sendable (LiveSnapshot) throws -> Void = { _ in }) async throws -> LiveLookReport {
        let foreign = plan.filter { !LiveLook.writableCodes.contains($0.propID) }
        guard foreign.isEmpty else {
            throw CameraError.invalid("not a live look code: " + foreign.map { LiveHex.code($0.propID) }.joined(separator: " "))
        }
        let listed: (UInt16) -> Bool = { [properties] c in properties.isEmpty || properties.contains(c) }
        let toWrite = plan.filter { listed($0.propID) }
        let skipped = plan.filter { !listed($0.propID) }.map(\.propID)
        var seen = Set<UInt16>()
        let codes = ([LiveProps.usbMode.code] + LiveLook.snapshotCodes + plan.map(\.propID)).filter { seen.insert($0).inserted && listed($0) }

        let before = try await readLive(codes)
        var autoUpdate: Data?
        let autoCode = LiveProps.customSettingAutoUpdate.code
        if properties.contains(autoCode) { autoUpdate = try await readLive([autoCode]).values[autoCode] }
        let snapshot = LiveSnapshot(model: model, firmware: firmware, read: before, touched: toWrite.map(\.propID),
                                    redactingSerial: deviceInfo.serialNumber)
        try onSnapshot(snapshot)
        if !skipped.isEmpty { log("not advertised in this mode, skipped: " + skipped.map(LiveHex.code).joined(separator: " ")) }

        let write = try await writeLive(toWrite)
        let after = try await readLive(codes)
        return LiveLookReport(before: snapshot, planned: plan, skipped: skipped, write: write, after: after.values, autoUpdate: autoUpdate)
    }

    /// Put a snapshot back: `LiveLook.restorePlan` (gate order; only the touched codes when listed), skipping codes
    /// already at their snapshot value, then one more pass for anything that still differs. Refuses another model's file.
    public func restoreLive(_ snapshot: LiveSnapshot) async throws -> LiveRestoreReport {
        if !snapshot.model.isEmpty, !model.isEmpty, snapshot.model != model {
            throw CameraError.invalid("this snapshot is from a \(snapshot.model), the camera is a \(model)")
        }
        let listed: (UInt16) -> Bool = { [properties] c in properties.isEmpty || properties.contains(c) }
        func matches(_ w: PropWrite, _ now: [UInt16: Data]) -> Bool {
            now[w.propID].map { LiveLook.sameValue(w.propID, $0, w.bytes) } ?? false
        }
        // Read what the restore could touch (plus WB/Kelvin, which decide the Kelvin-first write), then plan.
        var seen = Set<UInt16>()
        let probe = (LiveLook.restorePlan(snapshot).map(\.propID) + [LiveProps.whiteBalance.code, LiveProps.colorTemperature.code])
            .filter { seen.insert($0).inserted && listed($0) }
        let current = try await readLive(probe)
        let planned = LiveLook.restorePlan(snapshot, current: current.values).filter { listed($0.propID) }
        let codes = planned.map(\.propID)

        let first = planned.filter { !matches($0, current.values) }
        let alreadyRight = planned.filter { matches($0, current.values) }.map(\.propID)
        let w1 = try await writeLive(first)
        var after = try await readLive(codes)

        let refused = Set(w1.entries.filter { !$0.accepted }.map(\.code))
        let again = planned.filter { !refused.contains($0.propID) && !matches($0, after.values) }
        var w2: LiveWriteReport?
        if !again.isEmpty {
            log("restore: \(again.count) code(s) still differ after the first pass; writing them once more")
            w2 = try await writeLive(again)
            after = try await readLive(codes)
        }
        let differences = planned.compactMap { w -> String? in
            if matches(w, after.values) { return nil }
            let now = after.values[w.propID].map { LiveProbe.describe(w.propID, $0) } ?? "unreadable"
            return "\(LiveHex.code(w.propID)) \(LiveProbe.label(w.propID)) is \(now), snapshot \(LiveProbe.describe(w.propID, w.bytes))"
        }
        return LiveRestoreReport(planned: planned, alreadyRight: alreadyRight, write: w1, retry: w2, after: after.values, differences: differences)
    }
}

/// A Sendable box for handing a value out of a callback that runs on another actor.
final class LockedValue<T: Sendable>: Sendable {
    private let m: Mutex<T>
    init(_ v: T) { m = Mutex(v) }
    var value: T {
        get { m.withLock { $0 } }
        set { m.withLock { $0 = newValue } }
    }
}
