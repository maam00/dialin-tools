// FujiSettingsFile.applyingLooks against the Python apply_plan (golden vectors from Tests/make-look-patch-vectors.py,
// on the same synthetic file as syntheticSettings()), plus the decode side (mismatches) and the inferred list.
import CryptoKit
import Foundation
import Testing
@testable import DialInCamera

private struct LookPatchVectors: Decodable {
    struct Base: Decodable { var k: Int; var seed: UInt64; var sha256: String }
    struct Case: Decodable {
        var name: String
        var slots: [Int]
        var looks: [Recipe]
        var allow_inferred: Bool
        var ok: Bool
        var changed: [[Int]]?
        var sha256: String?
        var checksum: Int?
        var refused: [String]?
        var error: String?
    }
    struct Real: Decodable {
        var file: String
        var input_sha256: String
        var slots: [Int]
        var looks: [Recipe]
        var ok: Bool
        var output_sha256: String?
    }
    var base: Base
    var cases: [Case]
    var real: Real?
}

private func sha(_ b: [UInt8]) -> String { SHA256.hash(data: Data(b)).map { String(format: "%02x", $0) }.joined() }

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

@Suite("Look patch (apply_plan port)")
struct LookPatchTests {
    private static func vectors() throws -> LookPatchVectors {
        try JSONDecoder().decode(LookPatchVectors.self, from: Fixture.data("look-patch-vectors.json"))
    }

    @Test("Same synthetic base as the Python generator")
    func base() throws {
        let v = try Self.vectors()
        #expect(sha(syntheticSettings(k: UInt16(v.base.k), seed: v.base.seed)) == v.base.sha256)
    }

    @Test("Every case: the same bytes, sha256 and checksum as apply_plan, or the same refusals")
    func golden() throws {
        let v = try Self.vectors()
        let file = try FujiSettingsFile(bytes: syntheticSettings(k: UInt16(v.base.k), seed: v.base.seed))
        for c in v.cases {
            let placements = zip(c.slots, c.looks).map { FujiSettingsFile.LookPlacement(slot: $0, recipe: $1) }
            if c.ok {
                let p = try file.applyingLooks(placements, allowInferred: c.allow_inferred)
                let changed = (0..<file.bytes.count).filter { file.bytes[$0] != p.file.bytes[$0] }.map { [$0, Int(p.file.bytes[$0])] }
                #expect(changed == c.changed ?? [], "\(c.name)")
                #expect(sha(p.file.bytes) == c.sha256, "\(c.name)")
                #expect(Int(p.file.storedChecksum) == c.checksum, "\(c.name)")
                #expect(p.file.checksumConstant == file.checksumConstant, "\(c.name): K survives")
                for pl in placements { #expect(p.file.mismatches(slot: pl.slot, against: pl.recipe).isEmpty, "\(c.name) C\(pl.slot)") }
            } else if let refused = c.refused {
                do {
                    _ = try file.applyingLooks(placements, allowInferred: c.allow_inferred)
                    Issue.record("\(c.name): expected a refusal")
                } catch SettingsFileError.invalid(let msg) {
                    let lines = msg.components(separatedBy: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
                    #expect(Array(lines) == refused, "\(c.name)")
                }
            } else {
                #expect(throws: SettingsFileError.self, "\(c.name)") { try file.applyingLooks(placements, allowInferred: c.allow_inferred) }
            }
        }
    }

    @Test("mismatches: the old slot differs, the patched one matches, untouched slots are untouched")
    func mismatches() throws {
        let file = try FujiSettingsFile(bytes: syntheticSettings())
        let look = Recipe(name: "Shade at noon", filmSim: .classicChrome, grain: .weakSmall, colorChrome: .strong,
                          whiteBalance: .daylight, wbShiftR: 2, wbShiftB: -4, highlight: 1, shadow: -1.5, color: 2,
                          sharpness: -1, noiseReduction: -4, clarity: 2)
        #expect(!file.mismatches(slot: 2, against: look).isEmpty)
        let p = try file.applyingLooks([.init(slot: 2, recipe: look)])
        #expect(p.file.mismatches(slot: 2, against: look).isEmpty)
        #expect(p.file.mismatches(slot: 3, against: look).contains { $0.hasPrefix("name:") })
        for s in [1, 3, 4, 5, 6, 7] {
            let r = p.file.slotRegion(s)
            #expect(Array(p.file.bytes[r]) == Array(file.bytes[r]), "C\(s) untouched")
        }
        // Color 0 stored as raw 7 (the X-T5's way) still means 0.
        let zero = Recipe(name: "Zero color", filmSim: .velvia, noiseReduction: -4)
        var q = try file.applyingLooks([.init(slot: 1, recipe: zero)]).file.bytes
        q[file.anchors[0] + 0x77] = 7
        #expect(try FujiSettingsFile(bytes: q).mismatches(slot: 1, against: zero).isEmpty)
        q[file.anchors[0] + 0x64] = 18  // raw 18 = Reala Ace

        let mm = try FujiSettingsFile(bytes: q).mismatches(slot: 1, against: zero)
        #expect(mm == ["film simulation: the camera has Reala Ace, the look wants Velvia"])
    }

    @Test("inferredValues names what needs --allow-inferred, in plain words")
    func inferred() {
        let verified = Recipe(name: "x", filmSim: .realaAce, whiteBalance: .kelvin, kelvin: 6300, color: 1, noiseReduction: -4)
        #expect(FujiSettingsFile.inferredValues(for: verified).isEmpty)
        let neg = Recipe(name: "x", filmSim: .classicNeg, whiteBalance: .shade, wbShiftR: 1, color: 4, noiseReduction: 0)
        let words = FujiSettingsFile.inferredValues(for: neg)
        // Each holds while that value is still unconfirmed (`npm run codes -- merge` may confirm it later).
        let c = ConfirmedCodes.x100vi
        #expect(words.contains("Classic Neg (film simulation code inferred)") == !c.isConfirmed(FilmSimulation.classicNeg))
        #expect(words.contains("Shade white balance (code inferred)") == !c.isConfirmed(WhiteBalance.shade))
        #expect(words.contains("noise reduction 0 (only −4 seen on a real file)") == (c.noiseReductions[0] == nil))
        #expect(words.contains("color 4 (code inferred)") == (c.colors[4] == nil))
        #expect(words.filter { $0.contains("shift") }.count == (c.isConfirmed(WhiteBalance.shade) ? 0 : 1))
    }

    @Test("Real fw 1.10 file (read in place, never copied): same output as apply_plan")
    func real() throws {
        let v = try Self.vectors()
        guard let real = v.real else { return }
        let url = repoRoot.appendingPathComponent(real.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let bytes = [UInt8](try Data(contentsOf: url))
        guard sha(bytes) == real.input_sha256 else { return }   // a different backup in place: nothing to compare
        let file = try FujiSettingsFile(bytes: bytes)
        let p = try file.applyingLooks(zip(real.slots, real.looks).map { .init(slot: $0, recipe: $1) })
        #expect(real.ok)
        #expect(sha(p.file.bytes) == real.output_sha256)
        #expect(p.file.checksumConstant == file.checksumConstant)
    }
}
