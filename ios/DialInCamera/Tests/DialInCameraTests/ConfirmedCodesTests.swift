// ConfirmedCodes (the mirror of lib/cameras.ts, rendered by `npm run codes`) against the writer that uses it
// (LookSlotMap), the app's plain refusal, and a real fw 1.10 settings file when present (read in place, never copied).
import Foundation
import Testing
@testable import DialInCamera

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let realSettings = repoRoot.appendingPathComponent(".dialin/test-fixtures/settings.dat")

/// What the 10/9 USB session proved (a subset of .x100vi forever; more may be merged in later).
let oct9Codes = ConfirmedCodes.x100vi.keeping(
    filmSims: [.velvia, .classicChrome, .realaAce, .proNegStd, .nostalgicNeg, .acrosYe, .acrosR],
    whiteBalances: [.auto, .daylight, .kelvin], colors: [-1, 0, 1, 2, 3], noiseReductions: [-4])

@Suite("Confirmed settings-file codes")
struct ConfirmedCodesTests {
    let codes = ConfirmedCodes.x100vi

    /// A look built only from confirmed values; each test changes one field.
    var base: Recipe {
        Recipe(name: "Probe", filmSim: .realaAce, grain: .off, whiteBalance: .auto, dynamicRange: .dr100, color: 0,
               noiseReduction: -4, clarity: 0)
    }

