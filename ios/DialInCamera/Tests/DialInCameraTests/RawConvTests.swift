// In-camera RAW re-rendering against a fake X100VI, and the D185 patcher against FilmKit's encodings.
// FilmKit = https://github.com/eggricesoy/filmkit (MIT); line numbers are src/profile/d185.ts and
// src/profile/preset-translate.ts at the commit vendored in lib/fuji/vendor.
import Foundation
import Testing
@testable import DialInCamera

private func sample() throws -> D185Profile { try D185Profile(FakeRawConvCamera.sampleProfile()) }

// Allow scheduler contention in the full suite; wedge tests still pass their own short deadline.
private func connected(_ configure: @Sendable (inout FakeRawConvCamera.Config) -> Void = { _ in },
                       renderTimeout: Duration = .seconds(3)) async throws -> (FujiRawConverter, FakeRawConvCamera) {
    var cfg = FakeRawConvCamera.Config()
    configure(&cfg)
    let fake = FakeRawConvCamera(config: cfg)
    let conv = FujiRawConverter(
        transport: fake,
        timing: .init(pollInterval: .milliseconds(1), renderTimeout: renderTimeout, uploadTimeout: .seconds(5),
                      downloadTimeout: .seconds(5), commandTimeout: .seconds(5)))
    try await conv.connect(timeout: .seconds(1))
    return (conv, fake)
}

@Suite("D185 profile")
struct D185ProfileTests {
    @Test("Parses count, offset (len − n·4, FilmKit d185.ts:91-95) and the IOP header")
    func parse() throws {
        let p = try sample()
        #expect(p.bytes.count == 625)
        #expect(p.count == 29)
        #expect(p.paramsOffset == 625 - 29 * 4)
        #expect(p.iopCode == "FF179503")
        #expect(p[6] == 400)
        #expect(p[8] == 0x14)
        #expect(p[16] == -10)
        #expect(p[20] == 0x8000)
        #expect(p[99] == 0)
    }

    @Test("Rejects short or implausible profiles")
    func rejects() {
        #expect(throws: RawConvError.self) { try D185Profile(Data([1, 2, 3])) }
        var d = Data(count: 625)
        d[0] = 0xFF   // 255 params can't fit
        #expect(throws: RawConvError.self) { try D185Profile(d) }
    }

    @Test("Writing one parameter changes exactly its 4 bytes")
    func setParam() throws {
        var p = try sample()
        let before = p.bytes
        p[17] = -15
        #expect(p.bytes.count == before.count)
        let diff = (0..<before.count).filter { p.bytes[$0] != before[$0] }
        let o = p.paramsOffset + 17 * 4
        #expect(!diff.isEmpty && diff.allSatisfy { (o..<o + 4).contains($0) })
        #expect(p[17] == -15)
        #expect(p.changedIndices(from: try sample()) == [17])
    }

    @Test("As-shot decode = FilmKit cameraProfileToUIValues (preset-translate.ts:208-245)")
    func asShot() throws {
        let s = D185AsShot(try sample(), exposureIndex: 5)
        #expect(s.filmSim == "Reala Ace")
        #expect(s.dynamicRange == 400)
        #expect(s.grain == "Weak Small")
        #expect(s.colorChrome == "Weak")
        #expect(s.colorChromeFxBlue == "Weak")
        #expect(s.whiteBalanceCode == 0)
        #expect(s.highlight == -1)
        #expect(s.shadow == 0)
        #expect(s.color == 1)
        #expect(s.sharpness == -1)
        #expect(s.noiseReduction == -4)
        #expect(s.clarity == 0)
        #expect(s.exposureEV == 0)
        #expect(s.line.hasPrefix("Reala Ace · DR400 · grain Weak Small · CC Weak/Weak · WB as shot R0 B0"))
    }

