// A "look" in human terms: what the AI writes, what our server sends, what the camera menu shows.
// Mirrors `Recipe` in lib/fuji/recipe.ts field for field (snake_case JSON, same enum strings).
import Foundation

// MARK: - Enums (raw values are the exact strings in lib/fuji/recipe.ts)

public enum FilmSimulation: String, Codable, CaseIterable, Sendable {
    case provia = "Provia"
    case velvia = "Velvia"
    case astia = "Astia"
    case classicChrome = "Classic Chrome"
    case realaAce = "Reala Ace"
    case proNegHi = "Pro Neg Hi"
    case proNegStd = "Pro Neg Std"
    case classicNeg = "Classic Neg"
    case nostalgicNeg = "Nostalgic Neg"
    case eterna = "Eterna"
    case eternaBleachBypass = "Eterna Bleach Bypass"
    case acros = "Acros"
    case acrosYe = "Acros+Ye"
    case acrosR = "Acros+R"
    case acrosG = "Acros+G"
    case monochrome = "Monochrome"
    case monochromeYe = "Monochrome+Ye"
    case monochromeR = "Monochrome+R"
    case monochromeG = "Monochrome+G"
    case sepia = "Sepia"

    /// Camera code written to D192 (FilmKit `FilmSim`, vendor/enums.ts).
    public var code: Int {
        switch self {
        case .provia: FujiFilmSim.provia
        case .velvia: FujiFilmSim.velvia
        case .astia: FujiFilmSim.astia
        case .classicChrome: FujiFilmSim.classicChrome
        case .realaAce: FujiFilmSim.realaAce
        case .proNegHi: FujiFilmSim.proNegHi
        case .proNegStd: FujiFilmSim.proNegStd
        case .classicNeg: FujiFilmSim.classicNeg
        case .nostalgicNeg: FujiFilmSim.nostalgicNeg
        case .eterna: FujiFilmSim.eterna
        case .eternaBleachBypass: FujiFilmSim.eternaBleach
        case .acros: FujiFilmSim.acros
        case .acrosYe: FujiFilmSim.acrosYe
        case .acrosR: FujiFilmSim.acrosR
        case .acrosG: FujiFilmSim.acrosG
        case .monochrome: FujiFilmSim.monochrome
        case .monochromeYe: FujiFilmSim.monochromeYe
        case .monochromeR: FujiFilmSim.monochromeR
        case .monochromeG: FujiFilmSim.monochromeG
        case .sepia: FujiFilmSim.sepia
        }
    }

    public var isMonochrome: Bool { FujiFilmSim.monochromeCodes.contains(code) }

    public init?(code: Int) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }
}

public enum WhiteBalance: String, Codable, CaseIterable, Sendable {
    case auto = "Auto"
    case autoAmbience = "Auto Ambience"
    case daylight = "Daylight"
    case shade = "Shade"
    case fluorescent1 = "Fluorescent 1"
    case fluorescent2 = "Fluorescent 2"
    case fluorescent3 = "Fluorescent 3"
    case incandescent = "Incandescent"
    case kelvin = "Kelvin"

    /// Camera code written to D199 (FilmKit `WBMode`).
    public var code: Int {
        switch self {
        case .auto: FujiWB.auto
        case .autoAmbience: FujiWB.ambiencePriority
        case .daylight: FujiWB.daylight
        case .shade: FujiWB.shade
        case .fluorescent1: FujiWB.fluorescent1
        case .fluorescent2: FujiWB.fluorescent2
        case .fluorescent3: FujiWB.fluorescent3
        case .incandescent: FujiWB.incandescent
        case .kelvin: FujiWB.colorTemp
        }
    }

    public init?(code: Int) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }
}

public enum Grain: String, Codable, CaseIterable, Sendable {
    case off = "Off"
    case weakSmall = "Weak Small"
    case strongSmall = "Strong Small"
    case weakLarge = "Weak Large"
    case strongLarge = "Strong Large"

    /// FilmKit `GrainEffect` UI value (strength in the low byte, size in the high byte).
    public var effect: Int {
        switch self {
        case .off: FujiGrain.off
        case .weakSmall: FujiGrain.weakSmall
        case .strongSmall: FujiGrain.strongSmall
        case .weakLarge: FujiGrain.weakLarge
        case .strongLarge: FujiGrain.strongLarge
        }
    }

    public init?(effect: Int) {
        guard let match = Self.allCases.first(where: { $0.effect == effect }) else { return nil }
        self = match
    }
}

/// Off / Weak / Strong, used by Color Chrome and Color Chrome FX Blue.
public enum Effect: String, Codable, CaseIterable, Sendable {
    case off = "Off"
    case weak = "Weak"
    case strong = "Strong"

    /// `EFFECTS` in recipe.ts: 0 / 1 / 2 (the slot wire value is this + 1).
    public var level: Int {
        switch self {
        case .off: 0
        case .weak: 1
        case .strong: 2
        }
    }