    @Test("The seven sims written and read back on 10/9 are confirmed, with the bytes that file shows")
    func list() {
        #expect(Set(oct9Codes.confirmedFilmSims) == [.velvia, .classicChrome, .realaAce, .proNegStd, .nostalgicNeg, .acrosYe, .acrosR])
        #expect(oct9Codes.filmSims == ["Reala Ace": 18, "Pro Neg Std": 13, "Velvia": 4, "Classic Chrome": 15, "Nostalgic Neg": 17,
                                       "Acros+R": 23, "Acros+Ye": 24])
        #expect(oct9Codes.whiteBalances == ["Auto": .init(code: 0, shiftEntry: 0), "Daylight": .init(code: 3, shiftEntry: 7),
                                            "Kelvin": .init(code: 10, shiftEntry: 6)])
        #expect(oct9Codes.colors == [-1: 8, 0: 0, 1: 6, 2: 5, 3: 4] && oct9Codes.noiseReductions == [-4: 0])
        for (v, raw) in codes.noiseReductions { #expect(raw == v + 4, "the writer encodes NR as raw = value + 4") }
    }

    @Test("ConfirmedCodes and the writer's slot map agree value by value")
    func agreesWithLookSlotMap() throws {
        let sim = try #require(LookSlotMap.field("film_sim"))
        for s in FilmSimulation.allCases {
            let code = try #require(LookSlotMap.filmSimCodes[s])
            #expect(LookSlotMap.isVerified(sim, .int(code), wb: 2) == codes.isConfirmed(s), "\(s)")
            if let raw = codes.filmSims[s.rawValue] { #expect(try sim.encode(.int(code)) == [UInt8(raw)], "\(s)") }
        }
        let wbField = try #require(LookSlotMap.field("white_balance"))
        let shift = try #require(LookSlotMap.field("wb_shift_r"))
        for w in WhiteBalance.allCases {
            let code = try #require(LookSlotMap.wbCodes[w])
            let verified = LookSlotMap.isVerified(wbField, .int(code), wb: code) && LookSlotMap.isVerified(shift, .int(0), wb: code)
            #expect(verified == codes.isConfirmed(w), "\(w)")
            if let c = codes.whiteBalances[w.rawValue] {
                #expect(try wbField.encode(.int(code)) == [UInt8(c.code)], "\(w)")
                #expect(shift.offset(anchor: 0, wb: code) == -0x0D + 4 * c.shiftEntry, "\(w) shift entry")
            }
        }
        let color = try #require(LookSlotMap.field("color"))
        let nr = try #require(LookSlotMap.field("nr"))
        for v in -4...4 {
            #expect(LookSlotMap.isVerified(color, .float(Double(v)), wb: 2) == (codes.colors[v] != nil), "color \(v)")
            if let raw = codes.colors[v] { #expect(try color.encode(.float(Double(v))) == [UInt8(raw)]) }
            #expect(LookSlotMap.isVerified(nr, .int(v), wb: 2) == (codes.noiseReductions[v] != nil), "nr \(v)")
        }
    }

    @Test("unverified(in:) is empty exactly when the patcher writes the look without allowInferred")
    func agreesWithPatcher() throws {
        let file = try FujiSettingsFile(FakeFujiBLECamera.sampleSettings())
        var looks: [Recipe] = []
        for s in FilmSimulation.allCases { var r = base; r.filmSim = s; looks.append(r) }
        for w in WhiteBalance.allCases { var r = base; r.whiteBalance = w; r.kelvin = w == .kelvin ? 6300 : 0; r.wbShiftR = 2; looks.append(r) }
        for c in -4...4 { var r = base; r.color = c; looks.append(r) }
        for c in -4...4 { var r = base; r.filmSim = .acrosR; r.color = c; looks.append(r) }  // B&W: color isn't written
        for n in -4...4 { var r = base; r.noiseReduction = n; looks.append(r) }
        for r in looks {
            let refused = !codes.unverified(in: r).isEmpty
            var threw = false
            do { _ = try file.applyingLooks([.init(slot: 7, recipe: r)]) } catch { threw = true }
            #expect(refused == threw, "\(r.filmSim.rawValue) \(r.whiteBalance.rawValue) color \(r.color) NR \(r.noiseReduction)")
            #expect(refused == !FujiSettingsFile.inferredValues(for: r).isEmpty)
            #expect((FujiSettingsFile.unverifiedReason(for: r) != nil) == refused)
        }
        for r in FakeFujiBLECamera.sampleLooks { #expect(codes.unverified(in: r).isEmpty, "\(r.name)") }
    }

    @Test("The refusal is plain")
    func words() {
        var astia = base
        astia.filmSim = .astia
        #expect(FujiSettingsFile.unverifiedReason(for: astia, codes: oct9Codes)
            == "This look uses a film simulation we haven't verified on your camera yet.")
        astia.whiteBalance = .shade
        #expect(FujiSettingsFile.unverifiedReason(for: astia, codes: oct9Codes)
            == "This look uses a film simulation and a white balance we haven't verified on your camera yet.")
        #expect(oct9Codes.unverified(in: astia).map(\.detail) == ["Astia", "Shade white balance"])
        let two = BLESlotWriter.plainRefusal([
            .init(slot: 1, name: "Soft faces", values: [.filmSimulation(.astia)]),
            .init(slot: 2, name: "Old town", values: [.filmSimulation(.classicNeg)]),
        ])
        #expect(two == "Soft faces, Old town: These looks use a film simulation we haven't verified on your camera yet. Nothing was sent.")
    }

    @Test("Every confirmed code is in a real fw 1.10 file (read in place, skipped when absent)")
    func realFile() throws {
        guard FileManager.default.fileExists(atPath: realSettings.path) else { return }
        let file = try FujiSettingsFile(try Data(contentsOf: realSettings))
        let simBytes = Set(file.anchors.map { Int(file.bytes[$0 + 0x64]) })
        for (name, raw) in oct9Codes.filmSims { #expect(simBytes.contains(raw), "\(name) = \(raw) not in any slot") }
        let wbBytes = Set(file.anchors.map { Int(file.bytes[$0 - 0x0F]) })
        for (name, wb) in oct9Codes.whiteBalances { #expect(wbBytes.contains(wb.code), "\(name)") }
        let colorBytes = Set(file.anchors.map { Int(file.bytes[$0 + 0x77]) })
        for (v, raw) in oct9Codes.colors { #expect(colorBytes.contains(raw), "color \(v)") }
        for a in file.anchors { #expect(oct9Codes.noiseReductions.values.contains(Int(file.bytes[a + 0x2B]))) }
        // And the slots decode back to the 10/9 looks through the derived map.
        #expect(file.recipe(slot: 1)?.filmSim == .realaAce && file.recipe(slot: 7)?.filmSim == .acrosYe)
    }
}
