// The camera's RAW-conversion profile: PTP property 0xD185, 625 bytes on the X100VI, readable only after a RAF has
// been uploaded. Rendering a look means patching a copy of it and writing it back. C1–C7 are never involved.
//
// Layout (interoperability study of FUJIFILM's desktop RAW conversion, cross-checked against libfuji and FilmKit and
// our own D185 reads on an X100VI):
//   - u16 field count at 0 (0x1D = 29 in full profiles), a PTP string (u8 char count + UTF-16LE) holding the IOP code in a
//     fixed 0x1FF-byte area from offset 2, then int32 LE fields at FIXED absolute offsets from 0x201.
//   - The X100VI's 625 bytes are exactly 0x201 + 28 × 4: every field up to the digital teleconverter, without the
//     29th (Portrait Enhancer, which this body doesn't offer).
//   - Our indices keep FilmKit's numbering (https://github.com/eggricesoy/filmkit, MIT, Copyright (c) 2026 eggricesoy):
//     params at `length − count·4` = 509, so index i sits at absolute 0x1FD + 4i and the profile's field k is our index k+1.
//     Index 0 is the last 4 bytes of the IOP string area, not a parameter.
//   - Where FilmKit and the full map differ, the full map wins: exposure bias is index 5 (FilmKit said 4, which is image quality),
//     index 11 is the WB shoot condition (FilmKit said smooth skin, which is 24), mono warm/cool and magenta/green are
//     23 and 26 (libfuji fp/src/d185.c, MIT, Copyright 2025 Daniel C, had these right). `D185Layout.full` encodes
//     the full map (`dialin-cam rawconv --layout full`); `D185Layout.filmKit` stays the default until that is verified.
// Header: u8 IOP-code character count at offset 2, then UTF-16LE characters (libfuji `fp_parse_d185` agrees).
import Foundation

/// A D185 profile as the camera returned it (or a patched copy of one).
public struct D185Profile: Sendable, Equatable {
    /// Every byte, exactly as read. Patching never changes the length or anything outside the touched parameters.
    public private(set) var bytes: Data
    /// Parameter count (u16 at offset 0). 29 in every profile the references describe.
    public let count: Int
    /// Where the int32 parameters start: `length − count·4`.
    public let paramsOffset: Int
    /// The processor code in the header ("FF179503"-style), for the log.
    public let iopCode: String

    public init(_ data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 16 else { throw RawConvError.badProfile("only \(b.count) bytes; is a RAF loaded?") }
        let n = Int(LE.u16(b, 0))
        guard (8...64).contains(n) else { throw RawConvError.badProfile("parameter count \(n) is implausible (\(b.count) bytes)") }
        let off = b.count - n * 4
        guard off >= 3 else { throw RawConvError.badProfile("\(n) parameters don't fit in \(b.count) bytes") }
        var units: [UInt16] = []
        var o = 3
        for _ in 0..<Int(b[2]) {
            guard o + 2 <= off else { break }
            let u = LE.u16(b, o)
            o += 2
            if u == 0 { break }
            units.append(u)
        }
        bytes = data
        count = n
        paramsOffset = off
        iopCode = String(decoding: units, as: UTF16.self)
    }

    /// Parameter `index` as int32. Indices outside 0..<count read 0.
    public subscript(index: Int) -> Int32 {
        get {
            guard index >= 0, index < count else { return 0 }
            let o = paramsOffset + index * 4
            let b = [UInt8](bytes[bytes.startIndex + o ..< bytes.startIndex + o + 4])
            return Int32(bitPattern: LE.u32(b, 0))
        }
        set {
            precondition(index >= 0 && index < count, "D185 index \(index) outside 0..<\(count)")
            let o = bytes.startIndex + paramsOffset + index * 4
            let u = UInt32(bitPattern: newValue)
            bytes.replaceSubrange(o ..< o + 4, with: [UInt8(u & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 24)])
        }
    }

    public func contains(index: Int) -> Bool { index >= 0 && index < count }

    /// All parameters in order.
    public var params: [Int32] { (0..<count).map { self[$0] } }

