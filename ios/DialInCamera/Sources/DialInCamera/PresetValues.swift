// FilmKit's `PresetUIValues`: the middle step between a `Recipe` and the slot's wire bytes.
// Ported from lib/fuji/vendor/preset-translate.ts (FilmKit, MIT, Copyright (c) 2026 eggricesoy)
// and lib/fuji/recipe.ts (`recipeToPresetValues`, `presetValuesToText`).
import Foundation

public struct PresetValues: Equatable, Sendable {
    public var filmSimulation = 0
    /// UI enum 1/2/3 (DR100/200/400); 0 = unknown/Auto.
    public var dynamicRange = 0
    /// FujiGrain UI value.
    public var grainEffect = 0
    /// 0/1/2.
    public var smoothSkin = 0
    public var colorChrome = 0
    public var colorChromeFxBlue = 0
    public var whiteBalance = 0
    public var wbShiftR = 0
    public var wbShiftB = 0
    public var wbColorTemp = 6500
    public var highlightTone = 0.0
    public var shadowTone = 0.0
    public var color = 0.0
    public var sharpness = 0.0
    /// -4…+4.
    public var noiseReduction = 0
    public var clarity = 0.0
    public var exposure = 0.0
    public var dRangePriority = 0
    public var monoWC = 0.0
    public var monoMG = 0.0

    public init() {}

    public var isMonochrome: Bool { FujiFilmSim.monochromeCodes.contains(filmSimulation) }

    /// recipe.ts `recipeToPresetValues`.
    public init(recipe r: Recipe) {
        let mono = r.filmSim.isMonochrome
        filmSimulation = r.filmSim.code
        dynamicRange = r.dynamicRange.level
        grainEffect = r.grain.effect
        smoothSkin = 0
        colorChrome = r.colorChrome.level
        colorChromeFxBlue = r.colorChromeFxBlue.level
        whiteBalance = r.whiteBalance.code
        wbShiftR = r.wbShiftR
        wbShiftB = r.wbShiftB
        wbColorTemp = r.whiteBalance == .kelvin ? (r.kelvin != 0 ? r.kelvin : 5500) : 0
        highlightTone = r.highlight
        shadowTone = r.shadow
        color = mono ? 0 : Double(r.color)
        sharpness = Double(r.sharpness)
        noiseReduction = r.noiseReduction
        clarity = Double(r.clarity)
        exposure = 0
        dRangePriority = 0
        monoWC = 0
        monoMG = 0
    }

    /// preset-translate.ts `translatePresetToUI`: what a slot's props mean.
    public init(props settings: [RawProp]) {
        self.init()
        func prop(_ id: UInt16) -> Int? { settings.first { $0.id == id }?.intValue }
        func decodeTone(_ raw: Int) -> Double { raw == 0x8000 || raw == -32768 ? 0 : Double(raw) / 10 }
        let drMap = [100: 1, 200: 2, 400: 3]
        let grainMap = [1: FujiGrain.off, 2: FujiGrain.weakSmall, 3: FujiGrain.strongSmall, 4: FujiGrain.weakLarge, 5: FujiGrain.strongLarge]

        if let v = prop(FujiProp.filmSimulation) { filmSimulation = v }
        if let v = prop(FujiProp.dynamicRange) { dynamicRange = drMap[v] ?? 0 }
        if let v = prop(FujiProp.grain) { grainEffect = grainMap[v] ?? 0 }
        if let v = prop(FujiProp.smoothSkin) { smoothSkin = max(0, v - 1) }
        if let v = prop(FujiProp.colorChrome) { colorChrome = max(0, v - 1) }
        if let v = prop(FujiProp.colorChromeFxBlue) { colorChromeFxBlue = max(0, v - 1) }
        if isMonochrome {
            if let v = prop(FujiProp.monoWarmCool) { monoWC = Double(v) / 10 }
            if let v = prop(FujiProp.monoMagentaGreen) { monoMG = Double(v) / 10 }
        }
        if let v = prop(FujiProp.whiteBalance) { whiteBalance = v & 0xFFFF }
        if let v = prop(FujiProp.wbShiftR) { wbShiftR = v }
        if let v = prop(FujiProp.wbShiftB) { wbShiftB = v }
        if let v = prop(FujiProp.colorTemperature), v > 0 { wbColorTemp = v }
        if let v = prop(FujiProp.highlight) { highlightTone = decodeTone(v) }
        if let v = prop(FujiProp.shadow) { shadowTone = decodeTone(v) }
        if let v = prop(FujiProp.color) { color = decodeTone(v) }
        if let v = prop(FujiProp.sharpness) { sharpness = decodeTone(v) }
        if let v = prop(FujiProp.highISONR) { noiseReduction = FujiNR.decode[v & 0xFFFF] ?? 0 }
        if let v = prop(FujiProp.clarity) { clarity = decodeTone(v) }
    }

    /// recipe.ts `presetValuesToText`, for printing what's in a slot.
    public var summary: String {
        let simNames = Dictionary(uniqueKeysWithValues: FilmSimulation.allCases.map { ($0.code, $0.rawValue) })
        let wbNames = Dictionary(uniqueKeysWithValues: WhiteBalance.allCases.map { ($0.code, $0.rawValue) })
        let grainNames = Dictionary(uniqueKeysWithValues: Grain.allCases.map { ($0.effect, $0.rawValue) })
        let effectNames = Dictionary(uniqueKeysWithValues: Effect.allCases.map { ($0.level, $0.rawValue) })
        let drNames = Dictionary(uniqueKeysWithValues: DynamicRange.allCases.map { ($0.level, $0.rawValue) })
        let wb = wbNames[whiteBalance] ?? "WB 0x" + String(whiteBalance, radix: 16)
        let kelvin = whiteBalance == FujiWB.colorTemp ? " \(wbColorTemp)K" : ""
        return [
            simNames[filmSimulation] ?? "sim \(filmSimulation)",
            drNames[dynamicRange] ?? "DR?",
            "grain \(grainNames[grainEffect] ?? String(grainEffect))",
            "CC \(effectNames[colorChrome] ?? "undefined")/\(effectNames[colorChromeFxBlue] ?? "undefined")",
            "\(wb)\(kelvin) R\(wbShiftR) B\(wbShiftB)",
            "H\(jsNumber(highlightTone)) S\(jsNumber(shadowTone)) C\(jsNumber(color)) Sh\(jsNumber(sharpness)) NR\(noiseReduction) Cl\(jsNumber(clarity))",
        ].joined(separator: " · ")
    }
}

/// Formats a number the way JavaScript's String(n) does for the values we print (2 → "2", -1.5 → "-1.5").
func jsNumber(_ x: Double) -> String {
    if x == x.rounded(), abs(x) < 1e15 { return String(Int(x)) }
    return String(x)
}

/// JavaScript Math.round: halves round toward +∞.
func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }
