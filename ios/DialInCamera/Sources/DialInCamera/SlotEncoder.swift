// Recipe → the exact SetDevicePropValue writes for one C-slot, in the order the camera accepts.
// Byte-for-byte port of lib/fuji/camera.ts `writeSlot` (order + gating) on top of FilmKit's
// `translateUIToPresetProps` (lib/fuji/vendor/preset-translate.ts, MIT, Copyright (c) 2026 eggricesoy).
// Golden vectors: Tests/DialInCameraTests/Fixtures/slot-write-vectors.json.
import Foundation

/// One property write: the PTP property code and its little-endian payload.
public struct PropWrite: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var propID: UInt16
    public var bytes: Data

    public init(propID: UInt16, bytes: Data) {
        self.propID = propID
        self.bytes = bytes
    }

    public var description: String { "\(hex16(propID))=\(bytes.hexString)" }
}

public enum SlotEncoder {
    /// camera.ts `WRITE_ORDER` (docs/FUJIFILM-PROTOCOL.md §2.5). Never: D18E/D18F, D1A3/D1A4, D1A5.
    public static let writeOrder: [UInt16] = [
        FujiProp.filmSimulation,
        FujiProp.dRangePriority, // forced Off so DR / tones apply
        FujiProp.dynamicRange,
        FujiProp.grain, FujiProp.colorChrome, FujiProp.colorChromeFxBlue, FujiProp.smoothSkin,
        FujiProp.whiteBalance, FujiProp.colorTemperature, // Kelvin only exists when WB = Kelvin
        FujiProp.wbShiftR, FujiProp.wbShiftB,
        FujiProp.highlight, FujiProp.shadow, FujiProp.color, FujiProp.sharpness, FujiProp.highISONR, FujiProp.clarity,
    ]

    /// preset-translate.ts `UNKNOWN_DEFAULTS`: used only when neither a computed value nor a base value exists.
    static let unknownDefaults: [UInt16: Int] = [
        FujiProp.imageSize: 7, FujiProp.imageQuality: 4, FujiProp.dRangePriority: 0, FujiProp.highISONR: 0x4000,
        FujiProp.lensModulationOptimiser: 1, FujiProp.colorSpace: 1, FujiProp.liveImageSize: 7,
    ]