    /// Indices whose value differs from `other` (same layout assumed).
    public func changedIndices(from other: D185Profile) -> [Int] {
        (0..<min(count, other.count)).filter { self[$0] != other[$0] }
    }
}

/// One D185 field.
public struct D185Field: Sendable, Equatable {
    /// Our index (FilmKit numbering): absolute offset 0x1FD + 4·index.
    public var index: Int
    /// Our short name for the field.
    public var name: String
    public var meaning: String
    /// Wire encoding and legal values (int32 LE; "signed" where the value is sign-extended on read).
    public var encoding: String
    /// Whether the X100VI offers it.
    public var x100vi: Bool
    public var absoluteOffset: Int { 0x1FD + 4 * index }
}

/// The complete D185 map: 29 int32 fields at fixed offsets 0x201…0x271 (reads and writes use the same offsets).
/// Names are ours; "default" means the value a freshly reset profile holds.
public enum D185Map {
    public static let fields: [D185Field] = [
        D185Field(index: 1, name: "shootCondition", meaning: "shooting condition: 1 = reflect the shot's own settings, 2 = use this profile (default)", encoding: "1 | 2", x100vi: true),
        D185Field(index: 2, name: "fileType", meaning: "output file type", encoding: "7 JPEG, 18 HEIF, 9 TIFF 8-bit, 11 TIFF 16-bit (the X100VI offers all four)", x100vi: true),
        D185Field(index: 3, name: "imageSize", meaning: "output size + aspect, used when D183 = 1", encoding: "composite: L 3:2 = 7, M 3:2 = 4, S 3:2 = 1; L/M/S 16:9 = 8/5/2, 1:1 = 9/6/3, 4:3 = 14/18/10, 5:4 = 16/20/12 (X100VI set)", x100vi: true),
        D185Field(index: 4, name: "imageQuality", meaning: "JPEG/HEIF quality", encoding: "2 Fine, 3 Normal", x100vi: true),
        D185Field(index: 5, name: "exposureBias", meaning: "push/pull", encoding: "signed milli-EV in thirds (thirds × 333.333, rounded): ±333, ±667, ±1000 …; X100VI range −2000…+3000", x100vi: true),
        D185Field(index: 6, name: "dynamicRange", meaning: "dynamic range %", encoding: "100 / 200 / 400 (HDR RAFs: 200/400/800); can't exceed the shot's", x100vi: true),
        D185Field(index: 7, name: "dRangePriority", meaning: "D-Range Priority", encoding: "0 off, 1 weak, 2 strong; 3 marks an HDR-plus shot", x100vi: true),
        D185Field(index: 8, name: "filmSimulation", meaning: "film simulation", encoding: "PTP film codes 1…20", x100vi: true),
        D185Field(index: 9, name: "grain", meaning: "grain strength + size", encoding: "1 off(small), 2 weak small, 3 strong small, 4 weak large, 5 strong large, 6 off small, 7 off large; off+large is stored as 7", x100vi: true),
        D185Field(index: 10, name: "colorChrome", meaning: "Color Chrome", encoding: "1 off, 2 weak, 3 strong", x100vi: true),
        D185Field(index: 11, name: "wbSource", meaning: "WB source: 1 = the shot's WB ('as shot'), 2 = the WB in index 12", encoding: "1 | 2; set 2 whenever a WB mode is set", x100vi: true),
        D185Field(index: 12, name: "whiteBalance", meaning: "WB mode", encoding: "PTP WB codes (0x0002 auto, 0x8020 AWP, 0x8021 AAP, 0x0004 daylight, 0x8006 shade, 0x8001-3 fluorescent, 0x0006 incandescent, 0x0008 underwater, 0x8007 Kelvin)", x100vi: true),
        D185Field(index: 13, name: "wbShiftRed", meaning: "WB shift red", encoding: "signed −9…+9", x100vi: true),
        D185Field(index: 14, name: "wbShiftBlue", meaning: "WB shift blue", encoding: "signed −9…+9", x100vi: true),
        D185Field(index: 15, name: "kelvin", meaning: "Kelvin", encoding: "2500…10000 step 10; default 10000", x100vi: true),
        D185Field(index: 16, name: "highlightTone", meaning: "highlight tone", encoding: "signed ×10, −20…+40 step 5", x100vi: true),
        D185Field(index: 17, name: "shadowTone", meaning: "shadow tone", encoding: "signed ×10, −20…+40 step 5", x100vi: true),
        D185Field(index: 18, name: "color", meaning: "color", encoding: "signed ×10, −40…+40", x100vi: true),
        D185Field(index: 19, name: "sharpness", meaning: "sharpness", encoding: "signed ×10, −40…+40", x100vi: true),
        D185Field(index: 20, name: "highISONR", meaning: "high ISO NR", encoding: "Fujifilm NR table (0x2000 = 0, 0x8000 = −4, 0x5000 = +4)", x100vi: true),
        D185Field(index: 21, name: "lensModulationOptimiser", meaning: "lens modulation optimiser", encoding: "default 2; not offered on the X100VI", x100vi: false),
        D185Field(index: 22, name: "colorSpace", meaning: "color space", encoding: "1 sRGB, 2 Adobe RGB", x100vi: true),
        D185Field(index: 23, name: "monoWarmCool", meaning: "B&W warm/cool", encoding: "signed; ×10 like slot prop D193 (scale unverified in D185); Monochrome±filters and Acros±filters only, not Sepia", x100vi: true),
        D185Field(index: 24, name: "smoothSkin", meaning: "smooth skin", encoding: "1 off, 2 weak, 3 strong", x100vi: true),
        D185Field(index: 25, name: "colorChromeFXBlue", meaning: "Color Chrome FX Blue", encoding: "1 off, 2 weak, 3 strong", x100vi: true),
        D185Field(index: 26, name: "monoMagentaGreen", meaning: "B&W magenta/green", encoding: "signed; ×10 like slot prop D194 (scale unverified in D185); same film sims as index 23", x100vi: true),
        D185Field(index: 27, name: "clarity", meaning: "clarity", encoding: "signed ×10, −50…+50", x100vi: true),
        D185Field(index: 28, name: "digitalTeleconverter", meaning: "digital teleconverter crop", encoding: "1 = apply the shot's teleconverter crop (forces M at 1.4×, S at 2.0×), 2 = off (full frame; default)", x100vi: true),
        D185Field(index: 29, name: "portraitEnhancer", meaning: "portrait enhancer", encoding: "1 off (newer bodies only; beyond the X100VI's 625 bytes)", x100vi: false),
    ]

