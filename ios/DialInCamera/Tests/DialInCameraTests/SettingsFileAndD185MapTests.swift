// The full D185 field map and the X100VI settings-file codec (docs/FUJIFILM-PROTOCOL.md §4).
// Real files are read in place when present and never copied: backups/settings-*.dat holds the camera serial; saved
// D185 dumps are read from the folder named by DIALIN_D185_DUMPS, if set.
import Foundation
import Testing
@testable import DialInCamera

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let realSettings = repoRoot.appendingPathComponent(".dialin/test-fixtures/settings.dat")
private let d185Dumps: URL? = ProcessInfo.processInfo.environment["DIALIN_D185_DUMPS"].map { URL(fileURLWithPath: $0) }

/// A full-layout profile: u16 0x1D, PTP string in a 0x1FF-byte area from 2, int32 fields
/// from 0x201. `fields[k]` is the profile's field k (our index k+1); 28 fields = the X100VI's 625 bytes.
private func fujiProfile(_ fields: [Int32], iop: String = "FF179503") -> Data {
    var d = Data()
    d.appendLE16(0x1D)
    let units = Array(iop.utf16)
    d.append(UInt8(units.count + 1))
    for u in units { d.appendLE16(u) }
    d.appendLE16(0)
    d.append(Data(count: 0x201 - d.count))
    for v in fields { d.appendLE32(UInt32(bitPattern: v)) }
    return d
}

/// Reset-profile defaults with a shot's look on top, as 28 fields.
private func x100viFields() -> [Int32] {
    // ShootCond, FileType, Size, Quality, EV, DR, DR-P, Film, Grain, CC, WBCond, WB, R, B, K, H, S, Color, Sharp, NR,
    // LMO, Space, MonoWC, Skin, CCB, MonoMG, Clarity, TC
    [2, 7, 7, 2, 333, 400, 0, 0x14, 2, 2, 1, 2, 0, 0, 10000, -10, 0, 10, -10, 0x8000, 2, 1, 0, 1, 2, 0, 0, 2]
}

@Suite("D185: the full field map")
struct D185MapTests {
    @Test("The X100VI's 625 bytes are exactly 0x201 + 28 fields; our index k+1 = the profile's field k")
    func geometry() throws {
        let p = try D185Profile(fujiProfile(x100viFields()))
        #expect(p.bytes.count == 625 && p.count == 29 && p.paramsOffset == 509)
        #expect(p.iopCode == "FF179503")
        #expect(p[0] == 0)                              // tail of the IOP area, not a parameter
        #expect(p[1] == 2 && p[2] == 7 && p[5] == 333 && p[6] == 400 && p[8] == 0x14 && p[28] == 2)
        #expect(D185Map.field(5)?.absoluteOffset == 0x211)   // exposure bias
        #expect(D185Map.field(28)?.absoluteOffset == 0x26D)
        #expect(D185Map.field(28)!.absoluteOffset + 4 == 625)
        #expect(D185Map.fields.map(\.index) == Array(1...29))
    }

    @Test("Full layout: exposure 5, WB source 11, smooth skin 24, extras named")
    func layout() throws {
        let l = D185Layout.full
        #expect(l.exposureBias == 5 && l.wbShootCondition == 11 && l.smoothSkin == 24 && l.imageSize == 3)
        #expect(l.monoWarmCool == 23 && l.monoMagentaGreen == 26 && l.colorChromeFxBlue == 25 && l.clarity == 27)
        #expect(D185Layout.named("full") == .full && D185Layout.named("FilmKit") == .filmKit && D185Layout.named("x") == nil)
        let p = try D185Profile(fujiProfile(x100viFields()))
        #expect(l.exposureIndex(for: p).index == 5 && l.exposureIndex(for: p).confident)
        #expect(l.label(11, exposureIndex: 5).hasPrefix("WB shoot condition"))
        #expect(l.label(0, exposureIndex: 5).contains("not a parameter"))
        let json = try JSONEncoder().encode(l)
        #expect(try JSONDecoder().decode(D185Layout.self, from: json) == l)
    }

    @Test("WB: a mode writes source 2; As Shot writes source 1 and leaves the mode")
    func whiteBalance() throws {
        let base = try D185Profile(fujiProfile(x100viFields()))
        let shade = try D185Patch.apply(RenderSettings(whiteBalance: .mode(.shade)), to: base, layout: .full)
        #expect(shade.profile[12] == 0x8006 && shade.profile[11] == 2)
        var b2 = base
        b2[11] = 2
        let asShot = try D185Patch.apply(RenderSettings(whiteBalance: .asShot), to: b2, layout: .full)
        #expect(asShot.profile[11] == 1 && asShot.profile[12] == base[12])
        let k = try D185Patch.apply(RenderSettings(kelvin: 6300), to: base, layout: .full)
        #expect(k.profile[12] == 0x8007 && k.profile[15] == 6300 && k.profile[11] == 2)
    }

