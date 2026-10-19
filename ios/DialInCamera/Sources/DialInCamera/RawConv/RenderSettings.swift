// What to change for one re-render, and the patch that applies it onto the camera's own D185 profile.
//
// Every field is optional: unset fields keep the base profile's value, which keeps the camera's "use the shot's EXIF"
// sentinels (FilmKit: patching instead of rebuilding "eliminates the visual shift", d185.ts:79-86).
// Encodings are FilmKit's `patchProfile` (https://github.com/eggricesoy/filmkit src/profile/d185.ts:87-129, MIT,
// Copyright (c) 2026 eggricesoy): raw film-sim code, grain flat enum 1–5 (:63-69), effects 1-indexed (:104-106), DR as
// raw percent (:72), WB mode code + Kelvin (:109-112), tones/color/sharpness/clarity ×10 (:115-123), NR through
// NR_ENCODE (preset-translate.ts:103-106). Exposure is milli-EV snapped to thirds (libfuji fp/src/fp.h:35-53).
// JSON keys and enum strings are the Recipe's (snake_case, "Acros+R", "Weak Small", "DR400").
// With the full layout (D185Layout.full) the patch also sets the WB source:
// a WB mode is written together with WB shoot condition 2; "As Shot" is shoot condition 1 with the mode left alone.
import Foundation

/// White balance for a render: the shot's own ("As Shot", sentinel 0) or one of the camera's modes.
public enum RenderWhiteBalance: Codable, Hashable, Sendable {
    case asShot
    case mode(WhiteBalance)

    public var code: Int {
        switch self {
        case .asShot: FujiWB.asShot
        case .mode(let wb): wb.code
        }
    }

    public var name: String {
        switch self {
        case .asShot: "As Shot"
        case .mode(let wb): wb.rawValue
        }
    }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        if s.lowercased() == "as shot" { self = .asShot; return }
        guard let wb = WhiteBalance(rawValue: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown white balance \"\(s)\""))
        }
        self = .mode(wb)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}

/// D185 image-size composite (the X100VI's value set): row L/M/S × aspect. Used when D183 = 1.
public enum D185ImageSize {
    static let table: [String: Int] = [
        "L 3:2": 7, "M 3:2": 4, "S 3:2": 1, "L 16:9": 8, "M 16:9": 5, "S 16:9": 2, "L 1:1": 9, "M 1:1": 6, "S 1:1": 3,
        "L 4:3": 14, "M 4:3": 18, "S 4:3": 10, "L 5:4": 16, "M 5:4": 20, "S 5:4": 12,
    ]

    /// "M", "m 3:2", "L 16:9" → code; a bare size means 3:2.
    public static func code(_ name: String) -> Int? {
        let t = name.trimmingCharacters(in: .whitespaces).uppercased()
        return table[t.count == 1 ? t + " 3:2" : t]
    }

    public static func name(code: Int) -> String { table.first { $0.value == code }?.key ?? "code \(code)" }
}