    public static func field(_ index: Int) -> D185Field? { fields.first { $0.index == index } }
}

/// Which parameter means what. `init()` / `.filmKit` are FilmKit's X100VI indices (d185.ts:47-66), verified on the
/// camera; `.full` is the complete map (D185Map), `--layout full`, not yet A/B-tested against FilmKit's on the camera.
public struct D185Layout: Codable, Sendable, Equatable {
    /// nil = decide per profile with `detectExposureIndex` (FilmKit 4 vs libfuji 5).
    public var exposureBias: Int?
    public var dynamicRange = 6
    public var dRangePriority = 7
    public var filmSimulation = 8
    public var grain = 9
    public var colorChrome = 10
    public var whiteBalance = 12
    public var wbShiftR = 13
    public var wbShiftB = 14
    public var kelvin = 15
    public var highlight = 16
    public var shadow = 17
    public var color = 18
    public var sharpness = 19
    public var noiseReduction = 20
    public var colorChromeFxBlue = 25
    public var clarity = 27
    /// libfuji only (d185.c:30,33); FilmKit says toning isn't in D185. Experimental.
    public var monoWarmCool = 23
    public var monoMagentaGreen = 26
    /// Value meaning "Off" for CC FX Blue: 1 (FilmKit, d185.ts:105) or 0 (libfuji fp.h:164-166).
    public var colorChromeFxBlueBase = 1
    /// libfuji's "WB shoot condition" (index 11; 1 = use the shot's WB, which takes precedence over the WB mode,
    /// d185.c:150-153). nil (default, FilmKit) = never written. Set to 11 if a WB-mode change renders identical.
    public var wbShootCondition: Int?
    /// Value written to `wbShootCondition` when a render changes the WB mode or Kelvin (2 = use index 12).
    public var wbShootConditionOff = 2
    /// Full-map-only fields (nil in the FilmKit layout): shooting condition, file type, image size, image quality, LMO,
    /// color space, smooth skin, digital teleconverter.
    public var shootCondition: Int?
    public var fileType: Int?
    public var imageSize: Int?
    public var imageQuality: Int?
    public var lensModulation: Int?
    public var colorSpace: Int?
    public var smoothSkin: Int?
    public var digitalTeleConv: Int?