    /// preset-translate.ts `translateUIToPresetProps`: the whole encoded block in FilmKit's order, including
    /// props our writer never sends. Conditional props (D193/D194, D19C, D19F) are omitted when not applicable.
    /// Unknown fields take the base slot's bytes, then FilmKit's observed defaults.
    public static func presetProps(_ v: PresetValues, base: [RawProp] = []) -> [PropWrite] {
        var baseMap: [UInt16: Data] = [:]
        for p in base { baseMap[p.id] = p.bytes } // later entries win, like `new Map(...)`
        func make(_ id: UInt16, _ computed: Data? = nil) -> PropWrite {
            PropWrite(propID: id, bytes: computed ?? baseMap[id] ?? PTPPack.u16(unknownDefaults[id] ?? 0))
        }
        let drToPreset = [1: 100, 2: 200, 3: 400]
        let grainToPreset = [
            FujiGrain.off: 1, FujiGrain.weakSmall: 2, FujiGrain.strongSmall: 3, FujiGrain.weakLarge: 4, FujiGrain.strongLarge: 5,
        ]
        let mono = v.isMonochrome
        var out: [PropWrite] = []
        out.append(make(FujiProp.imageSize))
        out.append(make(FujiProp.imageQuality))
        out.append(make(FujiProp.dynamicRange, PTPPack.u16(drToPreset[v.dynamicRange] ?? 100)))
        out.append(make(FujiProp.dRangePriority))
        out.append(make(FujiProp.filmSimulation, PTPPack.u16(v.filmSimulation != 0 ? v.filmSimulation : 1)))
        if mono && v.monoWC != 0 { out.append(make(FujiProp.monoWarmCool, PTPPack.i16(jsRound(v.monoWC * 10)))) }
        if mono && v.monoMG != 0 { out.append(make(FujiProp.monoMagentaGreen, PTPPack.i16(jsRound(v.monoMG * 10)))) }
        out.append(make(FujiProp.grain, PTPPack.u16(grainToPreset[v.grainEffect] ?? 1)))
        out.append(make(FujiProp.colorChrome, PTPPack.u16(v.colorChrome + 1)))
        out.append(make(FujiProp.colorChromeFxBlue, PTPPack.u16(v.colorChromeFxBlue + 1)))
        out.append(make(FujiProp.smoothSkin, PTPPack.u16(v.smoothSkin + 1)))
        out.append(make(FujiProp.whiteBalance, PTPPack.u16(v.whiteBalance)))
        if v.whiteBalance == FujiWB.colorTemp && v.wbColorTemp > 0 {
            out.append(make(FujiProp.colorTemperature, PTPPack.u16(v.wbColorTemp)))
        }
        out.append(make(FujiProp.wbShiftR, PTPPack.i16(v.wbShiftR)))
        out.append(make(FujiProp.wbShiftB, PTPPack.i16(v.wbShiftB)))
        out.append(make(FujiProp.highlight, PTPPack.i16(jsRound(v.highlightTone * 10))))
        out.append(make(FujiProp.shadow, PTPPack.i16(jsRound(v.shadowTone * 10))))
        if !mono { out.append(make(FujiProp.color, PTPPack.i16(jsRound(v.color * 10)))) }
        out.append(make(FujiProp.sharpness, PTPPack.i16(jsRound(v.sharpness * 10))))
        if let nr = FujiNR.encode[v.noiseReduction] {
            out.append(make(FujiProp.highISONR, PTPPack.u16(nr)))
        } else {
            out.append(make(FujiProp.highISONR)) // off-table value: keep the slot's own bytes
        }
        out.append(make(FujiProp.clarity, PTPPack.i16(jsRound(v.clarity * 10))))
        out.append(make(FujiProp.lensModulationOptimiser))
        out.append(make(FujiProp.colorSpace))
        out.append(make(FujiProp.liveImageSize))
        return out
    }

    /// The slot props to write, in camera order (camera.ts `writeSlot`): D-Range Priority forced to 0, colour-only
    /// props dropped for monochrome sims, D18E/D18F/D1A3/D1A4/D1A5 never included.
    public static func writes(for values: PresetValues, base: [RawProp] = []) -> [PropWrite] {
        var encoded: [UInt16: Data] = [:]
        for p in presetProps(values, base: base) { encoded[p.propID] = p.bytes }
        encoded[FujiProp.dRangePriority] = PTPPack.u16(0)
        let mono = values.isMonochrome
        return writeOrder.compactMap { id in
            guard let bytes = encoded[id], !(mono && FujiProp.colorOnly.contains(id)) else { return nil }
            return PropWrite(propID: id, bytes: bytes)
        }
    }

    public static func writes(for recipe: Recipe, base: [RawProp] = []) -> [PropWrite] {
        writes(for: PresetValues(recipe: recipe), base: base)
    }

    /// Every SetDevicePropValue `FujiCamera.writeSlot` sends on a clean write, in order: D18C (select), D18D (name),
    /// then the slot props. This is exactly what the golden vectors record. `name` is written as given; use
    /// `recipe.slotName` for the camera-safe form.
    public static func plan(slot: Int, name: String, values: PresetValues, base: [RawProp] = []) -> [PropWrite] {
        [PropWrite(propID: FujiProp.slot, bytes: PTPPack.u16(slot)), PropWrite(propID: FujiProp.name, bytes: PTPPack.string(name))]
            + writes(for: values, base: base)
    }

    public static func plan(slot: Int, recipe: Recipe, base: [RawProp] = []) -> [PropWrite] {
        plan(slot: slot, name: recipe.slotName, values: PresetValues(recipe: recipe), base: base)
    }
}