    @Test("Full-layout-only fields: size, color space, smooth skin, teleconverter; refused under the FilmKit layout")
    func extras() throws {
        let base = try D185Profile(fujiProfile(x100viFields()))
        let r = try D185Patch.apply(
            RenderSettings(exposure: -1, imageSize: "M", colorSpace: "Adobe RGB", smoothSkin: .weak, teleconverter: false),
            to: base, layout: .full)
        #expect(r.profile[3] == 4 && r.profile[22] == 2 && r.profile[24] == 2 && r.profile[28] == 2 && r.profile[5] == -1000)
        #expect(r.notes.contains { $0.contains("D183 = 1") })
        #expect(Set(r.profile.changedIndices(from: base)) == [3, 5, 22, 24])   // TC was already 2
        #expect(D185ImageSize.code("l 16:9") == 8 && D185ImageSize.code("S") == 1 && D185ImageSize.code("XL") == nil)
        #expect(throws: RawConvError.self) { try D185Patch.apply(RenderSettings(imageSize: "M"), to: base) }
        #expect(throws: RawConvError.self) { try RenderSettings(imageSize: "huge").validate() }
        let back = D185AsShot(r.profile, layout: .full, exposureIndex: 5)
        #expect(back.imageSize == 4 && back.colorSpace == 2 && back.smoothSkin == 2 && back.digitalTeleConv == 2)
        #expect(back.shootCondition == 2 && back.wbShootCondition == 1 && back.exposureEV == -1)
        #expect(back.line.contains("size M 3:2"))
    }

    @Test("FilmKit layout keeps its old behaviour (exposure detected, index 11 untouched)")
    func filmKitUnchanged() throws {
        let base = try D185Profile(fujiProfile(x100viFields()))
        let r = try D185Patch.apply(RenderSettings(whiteBalance: .mode(.daylight)), to: base)
        #expect(r.profile[12] == 4 && r.profile[11] == base[11])
    }

    @Test("Real D185 dumps (DIALIN_D185_DUMPS, optional): the full structure holds")
    func realDumps() throws {
        let fm = FileManager.default
        guard let d185Dumps, let dirs = try? fm.contentsOfDirectory(at: d185Dumps, includingPropertiesForKeys: nil) else { return }
        var seen = 0
        for dir in dirs {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasSuffix(".d185.bin") {
                let p = try D185Profile(Data(contentsOf: f))
                seen += 1
                #expect(p.bytes.count == 625 && p.count == 29, "\(f.lastPathComponent)")
                #expect(3 + p.iopCode.utf16.count * 2 <= 0x201)
                #expect([1, 2].contains(p[1]) && [1, 2].contains(p[11]) && [1, 2].contains(p[28]), "\(f.lastPathComponent)")
                #expect([2, 3].contains(p[4]), "image quality at index 4: \(p[4])")
                let ev = Double(p[5]), k = (ev * 3 / 1000).rounded()
                #expect(abs(ev - k * 1000 / 3) <= 2 && abs(ev) <= 5000, "exposure at index 5: \(p[5])")
            }
        }
        _ = seen
    }
}

// MARK: - Settings file

