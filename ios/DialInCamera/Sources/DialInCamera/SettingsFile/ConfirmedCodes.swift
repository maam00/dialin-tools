// Which look values have CONFIRMED codes in the camera's settings file (the file the Bluetooth writer patches): a value
// is confirmed only when a real file from the body showed the byte it is stored as. The mirror of lib/cameras.ts
// `ConfirmedCodes`, the single source of truth with the evidence for every code: the block between the <codes:…>
// markers is rendered from it (`npm run codes -- render`), and `npm run test:plan` fails if the two drift.
//
// LookSlotMap (SettingsLookPatch.swift) takes its verified codes from here, so the writer's refusals, the app's plain
// refusal and the backend planner always agree. Anything not listed is only inferred from the X-T5 and is refused
// before a write unless the developer switch allows it. `dialin-cam map-codes` measures the missing ones over USB;
// `npm run codes -- merge <codes.json> --write` adds them here, in lib/cameras.ts and in ble/maps/x100vi-fw110.json.
import Foundation

public struct ConfirmedCodes: Sendable, Equatable {
    /// A white balance's byte at slot − 0x0F and the entry of the per-mode WB-shift table its shift is stored in.
    public struct WB: Sendable, Equatable, Hashable {
        public var code: Int
        public var shiftEntry: Int
        public init(code: Int, shiftEntry: Int) {
            self.code = code
            self.shiftEntry = shiftEntry
        }
    }

    public var model: String
    public var layout: String
    public var firmware: [String]
    /// FilmSimulation.rawValue → its byte at slot + 0x64.
    public var filmSims: [String: Int]
    /// WhiteBalance.rawValue → its byte and WB-shift entry.
    public var whiteBalances: [String: WB]
    /// Color −4…+4 → its byte at slot + 0x77.
    public var colors: [Int: Int]
    /// High ISO NR −4…+4 → its byte at slot + 0x2B.
    public var noiseReductions: [Int: Int]

    public init(model: String, layout: String, firmware: [String], filmSims: [String: Int], whiteBalances: [String: WB],
                colors: [Int: Int], noiseReductions: [Int: Int]) {
        self.model = model
        self.layout = layout
        self.firmware = firmware
        self.filmSims = filmSims
        self.whiteBalances = whiteBalances
        self.colors = colors
        self.noiseReductions = noiseReductions
    }

    public func isConfirmed(_ sim: FilmSimulation) -> Bool { filmSims[sim.rawValue] != nil }
    public func isConfirmed(_ wb: WhiteBalance) -> Bool { whiteBalances[wb.rawValue] != nil }

    /// A copy that keeps only some of the confirmed values (nil = keep all of that kind). Tests use it to pin "what 10/9
    /// proved", so they still hold after `npm run codes -- merge` confirms more.
    public func keeping(filmSims: Set<FilmSimulation>? = nil, whiteBalances: Set<WhiteBalance>? = nil, colors: Set<Int>? = nil,
                        noiseReductions: Set<Int>? = nil) -> ConfirmedCodes {
        var c = self
        if let filmSims { c.filmSims = c.filmSims.filter { k, _ in filmSims.contains { $0.rawValue == k } } }
        if let whiteBalances { c.whiteBalances = c.whiteBalances.filter { k, _ in whiteBalances.contains { $0.rawValue == k } } }
        if let colors { c.colors = c.colors.filter { colors.contains($0.key) } }
        if let noiseReductions { c.noiseReductions = c.noiseReductions.filter { noiseReductions.contains($0.key) } }
        return c
    }

    /// The film sims with confirmed codes, in the Recipe enum's order.
    public var confirmedFilmSims: [FilmSimulation] { FilmSimulation.allCases.filter(isConfirmed) }