    @Test("Exposure index: decided from the values (FilmKit 4 vs libfuji 5)")
    func exposureIndex() throws {
        // The sample holds a quality code at 4 and 0 at 5: libfuji's reading.
        let g = D185Layout.detectExposureIndex(try sample())
        #expect(g.index == 5 && g.confident)

        var p = try sample()
        p[4] = -333   // a valid ⅓-EV value
        p[5] = 7      // a code
        let g2 = D185Layout.detectExposureIndex(p)
        #expect(g2.index == 4 && g2.confident)

        p[4] = 0
        p[5] = 0
        let g3 = D185Layout.detectExposureIndex(p)
        #expect(g3.index == 4 && !g3.confident)

        var fixed = D185Layout.filmKit
        fixed.exposureBias = 5
        #expect(fixed.exposureIndex(for: p).index == 5)
    }

    @Test("Layout JSON: any subset of keys, the rest stay FilmKit's")
    func layoutJSON() throws {
        let l = try JSONDecoder().decode(D185Layout.self, from: Data(#"{"exposure_bias": 5, "wb_shoot_condition": 11, "color_chrome_fx_blue_base": 0}"#.utf8))
        #expect(l.exposureBias == 5)
        #expect(l.wbShootCondition == 11)
        #expect(l.colorChromeFxBlueBase == 0)
        #expect(l.filmSimulation == 8 && l.clarity == 27 && l.whiteBalance == 12)
        let round = try JSONDecoder().decode(D185Layout.self, from: JSONEncoder().encode(l))
        #expect(round == l)
    }
}

@Suite("D185 patch (FilmKit encodings)")
struct D185PatchTests {
    @Test("Unchanged settings leave every byte alone")
    func unchanged() throws {
        let r = try D185Patch.apply(.unchanged, to: try sample())
        #expect(r.profile == (try sample()))
        #expect(r.changes.isEmpty && r.notes.isEmpty)
    }

    @Test("Each field lands at FilmKit's index with FilmKit's encoding")
    func encodings() throws {
        let base = try sample()
        func one(_ s: RenderSettings) throws -> [Int: Int32] {
            let r = try D185Patch.apply(s, to: base)
            #expect(r.profile.bytes.count == base.bytes.count)
            #expect(r.profile.bytes.prefix(base.paramsOffset) == base.bytes.prefix(base.paramsOffset))   // header untouched
            return Dictionary(uniqueKeysWithValues: r.profile.changedIndices(from: base).map { ($0, r.profile[$0]) })
        }
        #expect(try one(RenderSettings(filmSim: .classicChrome)) == [8: 0x0B])                 // d185.ts:93
        #expect(try one(RenderSettings(grain: .strongLarge)) == [9: 5])                        // GRAIN_TO_NATIVE :63-69
        #expect(try one(RenderSettings(grain: .off)) == [9: 1])
        #expect(try one(RenderSettings(colorChrome: .strong)) == [10: 3])                      // effects +1 :104
        #expect(try one(RenderSettings(colorChromeFxBlue: .off)) == [25: 1])                   // :105
        #expect(try one(RenderSettings(dynamicRange: .dr200)) == [6: 200])                     // DR_TO_NATIVE :72
        #expect(try one(RenderSettings(whiteBalance: .mode(.daylight))) == [12: 4])            // :109
        #expect(try one(RenderSettings(whiteBalance: .mode(.kelvin), kelvin: 6300)) == [12: 0x8007, 15: 6300])  // :109,112
        #expect(try one(RenderSettings(kelvin: 4200)) == [12: 0x8007, 15: 4200])
        #expect(try one(RenderSettings(wbShiftR: 2, wbShiftB: -5)) == [13: 2, 14: -5])         // :110-111
        #expect(try one(RenderSettings(highlight: -1.5, shadow: 2.5)) == [16: -15, 17: 25])    // ×10 :115-116
        #expect(try one(RenderSettings(color: -2)) == [18: -20])                               // :117
        #expect(try one(RenderSettings(sharpness: 2)) == [19: 20])                             // :118
        #expect(try one(RenderSettings(clarity: -3)) == [27: -30])                             // :123
        #expect(try one(RenderSettings(dRangePriority: 1)).keys.contains(7))                   // wideDRange :96
        #expect(try one(RenderSettings(exposure: 1.0 / 3)) == [5: 333])                        // libfuji fp.h:43
        #expect(try one(RenderSettings(exposure: -2.0 / 3)) == [5: -667])                      // fp.h:46 0xfffffd65
    }

    @Test("NR uses Fuji's table, not ×10 (preset-translate.ts:103-106)")
    func noiseReduction() throws {
        let expected: [Int: Int32] = [-4: 0x8000, -3: 0x7000, -2: 0x4000, -1: 0x3000, 0: 0x2000, 1: 0x1000, 2: 0, 3: 0x6000, 4: 0x5000]
        for (ui, wire) in expected {
            let r = try D185Patch.apply(RenderSettings(noiseReduction: ui), to: try sample())
            #expect(r.profile[20] == wire)
        }
    }

    @Test("Exposure snaps to thirds the way libfuji's table spells them")
    func milliEV() {
        #expect(D185Patch.milliEV(0.33) == 333)
        #expect(D185Patch.milliEV(0.7) == 667)
        #expect(D185Patch.milliEV(1) == 1000)
        #expect(D185Patch.milliEV(1.33) == 1333)
        #expect(D185Patch.milliEV(-0.33) == -333)   // 0xfffffeb3
        #expect(D185Patch.milliEV(-1) == -1000)     // 0xfffffc18
        #expect(D185Patch.milliEV(3) == 3000)
    }

    @Test("Round trip: decode(patch(base, s)) gives s back")
    func roundTrip() throws {
        let s = RenderSettings(
            filmSim: .classicChrome, whiteBalance: .mode(.kelvin), kelvin: 6300, wbShiftR: 1, wbShiftB: -3, dynamicRange: .dr200,
            highlight: -1.5, shadow: -1, color: -1, sharpness: -2, noiseReduction: -4, clarity: -2, grain: .strongSmall,
            colorChrome: .weak, colorChromeFxBlue: .off, exposure: 1.0 / 3)
        let r = try D185Patch.apply(s, to: try sample())
        let back = D185AsShot(r.profile, exposureIndex: r.exposureIndex.index)
        #expect(back.filmSim == "Classic Chrome")
        #expect(back.whiteBalanceCode == FujiWB.colorTemp && back.kelvin == 6300)
        #expect(back.wbShiftR == 1 && back.wbShiftB == -3)
        #expect(back.dynamicRange == 200)
        #expect(back.highlight == -1.5 && back.shadow == -1 && back.color == -1 && back.sharpness == -2 && back.clarity == -2)
        #expect(back.noiseReduction == -4)
        #expect(back.grain == "Strong Small" && back.colorChrome == "Weak" && back.colorChromeFxBlue == "Off")
        #expect(back.exposureEV == 0.333)
    }

    @Test("Untouched sentinels survive: WB as shot (0) and NR 0x8000 (FilmKit d185.ts:53,57)")
    func sentinels() throws {
        let r = try D185Patch.apply(RenderSettings(filmSim: .velvia, highlight: 0), to: try sample())
        #expect(r.profile[12] == 0)
        #expect(r.profile[20] == 0x8000)
        #expect(r.profile[11] == 1)   // never written: FilmKit smooth skin / libfuji WB shoot condition
    }

    @Test("Golden vector: the plan's Hard noon B&W onto _DSF1222's (synthetic) profile")
    func golden() throws {
        let look = Recipe(
            name: "Hard noon B&W", filmSim: .acrosR, grain: .weakLarge, colorChrome: .off, colorChromeFxBlue: .off,
            whiteBalance: .auto, kelvin: 0, wbShiftR: 0, wbShiftB: 0, dynamicRange: .dr200, highlight: 1, shadow: 2.5,
            color: 0, sharpness: 0, noiseReduction: -4, clarity: 1)
        let r = try D185Patch.apply(RenderSettings(recipe: look), to: try sample())
        var want = try sample().params
        want[6] = 200      // DR200 (≤ the shot's DR400)
        want[8] = 0x0E     // Acros+R
        want[9] = 4        // Weak Large
        want[12] = 2       // Auto
        want[16] = 10      // H +1
        want[17] = 25      // S +2.5
        want[18] = 0       // B&W: color neutralised
        want[19] = 0       // sharpness 0
        want[20] = 0x8000  // NR −4
        want[27] = 10      // clarity +1
        #expect(r.profile.params == want)
        #expect(r.notes.contains { $0.hasPrefix("B&W sim: skipped") })
    }

    @Test("DR can't exceed the shot's (libfuji d185.c:127); B&W skips color-only settings; toning only on B&W")
    func rules() throws {
        var base = try sample()
        base[6] = 100
        let r = try D185Patch.apply(RenderSettings(dynamicRange: .dr400), to: base)
        #expect(r.profile[6] == 100)
        #expect(r.notes.first?.contains("shot at DR100") == true)

        let mono = try D185Patch.apply(RenderSettings(filmSim: .acros, wbShiftR: 3, color: 2), to: try sample())
        #expect(mono.profile[13] == 0 && mono.profile[18] == 0)

        let tone = try D185Patch.apply(RenderSettings(filmSim: .acrosYe, monoWarmCool: 2, monoMagentaGreen: -1), to: try sample())
        #expect(tone.profile[23] == 20 && tone.profile[26] == -10)
        let notMono = try D185Patch.apply(RenderSettings(monoWarmCool: 2), to: try sample())
        #expect(notMono.profile[23] == 0 && notMono.notes.contains { $0.contains("isn't B&W") })
    }

    @Test("WB shoot condition is written only when the layout names it")
    func shootCondition() throws {
        var l = D185Layout.filmKit
        #expect(try D185Patch.apply(RenderSettings(whiteBalance: .mode(.shade)), to: try sample(), layout: l).profile[11] == 1)
        l.wbShootCondition = 11
        #expect(try D185Patch.apply(RenderSettings(whiteBalance: .mode(.shade)), to: try sample(), layout: l).profile[11] == 2)
        #expect(try D185Patch.apply(RenderSettings(highlight: 1), to: try sample(), layout: l).profile[11] == 1)
    }

    @Test("Raw overrides apply last; a guessed exposure index is flagged")
    func rawAndGuess() throws {
        let r = try D185Patch.apply(RenderSettings(highlight: 1, raw: ["16": 40, "11": 2]), to: try sample())
        #expect(r.profile[16] == 40 && r.profile[11] == 2)

        var p = try sample()
        p[4] = 0
        let g = try D185Patch.apply(RenderSettings(exposure: 1), to: p)
        #expect(g.profile[4] == 1000)
        #expect(g.notes.contains { $0.contains("guess") })
    }

    @Test("Out-of-range settings are refused with every problem named")
    func validation() {
        #expect(throws: RawConvError.self) { try RenderSettings(highlight: 0.3).validate() }
        #expect(throws: RawConvError.self) { try RenderSettings(clarity: 9).validate() }
        #expect(throws: RawConvError.self) { try RenderSettings(kelvin: 12000).validate() }
        #expect(throws: RawConvError.self) { try RenderSettings(exposure: 4).validate() }
        #expect(throws: RawConvError.self) { try RenderSettings(whiteBalance: .mode(.daylight), kelvin: 5000).validate() }
        do {
            try RenderSettings(wbShiftR: 12, highlight: 5).validate()
        } catch let e as RawConvError {
            #expect(e.description.contains("highlight") && e.description.contains("wb_shift_r"))
        } catch {}
    }
}

@Suite("Render settings and files")
struct RenderFilesTests {
    @Test("variants.json settings decode (colorlab's snake_case + Recipe enum strings)")
    func decodeSettings() throws {
        let json = #"{"film_sim":"Acros+R","white_balance":"As Shot","wb_shift_r":1,"wb_shift_b":-1,"dynamic_range":"DR200","highlight":-0.5,"grain":"Weak Large","color_chrome":"Off","exposure":0.33,"raw":{"11":2}}"#
        let s = try JSONDecoder().decode(RenderSettings.self, from: Data(json.utf8))
        #expect(s.filmSim == .acrosR && s.whiteBalance == .asShot && s.wbShiftR == 1 && s.dynamicRange == .dr200)
        #expect(s.grain == .weakLarge && s.colorChrome == .off && s.exposure == 0.33 && s.raw == ["11": 2])
        #expect(s.summary.contains("Acros+R") && s.summary.contains("+0.33 EV"))
        let again = try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(s))
        #expect(again == s)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RenderSettings.self, from: Data(#"{"white_balance":"Moonlight"}"#.utf8)) }
    }

    @Test("A recipe becomes a whole-look render")
    func recipe() throws {
        let r = Recipe(name: "Faded dock", filmSim: .nostalgicNeg, grain: .strongSmall, colorChrome: .weak, whiteBalance: .kelvin,
                       kelvin: 6300, wbShiftR: 1, wbShiftB: -3, dynamicRange: .dr400, highlight: -1.5, shadow: -1, color: -1,
                       sharpness: -2, noiseReduction: -4, clarity: -2)
        let s = RenderSettings(recipe: r)
        #expect(s.filmSim == .nostalgicNeg && s.whiteBalance == .mode(.kelvin) && s.kelvin == 6300 && s.exposure == nil)
        #expect(RenderSettings(recipe: Recipe(name: "x", filmSim: .provia, whiteBalance: .auto)).kelvin == nil)
    }

    @Test("variants.json: wrapper object or bare array")
    func variantsFile() throws {
        let w = try VariantsFile.decode(Data(#"{"photo":"a.JPG","raf":"a.RAF","variants":[{"name":"bw","settings":{"film_sim":"Acros"}}]}"#.utf8))
        #expect(w.raf == "a.RAF" && w.variants.first?.settings.filmSim == .acros)
        let a = try VariantsFile.decode(Data(#"[{"name":"warm","settings":{"wb_shift_r":1}}]"#.utf8))
        #expect(a.variants.count == 1 && a.raf == nil)
    }

    @Test("Slugs, RAF header, JPEG size")
    func helpers() {
        #expect(RenderVariant.slug("Harbor Color, a touch warmer!") == "harbor-color-a-touch-warmer")
        #expect(RenderVariant.slug("***") == "variant")
        #expect(RAFHeader.model(FakeRawConvCamera.tinyRAF()) == "X100VI")
        #expect(RAFHeader.model(Data("not a raf at all, sorry, not at all, no....................".utf8)) == nil)
        let size = JPEGSize.of(FakeRawConvCamera.tinyJPEG(width: 3888, height: 2592))
        #expect(size?.width == 3888 && size?.height == 2592)
        #expect(RenderedImageKind(sniffing: FakeRawConvCamera.tinyJPEG(width: 1, height: 1)) == .jpeg)
        #expect(RenderedImageKind(sniffing: Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])) == .heif)
    }

    @Test("renders.json timing summary and determinism")
    func timing() {
        func rec(_ n: String, _ ms: Double, _ sha: String) -> RenderManifest.Record {
            var r = RenderManifest.Record(variant: RenderVariant(name: n, settings: .unchanged), pass: 1, thumbnail: false, startValue: 0)
            r.totalMs = ms
            r.sha256 = sha
            return r
        }
        let t = RenderManifest.Timing.from(upload: [.init(name: "upload", ms: 2500)],
                                           records: [rec("a", 6000, "x"), rec("a", 2000, "x"), rec("a", 3000, "x")])
        #expect(t.uploadMs == 2500 && t.firstRenderMs == 6000 && t.laterMeanMs == 2500 && t.laterMaxMs == 3000)
        #expect(t.deterministic == true)
        let t2 = RenderManifest.Timing.from(upload: [], records: [rec("a", 1, "x"), rec("a", 1, "y")])
        #expect(t2.deterministic == false)
    }
}

@Suite("FujiRawConverter against a fake X100VI")
struct FujiRawConverterTests {
    @Test("900C ObjectInfo is FilmKit's 82 bytes: format 0xF802, size, \"FUP_FILE.dat\" (session.ts:489-511)")
    func objectInfo() {
        let oi = FujiRawConverter.rafObjectInfo(size: 36_145_296)   // _DSF1222.RAF
        #expect(oi.count == 82)
        let want = "00000000" + "02f8" + "0000" + "90882702" + "0000" + String(repeating: "00000000", count: 7) + "0000"
            + "00000000" + "00000000" + "0d" + "460055005000" + "5f00" + "460049004c004500" + "2e00640061007400" + "0000" + "000000"
        #expect(oi.hexString == want)
    }

    @Test("Upload: 900C [0,0,0] + 900D with the whole RAF, then D185 read once and cached")
    func load() async throws {
        let (conv, fake) = try await connected()
        let raf = FakeRawConvCamera.tinyRAF(size: 10_000)
        let r = try await conv.loadRaf(data: raf)
        #expect(r.rafModel == "X100VI" && r.profile.bytes.count == 625)
        #expect(r.steps.map(\.name) == ["object info", "upload", "read profile"])
        let cmds = await fake.commands
        let after = cmds.drop { $0.op != FujiRawConverter.Op.sendObjectInfo }.map(\.op)
        #expect(after == [0x900C, 0x900D, 0x1015])
        #expect(cmds.first { $0.op == 0x900C }?.params == [0, 0, 0])
        #expect(cmds.first { $0.op == 0x900D }?.params == [])
        #expect(await fake.uploadedRAF == raf)
        _ = try await conv.getProfile()
        _ = try await conv.getProfile()
        #expect(await fake.commands.filter { $0.op == 0x1015 && $0.params == [0xD185] }.count == 1)
    }

    @Test("A RAF from another model, or not a RAF, is refused before anything is sent")
    func wrongRAF() async throws {
        let (conv, fake) = try await connected()
        await #expect(throws: RawConvError.wrongModel(raf: "X-T5", camera: "X100VI")) {
            try await conv.loadRaf(data: FakeRawConvCamera.tinyRAF(model: "X-T5"))
        }
        await #expect(throws: RawConvError.self) { try await conv.loadRaf(data: Data(count: 200)) }
        #expect(await !fake.ops.contains(0x900C))
    }

    @Test("Wrong USB mode → needsUSBMode")
    func wrongMode() async throws {
        let fake = FakeRawConvCamera(config: { var c = FakeRawConvCamera.Config(); c.usbMode = 5; return c }())
        let conv = FujiRawConverter(transport: fake)
        await #expect(throws: CameraError.self) { try await conv.connect(timeout: .seconds(1)) }
    }

    @Test("Missing RAW-conversion codes in DeviceInfo are reported, not fatal")
    func notAdvertised() async throws {
        var c = FakeRawConvCamera.Config()
        c.advertiseRawConv = false
        let conv = FujiRawConverter(transport: FakeRawConvCamera(config: c))
        let info = try await conv.connect(timeout: .seconds(1))
        #expect(info.notAdvertised == ["op 900C", "op 900D", "prop D183", "prop D185"])
        #expect(info.usbMode == 6 && info.identity["D187"] == "X100VI_0110")
    }

    @Test("Unchanged render: D185 written back byte-identical, D183 = 0, poll until a new object, GetObject, DeleteObject")
    func renderUnchanged() async throws {
        let (conv, fake) = try await connected()
        let load = try await conv.loadRaf(data: FakeRawConvCamera.tinyRAF())
        let r = try await conv.render(profile: load.profile)
        #expect(await fake.renderedProfiles == [FakeRawConvCamera.sampleProfile()])
        #expect(await fake.startValues == [0])
        #expect(r.data == FakeRawConvCamera.Config().renderBytes && r.kind == .jpeg && !r.thumbnail)
        #expect(r.steps.map(\.name) == ["set profile", "start", "wait", "download", "delete"])
        #expect(r.steps.first { $0.name == "wait" }?.count == 3)
        #expect(await fake.deletedHandles == [r.handle])
        let set = await fake.commands.filter { $0.op == 0x1016 }
        #expect(set.map(\.params) == [[0xD185], [0xD183]])
        #expect(set.last?.dataOut == Data([0, 0]))
        #expect(await fake.commands.contains { $0.op == 0x1007 && $0.params == [0xFFFF_FFFF, 0, 0] })
    }

    @Test("D183 = 1 is sent as 01 00 (rawji's value)")
    func startOne() async throws {
        let (conv, fake) = try await connected()
        _ = try await conv.loadRaf(data: FakeRawConvCamera.tinyRAF())
        _ = try await conv.render(.unchanged, start: .one)
        #expect(await fake.startValues == [1])
    }

    @Test("A patched render sends exactly the patch; several renders each get and delete their own object")
    func renderPatched() async throws {
        let (conv, fake) = try await connected()
        let load = try await conv.loadRaf(data: FakeRawConvCamera.tinyRAF())
        let s = RenderSettings(filmSim: .acrosR, highlight: 1)
        let (r1, patch) = try await conv.render(s)
        #expect(await fake.renderedProfiles.last == patch.profile.bytes)
        #expect(patch.profile[8] == 0x0E && patch.profile[16] == 10)
        let (r2, _) = try await conv.render(.unchanged)
        #expect(await fake.renderedProfiles.last == load.profile.bytes)   // every render patches the base, not the last
        #expect(r1.handle != r2.handle)
        #expect(await fake.deletedHandles == [r1.handle, r2.handle])
    }

    @Test("Objects listed before the trigger (e.g. the RAF) are never taken as the render or deleted")
    func staleHandles() async throws {
        let (conv, fake) = try await connected { $0.listUploadedRAF = true }
        _ = try await conv.loadRaf(data: FakeRawConvCamera.tinyRAF())
        let r = try await conv.render(.unchanged).0
        #expect(r.data == FakeRawConvCamera.Config().renderBytes)
        #expect(r.staleHandles == [1])
        #expect(await !fake.deletedHandles.contains(1))
    }

    @Test("GetThumb for a fast preview; falls back to GetObject when refused")
    func thumbnail() async throws {
        let (conv, _) = try await connected()
        _ = try await conv.loadRaf(data: FakeRawConvCamera.tinyRAF())
        let t = try await conv.render(.unchanged, thumbnail: true).0
        #expect(t.thumbnail && t.data == FakeRawConvCamera.Config().thumbBytes && t.steps.contains { $0.name == "thumb" })

        let (conv2, _) = try await connected { $0.supportsThumb = false }
        _ = try await conv2.loadRaf(data: FakeRawConvCamera.tinyRAF())
        let f = try await conv2.render(.unchanged, thumbnail: true).0
        #expect(!f.thumbnail && f.data == FakeRawConvCamera.Config().renderBytes)
    }

    @Test("A render that never appears is a wedge, with power-cycle instructions")
    func wedge() async throws {
        let (conv, _) = try await connected({ $0.wedge = true }, renderTimeout: .milliseconds(80))
        _ = try await conv.loadRaf(data: FakeRawConvCamera.tinyRAF())
        do {
            _ = try await conv.render(.unchanged)
            Issue.record("expected a wedge")
        } catch let e as RawConvError {
            #expect(e.isWedge)
            #expect(e.description.contains("switch it OFF") && e.description.contains("power cycle"))
        }
    }

    @Test("A transport timeout mid-render (e.g. GetObject) is a wedge too")
    func timeoutIsWedge() async throws {
        let (conv, _) = try await connected { $0.timeoutOn = FujiRawConverter.Op.getObject }
        _ = try await conv.loadRaf(data: FakeRawConvCamera.tinyRAF())
        await #expect(throws: RawConvError.wedged("downloading the render (GetObject)")) { try await conv.render(.unchanged) }
    }

    @Test("A refused profile is reported with the code (not a wedge); nothing renders without a RAF")
    func refusals() async throws {
        let (conv, _) = try await connected { $0.rejectProfile = { $0 != FakeRawConvCamera.sampleProfile() } }
        await #expect(throws: RawConvError.noRafLoaded) { try await conv.render(.unchanged) }
        _ = try await conv.loadRaf(data: FakeRawConvCamera.tinyRAF())
        do {
            _ = try await conv.render(RenderSettings(highlight: 2))
            Issue.record("expected a refusal")
        } catch let RawConvError.refused(_, code, _) {
            #expect(code == PTP.Response.invalidDevicePropValue)
        }
        let ok = try await conv.render(.unchanged).0   // the camera is still usable
        #expect(ok.kind == .jpeg)
        let short = try D185Profile(FakeRawConvCamera.profile(iop: "X", params: [Int32](repeating: 0, count: 29), length: 600))
        await #expect(throws: RawConvError.profileSizeChanged(expected: 625, got: 600)) { try await conv.render(profile: short) }
    }
}