    public init() {}

    public static let filmKit = D185Layout()

    /// The complete map (see D185Map).
    public static let full: D185Layout = {
        var l = D185Layout()
        l.exposureBias = 5
        l.wbShootCondition = 11
        l.colorChromeFxBlueBase = 1
        l.shootCondition = 1
        l.fileType = 2
        l.imageSize = 3
        l.imageQuality = 4
        l.lensModulation = 21
        l.colorSpace = 22
        l.smoothSkin = 24
        l.digitalTeleConv = 28
        return l
    }()

    /// "full" / "fuji", "filmkit", or a JSON file of indices.
    public static func named(_ name: String) -> D185Layout? {
        switch name.lowercased() {
        case "full", "fuji": .full
        case "filmkit": .filmKit
        default: nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case exposureBias = "exposure_bias", dynamicRange = "dynamic_range", dRangePriority = "d_range_priority"
        case filmSimulation = "film_simulation", grain, colorChrome = "color_chrome", whiteBalance = "white_balance"
        case wbShiftR = "wb_shift_r", wbShiftB = "wb_shift_b", kelvin, highlight, shadow, color, sharpness
        case noiseReduction = "noise_reduction", colorChromeFxBlue = "color_chrome_fx_blue", clarity
        case monoWarmCool = "mono_wc", monoMagentaGreen = "mono_mg", colorChromeFxBlueBase = "color_chrome_fx_blue_base"
        case wbShootCondition = "wb_shoot_condition", wbShootConditionOff = "wb_shoot_condition_off"
        case shootCondition = "shoot_condition", fileType = "file_type", imageSize = "image_size"
        case imageQuality = "image_quality", lensModulation = "lens_modulation", colorSpace = "color_space"
        case smoothSkin = "smooth_skin", digitalTeleConv = "digital_tele_conv"
    }

    /// Any subset of keys; the rest keep FilmKit's defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys, _ d: Int) throws -> Int { try c.decodeIfPresent(Int.self, forKey: k) ?? d }
        exposureBias = try c.decodeIfPresent(Int.self, forKey: .exposureBias)
        dynamicRange = try v(.dynamicRange, 6)
        dRangePriority = try v(.dRangePriority, 7)
        filmSimulation = try v(.filmSimulation, 8)
        grain = try v(.grain, 9)
        colorChrome = try v(.colorChrome, 10)
        whiteBalance = try v(.whiteBalance, 12)
        wbShiftR = try v(.wbShiftR, 13)
        wbShiftB = try v(.wbShiftB, 14)
        kelvin = try v(.kelvin, 15)
        highlight = try v(.highlight, 16)
        shadow = try v(.shadow, 17)
        color = try v(.color, 18)
        sharpness = try v(.sharpness, 19)
        noiseReduction = try v(.noiseReduction, 20)
        colorChromeFxBlue = try v(.colorChromeFxBlue, 25)
        clarity = try v(.clarity, 27)
        monoWarmCool = try v(.monoWarmCool, 23)
        monoMagentaGreen = try v(.monoMagentaGreen, 26)
        colorChromeFxBlueBase = try v(.colorChromeFxBlueBase, 1)
        wbShootCondition = try c.decodeIfPresent(Int.self, forKey: .wbShootCondition)
        wbShootConditionOff = try v(.wbShootConditionOff, 2)
        shootCondition = try c.decodeIfPresent(Int.self, forKey: .shootCondition)
        fileType = try c.decodeIfPresent(Int.self, forKey: .fileType)
        imageSize = try c.decodeIfPresent(Int.self, forKey: .imageSize)
        imageQuality = try c.decodeIfPresent(Int.self, forKey: .imageQuality)
        lensModulation = try c.decodeIfPresent(Int.self, forKey: .lensModulation)
        colorSpace = try c.decodeIfPresent(Int.self, forKey: .colorSpace)
        smoothSkin = try c.decodeIfPresent(Int.self, forKey: .smoothSkin)
        digitalTeleConv = try c.decodeIfPresent(Int.self, forKey: .digitalTeleConv)
    }