    public init?(level: Int) {
        guard let match = Self.allCases.first(where: { $0.level == level }) else { return nil }
        self = match
    }
}

public enum DynamicRange: String, Codable, CaseIterable, Sendable {
    case dr100 = "DR100"
    case dr200 = "DR200"
    case dr400 = "DR400"

    /// `DYNAMIC_RANGES` in recipe.ts (FilmKit UI enum 1/2/3; the wire value is 100/200/400).
    public var level: Int {
        switch self {
        case .dr100: 1
        case .dr200: 2
        case .dr400: 3
        }
    }

    /// `DR_MIN_ISO` in recipe.ts: the camera refuses this DR below this ISO.
    public var minimumISO: Int {
        switch self {
        case .dr100: 125
        case .dr200: 250
        case .dr400: 500
        }
    }

    public init?(level: Int) {
        guard let match = Self.allCases.first(where: { $0.level == level }) else { return nil }
        self = match
    }
}

// MARK: - Recipe

/// One look. JSON-identical to the TypeScript `Recipe` the server produces.
public struct Recipe: Codable, Hashable, Sendable {
    public var name: String
    public var filmSim: FilmSimulation
    public var grain: Grain
    public var colorChrome: Effect
    public var colorChromeFxBlue: Effect
    public var whiteBalance: WhiteBalance
    /// Only used when `whiteBalance == .kelvin`; otherwise 0.
    public var kelvin: Int
    public var wbShiftR: Int
    public var wbShiftB: Int
    public var dynamicRange: DynamicRange
    /// -2…+4 in 0.5 steps.
    public var highlight: Double
    /// -2…+4 in 0.5 steps.
    public var shadow: Double
    /// -4…+4. Ignored for B&W film sims.
    public var color: Int
    public var sharpness: Int
    public var noiseReduction: Int
    public var clarity: Int
    /// What this look does, max 12 words (shown in the app, never written to the camera).
    public var why: String

    enum CodingKeys: String, CodingKey {
        case name
        case filmSim = "film_sim"
        case grain
        case colorChrome = "color_chrome"
        case colorChromeFxBlue = "color_chrome_fx_blue"
        case whiteBalance = "white_balance"
        case kelvin
        case wbShiftR = "wb_shift_r"
        case wbShiftB = "wb_shift_b"
        case dynamicRange = "dynamic_range"
        case highlight, shadow, color, sharpness
        case noiseReduction = "noise_reduction"
        case clarity, why
    }

    public init(
        name: String, filmSim: FilmSimulation, grain: Grain = .off, colorChrome: Effect = .off,
        colorChromeFxBlue: Effect = .off, whiteBalance: WhiteBalance = .auto, kelvin: Int = 0,
        wbShiftR: Int = 0, wbShiftB: Int = 0, dynamicRange: DynamicRange = .dr100, highlight: Double = 0,
        shadow: Double = 0, color: Int = 0, sharpness: Int = 0, noiseReduction: Int = 0, clarity: Int = 0,
        why: String = ""
    ) {
        self.name = name
        self.filmSim = filmSim
        self.grain = grain
        self.colorChrome = colorChrome
        self.colorChromeFxBlue = colorChromeFxBlue
        self.whiteBalance = whiteBalance
        self.kelvin = kelvin
        self.wbShiftR = wbShiftR
        self.wbShiftB = wbShiftB
        self.dynamicRange = dynamicRange
        self.highlight = highlight
        self.shadow = shadow
        self.color = color
        self.sharpness = sharpness
        self.noiseReduction = noiseReduction
        self.clarity = clarity
        self.why = why
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        filmSim = try c.decode(FilmSimulation.self, forKey: .filmSim)
        grain = try c.decode(Grain.self, forKey: .grain)
        colorChrome = try c.decode(Effect.self, forKey: .colorChrome)
        colorChromeFxBlue = try c.decode(Effect.self, forKey: .colorChromeFxBlue)
        whiteBalance = try c.decode(WhiteBalance.self, forKey: .whiteBalance)
        kelvin = try c.decode(Int.self, forKey: .kelvin)
        wbShiftR = try c.decode(Int.self, forKey: .wbShiftR)
        wbShiftB = try c.decode(Int.self, forKey: .wbShiftB)
        dynamicRange = try c.decode(DynamicRange.self, forKey: .dynamicRange)
        highlight = try c.decode(Double.self, forKey: .highlight)
        shadow = try c.decode(Double.self, forKey: .shadow)
        color = try c.decode(Int.self, forKey: .color)
        sharpness = try c.decode(Int.self, forKey: .sharpness)
        noiseReduction = try c.decode(Int.self, forKey: .noiseReduction)
        clarity = try c.decode(Int.self, forKey: .clarity)
        // Required in the TS type; tolerate its absence so a terse server reply still loads into the camera.
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
    }

