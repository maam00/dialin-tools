// Whole looks into C1–C7 of an X100VI (fw 1.10) settings file: the Swift port of ble/fuji_ble/correlate.py `apply_plan`
// (+ `recipe_values`, `encode_field`, `wb_table_offset_for`, `_observed`, and backupfile.py `patch_many` with the
// incremental checksum). Golden vectors from the Python code: Tests/DialInCameraTests/Fixtures/look-patch-vectors.json
// (made by Tests/make-look-patch-vectors.py).
//
// The slot map below is ble/maps/x100vi-fw110.json (`fields` + `records`), baked in: offsets relative to each slot's
// anchor, encodings, and which values were seen on a real file ("located" + observed) vs inferred from the X-T5. The
// seen codes come from ConfirmedCodes.x100vi (lib/cameras.ts). As in Python, an inferred encoding is refused unless
// `allowInferred`, and every refusal is listed before anything is written. A refused file is never produced.
//
// What the writer sets per look (camera.ts writeSlot, mirrored by recipe_values): film sim, D-Range Priority forced Off,
// DR, grain strength (+ size unless Off), smooth skin Off, WB, highlight, shadow, sharpness, NR, clarity, Kelvin only for
// WB Kelvin (0 → 5500), and for colour sims Color, CC, CC FX Blue and the WB shift in the table entry of the look's WB
// mode. Mono sims skip Color/CC/CCB/shift (the slot keeps its old values). The name is Recipe.slotName (ASCII, ≤14).
import Foundation

extension FujiSettingsFile {
    /// One look aimed at one slot (1…7).
    public struct LookPlacement: Codable, Sendable, Hashable {
        public var slot: Int
        public var recipe: Recipe
        public init(slot: Int, recipe: Recipe) {
            self.slot = slot
            self.recipe = recipe
        }
    }

    /// A patched file plus what changed. `allowed` = every byte offset the edits may change (the checksum aside).
    public struct LookPatch: Sendable {
        public var file: FujiSettingsFile
        public var lines: [String]
        public var allowed: Set<Int>
        public var warnings: [String]
    }

    /// `apply_plan` byte for byte: each look into its slot, the checksum fixed incrementally once, the round trip
    /// validated. Throws `SettingsFileError.invalid` listing every refusal (nothing is written), e.g. an inferred
    /// encoding without `allowInferred`. A name total over ~95 characters is a warning here (as in Python); the
    /// Bluetooth writer refuses it.
    public func applyingLooks(_ placements: [LookPlacement], allowInferred: Bool = false) throws -> LookPatch {
        let plan = try LookSlotMap.edits(for: placements, in: self, allowInferred: allowInferred)
        guard plan.refused.isEmpty else {
            throw SettingsFileError.invalid("refusing to write (nothing written):\n  " + plan.refused.joined(separator: "\n  "))
        }
        var out = bytes
        var allowed = Set<Int>()
        for e in plan.edits {
            guard e.offset >= 0, e.offset + e.bytes.count <= out.count else {
                throw SettingsFileError.invalid(String(format: "patch 0x%X+%d is outside the %d-byte file", e.offset, e.bytes.count, out.count))
            }
            guard e.offset >= payloadStart else {
                throw SettingsFileError.invalid(String(format: "refusing to patch the header (offset 0x%X)", e.offset))
            }
            guard !(e.offset < Self.checksumOffset + 4 && Self.checksumOffset < e.offset + e.bytes.count) else {
                throw SettingsFileError.invalid("patch overlaps the checksum field")
            }
            out.replaceSubrange(e.offset..<e.offset + e.bytes.count, with: e.bytes)
            allowed.formUnion(e.offset..<e.offset + e.bytes.count)
        }
        var warnings: [String] = []
        let names = plan.names
        let total = names.reduce(0) { $0 + $1.count }
        if total > Self.nameBudget {
            warnings.append("WARNING: the seven names total \(total) characters (X-T5 restores refuse above ~\(Self.nameBudget))")
        }
        let sum = try Self.expectedChecksum(original: self, patchedBytes: out)
        out[Self.checksumOffset] = UInt8(sum & 0xFF)
        out[Self.checksumOffset + 1] = UInt8(sum >> 8)
        let fixed = try FujiSettingsFile(bytes: out)
        let problems = Self.validate(original: self, patched: fixed, allowed: allowed)
        guard problems.isEmpty else { throw SettingsFileError.invalid("round-trip check failed: " + problems.joined(separator: "; ")) }
        var lines = plan.report
        lines.append(String(format: "checksum 0x%04X → 0x%04X (incremental 16-bit byte sum @ 0x108)", storedChecksum, sum))
        return LookPatch(file: fixed, lines: lines, allowed: allowed, warnings: warnings)
    }