    /// What each index is called, for dumps. The full map's name where this layout follows it, FilmKit's otherwise.
    public func label(_ index: Int, exposureIndex: Int?) -> String {
        if index == exposureIndex { return "exposure bias (milli-EV)" }
        var names: [Int: String] = [:]
        func put(_ i: Int?, _ n: String) { if let i, names[i] == nil { names[i] = n } }
        put(dynamicRange, "DR %"); put(dRangePriority, "D-Range Priority"); put(filmSimulation, "film sim")
        put(grain, "grain (1–7)"); put(colorChrome, "color chrome (1–3)"); put(whiteBalance, "WB mode")
        put(wbShiftR, "WB shift R"); put(wbShiftB, "WB shift B"); put(kelvin, "Kelvin"); put(highlight, "highlight ×10")
        put(shadow, "shadow ×10"); put(color, "color ×10"); put(sharpness, "sharpness ×10"); put(noiseReduction, "NR (Fujifilm table)")
        put(colorChromeFxBlue, "CC FX Blue"); put(clarity, "clarity ×10"); put(wbShootCondition, "WB shoot condition (1 as shot, 2 use WB mode)")
        put(shootCondition, "shoot condition (1 as shot, 2 use profile)"); put(fileType, "file type (7 JPEG)")
        put(imageSize, "image size (7 L 3:2, 4 M, 1 S)"); put(imageQuality, "image quality (2 Fine, 3 Normal)")
        put(lensModulation, "LMO"); put(colorSpace, "color space (1 sRGB, 2 Adobe)"); put(smoothSkin, "smooth skin (1–3)")
        put(digitalTeleConv, "teleconverter (1 shot's crop, 2 off)")
        let fuji = self == .full || shootCondition != nil
        put(monoWarmCool, fuji ? "mono warm/cool ×10" : "[libfuji: mono warm/cool ×10]")
        put(monoMagentaGreen, fuji ? "mono magenta/green ×10" : "[libfuji: mono magenta/green ×10]")
        if let n = names[index] { return n }
        if index == 0 { return "(tail of the IOP string area, not a parameter)" }
        if let f = D185Map.field(index) { return "[\(f.name)]" }
        return "?"
    }

    // MARK: Exposure index

    public struct ExposureIndexGuess: Codable, Sendable, Equatable {
        public var index: Int
        public var confident: Bool
        public var evidence: String
    }

    /// FilmKit puts exposure bias at 4 (d185.ts:47); libfuji's order puts image quality there and exposure bias at 5
    /// (d185.c:12-13). A valid exposure value is 0 or a third of an EV in milli-EV (libfuji fp.h:35-53: 333, 667, 1000…);
    /// image quality / size are small positive codes. Pick the index whose value only an exposure could hold.
    public static func detectExposureIndex(_ p: D185Profile) -> ExposureIndexGuess {
        let v4 = Int(p[4]), v5 = Int(p[5])
        func isEV(_ v: Int) -> Bool {
            guard abs(v) <= 5000 else { return false }
            let k = (Double(v) * 3 / 1000).rounded()
            return abs(Double(v) - k * 1000 / 3) <= 2 && (v == 0 || abs(v) >= 300)
        }
        func isCode(_ v: Int) -> Bool { (1...32).contains(v) }
        if isCode(v4) && isEV(v5) {
            return ExposureIndexGuess(index: 5, confident: true,
                evidence: "index 4 = \(v4) looks like an image-quality code and index 5 = \(v5) is a valid exposure (libfuji order)")
        }
        if isCode(v5) && isEV(v4) {
            return ExposureIndexGuess(index: 4, confident: true,
                evidence: "index 5 = \(v5) looks like a code and index 4 = \(v4) is a valid exposure (FilmKit order)")
        }
        return ExposureIndexGuess(index: 4, confident: false,
            evidence: "ambiguous (index 4 = \(v4), index 5 = \(v5)); using FilmKit's 4. Verify with an A/B render, or pass --exposure-index")
    }

