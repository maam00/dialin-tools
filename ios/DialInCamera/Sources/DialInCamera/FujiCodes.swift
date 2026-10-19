// Fujifilm property codes and value tables for the C1–C7 slot block.
//
// Ported from FilmKit (https://github.com/eggricesoy/filmkit, MIT, commit 9e3bbcf; vendored in
// lib/fuji/vendor/enums.ts and constants.ts), with the corrections in docs/FUJIFILM-PROTOCOL.md §2.3-2.4
// (D191 = D-Range Priority, D1A3 = Lens Modulation Optimiser, D1A5 is live image size and not slot data).
// FilmKit: Copyright (c) 2026 eggricesoy, MIT License.

/// Slot-block property codes (docs/FUJIFILM-PROTOCOL.md §2.3).
public enum FujiProp {
    /// Slot edit cursor, u16 1–7. Not the slot the camera shoots with.
    public static let slot: UInt16 = 0xD18C
    /// Slot name, PTP string.
    public static let name: UInt16 = 0xD18D
    public static let imageSize: UInt16 = 0xD18E
    public static let imageQuality: UInt16 = 0xD18F
    /// u16 100/200/400 (0 = Auto).
    public static let dynamicRange: UInt16 = 0xD190
    /// u16 0 Off, 1 Weak, 2 Strong, 0x8000 Auto. When non-zero the camera rejects D190/D19D/D19E.
    public static let dRangePriority: UInt16 = 0xD191
    public static let filmSimulation: UInt16 = 0xD192
    public static let monoWarmCool: UInt16 = 0xD193
    public static let monoMagentaGreen: UInt16 = 0xD194
    public static let grain: UInt16 = 0xD195
    public static let colorChrome: UInt16 = 0xD196
    public static let colorChromeFxBlue: UInt16 = 0xD197
    public static let smoothSkin: UInt16 = 0xD198
    public static let whiteBalance: UInt16 = 0xD199
    public static let wbShiftR: UInt16 = 0xD19A
    public static let wbShiftB: UInt16 = 0xD19B
    public static let colorTemperature: UInt16 = 0xD19C
    public static let highlight: UInt16 = 0xD19D
    public static let shadow: UInt16 = 0xD19E
    public static let color: UInt16 = 0xD19F
    public static let sharpness: UInt16 = 0xD1A0
    public static let highISONR: UInt16 = 0xD1A1
    public static let clarity: UInt16 = 0xD1A2
    public static let lensModulationOptimiser: UInt16 = 0xD1A3
    public static let colorSpace: UInt16 = 0xD1A4
    /// LIVE image size (C0). Never read or written as part of a slot.
    public static let liveImageSize: UInt16 = 0xD1A5

    /// First and last code of the slot block as read by `readSlot` (D1A5 excluded on purpose).
    public static let slotBlock: ClosedRange<UInt16> = 0xD18E...0xD1A4

    /// PC connection mode: 5 tether, 6 RAW CONV./BACKUP RESTORE, 8 webcam (libfuji fujiptp.h:296-308).
    public static let usbMode: UInt16 = 0xD16E
    /// `<Model>_<fw>` identity strings desktop RAW conversion keys on.
    public static let tetherCondition: UInt16 = 0xD186
    public static let compatibilityCode: UInt16 = 0xD187

    /// Never written by our writer (§4.4, §13 #1/#3).
    public static let neverWritten: Set<UInt16> = [imageSize, imageQuality, lensModulationOptimiser, colorSpace, liveImageSize]
    /// Colour-only props skipped for monochrome film sims (camera.ts MONO_SKIP).
    public static let colorOnly: Set<UInt16> = [colorChrome, colorChromeFxBlue, wbShiftR, wbShiftB, color]

    /// Human label for logs.
    public static func label(_ id: UInt16) -> String {
        let names: [UInt16: String] = [
            slot: "slot", name: "name", imageSize: "image size", imageQuality: "image quality",
            dynamicRange: "DR", dRangePriority: "D-Range Priority", filmSimulation: "film sim",
            monoWarmCool: "mono WC", monoMagentaGreen: "mono MG", grain: "grain", colorChrome: "color chrome",
            colorChromeFxBlue: "CC FX blue", smoothSkin: "smooth skin", whiteBalance: "WB", wbShiftR: "WB shift R",
            wbShiftB: "WB shift B", colorTemperature: "Kelvin", highlight: "highlight", shadow: "shadow",
            color: "color", sharpness: "sharpness", highISONR: "NR", clarity: "clarity",
            lensModulationOptimiser: "LMO", colorSpace: "color space", liveImageSize: "live image size",
        ]
        return names[id] ?? hex16(id)
    }
}

/// FilmKit `FilmSim` (vendor/enums.ts).
public enum FujiFilmSim {
    public static let provia = 0x01
    public static let velvia = 0x02
    public static let astia = 0x03
    public static let proNegHi = 0x04
    public static let proNegStd = 0x05
    public static let monochrome = 0x06
    public static let monochromeYe = 0x07
    public static let monochromeR = 0x08
    public static let monochromeG = 0x09
    public static let sepia = 0x0A
    public static let classicChrome = 0x0B
    public static let acros = 0x0C
    public static let acrosYe = 0x0D
    public static let acrosR = 0x0E
    public static let acrosG = 0x0F
    public static let eterna = 0x10
    public static let classicNeg = 0x11
    public static let eternaBleach = 0x12
    public static let nostalgicNeg = 0x13
    public static let realaAce = 0x14

    /// FilmKit `MONOCHROME_SIMS`.
    public static let monochromeCodes: Set<Int> = [
        monochrome, monochromeYe, monochromeR, monochromeG, sepia, acros, acrosYe, acrosR, acrosG,
    ]
}

/// FilmKit `WBMode`.
public enum FujiWB {
    public static let asShot = 0x0000
    public static let auto = 0x0002
    public static let daylight = 0x0004
    public static let incandescent = 0x0006
    public static let underwater = 0x0008
    public static let fluorescent1 = 0x8001
    public static let fluorescent2 = 0x8002
    public static let fluorescent3 = 0x8003
    public static let shade = 0x8006
    public static let colorTemp = 0x8007
    public static let ambiencePriority = 0x8021
}

/// FilmKit `GrainEffect` (UI value: strength in the low byte, size in the high byte).
public enum FujiGrain {
    public static let off = 0x0000
    public static let weakSmall = 0x0002
    public static let strongSmall = 0x0003
    public static let weakLarge = 0x0102
    public static let strongLarge = 0x0103
}

/// High ISO NR: Fuji's non-linear encoding (FilmKit preset-translate.ts NR_ENCODE / NR_DECODE; §4.1).
public enum FujiNR {
    public static let encode: [Int: Int] = [
        -4: 0x8000, -3: 0x7000, -2: 0x4000, -1: 0x3000, 0: 0x2000, 1: 0x1000, 2: 0x0000, 3: 0x6000, 4: 0x5000,
    ]
    public static let decode: [Int: Int] = Dictionary(uniqueKeysWithValues: encode.map { ($1, $0) })
}

func hex16(_ v: UInt16) -> String { "0x" + String(v, radix: 16) }