    /// This recipe's values whose encoding was never seen on a real file, in plain words
    /// ("Classic Neg (film simulation code inferred)"). Empty = every byte it needs is verified.
    public static func inferredValues(for recipe: Recipe) -> [String] {
        LookSlotMap.values(for: recipe).compactMap { key, value -> String? in
            guard let f = LookSlotMap.field(key), !LookSlotMap.isVerified(f, value, wb: LookSlotMap.wbCode(recipe)) else { return nil }
            switch key {
            case "film_sim": return "\(recipe.filmSim.rawValue) (film simulation code inferred)"
            case "white_balance": return "\(recipe.whiteBalance.rawValue) white balance (code inferred)"
            case "nr": return "noise reduction \(recipe.noiseReduction) (only −4 seen on a real file)"
            case "color": return "color \(recipe.color) (code inferred)"
            case "wb_shift_r", "wb_shift_b": return "white balance shift under \(recipe.whiteBalance.rawValue) (never seen on a real file)"
            default: return "\(f.label) \(value.describe(key)) (inferred)"
            }
        }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// How slot `slot` of THIS file differs from what `applyingLooks` writes for `recipe`: the name and every field the
    /// writer sets, compared as stored values (a byte the camera stores differently but means the same, like Color 0 as
    /// raw 7, matches). Empty = the slot holds the look.
    public func mismatches(slot: Int, against recipe: Recipe) -> [String] {
        guard (1...7).contains(slot) else { return ["slot \(slot) is not 1…7"] }
        var out: [String] = []
        let wantName = recipe.slotName
        let haveName = name(slot: slot)
        if haveName != wantName { out.append("name: the camera has \"\(haveName)\", the look is \"\(wantName)\"") }
        let anchor = anchors[slot - 1]
        let wb = LookSlotMap.wbCode(recipe)
        for (key, value) in LookSlotMap.values(for: recipe) {
            guard let f = LookSlotMap.field(key), let off = f.offset(anchor: anchor, wb: wb),
                  let want = try? f.encode(value) else { continue }
            let have = Array(bytes[off..<off + want.count])
            if have == want { continue }
            let haveRaw = f.interp == .u16le ? Int(LE.u16(have, 0)) : Int(have[0])
            if let decoded = f.decode(raw: haveRaw), decoded.matches(value) { continue }
            let haveText = f.decode(raw: haveRaw).map { $0.describe(key) } ?? "raw \(haveRaw)"
            out.append("\(f.label): the camera has \(haveText), the look wants \(value.describe(key))")
        }
        return out
    }

    /// The look slot `slot` holds, read back through the same map (nil when a value has no name in it: DR Auto, Auto
    /// White Priority, a custom WB, an unknown film code). Mono slots report Color 0, CC off and no shift (the camera
    /// keeps stale values there that a mono look ignores).
    public func recipe(slot: Int) -> Recipe? {
        guard (1...7).contains(slot) else { return nil }
        let a = anchors[slot - 1]
        func dec(_ key: String, wb: Int = 0x0002) -> LookValue? {
            guard let f = LookSlotMap.field(key), let off = f.offset(anchor: a, wb: wb), off + 2 <= bytes.count else { return nil }
            return f.decode(raw: f.interp == .u16le ? Int(LE.u16(bytes, off)) : Int(bytes[off]))
        }
        func int(_ v: LookValue?) -> Int? { v.map { Int($0.double.rounded()) } }
        guard let code = int(dec("film_sim")), let sim = LookSlotMap.filmSimCodes.first(where: { $0.value == code })?.key,
              let wbCode = int(dec("white_balance")), let wb = LookSlotMap.wbCodes.first(where: { $0.value == wbCode })?.key,
              let drValue = int(dec("dynamic_range")), let dr = DynamicRange(rawValue: "DR\(drValue)"),
              let strength = int(dec("grain_strength")), let h = dec("highlight")?.double, let sh = dec("shadow")?.double,
              let sharp = int(dec("sharpness")), let nr = int(dec("nr")), let clarity = int(dec("clarity"))
        else { return nil }
        let grain: Grain
        switch (strength, int(dec("grain_size"))) {
        case (0, _): grain = .off
        case (1, 0): grain = .weakSmall
        case (2, 0): grain = .strongSmall
        case (1, 1): grain = .weakLarge
        case (2, 1): grain = .strongLarge
        default: return nil
        }
        var r = Recipe(name: name(slot: slot), filmSim: sim, grain: grain, whiteBalance: wb, dynamicRange: dr, highlight: h,
                       shadow: sh, sharpness: sharp, noiseReduction: nr, clarity: clarity)
        if wb == .kelvin { r.kelvin = int(dec("kelvin")) ?? 0 }
        if !LookSlotMap.monoSims.contains(code) {
            guard let color = int(dec("color")), let cc = int(dec("color_chrome")).flatMap(Effect.init(level:)),
                  let ccb = int(dec("cc_fx_blue")).flatMap(Effect.init(level:)),
                  let sr = int(dec("wb_shift_r", wb: wbCode)), let sb = int(dec("wb_shift_b", wb: wbCode)) else { return nil }
            r.color = color
            r.colorChrome = cc
            r.colorChromeFxBlue = ccb
            r.wbShiftR = sr
            r.wbShiftB = sb
        }
        return r
    }

    /// Slot `slot`'s look in the words the camera's menu uses: "Classic Chrome, Color +2, Grain Weak Small, …".
    public func lookDescription(slot: Int) -> String? { recipe(slot: slot).map(Self.describe) }

    /// A recipe in the camera menu's words (Camera Check reads C1 back to the tester with this).
    public static func describe(_ r: Recipe) -> String {
        func signed(_ v: Double) -> String {
            let text = v == v.rounded() ? "\(Int(abs(v)))" : "\(abs(v))"
            return v > 0 ? "+" + text : v < 0 ? "\u{2212}" + text : "0"
        }
        var parts = [r.filmSim.rawValue]
        let mono = r.filmSim.isMonochrome
        if !mono { parts.append("Color \(signed(Double(r.color)))") }
        parts.append("Grain \(r.grain.rawValue)")
        if !mono {
            parts.append("Color Chrome \(r.colorChrome.rawValue)")
            parts.append("Color Chrome FX Blue \(r.colorChromeFxBlue.rawValue)")
        }
        var wb = "White balance \(r.whiteBalance == .kelvin ? "\(r.kelvin)K" : r.whiteBalance.rawValue)"
        if !mono && (r.wbShiftR != 0 || r.wbShiftB != 0) { wb += " R\(signed(Double(r.wbShiftR))) B\(signed(Double(r.wbShiftB)))" }
        parts.append(wb)
        parts.append(r.dynamicRange.rawValue)
        parts.append("Highlight \(signed(r.highlight))")
        parts.append("Shadow \(signed(r.shadow))")
        parts.append("Sharpness \(signed(Double(r.sharpness)))")
        parts.append("Clarity \(signed(Double(r.clarity)))")
        parts.append("High ISO NR \(signed(Double(r.noiseReduction)))")
        return parts.joined(separator: ", ")
    }

    /// Byte range of slot `slot`'s whole record including its preamble (Kelvin at −0x74 … the next preamble).
    public func slotRegion(_ slot: Int) -> Range<Int> {
        let a = anchors[slot - 1]
        let lo = a - 0x80
        let hi = slot == 7 ? bytes.count : anchors[slot] - 0x80
        return lo..<hi
    }

    /// The block that moves with every shot (last frame number / folder), C1 − 0xE2; the X-T5 checksum skips the same
    /// spot. A verification ignores it.
    public static let frameCounterBlock = 0xF71E..<0xF72A
}

public typealias LookPlacement = FujiSettingsFile.LookPlacement

// MARK: - The slot map (ble/maps/x100vi-fw110.json)

/// A value the writer sets, in correlate.py's `FieldDef.to_value` units: an int or a float (they print differently in
/// refusals, and decide which encoding keys match, exactly as in Python).
enum LookValue: Sendable, Equatable {
    case int(Int)
    case float(Double)