    /// The exposure index to use for `profile`: the layout's fixed one, else the detected one.
    public func exposureIndex(for profile: D185Profile) -> ExposureIndexGuess {
        if let fixed = exposureBias {
            return ExposureIndexGuess(index: fixed, confident: true, evidence: "fixed by the layout / --exposure-index")
        }
        return Self.detectExposureIndex(profile)
    }
}

/// The shot's own recipe as the base profile states it: FilmKit's `cameraProfileToUIValues`
/// (preset-translate.ts:208-245), keeping the raw values next to the decoded ones so a dump can be checked against the
/// JPEG's maker note.
public struct D185AsShot: Codable, Sendable, Equatable {
    public var filmSim: String?
    public var filmSimCode: Int
    /// Raw percent (100/200/400); 0 = not stated.
    public var dynamicRange: Int
    public var dRangePriority: Int
    public var grain: String?
    public var colorChrome: String?
    public var colorChromeFxBlue: String?
    /// 0 = "as shot" sentinel (FilmKit: can't be extracted).
    public var whiteBalanceCode: Int
    public var wbShiftR: Int
    public var wbShiftB: Int
    public var kelvin: Int
    /// nil where the value is the 0x8000 "use the shot's EXIF" sentinel.
    public var highlight: Double?
    public var shadow: Double?
    public var color: Double?
    public var sharpness: Double?
    public var noiseReduction: Int?
    public var clarity: Double?
    public var exposureEV: Double?
    public var exposureIndex: Int
    /// Full-map extras (nil when the layout doesn't name them): raw values as the camera stated them.
    public var shootCondition: Int?
    public var wbShootCondition: Int?
    public var fileType: Int?
    public var imageSize: Int?
    public var imageQuality: Int?
    public var colorSpace: Int?
    public var smoothSkin: Int?
    public var digitalTeleConv: Int?
    public var monoWarmCool: Double?
    public var monoMagentaGreen: Double?

    enum CodingKeys: String, CodingKey {
        case filmSim = "film_sim", filmSimCode = "film_sim_code", dynamicRange = "dynamic_range"
        case dRangePriority = "d_range_priority", grain, colorChrome = "color_chrome"
        case colorChromeFxBlue = "color_chrome_fx_blue", whiteBalanceCode = "white_balance_code"
        case wbShiftR = "wb_shift_r", wbShiftB = "wb_shift_b", kelvin, highlight, shadow, color, sharpness
        case noiseReduction = "noise_reduction", clarity, exposureEV = "exposure_ev", exposureIndex = "exposure_index"
        case shootCondition = "shoot_condition", wbShootCondition = "wb_shoot_condition", fileType = "file_type"
        case imageSize = "image_size", imageQuality = "image_quality", colorSpace = "color_space", smoothSkin = "smooth_skin"
        case digitalTeleConv = "digital_tele_conv", monoWarmCool = "mono_wc", monoMagentaGreen = "mono_mg"
    }