    /// The name the camera will show: ASCII only, max 14 characters (recipe.ts `slotName`).
    public var slotName: String { Self.slotName(name) }

    /// Camera-safe slot name: NFKD, keep printable ASCII, trim, first 14 characters, else "AI Look".
    public static func slotName(_ name: String) -> String {
        let ascii = String(String.UnicodeScalarView(
            name.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E }
        ))
        let trimmed = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = String(trimmed.prefix(14))
        return cut.isEmpty ? "AI Look" : cut
    }
}

extension Recipe {
    /// Best-effort reverse mapping from what a slot holds (e.g. to show "what's in the camera now").
    /// Returns nil when the slot holds something our schema can't express (unknown film sim / WB, DR Auto…).
    public init?(name: String, values v: PresetValues) {
        guard let sim = FilmSimulation(code: v.filmSimulation),
              let wb = WhiteBalance(code: v.whiteBalance),
              let grain = Grain(effect: v.grainEffect),
              let cc = Effect(level: v.colorChrome),
              let ccb = Effect(level: v.colorChromeFxBlue),
              let dr = DynamicRange(level: v.dynamicRange)
        else { return nil }
        self.init(
            name: name, filmSim: sim, grain: grain, colorChrome: cc, colorChromeFxBlue: ccb, whiteBalance: wb,
            kelvin: wb == .kelvin ? v.wbColorTemp : 0, wbShiftR: v.wbShiftR, wbShiftB: v.wbShiftB, dynamicRange: dr,
            highlight: v.highlightTone, shadow: v.shadowTone, color: Int(v.color.rounded()),
            sharpness: Int(v.sharpness.rounded()), noiseReduction: v.noiseReduction, clarity: Int(v.clarity.rounded()),
            why: ""
        )
    }
}

// MARK: - Server plan shapes (lib/generate.ts)

/// Dial settings that go with a look (lib/exposure.ts `Exposure`). Strings are dial positions ("A", "f/2.8", "1/250", "+⅔").
public struct Exposure: Codable, Hashable, Sendable {
    public var aperture: String
    public var shutter: String
    public var iso: String
    public var expComp: String
    public var nd: Bool

    enum CodingKeys: String, CodingKey {
        case aperture, shutter, iso
        case expComp = "exp_comp"
        case nd
    }

    public init(aperture: String, shutter: String, iso: String, expComp: String, nd: Bool) {
        self.aperture = aperture
        self.shutter = shutter
        self.iso = iso
        self.expComp = expComp
        self.nd = nd
    }
}

/// A look in a day plan: the Recipe fields plus when to use it (generate.ts `DayLook = Recipe & {...}`, flat JSON).
public struct DayLook: Codable, Hashable, Sendable {
    public var recipe: Recipe
    public var when: String
    public var exposure: Exposure
    public var tip: String

    enum ExtraKeys: String, CodingKey { case when, exposure, tip }

    public init(recipe: Recipe, when: String, exposure: Exposure, tip: String) {
        self.recipe = recipe
        self.when = when
        self.exposure = exposure
        self.tip = tip
    }

    public init(from decoder: any Decoder) throws {
        recipe = try Recipe(from: decoder)
        let c = try decoder.container(keyedBy: ExtraKeys.self)
        when = try c.decode(String.self, forKey: .when)
        exposure = try c.decode(Exposure.self, forKey: .exposure)
        tip = try c.decode(String.self, forKey: .tip)
    }

    public func encode(to encoder: any Encoder) throws {
        try recipe.encode(to: encoder)
        var c = encoder.container(keyedBy: ExtraKeys.self)
        try c.encode(when, forKey: .when)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(tip, forKey: .tip)
    }
}

/// "Beach day by the sea" → seven looks for the whole day (generate.ts `DayPlan`).
public struct DayPlan: Codable, Hashable, Sendable {
    public var summary: String
    public var looks: [DayLook]

    /// The looks to hand to `CameraLink.load(looks:)`, C1 first.
    public var recipes: [Recipe] { looks.map(\.recipe) }

    public init(summary: String, looks: [DayLook]) {
        self.summary = summary
        self.looks = looks
    }
}

/// One frame + what the user said → N looks + one set of dials (generate.ts `Plan`).
public struct MomentPlan: Codable, Hashable, Sendable {
    public var scene: String
    public var looks: [Recipe]
    public var exposure: Exposure
    public var focusTip: String
    public var why: String

    enum CodingKeys: String, CodingKey {
        case scene, looks, exposure
        case focusTip = "focus_tip"
        case why
    }

    public init(scene: String, looks: [Recipe], exposure: Exposure, focusTip: String, why: String) {
        self.scene = scene
        self.looks = looks
        self.exposure = exposure
        self.focusTip = focusTip
        self.why = why
    }
}