/// One render's changes. JSON-compatible with tools/colorlab variants.json `settings`.
public struct RenderSettings: Codable, Hashable, Sendable {
    public var filmSim: FilmSimulation?
    public var whiteBalance: RenderWhiteBalance?
    /// Kelvin 2500–10000. Setting it without `whiteBalance` means WB = Kelvin.
    public var kelvin: Int?
    public var wbShiftR: Int?
    public var wbShiftB: Int?
    /// Can't exceed the DR the RAF was shot at (libfuji d185.c:127: "can only select equal or lower than in RAW").
    public var dynamicRange: DynamicRange?
    /// 0 Off, 1 Weak, 2 Strong. While on, the camera ignores DR/highlight/shadow (libfuji d185.c:131-133).
    public var dRangePriority: Int?
    /// −2…+4 in 0.5 steps.
    public var highlight: Double?
    public var shadow: Double?
    /// −4…+4. Not applied to B&W sims.
    public var color: Int?
    public var sharpness: Int?
    public var noiseReduction: Int?
    /// −5…+5.
    public var clarity: Int?
    public var grain: Grain?
    public var colorChrome: Effect?
    public var colorChromeFxBlue: Effect?
    /// Push/pull in EV, snapped to ⅓ (+0.33 → +333 milli-EV). −2…+3 (the camera menu offers −1…+3).
    public var exposure: Double?
    /// EXPERIMENTAL (libfuji only): B&W toning, −18…+18, B&W sims only.
    public var monoWarmCool: Int?
    public var monoMagentaGreen: Int?
    /// Full layout only (D185Layout.full). Output size, "L"/"M"/"S" with an optional aspect ("M 3:2"); the camera uses it
    /// when D183 = 1 (`--start 1`). M 3:2 = 5472 × 3648.
    public var imageSize: String?
    /// "sRGB" or "Adobe RGB".
    public var colorSpace: String?
    public var smoothSkin: Effect?
    /// true = keep the shot's digital-teleconverter crop (Fuji then caps the size at M for 1.4×, S for 2.0×),
    /// false = render the full frame.
    public var teleconverter: Bool?
    /// Experiments: parameter index (as a string) → raw int32, applied last. E.g. {"11": 2}.
    public var raw: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case filmSim = "film_sim", whiteBalance = "white_balance", kelvin
        case wbShiftR = "wb_shift_r", wbShiftB = "wb_shift_b", dynamicRange = "dynamic_range"
        case dRangePriority = "d_range_priority", highlight, shadow, color, sharpness
        case noiseReduction = "noise_reduction", clarity, grain, colorChrome = "color_chrome"
        case colorChromeFxBlue = "color_chrome_fx_blue", exposure, monoWarmCool = "mono_wc"
        case monoMagentaGreen = "mono_mg", raw
        case imageSize = "image_size", colorSpace = "color_space", smoothSkin = "smooth_skin", teleconverter
    }

    public init(
        filmSim: FilmSimulation? = nil, whiteBalance: RenderWhiteBalance? = nil, kelvin: Int? = nil, wbShiftR: Int? = nil,
        wbShiftB: Int? = nil, dynamicRange: DynamicRange? = nil, dRangePriority: Int? = nil, highlight: Double? = nil,
        shadow: Double? = nil, color: Int? = nil, sharpness: Int? = nil, noiseReduction: Int? = nil, clarity: Int? = nil,
        grain: Grain? = nil, colorChrome: Effect? = nil, colorChromeFxBlue: Effect? = nil, exposure: Double? = nil,
        monoWarmCool: Int? = nil, monoMagentaGreen: Int? = nil, raw: [String: Int]? = nil,
        imageSize: String? = nil, colorSpace: String? = nil, smoothSkin: Effect? = nil, teleconverter: Bool? = nil
    ) {
        self.filmSim = filmSim
        self.whiteBalance = whiteBalance
        self.kelvin = kelvin
        self.wbShiftR = wbShiftR
        self.wbShiftB = wbShiftB
        self.dynamicRange = dynamicRange
        self.dRangePriority = dRangePriority
        self.highlight = highlight
        self.shadow = shadow
        self.color = color
        self.sharpness = sharpness
        self.noiseReduction = noiseReduction
        self.clarity = clarity
        self.grain = grain
        self.colorChrome = colorChrome
        self.colorChromeFxBlue = colorChromeFxBlue
        self.exposure = exposure
        self.monoWarmCool = monoWarmCool
        self.monoMagentaGreen = monoMagentaGreen
        self.raw = raw
        self.imageSize = imageSize
        self.colorSpace = colorSpace
        self.smoothSkin = smoothSkin
        self.teleconverter = teleconverter
    }

    /// A whole look: every recipe field. (Recipes carry no exposure or D-Range Priority, so those stay as shot.)
    public init(recipe r: Recipe) {
        self.init(
            filmSim: r.filmSim, whiteBalance: .mode(r.whiteBalance), kelvin: r.whiteBalance == .kelvin ? (r.kelvin != 0 ? r.kelvin : 5500) : nil,
            wbShiftR: r.wbShiftR, wbShiftB: r.wbShiftB, dynamicRange: r.dynamicRange, highlight: r.highlight,
            shadow: r.shadow, color: r.color, sharpness: r.sharpness, noiseReduction: r.noiseReduction, clarity: r.clarity,
            grain: r.grain, colorChrome: r.colorChrome, colorChromeFxBlue: r.colorChromeFxBlue)
    }

    public static let unchanged = RenderSettings()

    public var isEmpty: Bool { self == .unchanged }

    /// Range checks that don't need the base profile. Throws `RawConvError.invalidSettings` naming every problem.
    public func validate() throws {
        var bad: [String] = []
        func half(_ name: String, _ v: Double?, _ lo: Double, _ hi: Double) {
            guard let v else { return }
            if v < lo || v > hi || (v * 2).rounded() != v * 2 { bad.append("\(name) \(jsNumber(v)) (\(jsNumber(lo))…\(jsNumber(hi)) in 0.5 steps)") }
        }
        func int(_ name: String, _ v: Int?, _ lo: Int, _ hi: Int) {
            guard let v else { return }
            if v < lo || v > hi { bad.append("\(name) \(v) (\(lo)…\(hi))") }
        }
        half("highlight", highlight, -2, 4)
        half("shadow", shadow, -2, 4)
        int("color", color, -4, 4)
        int("sharpness", sharpness, -4, 4)
        int("noise_reduction", noiseReduction, -4, 4)
        int("clarity", clarity, -5, 5)
        int("wb_shift_r", wbShiftR, -9, 9)
        int("wb_shift_b", wbShiftB, -9, 9)
        int("kelvin", kelvin, 2500, 10000)
        int("d_range_priority", dRangePriority, 0, 2)
        int("mono_wc", monoWarmCool, -18, 18)
        int("mono_mg", monoMagentaGreen, -18, 18)
        if let e = exposure, e < -2 || e > 3 { bad.append("exposure \(e) (−2…+3 EV)") }
        if case .mode(let wb)? = whiteBalance, wb != .kelvin, kelvin != nil { bad.append("kelvin given with white_balance \(wb.rawValue)") }
        for k in (raw ?? [:]).keys where Int(k) == nil { bad.append("raw key \"\(k)\" is not an index") }
        if let sz = imageSize, D185ImageSize.code(sz) == nil { bad.append("image_size \"\(sz)\" (L/M/S, optionally with 3:2, 16:9, 1:1, 4:3, 5:4)") }
        if let cs = colorSpace, RenderSettings.colorSpaceCode(cs) == nil { bad.append("color_space \"\(cs)\" (sRGB or Adobe RGB)") }
        if !bad.isEmpty { throw RawConvError.invalidSettings(bad.joined(separator: "; ")) }
    }

    static func colorSpaceCode(_ s: String) -> Int? {
        switch s.lowercased().replacingOccurrences(of: " ", with: "") {
        case "srgb": 1
        case "adobergb", "adobe": 2
        default: nil
        }
    }

    /// The film sim this render ends up with, given the base's.
    func targetFilmSimCode(base: Int) -> Int { filmSim?.code ?? base }

    /// "Acros+R · WB Daylight R+1 B−1 · H−1 S+0.5 · +⅓ EV" (only what changes).
    public var summary: String {
        if isEmpty { return "as shot (unchanged)" }
        func s(_ v: Double) -> String { (v > 0 ? "+" : "") + jsNumber(v) }
        func si(_ v: Int) -> String { (v > 0 ? "+" : "") + String(v) }
        var parts: [String] = []
        if let f = filmSim { parts.append(f.rawValue) }
        var wb: [String] = []
        if let w = whiteBalance { wb.append(w.name + (kelvin.map { " \($0)K" } ?? "")) } else if let k = kelvin { wb.append("\(k)K") }
        if let r = wbShiftR { wb.append("R\(si(r))") }
        if let b = wbShiftB { wb.append("B\(si(b))") }
        if !wb.isEmpty { parts.append("WB " + wb.joined(separator: " ")) }
        if let d = dynamicRange { parts.append(d.rawValue) }
        if let d = dRangePriority { parts.append("DR-P \(d)") }
        var tones: [String] = []
        if let h = highlight { tones.append("H\(s(h))") }
        if let v = shadow { tones.append("S\(s(v))") }
        if let c = color { tones.append("Color\(si(c))") }
        if let c = sharpness { tones.append("Sharp\(si(c))") }
        if let c = noiseReduction { tones.append("NR\(si(c))") }
        if let c = clarity { tones.append("Clarity\(si(c))") }
        if !tones.isEmpty { parts.append(tones.joined(separator: " ")) }
        if let g = grain { parts.append("grain \(g.rawValue)") }
        if let c = colorChrome { parts.append("CC \(c.rawValue)") }
        if let c = colorChromeFxBlue { parts.append("CC Blue \(c.rawValue)") }
        if let e = exposure { parts.append(String(format: "%+.2f EV", e)) }
        if let w = monoWarmCool { parts.append("WC\(si(w))") }
        if let m = monoMagentaGreen { parts.append("MG\(si(m))") }
        if let v = imageSize { parts.append("size \(v)") }
        if let v = colorSpace { parts.append(v) }
        if let v = smoothSkin { parts.append("skin \(v.rawValue)") }
        if let v = teleconverter { parts.append(v ? "TC crop" : "TC off") }
        if let r = raw, !r.isEmpty { parts.append("raw " + r.sorted { $0.key < $1.key }.map { "[\($0.key)]=\($0.value)" }.joined(separator: ",")) }
        return parts.joined(separator: " · ")
    }
}