/// A 70,524-byte X100VI-shaped file (fake serial, seeded payload) whose checksum is (payload sum + k) mod 2¹⁶.
func syntheticSettings(k: UInt16 = 0x1234, seed: UInt64 = 7) -> [UInt8] {
    var state = seed
    var b = [UInt8](repeating: 0, count: FujiSettingsFile.fw110Size)
    for i in 0xA8..<b.count {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        b[i] = UInt8(truncatingIfNeeded: state >> 33)
    }
    b.replaceSubrange(0..<16, with: Array("FUJIFILMX-BACKUP".utf8))
    b.replaceSubrange(0x10..<0x14, with: Array("0100".utf8))
    b.replaceSubrange(0x14..<0x1A, with: Array("X100VI".utf8))
    b.replaceSubrange(0x34..<0x48, with: Array("SYNTHETICSERIAL00000".utf8))
    func put32(_ o: Int, _ v: Int) { for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    put32(0x98, 0xA8)
    put32(0xA0, b.count - 0xA8)
    put32(0x108, 0)
    let names = ["Harbor color", "Sunny faces", "Deep blue sea", "Old fisherman", "Faded dock", "Hard noon B&W", "Gritty B&W"]
    for (i, n) in names.enumerated() {
        let at = 0xF800 + i * 0x400 + FujiSettingsFile.nameRel
        var field = Array(n.utf8)
        field += [UInt8](repeating: 0, count: FujiSettingsFile.nameFieldLength - field.count)
        b.replaceSubrange(at..<at + FujiSettingsFile.nameFieldLength, with: field)
        let a = 0xF800 + i * 0x400
        b[a + 0x2F] = 0; b[a + 0x31] = 1; b[a + 0x32] = 2; b[a + 0x84] = 3
    }
    var sum = 0
    for i in 0xA8..<b.count where !(0x108..<0x10C).contains(i) { sum += Int(b[i]) }
    let s = UInt16(truncatingIfNeeded: sum + Int(k))
    b[0x108] = UInt8(s & 0xFF)
    b[0x109] = UInt8(s >> 8)
    return b
}

@Suite("X100VI settings file")
struct SettingsFileTests {
    @Test("Header, geometry, checksum constant")
    func parse() throws {
        let f = try FujiSettingsFile(bytes: syntheticSettings(k: 0xBEEF))
        #expect(f.anchors.first == 0xF800 && f.anchors.last == 0x11000)
        #expect(f.checksumConstant == 0xBEEF)
        #expect(f.names[6] == "Gritty B&W")
        #expect(f.value("image_size", slot: 1)?.name == "L" && f.value("af_mode", slot: 1)?.name == "Zone")
    }

    @Test("Rename C7: only the name and the checksum change; K survives")
    func rename() throws {
        let f = try FujiSettingsFile(bytes: syntheticSettings())
        let r = try f.patched([.name(slot: 7, "BT TEST")])
        #expect(r.file.name(slot: 7) == "BT TEST")
        #expect(r.file.checksumConstant == f.checksumConstant)
        let changed = (0..<f.bytes.count).filter { f.bytes[$0] != r.file.bytes[$0] }
        #expect(changed.allSatisfy { r.allowed.contains($0) || $0 == 0x108 || $0 == 0x109 })
        #expect(FujiSettingsFile.validate(original: f, patched: r.file, allowed: r.allowed).isEmpty)
    }

    @Test("Hypothesis fields need the flag; names are checked; tampering is caught")
    func guards() throws {
        let f = try FujiSettingsFile(bytes: syntheticSettings())
        #expect(throws: SettingsFileError.self) { try f.patched([.field(slot: 1, key: "af_mode", value: "Single point")]) }
        let r = try f.patched([.field(slot: 1, key: "af_mode", value: "single point")], allowHypothesis: true)
        #expect(r.file.value("af_mode", slot: 1)?.raw == 2)
        #expect(throws: SettingsFileError.self) { try f.patched([.name(slot: 1, String(repeating: "x", count: 26))]) }
        #expect(throws: SettingsFileError.self) { try f.patched([.name(slot: 1, "Café")]) }
        #expect(throws: SettingsFileError.self) { try f.patched((1...7).map { .name(slot: $0, String(repeating: "N", count: 14)) }) }
        #expect(throws: SettingsFileError.self) { try f.patched([.field(slot: 8, key: "image_size", value: "M")]) }
        var bad = r.file.bytes
        bad[0x9000] ^= 1
        #expect(!FujiSettingsFile.validate(original: f, patched: try FujiSettingsFile(bytes: bad), allowed: r.allowed).isEmpty)
        var sum = r.file.bytes
        sum[0x108] ^= 1
        #expect(!FujiSettingsFile.validate(original: f, patched: try FujiSettingsFile(bytes: sum)).isEmpty)
    }

    @Test("Refuses other models, sizes and non-backups")
    func refuses() {
        var b = syntheticSettings()
        b.replaceSubrange(0x14..<0x1A, with: Array("X-T5\0\0".utf8))
        #expect(throws: SettingsFileError.self) { try FujiSettingsFile(bytes: b) }
        #expect(throws: SettingsFileError.self) { try FujiSettingsFile(bytes: Array(syntheticSettings().dropLast(4))) }
        #expect(throws: SettingsFileError.self) { try FujiSettingsFile(bytes: [UInt8](repeating: 0, count: 70524)) }
    }

    @Test("Real fw 1.10 file (read in place): checksum field, names, look, an in-memory C7 rename")
    func real() throws {
        // The repo-root math must be right, or this test would silently skip.
        #expect(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("ios/DialInCamera/Package.swift").path))
        guard FileManager.default.fileExists(atPath: realSettings.path) else { return }
        let f = try FujiSettingsFile(try Data(contentsOf: realSettings))
        #expect(f.storedChecksum == 0xC6DB && f.checksumConstant == 0xE5AE)
        #expect(f.bytes[0x10A] == 0 && f.bytes[0x10B] == 0)
        #expect(f.names == ["Harbor color", "Sunny faces", "Deep blue sea", "Old fisherman", "Faded dock", "Hard noon B&W", "Gritty B&W"])
        let c1 = f.look(slot: 1)
        #expect(c1.filmSimCode == 20 && c1.dynamicRange == 400 && c1.highlight == -1 && c1.sharpness == -1 && c1.kelvin == 4350)
        #expect(f.look(slot: 5).filmSimCode == 19 && f.look(slot: 5).kelvin == 6300 && f.look(slot: 5).whiteBalanceRaw == 0x0A)
        #expect(f.value("image_size", slot: 3)?.name == "L" && f.value("image_quality", slot: 3)?.name == "Fine+RAW")
        let r = try f.patched([.name(slot: 7, "DIALIN C7")])
        #expect(r.file.name(slot: 7) == "DIALIN C7" && r.file.checksumConstant == f.checksumConstant)
        let same = try f.patched((1...7).map { .name(slot: $0, f.name(slot: $0)) })
        #expect(same.file.bytes == f.bytes)
    }
}