    public init(_ p: D185Profile, layout: D185Layout = .filmKit, exposureIndex: Int) {
        func tone(_ i: Int) -> Double? {
            let raw = Int(p[i])
            return raw == 0x8000 || raw == -32768 ? nil : Double(raw) / 10   // preset-translate.ts:89-92
        }
        func effect(_ v: Int32, base: Int) -> String? { Effect(level: Int(v) - base)?.rawValue }
        let grainNames = [1: Grain.off, 2: .weakSmall, 3: .strongSmall, 4: .weakLarge, 5: .strongLarge, 6: .off, 7: .off]
        filmSimCode = Int(p[layout.filmSimulation])
        filmSim = FilmSimulation(code: filmSimCode)?.rawValue
        dynamicRange = Int(p[layout.dynamicRange])
        dRangePriority = Int(p[layout.dRangePriority])
        grain = grainNames[Int(p[layout.grain])]?.rawValue
        colorChrome = effect(p[layout.colorChrome], base: 1)
        colorChromeFxBlue = effect(p[layout.colorChromeFxBlue], base: layout.colorChromeFxBlueBase)
        whiteBalanceCode = Int(p[layout.whiteBalance]) & 0xFFFF
        wbShiftR = Int(p[layout.wbShiftR])
        wbShiftB = Int(p[layout.wbShiftB])
        kelvin = Int(p[layout.kelvin])
        highlight = tone(layout.highlight)
        shadow = tone(layout.shadow)
        color = tone(layout.color)
        sharpness = tone(layout.sharpness)
        let nr = Int(p[layout.noiseReduction]) & 0xFFFF
        noiseReduction = FujiNR.decode[nr]
        clarity = tone(layout.clarity)
        self.exposureIndex = exposureIndex
        func opt(_ i: Int?) -> Int? { i.flatMap { p.contains(index: $0) ? Int(p[$0]) : nil } }
        shootCondition = opt(layout.shootCondition)
        wbShootCondition = opt(layout.wbShootCondition)
        fileType = opt(layout.fileType)
        imageSize = opt(layout.imageSize)
        imageQuality = opt(layout.imageQuality)
        colorSpace = opt(layout.colorSpace)
        smoothSkin = opt(layout.smoothSkin)
        digitalTeleConv = opt(layout.digitalTeleConv)
        if layout.shootCondition != nil {
            monoWarmCool = p.contains(index: layout.monoWarmCool) ? Double(p[layout.monoWarmCool]) / 10 : nil
            monoMagentaGreen = p.contains(index: layout.monoMagentaGreen) ? Double(p[layout.monoMagentaGreen]) / 10 : nil
        }
        exposureEV = p.contains(index: exposureIndex) ? Double(p[exposureIndex]) / 1000 : nil
    }

    /// One line for the log: "Reala Ace · DR400 · grain Weak Small · CC Weak/Weak · WB as shot R0 B0 · H-1 S0 C1 Sh-1 NR-4 Cl0".
    public var line: String {
        func n(_ d: Double?) -> String { d.map(jsNumber) ?? "·" }
        let wb = whiteBalanceCode == 0 ? "as shot"
            : (WhiteBalance(code: whiteBalanceCode)?.rawValue ?? String(format: "0x%04X", whiteBalanceCode))
            + (whiteBalanceCode == FujiWB.colorTemp ? " \(kelvin)K" : "")
        return [
            filmSim ?? "sim \(filmSimCode)",
            dynamicRange > 0 ? "DR\(dynamicRange)" : "DR ·",
            dRangePriority != 0 ? "DR-P \(dRangePriority)" : nil,
            "grain \(grain ?? "?")",
            "CC \(colorChrome ?? "?")/\(colorChromeFxBlue ?? "?")",
            "WB \(wb) R\(wbShiftR) B\(wbShiftB)",
            "H\(n(highlight)) S\(n(shadow)) C\(n(color)) Sh\(n(sharpness)) NR\(noiseReduction.map(String.init) ?? "·") Cl\(n(clarity))",
            "EV[\(exposureIndex)] \(exposureEV.map { String(format: "%+.2f", $0) } ?? "·")",
            wbShootCondition.map { $0 == 1 ? "WB source: shot" : "WB source: profile" },
            shootCondition.map { $0 == 1 ? "shoot cond: as shot" : "shoot cond: profile" },
            imageSize.map { "size \(D185ImageSize.name(code: $0))" },
            digitalTeleConv.map { $0 == 1 ? "TC crop on" : "TC off" },
        ].compactMap { $0 }.joined(separator: " · ")
    }
}