/// Applies `RenderSettings` onto a base profile.
public enum D185Patch {
    public struct Change: Codable, Sendable, Equatable {
        public var index: Int
        public var field: String
        public var from: Int32
        public var to: Int32
    }

    public struct Result: Sendable, Equatable {
        public var profile: D185Profile
        public var changes: [Change]
        /// Things skipped or worth knowing ("DR400 skipped: shot at DR200 …").
        public var notes: [String]
        public var exposureIndex: D185Layout.ExposureIndexGuess
    }

    /// milli-EV for an EV value, snapped to thirds: 0.33 → 333, −0.67 → −667, 1 → 1000 (libfuji fp.h:35-53).
    public static func milliEV(_ ev: Double) -> Int32 {
        let thirds = (ev * 3).rounded()
        return Int32((thirds * 1000 / 3).rounded())
    }

    /// FilmKit `GRAIN_TO_NATIVE` (d185.ts:63-69).
    public static func nativeGrain(_ g: Grain) -> Int32 {
        switch g {
        case .off: 1
        case .weakSmall: 2
        case .strongSmall: 3
        case .weakLarge: 4
        case .strongLarge: 5
        }
    }

    public static func apply(_ s: RenderSettings, to base: D185Profile, layout: D185Layout = .filmKit) throws -> Result {
        try s.validate()
        var p = base
        var changes: [Change] = []
        var notes: [String] = []
        let ev = layout.exposureIndex(for: base)

        func set(_ index: Int, _ field: String, _ value: Int32) throws {
            guard p.contains(index: index) else {
                throw RawConvError.invalidSettings("\(field): index \(index) is outside this \(p.count)-parameter profile")
            }
            if base[index] != value { changes.append(Change(index: index, field: field, from: base[index], to: value)) }
            p[index] = value
        }

        let baseSim = Int(base[layout.filmSimulation])
        let targetSim = s.targetFilmSimCode(base: baseSim)
        let mono = FujiFilmSim.monochromeCodes.contains(targetSim)

        if let f = s.filmSim { try set(layout.filmSimulation, "film sim", Int32(f.code)) }

        // D-Range Priority first: when on, the camera owns DR and the tones.
        if let d = s.dRangePriority { try set(layout.dRangePriority, "D-Range Priority", Int32(d)) }
        let drpOn = Int(p[layout.dRangePriority]) != 0
        if let dr = s.dynamicRange {
            let want = Int32(dr.level == 1 ? 100 : dr.level == 2 ? 200 : 400)
            let shot = base[layout.dynamicRange]
            if [100, 200, 400].contains(shot), want > shot {
                notes.append("\(dr.rawValue) skipped: the RAF was shot at DR\(shot) and RAW conversion can't go higher")
            } else {
                try set(layout.dynamicRange, "DR %", want)
            }
        }
        if drpOn && (s.highlight != nil || s.shadow != nil || s.dynamicRange != nil) {
            notes.append("D-Range Priority is on in this profile: the camera may ignore DR, highlight and shadow")
        }

        if let g = s.grain { try set(layout.grain, "grain", nativeGrain(g)) }

        // Color-only settings. The slot writer skips these for B&W sims (camera.ts MONO_SKIP); do the same here.
        let colorOnly: [(String, Bool)] = [
            ("color", s.color != nil), ("color chrome", s.colorChrome != nil), ("CC FX Blue", s.colorChromeFxBlue != nil),
            ("WB shift", s.wbShiftR != nil || s.wbShiftB != nil),
        ]
        if mono {
            let skipped = colorOnly.filter(\.1).map(\.0)
            if !skipped.isEmpty { notes.append("B&W sim: skipped \(skipped.joined(separator: ", "))") }
            if s.filmSim != nil && !FujiFilmSim.monochromeCodes.contains(baseSim) && base[layout.color] != 0 {
                try set(layout.color, "color ×10", 0)
                notes.append("switched to B&W: color set to 0 (a B&W shot's profile carries no color setting)")
            }
        } else {
            if let c = s.colorChrome { try set(layout.colorChrome, "color chrome", Int32(c.level + 1)) }
            if let c = s.colorChromeFxBlue { try set(layout.colorChromeFxBlue, "CC FX Blue", Int32(c.level + layout.colorChromeFxBlueBase)) }
            if let r = s.wbShiftR { try set(layout.wbShiftR, "WB shift R", Int32(r)) }
            if let b = s.wbShiftB { try set(layout.wbShiftB, "WB shift B", Int32(b)) }
            if let c = s.color { try set(layout.color, "color ×10", Int32(c * 10)) }
        }

        // White balance: mode, then Kelvin (only meaningful for the Kelvin mode).
        var wb = s.whiteBalance
        if wb == nil, s.kelvin != nil { wb = .mode(.kelvin) }
        if let wb {
            if wb == .asShot, let i = layout.wbShootCondition {
                // "As shot" is WB shoot condition 1; the mode field is left alone.
                try set(i, "WB shoot condition", 1)
            } else {
                try set(layout.whiteBalance, "WB mode", Int32(wb.code))
                if wb == .mode(.kelvin) { try set(layout.kelvin, "Kelvin", Int32(s.kelvin ?? 5500)) }
                if let i = layout.wbShootCondition { try set(i, "WB shoot condition", Int32(layout.wbShootConditionOff)) }
            }
        }

        if let h = s.highlight { try set(layout.highlight, "highlight ×10", Int32((h * 10).rounded())) }
        if let v = s.shadow { try set(layout.shadow, "shadow ×10", Int32((v * 10).rounded())) }
        if let v = s.sharpness { try set(layout.sharpness, "sharpness ×10", Int32(v * 10)) }
        if let v = s.noiseReduction, let code = FujiNR.encode[v] { try set(layout.noiseReduction, "NR", Int32(code)) }
        if let v = s.clarity { try set(layout.clarity, "clarity ×10", Int32(v * 10)) }

        if let e = s.exposure {
            try set(ev.index, "exposure bias (milli-EV)", milliEV(e))
            if e < -1 { notes.append("exposure below −1 EV: the camera's own menu stops at −1") }
            if !ev.confident { notes.append("exposure written at index \(ev.index), which is a guess: \(ev.evidence)") }
        }

        if s.monoWarmCool != nil || s.monoMagentaGreen != nil {
            if mono {
                if let w = s.monoWarmCool { try set(layout.monoWarmCool, "mono warm/cool ×10 (experimental)", Int32(w * 10)) }
                if let m = s.monoMagentaGreen { try set(layout.monoMagentaGreen, "mono magenta/green ×10 (experimental)", Int32(m * 10)) }
                notes.append("B&W toning is experimental (libfuji indices 23/26; FilmKit says it isn't in D185)")
            } else {
                notes.append("B&W toning skipped: the film sim isn't B&W")
            }
        }

        func fujiIndex(_ i: Int?, _ name: String) throws -> Int {
            guard let i else { throw RawConvError.invalidSettings("\(name) needs the full D185 layout (--layout full)") }
            return i
        }
        if let sz = s.imageSize, let code = D185ImageSize.code(sz) {
            try set(try fujiIndex(layout.imageSize, "image_size"), "image size", Int32(code))
            notes.append("image size \(D185ImageSize.name(code: code)) is used when D183 = 1 (--start 1); D183 = 0 renders at the shot's size")
        }
        if let cs = s.colorSpace, let code = RenderSettings.colorSpaceCode(cs) {
            try set(try fujiIndex(layout.colorSpace, "color_space"), "color space", Int32(code))
        }
        if let v = s.smoothSkin { try set(try fujiIndex(layout.smoothSkin, "smooth_skin"), "smooth skin", Int32(v.level + 1)) }
        if let v = s.teleconverter {
            try set(try fujiIndex(layout.digitalTeleConv, "teleconverter"), "teleconverter", v ? 1 : 2)
        }

        for (k, v) in (s.raw ?? [:]).sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
            guard let i = Int(k) else { continue }
            try set(i, "raw[\(i)]", Int32(truncatingIfNeeded: v))
        }
        return Result(profile: p, changes: changes, notes: notes, exposureIndex: ev)
    }
}