    /// What `recipe` needs that has no confirmed code, in the writer's order (film sim, white balance, color, NR).
    /// Empty = every byte the writer sets for it is confirmed. B&W looks skip color (the writer leaves it alone).
    /// Grain, color chrome, DR, tones, sharpness, clarity, Kelvin and the shift are linear encodings confirmed over
    /// their whole range (lib/cameras.ts `wholeRange`).
    public func unverified(in r: Recipe) -> [UnverifiedValue] {
        var out: [UnverifiedValue] = []
        if !isConfirmed(r.filmSim) { out.append(.filmSimulation(r.filmSim)) }
        if !isConfirmed(r.whiteBalance) { out.append(.whiteBalance(r.whiteBalance)) }
        if !r.filmSim.isMonochrome && colors[r.color] == nil { out.append(.color(r.color)) }
        if noiseReductions[r.noiseReduction] == nil { out.append(.noiseReduction(r.noiseReduction)) }
        return out
    }
}

/// One value a look needs whose camera code isn't confirmed yet, with the app's plain refusal.
public enum UnverifiedValue: Hashable, Sendable {
    case filmSimulation(FilmSimulation)
    case whiteBalance(WhiteBalance)
    case color(Int)
    case noiseReduction(Int)

    /// What kind of setting it is, in the refusal's words.
    public var kind: String {
        switch self {
        case .filmSimulation: "a film simulation"
        case .whiteBalance: "a white balance"
        case .color: "a color setting"
        case .noiseReduction: "a noise reduction setting"
        }
    }

    /// "This look uses a film simulation we haven't verified on your camera yet."
    public var sentence: String { Self.sentence([self]) }

    /// One plain sentence for everything a look (or several looks) uses that isn't verified, each kind once:
    /// "This look uses a film simulation we haven't verified on your camera yet.",
    /// "These looks use a film simulation and a white balance we haven't verified on your camera yet."
    public static func sentence(_ values: [UnverifiedValue], subject: String = "This look", plural: Bool = false) -> String {
        var kinds: [String] = []
        for v in values where !kinds.contains(v.kind) { kinds.append(v.kind) }
        let what = kinds.count <= 1 ? (kinds.first ?? "a setting")
            : kinds.dropLast().joined(separator: ", ") + " and " + (kinds.last ?? "")
        return "\(subject) \(plural ? "use" : "uses") \(what) we haven't verified on your camera yet."
    }

    /// The value itself, for a detail line: "Astia", "Shade white balance", "color +4", "noise reduction −2".
    public var detail: String {
        func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : v < 0 ? "\u{2212}\(-v)" : "0" }
        switch self {
        case .filmSimulation(let s): return s.rawValue
        case .whiteBalance(let w): return "\(w.rawValue) white balance"
        case .color(let c): return "color \(signed(c))"
        case .noiseReduction(let n): return "noise reduction \(signed(n))"
        }
    }
}

extension FujiSettingsFile {
    /// The app's plain refusal for `recipe`, nil when it can be written without the developer switch:
    /// "This look uses a film simulation we haven't verified on your camera yet."
    public static func unverifiedReason(for recipe: Recipe, codes: ConfirmedCodes = .x100vi) -> String? {
        let values = codes.unverified(in: recipe)
        return values.isEmpty ? nil : UnverifiedValue.sentence(values)
    }
}

// <codes:X100VI> rendered from lib/cameras.ts X100VI_CONFIRMED by `npm run codes -- render`. Don't edit by hand.
extension ConfirmedCodes {
    /// X100VI fw 1.10 settings file (70,524 bytes). The evidence for every code is in lib/cameras.ts.
    public static let x100vi = ConfirmedCodes(
        model: "X100VI",
        layout: "X100VI fw 1.10 settings file (70,524 bytes)",
        firmware: ["1.10"],
        filmSims: [
            "Velvia": 4,
            "Classic Chrome": 15,
            "Reala Ace": 18,
            "Pro Neg Std": 13,
            "Nostalgic Neg": 17,
            "Acros+Ye": 24,
            "Acros+R": 23,
        ],
        whiteBalances: [
            "Auto": WB(code: 0, shiftEntry: 0),
            "Daylight": WB(code: 3, shiftEntry: 7),
            "Kelvin": WB(code: 10, shiftEntry: 6),
        ],
        colors: [-1: 8, 0: 0, 1: 6, 2: 5, 3: 4],
        noiseReductions: [-4: 0]
    )
}
// </codes:X100VI>