    var double: Double {
        switch self {
        case .int(let i): Double(i)
        case .float(let d): d
        }
    }

    /// Python `repr`.
    var repr: String {
        switch self {
        case .int(let i): "\(i)"
        case .float(let d): "\(d)"
        }
    }

    /// The keys `_observed` / `encode_field` try: str(v), json.dumps(v), json.dumps(float(v)), str(int(v)) if integral.
    var keys: [String] {
        let d = double
        var k = [repr]
        let f = "\(d)"
        if !k.contains(f) { k.append(f) }
        if d == d.rounded(), abs(d) < 1e15 {
            let i = "\(Int(d))"
            if !k.contains(i) { k.append(i) }
        }
        return k
    }

    func matches(_ other: LookValue) -> Bool { abs(double - other.double) < 1e-9 }

    func describe(_ key: String) -> String {
        let d = double
        switch key {
        case "film_sim": return LookSlotMap.filmSimNames[Int(d)] ?? "film code \(Int(d))"
        case "white_balance": return LookSlotMap.wbNames[Int(d)] ?? String(format: "WB 0x%04X", Int(d))
        case "dynamic_range": return Int(d) == 0 ? "DR Auto" : "DR\(Int(d))"
        case "kelvin": return "\(Int(d))K"
        case "grain_strength": return ["off", "weak", "strong"][safe: Int(d)] ?? "\(Int(d))"
        case "grain_size": return ["small", "large"][safe: Int(d)] ?? "\(Int(d))"
        case "color_chrome", "cc_fx_blue", "smooth_skin": return ["off", "weak", "strong"][safe: Int(d)] ?? "\(Int(d))"
        default:
            let text = d == d.rounded() ? "\(Int(d))" : "\(d)"
            return d > 0 ? "+" + text : text
        }
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

enum LookSlotMap {
    enum Interp: Sendable { case u8, u16le }

    enum Encoding: Sendable {
        /// value → raw by a lookup; `map` = seen on a real file, `inferred` = from the X-T5; `aliases` decode only.
        case enumeration(map: [String: Int], inferred: [String: Int], aliases: [Int: String])
        /// value = c0 + c1 · raw (variant "value"), or DR index = raw (variant "index").
        case affine(c0: Double, c1: Double, index: Bool)
        /// The USB wire value as stored (Kelvin, u16 LE).
        case ptpWire
        /// The WB shift: one entry per WB mode, value = c0 + c1 · raw.
        case wbTable(baseRel: Int, stride: Int, indexByPTP: [Int: Int], observedIndices: Set<Int>, c0: Double, c1: Double)
    }

    struct Field: Sendable {
        var key: String
        var label: String
        var rel: Int
        var interp: Interp
        var located: Bool
        /// `observed_values` keys of an inferred field.
        var observed: Set<String>
        var encoding: Encoding

        func offset(anchor: Int, wb: Int) -> Int? {
            if case .wbTable(let base, let stride, let byPTP, _, _, _) = encoding {
                guard let idx = byPTP[wb] else { return nil }
                return anchor + base + stride * idx
            }
            return anchor + rel
        }

        /// `encode_field`.
        func encode(_ value: LookValue) throws -> [UInt8] {
            switch encoding {
            case .ptpWire:
                let wire = Int(value.double.rounded(.towardZero)) & 0xFFFF
                return [UInt8(wire & 0xFF), UInt8(wire >> 8)]
            case .affine(let c0, let c1, let index):
                var v = value.double
                if index {
                    guard let i = LookSlotMap.drIndex[Int(value.double)] else { throw SettingsFileError.invalid("\(key)=\(value.repr): not a DR") }
                    v = Double(i)
                }
                return try raw((v - c0) / c1, value)
            case .wbTable(_, _, _, _, let c0, let c1):
                return try raw((value.double - c0) / c1, value)
            case .enumeration(let map, let inferred, _):
                let mp = inferred.merging(map) { _, m in m }
                guard let k = value.keys.first(where: { mp[$0] != nil }), let r = mp[k] else {
                    throw SettingsFileError.invalid("\(key)=\(value.repr) was never seen in the training slots; known: \(mp.keys.sorted())")
                }
                return try write(r)
            }
        }

        private func raw(_ r: Double, _ value: LookValue) throws -> [UInt8] {
            guard abs(r - r.rounded()) <= 1e-6 else {
                throw SettingsFileError.invalid("\(value.repr) isn't representable for \(key) (raw \(r))")
            }
            return try write(Int(r.rounded()))
        }

        /// `write_raw`.
        private func write(_ r: Int) throws -> [UInt8] {
            switch interp {
            case .u8:
                guard (0...0xFF).contains(r) else { throw SettingsFileError.invalid("raw \(r) doesn't fit u8") }
                return [UInt8(r)]
            case .u16le:
                guard (0...0xFFFF).contains(r) else { throw SettingsFileError.invalid("raw \(r) doesn't fit u16le") }
                return [UInt8(r & 0xFF), UInt8(r >> 8)]
            }
        }

        /// `decode_field` for a raw value already read (nil = a raw this map can't name).
        func decode(raw: Int) -> LookValue? {
            switch encoding {
            case .ptpWire: return .int(raw)
            case .affine(let c0, let c1, let index):
                let v = c0 + c1 * Double(raw)
                if index { return LookSlotMap.drIndex.first(where: { $0.value == Int(v.rounded()) }).map { .int($0.key) } }
                return .float(v)
            case .wbTable(_, _, _, _, let c0, let c1): return .float(c0 + c1 * Double(raw))
            case .enumeration(let map, let inferred, let aliases):
                if let k = map.first(where: { $0.value == raw })?.key ?? aliases[raw] ?? inferred.first(where: { $0.value == raw })?.key,
                   let d = Double(k) {
                    return k.contains(".") ? .float(d) : .int(Int(d))
                }
                return nil
            }
        }
    }

    static let drIndex: [Int: Int] = [0: 0, 100: 1, 200: 2, 400: 3]

    private static func affine(_ key: String, _ label: String, _ rel: Int, c0: Double, c1: Double, index: Bool = false,
                               located: Bool = true, observed: Set<String> = []) -> Field {
        Field(key: key, label: label, rel: rel, interp: .u8, located: located, observed: observed,
              encoding: .affine(c0: c0, c1: c1, index: index))
    }

    // The verified codes come from ConfirmedCodes.x100vi (rendered from lib/cameras.ts, the source of truth); the
    // X-T5-derived guesses below fill in the rest as `inferred`, minus any guess for a confirmed value or byte. The
    // result is exactly ble/maps/x100vi-fw110.json (`npm run codes -- check` keeps the two in step).
    static let confirmed = ConfirmedCodes.x100vi

    /// The X-T5 table with Reala Ace at 0x12 and X-T5 codes ≥ 0x12 shifted +1 (PTP film-sim code → byte).
    static let filmSimGuesses: [String: Int] = [
        "1": 1, "2": 4, "3": 2, "4": 14, "5": 13, "6": 9, "7": 11, "8": 10, "9": 12, "10": 6, "11": 15, "12": 22, "13": 24,
        "14": 23, "15": 25, "16": 19, "17": 16, "18": 20, "19": 17, "20": 18,
    ]
    /// X-T5 WB codes (PTP WB code → byte).
    static let wbGuesses: [String: Int] = [
        "2": 0, "32800": 1, "32801": 2, "4": 3, "32774": 4, "32769": 5, "32770": 6, "32771": 7, "6": 8, "8": 9, "32775": 10,
        "32776": 11,
    ]
    /// X-T5 Color bytes, 7 − v (Color 0 is stored as 0 on this body; 7 decodes to 0 too).
    static let colorGuesses: [String: Int] = [
        "-4.0": 11, "-3.0": 10, "-2.0": 9, "-1.0": 8, "0.0": 0, "1.0": 6, "2.0": 5, "3.0": 4, "4.0": 3,
    ]
    /// The X-T5 order of the 14-entry WB-shift table (PTP WB code → entry).
    static let wbIndexGuesses: [Int: Int] = [
        0x0002: 0, 0x8020: 1, 0x8021: 2, 0x8008: 3, 0x8009: 4, 0x800A: 5, 0x8007: 6, 0x0004: 7, 0x8006: 8,
        0x8001: 9, 0x8002: 10, 0x8003: 11, 0x0006: 12, 0x0008: 13,
    ]

    /// Confirmed codes as `map`, the guesses that don't collide with them as `inferred`.
    static func split(_ map: [String: Int], guesses: [String: Int]) -> (map: [String: Int], inferred: [String: Int]) {
        let taken = Set(map.values)
        return (map, guesses.filter { map[$0.key] == nil && !taken.contains($0.value) })
    }

    static let filmSimSplit = split(Dictionary(uniqueKeysWithValues: confirmed.filmSims.compactMap { name, code in
        FilmSimulation(rawValue: name).flatMap { filmSimCodes[$0] }.map { (String($0), code) }
    }), guesses: filmSimGuesses)
    static let wbSplit = split(Dictionary(uniqueKeysWithValues: confirmed.whiteBalances.compactMap { name, wb in
        WhiteBalance(rawValue: name).flatMap { wbCodes[$0] }.map { (String($0), wb.code) }
    }), guesses: wbGuesses)
    static let colorSplit = split(Dictionary(uniqueKeysWithValues: confirmed.colors.map { ("\(Double($0.key))", $0.value) }),
                                  guesses: colorGuesses)
    static let wbIndexByPTP: [Int: Int] = wbIndexGuesses.merging(
        confirmed.whiteBalances.compactMap { name, wb in WhiteBalance(rawValue: name).flatMap { wbCodes[$0] }.map { ($0, wb.shiftEntry) } },
        uniquingKeysWith: { _, confirmed in confirmed })
    private static let observedShiftEntries = Set(confirmed.whiteBalances.values.map(\.shiftEntry))
    private static let observedNR = Set(confirmed.noiseReductions.keys.map { "\($0)" })

    /// ble/maps/x100vi-fw110.json `fields`, the ones apply_plan writes.
    static let fields: [Field] = [
        Field(key: "film_sim", label: "film simulation", rel: 0x64, interp: .u8, located: true, observed: [],
              encoding: .enumeration(map: filmSimSplit.map, inferred: filmSimSplit.inferred, aliases: [:])),
        affine("dynamic_range", "dynamic range", 0x74, c0: 0, c1: 1, index: true),
        Field(key: "dr_priority", label: "D-range priority", rel: 0x76, interp: .u8, located: false, observed: ["0"],
              encoding: .enumeration(map: ["0": 4], inferred: ["1": 3, "2": 2, "32768": 0], aliases: [:])),
        Field(key: "color", label: "color", rel: 0x77, interp: .u8, located: true, observed: [],
              encoding: .enumeration(map: colorSplit.map, inferred: colorSplit.inferred, aliases: [7: "0.0"])),
        affine("sharpness", "sharpness", 0x79, c0: 4, c1: -1),
        affine("highlight", "highlight", 0x7B, c0: -2, c1: 0.5),
        affine("shadow", "shadow", 0x7D, c0: -2, c1: 0.5),
        affine("color_chrome", "color chrome", 0x7F, c0: 0, c1: 1),
        affine("cc_fx_blue", "color chrome FX blue", 0x80, c0: 0, c1: 1),
        affine("grain_strength", "grain", 0x81, c0: 2, c1: -1),
        affine("grain_size", "grain size", 0x82, c0: 0, c1: 1),
        affine("smooth_skin", "smooth skin", 0x83, c0: 0, c1: 1, located: false, observed: ["0"]),
        affine("nr", "noise reduction", 0x2B, c0: -4, c1: 1, located: false, observed: observedNR),
        affine("clarity", "clarity", 0x2E, c0: -6, c1: 1),
        Field(key: "white_balance", label: "white balance", rel: -0x0F, interp: .u8, located: true, observed: [],
              encoding: .enumeration(map: wbSplit.map, inferred: wbSplit.inferred, aliases: [:])),
        Field(key: "kelvin", label: "Kelvin", rel: -0x74, interp: .u16le, located: true, observed: [], encoding: .ptpWire),
        Field(key: "wb_shift_r", label: "WB shift red", rel: -0x0D, interp: .u8, located: true, observed: [],
              encoding: .wbTable(baseRel: -0x0D, stride: 4, indexByPTP: wbIndexByPTP, observedIndices: observedShiftEntries, c0: 9, c1: -1)),
        Field(key: "wb_shift_b", label: "WB shift blue", rel: -0x0B, interp: .u8, located: true, observed: [],
              encoding: .wbTable(baseRel: -0x0B, stride: 4, indexByPTP: wbIndexByPTP, observedIndices: observedShiftEntries, c0: 9, c1: -1)),
    ]

    static func field(_ key: String) -> Field? { fields.first { $0.key == key } }

    /// correlate.py FILM_SIM_BY_NAME (lib/fuji/recipe.ts codes).
    static let filmSimCodes: [FilmSimulation: Int] = [
        .provia: 1, .velvia: 2, .astia: 3, .proNegHi: 4, .proNegStd: 5, .monochrome: 6, .monochromeYe: 7, .monochromeR: 8,
        .monochromeG: 9, .sepia: 10, .classicChrome: 11, .acros: 12, .acrosYe: 13, .acrosR: 14, .acrosG: 15, .eterna: 16,
        .classicNeg: 17, .eternaBleachBypass: 18, .nostalgicNeg: 19, .realaAce: 20,
    ]
    static let filmSimNames: [Int: String] = Dictionary(uniqueKeysWithValues: filmSimCodes.map { ($0.value, $0.key.rawValue) })
    static let monoSims: Set<Int> = [6, 7, 8, 9, 10, 12, 13, 14, 15]
    /// WB_BY_NAME.
    static let wbCodes: [WhiteBalance: Int] = [
        .auto: 0x0002, .autoAmbience: 0x8021, .daylight: 0x0004, .shade: 0x8006, .fluorescent1: 0x8001,
        .fluorescent2: 0x8002, .fluorescent3: 0x8003, .incandescent: 0x0006, .kelvin: 0x8007,
    ]
    static let wbNames: [Int: String] = Dictionary(uniqueKeysWithValues: wbCodes.map { ($0.value, $0.key.rawValue) })

    static func wbCode(_ r: Recipe) -> Int { wbCodes[r.whiteBalance] ?? 0x0002 }

    /// `recipe_values`, in the same key order.
    static func values(for r: Recipe) -> [(String, LookValue)] {
        let sim = filmSimCodes[r.filmSim] ?? 1
        let wb = wbCode(r)
        let (strength, size): (Int, Int?) = switch r.grain {
        case .off: (0, nil)
        case .weakSmall: (1, 0)
        case .strongSmall: (2, 0)
        case .weakLarge: (1, 1)
        case .strongLarge: (2, 1)
        }
        let dr = switch r.dynamicRange {
        case .dr100: 100
        case .dr200: 200
        case .dr400: 400
        }
        var v: [(String, LookValue)] = [
            ("film_sim", .int(sim)), ("dr_priority", .int(0)), ("dynamic_range", .int(dr)), ("grain_strength", .int(strength)),
            ("smooth_skin", .int(0)), ("white_balance", .int(wb)), ("highlight", .float(r.highlight)),
            ("shadow", .float(r.shadow)), ("sharpness", .float(Double(r.sharpness))), ("nr", .int(r.noiseReduction)),
            ("clarity", .float(Double(r.clarity))),
        ]
        if let size { v.append(("grain_size", .int(size))) }
        if wb == 0x8007 { v.append(("kelvin", .int(r.kelvin == 0 ? 5500 : r.kelvin))) }
        if !monoSims.contains(sim) {
            v += [("color", .float(Double(r.color))), ("color_chrome", .int(r.colorChrome.level)),
                  ("cc_fx_blue", .int(r.colorChromeFxBlue.level)), ("wb_shift_r", .int(r.wbShiftR)), ("wb_shift_b", .int(r.wbShiftB))]
        }
        return v
    }

    /// `_observed`, plus the WB-table entry check apply_plan does for the shift.
    static func isVerified(_ f: Field, _ value: LookValue, wb: Int) -> Bool {
        if !f.located { return !f.observed.isDisjoint(with: value.keys) }
        switch f.encoding {
        case .enumeration(let map, _, _): return value.keys.contains { map[$0] != nil }
        case .wbTable(_, _, let byPTP, let seen, _, _): return byPTP[wb].map(seen.contains) ?? false
        default: return true
        }
    }

    struct Edit: Sendable { var key: String; var offset: Int; var bytes: [UInt8] }

    struct Plan: Sendable {
        var edits: [Edit] = []
        var refused: [String] = []
        var report: [String] = []
        var names: [String] = []
    }

    /// `apply_plan` up to `patch_many`: the edits in order, the refusals, the report lines, the names after.
    static func edits(for placements: [FujiSettingsFile.LookPlacement], in file: FujiSettingsFile, allowInferred: Bool) throws -> Plan {
        var plan = Plan()
        plan.names = file.names
        for p in placements {
            guard (1...7).contains(p.slot) else { throw SettingsFileError.invalid("slot \(p.slot) is not 1..7") }
            let anchor = file.anchors[p.slot - 1]
            let wb = wbCode(p.recipe)
            let name = p.recipe.slotName
            var line = ["C\(p.slot) \(pyRepr(plan.names[p.slot - 1])) -> \(pyRepr(name)):"]
            for (key, value) in values(for: p.recipe) {
                guard let f = field(key) else {
                    plan.refused.append("C\(p.slot) \(key): not located in this map")
                    continue
                }
                if !f.located, f.observed.isDisjoint(with: value.keys), !allowInferred {
                    plan.refused.append("C\(p.slot) \(key)=\(value.repr): encoding inferred, not seen on a real file (--allow-inferred)")
                    continue
                }
                if f.located, case .enumeration(let map, _, _) = f.encoding, !value.keys.contains(where: { map[$0] != nil }), !allowInferred {
                    plan.refused.append("C\(p.slot) \(key)=\(value.repr): encoding inferred, not seen on a real file (--allow-inferred)")
                    continue
                }
                let off: Int?
                if case .wbTable(_, _, let byPTP, let seen, _, _) = f.encoding {
                    off = f.offset(anchor: anchor, wb: wb)
                    let idx = byPTP[wb]
                    if !(idx.map(seen.contains) ?? false) && !allowInferred {
                        plan.refused.append("C\(p.slot) \(key): WB-table entry \(idx.map(String.init) ?? "None") never seen (--allow-inferred)")
                        continue
                    }
                } else {
                    off = anchor + f.rel
                }
                guard let off else {
                    plan.refused.append(String(format: "C\(p.slot) \(key): no table entry for WB 0x%04x", wb))
                    continue
                }
                let new = try f.encode(value)
                let old = Array(file.bytes[off..<off + new.count])
                plan.edits.append(Edit(key: key, offset: off, bytes: new))
                if old != new { line.append("\(key) \(Data(old).hexString)->\(Data(new).hexString)") }
            }
            var field = Array(name.utf8.prefix(FujiSettingsFile.nameFieldLength))
            field += [UInt8](repeating: 0, count: FujiSettingsFile.nameFieldLength - field.count)
            plan.edits.append(Edit(key: "name", offset: anchor + FujiSettingsFile.nameRel, bytes: field))
            plan.names[p.slot - 1] = name
            plan.report.append(line.joined(separator: " "))
        }
        return plan
    }

    /// Python's repr of a str (single quotes unless the text holds one and no double quote).
    static func pyRepr(_ s: String) -> String {
        if s.contains("'") && !s.contains("\"") { return "\"\(s)\"" }
        return "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
