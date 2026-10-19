// Live looks end to end over the fake camera: FujiCamera.readLive / writeLive / applyLive / restoreLive, CameraLink and
// MockCameraLink's applyLookLive / restoreLive, the snapshot file, the read-only probe helpers, and settings-patch's
// round-trip check. No hardware.
import Foundation
import Testing
@testable import DialInCamera

/// A body in USB RAW CONV./BACKUP RESTORE that advertises the slot block plus the 23 live look codes and holds a live look.
private func liveFake(state: [UInt16: Data] = MockCameraLink.defaultLiveState, extra: [UInt16] = []) async -> FakePTPCamera {
    let fake = FakePTPCamera()
    await fake.configure { f in
        let more = LiveProps.lookBlock.map(\.code) + extra
        f.advertised += more.filter { !f.advertised.contains($0) }
        for (k, v) in state { f.global[k] = v }
    }
    return fake
}

private func connected(_ fake: FakePTPCamera) async throws -> FujiCamera {
    let cam = FujiCamera(transport: fake, timing: .immediate)
    try await cam.connect()
    return cam
}

private struct Stop: Error {}

@Suite("Live control: FujiCamera")
struct LiveCameraTests {
    @Test("readLive sends nothing but GetDevicePropValue, collects refusals, drops duplicates")
    func readOnly() async throws {
        let fake = await liveFake()
        let cam = try await connected(fake)
        let r = try await cam.readLive([0xD001, 0x5005, 0xD001, 0x500F])
        #expect(r.order == [0xD001, 0x5005, 0x500F])
        #expect(r.values[0xD001] == PTPPack.u16(1) && r.values[0x5005] == PTPPack.u16(2))
        #expect(r.refused == [0x500F: PTP.Response.devicePropNotSupported])
        #expect(Set(await fake.commands.map(\.op)) == [PTP.Op.getDeviceInfo, PTP.Op.getDevicePropValue])
        #expect(await fake.writes.isEmpty)
    }

    @Test("writeLive: each write read back at once, no D18C/D18D, clean")
    func writeReadBack() async throws {
        let fake = await liveFake()
        let cam = try await connected(fake)
        let w = [PropWrite(propID: 0xD001, bytes: PTPPack.u16(11)), PropWrite(propID: 0x5005, bytes: PTPPack.u16(4))]
        let rep = try await cam.writeLive(w)
        #expect(rep.isClean && rep.written == w && rep.hints.isEmpty)
        let seq = await fake.commands.dropFirst().map { ($0.op == PTP.Op.setDevicePropValue ? "set " : "get ") + LiveHex.code(UInt16($0.params[0])) }
        #expect(seq == ["set D001", "get D001", "set 5005", "get 5005"])
        #expect(await fake.global[0xD001] == PTPPack.u16(11))
        #expect(rep.line == "live: 2/2 written")
    }

    @Test("writeLive refuses anything but a look code before sending a single command")
    func foreignCodes() async throws {
        let fake = await liveFake()
        let cam = try await connected(fake)
        for bad: UInt16 in [0xD18C, 0xD18D, 0xD17F, 0xD1A5, 0xD00A, 0x500F, 0xD208, 0xD307] {
            await #expect(throws: CameraError.self) { try await cam.writeLive([PropWrite(propID: bad, bytes: PTPPack.u16(1))]) }
        }
        let mixed = [PropWrite(propID: 0xD001, bytes: PTPPack.u16(2)), PropWrite(propID: 0xD18C, bytes: PTPPack.u16(7))]
        await #expect(throws: CameraError.self) { try await cam.writeLive(mixed) }
        await #expect(throws: CameraError.self) { try await cam.applyLive(mixed) }
        #expect(await fake.writes.isEmpty)
    }

    @Test("Refusal, didn't-stick and grain Off reading back 7 are told apart, with plain hints")
    func notes() async throws {
        let fake = await liveFake()
        await fake.configure {
            $0.rejectProps = [0xD032]
            $0.ignoreWrites = [0xD320]
            $0.readBackOverride = [0xD023: PTPPack.u16(7)]
        }
        let cam = try await connected(fake)
        let rep = try await cam.writeLive([
            PropWrite(propID: 0xD023, bytes: PTPPack.u16(1)), PropWrite(propID: 0xD320, bytes: PTPPack.i16(-10)),
            PropWrite(propID: 0xD032, bytes: PTPPack.i16(10)),
        ])
        #expect(rep.entries[0].isClean, "grain Off written as 1, read back 7 = same setting")
        #expect(rep.refused == [0xD032: PTP.Response.invalidDevicePropValue])
        #expect(rep.mismatched.count == 1 && rep.mismatched[0].hasPrefix("D320"))
        #expect(rep.hints.contains { $0.hasPrefix("clarity refused (0x201C: set drive to S") })
        #expect(rep.hints.contains { $0 == "highlight tone didn't stick (camera kept a different value)" })
        #expect(!rep.isClean)
        #expect(rep.line.contains("refused: D032 InvalidDevicePropValue") && rep.line.contains("DIDN'T STICK: D320"))
    }

    @Test("Live DR400 at low ISO steps down to DR200 and says so")
    func drStepDown() async throws {
        let fake = await liveFake()
        await fake.configure { $0.rejectDRAbove = 200 }
        let cam = try await connected(fake)
        let rep = try await cam.writeLive([PropWrite(propID: 0xD007, bytes: PTPPack.u16(400))])
        #expect(rep.written == [PropWrite(propID: 0xD007, bytes: PTPPack.u16(200))])
        #expect(rep.entries[0].stuck && !rep.isClean)
        #expect(rep.hints.first?.hasPrefix("DR stepped down to DR200") == true)
    }

    @Test("applyLive: the snapshot comes before any write (a failing save writes nothing), then writes, then reads back")
    func applyOrder() async throws {
        let fake = await liveFake(extra: [0xD307])
        await fake.configure { $0.global[0xD307] = PTPPack.u16(1) }
        let cam = try await connected(fake)
        let plan = LiveLook.writes(for: Recipe.testLook())
        await #expect(throws: Stop.self) { try await cam.applyLive(plan) { _ in throw Stop() } }
        #expect(await fake.writes.isEmpty)

        let report = try await cam.applyLive(plan)
        #expect(report.isClean)
        #expect(report.before.rawValues[0xD001] == PTPPack.u16(1), "Provia before")
        #expect(report.after[0xD001] == PTPPack.u16(11), "Classic Chrome after")
        #expect(report.before.touched == plan.map { LiveHex.code($0.propID) })
        #expect(report.before.usbMode == 6)
        #expect(report.autoUpdate == PTPPack.u16(1))
        #expect(await fake.writes == plan, "exactly the planned writes, nothing else")
        #expect(report.lines.first == "D001 film simulation: Provia (1) → Classic Chrome (11)")
    }

    @Test("applyLive skips codes GetDeviceInfo doesn't list")
    func skipsUnadvertised() async throws {
        let fake = await liveFake()
        await fake.configure { $0.advertised.removeAll { $0 == 0xD017 } }
        let cam = try await connected(fake)
        let report = try await cam.applyLive(LiveLook.writes(for: Recipe.testLook()))
        #expect(report.skipped == [0xD017])
        #expect(!(await fake.writes).contains { $0.propID == 0xD017 })
        #expect(!report.isClean && report.lines.contains { $0.contains("D017") && $0.contains("not advertised") })
    }

    @Test("restoreLive puts every touched code back, skips the ones already right, refuses another model's file")
    func restore() async throws {
        let fake = await liveFake()
        let cam = try await connected(fake)
        let report = try await cam.applyLive(LiveLook.writes(for: Recipe.testLook()))
        let r = try await cam.restoreLive(report.before)
        #expect(r.isClean, "\(r.differences)")
        let before = report.before.rawValues
        for w in report.planned {
            let now = try #require(await fake.global[w.propID])
            #expect(LiveLook.sameValue(w.propID, now, before[w.propID]!), "\(LiveHex.code(w.propID))")
        }
        #expect(Set(r.alreadyRight).isSuperset(of: [0xD02E, 0xD189, 0xD032]), "unchanged by the look, so not rewritten")
        #expect(!r.write.written.contains { r.alreadyRight.contains($0.propID) })
        #expect(r.retry == nil)

        var other = report.before
        other.model = "X-T5"
        await #expect(throws: CameraError.self) { try await cam.restoreLive(other) }
    }

    @Test("restoreLive writes only the codes the snapshot says were touched")
    func restoreTouchedOnly() async throws {
        let fake = await liveFake()
        await fake.configure { $0.global[0xD001] = PTPPack.u16(2); $0.global[0x5005] = PTPPack.u16(4) }
        let cam = try await connected(fake)
        let snap = LiveSnapshot(model: "X100VI", firmware: "1.32", values: MockCameraLink.defaultLiveState, touched: [0xD001])
        let r = try await cam.restoreLive(snap)
        #expect(r.planned.map(\.propID) == [0xD001])
        #expect(await fake.writes.map(\.propID) == [0xD001])
        #expect(await fake.global[0x5005] == PTPPack.u16(4), "WB wasn't touched by look-live, so it stays")
    }

    @Test("A write that moves another code (film sim resetting Color Chrome) gets a second pass")
    func restoreSecondPass() async throws {
        let fake = await liveFake()
        await fake.configure {
            $0.global[0xD001] = PTPPack.u16(2)
            $0.global[0xD029] = PTPPack.u16(3)
            $0.writeSideEffects = [0xD001: [0xD029: PTPPack.u16(1)]]
        }
        let cam = try await connected(fake)
        let snap = LiveSnapshot(model: "X100VI", firmware: "1.32", values: [0xD001: PTPPack.u16(11), 0xD029: PTPPack.u16(3)],
                                touched: [0xD001, 0xD029])
        let r = try await cam.restoreLive(snap)
        #expect(r.alreadyRight == [0xD029])
        #expect(r.retry?.written == [PropWrite(propID: 0xD029, bytes: PTPPack.u16(3))])
        #expect(r.isClean)
        #expect(await fake.global[0xD029] == PTPPack.u16(3))
    }
}

@Suite("Live control: CameraLink and the mock")
struct LiveLinkTests {
    @Test("CameraLink.applyLookLive: snapshot handed out first, live codes only, C1–C7 untouched; restoreLive undoes it")
    func applyAndRestore() async throws {
        let fake = await liveFake()
        await fake.seed(slot: 3, recipe: Recipe(name: "Keep", filmSim: .acros))
        let link = CameraLink(transport: fake, timing: .immediate)
        let saved = LockedValue<LiveSnapshot?>(nil)
        let report = try await link.applyLookLive(.testLook(), only: nil, onSnapshot: { saved.value = $0 })
        #expect(report.isClean)
        #expect(report.planned == LiveLook.writes(for: .testLook()))
        #expect(saved.value == report.before)
        #expect(await link.lastLiveSnapshot == report.before)
        #expect(!(await fake.writes).contains { $0.propID == FujiProp.slot || $0.propID == FujiProp.name || FujiProp.slotBlock.contains($0.propID) })
        #expect(await fake.global[0xD001] == PTPPack.u16(11))

        let r = try await link.restoreLive(report.before)
        #expect(r.isClean)
        #expect(await fake.global[0xD001] == PTPPack.u16(1))
        #expect(try await link.fujiCamera.readSlot(3).recipe?.filmSim == .acros, "slot data never changed")
    }

    @Test("--only film_sim,wb: just those writes, and the snapshot lists just them as touched")
    func only() async throws {
        let fake = await liveFake()
        let link = CameraLink(transport: fake, timing: .immediate)
        let report = try await link.applyLookLive(.testLook(), only: try LiveLook.codes(forOnly: "film_sim,wb"))
        #expect(report.planned.map(\.propID) == [0xD001, 0x5005, 0xD017])
        #expect(report.before.touched == ["D001", "5005", "D017"])
        #expect(await fake.writes.map(\.propID) == [0xD001, 0x5005, 0xD017])
        await #expect(throws: CameraError.self) { try await link.applyLookLive(.testLook(), only: [0xD104]) }   // toning on a colour look
    }

    @Test("MockCameraLink: apply + restore without hardware; .rejects applies to the live twin")
    func mock() async throws {
        let mock = MockCameraLink(searchDelay: .zero, perSlot: .zero)
        let report = try await mock.applyLookLive(.testLook())
        #expect(report.isClean && mock.liveState[0xD001] == PTPPack.u16(11))
        let r = try await mock.restoreLive(report.before)
        #expect(r.isClean && mock.liveState[0xD001] == PTPPack.u16(1))

        let rejecting = MockCameraLink(scenario: .rejects(propID: FujiProp.clarity), searchDelay: .zero, perSlot: .zero)
        let rr = try await rejecting.applyLookLive(.testLook())
        #expect(rr.write.refused == [0xD032: PTP.Response.invalidDevicePropValue] && !rr.isClean)
    }

    @Test("A conformer that predates live looks throws instead of pretending")
    func legacyConformer() async {
        await #expect(throws: CameraError.self) { try await PreLiveLink().applyLookLive(.testLook()) }
        await #expect(throws: CameraError.self) {
            try await PreLiveLink().restoreLive(LiveSnapshot(model: "", firmware: "", values: [:]))
        }
    }
}

private final class PreLiveLink: CameraLinking, @unchecked Sendable {
    var state: AsyncStream<CameraLinkState> { AsyncStream { $0.finish() } }
    var currentState: CameraLinkState { .searching }
    func connect() async throws {}
    func load(looks: [Recipe]) async throws -> LoadReport { LoadReport(slots: [], backup: SlotBackup(model: "", slots: [])) }
    func disconnect() async {}
}

@Suite("Live snapshot file and probe helpers")
struct LiveSnapshotProbeTests {
    @Test("Snapshot JSON: hex codes and bytes, decoded readings, refusals, touched; the serial never lands in it")
    func snapshotJSON() throws {
        let snap = LiveSnapshot(
            model: "X100VI", firmware: "1.10", usbMode: 6,
            values: [0xD001: PTPPack.u16(11), 0xD320: PTPPack.i16(-15), 0xD184: PTPPack.string("SN12345678X")],
            refused: [0xD017: PTP.Response.invalidDevicePropValue], touched: [0xD001], redactingSerial: "12345678",
            at: "2026-10-10T08:00:00Z")
        let json = try snap.jsonData()
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("\"D001\" : \"0b00\"") && text.contains("\"usb_mode\" : 6"))
        #expect(!text.contains("12345678"))
        #expect(snap.values["D184"] == LiveProbe.redacted)
        let back = try LiveSnapshot.decode(json)
        #expect(back == snap)
        #expect(back.rawValues[0xD001] == PTPPack.u16(11) && back.rawValues[0xD320] == PTPPack.i16(-15) && back.rawValues[0xD184] == nil)
        #expect(back.touchedCodes == [0xD001])
        #expect(back.decoded?["D001"] == "Classic Chrome (11)" && back.decoded?["D320"] == "-1.5 (-15)")
        #expect(back.refused?["D017"] == "0x201C")
        #expect(throws: CameraError.self) { try LiveSnapshot.decode(Data(#"{"schema":"x","model":"","firmware":"","at":"","values":{}}"#.utf8)) }
        #expect(throws: CameraError.self) { try LiveSnapshot.decode(Data("[]".utf8)) }
    }

    @Test("--only groups, aliases and codes; only look codes are writable")
    func onlyGroups() throws {
        #expect(try LiveLook.codes(forOnly: "film_sim") == [0xD001, 0xD104, 0xD031])
        #expect(try LiveLook.codes(forOnly: "wb, D320") == [0x5005, 0xD017, 0xD320])
        #expect(try LiveLook.codes(forOnly: "tones") == [0xD02E, 0xD320, 0xD321])
        #expect(try LiveLook.codes(forOnly: "DR,nr") == [0xD02E, 0xD007, 0xD01C])
        for bad in ["iso", "D18C", "D1A5", ",", "drive"] {
            #expect(throws: CameraError.self) { try LiveLook.codes(forOnly: bad) }
        }
        #expect(LiveLook.writableCodes.count == 19)
        #expect(LiveLook.writableCodes.isDisjoint(with: [0xD1A5, 0xD018, 0xD34D, 0xD00A, 0xD18C, 0xD18D]))
        #expect(Set(LiveLook.groups.flatMap(\.codes)) == LiveLook.writableCodes, "every writable code is reachable by a group")
        let mono = LiveLook.plan(for: .testLook(filmSim: .acros, whiteBalance: .auto, kelvin: 0), only: try LiveLook.codes(forOnly: "film_sim"))
        #expect(mono.map(\.propID) == [0xD001], "no toning in a Recipe, so none written")
    }

    @Test("restorePlan keeps the gate order and, when listed, only the touched codes")
    func restorePlan() {
        var values = MockCameraLink.defaultLiveState
        values[0x5005] = PTPPack.u16(0x8007)
        values[0xD017] = PTPPack.u16(5200)
        let full = LiveLook.restorePlan(LiveSnapshot(model: "X100VI", firmware: "", values: values))
        let codes = full.map(\.propID)
        #expect(codes.first == 0xD001 && codes.firstIndex(of: 0x5005)! < codes.firstIndex(of: 0xD017)!)
        #expect(codes.firstIndex(of: 0xD007)! < codes.firstIndex(of: 0xD02E)!)
        #expect(full.first { $0.propID == 0xD023 }?.bytes == PTPPack.u16(1), "grain 6 restored as 1")
        let some = LiveLook.restorePlan(LiveSnapshot(model: "X100VI", firmware: "", values: values, touched: [0xD017, 0x5005]))
        #expect(some.map(\.propID) == [0x5005, 0xD017])
        // Snapshot on Auto WB (Kelvin 6500 stored), camera now on Kelvin: Kelvin goes back first, while it's still writable.
        let auto = LiveSnapshot(model: "X100VI", firmware: "", values: MockCameraLink.defaultLiveState, touched: [0xD017, 0x5005])
        #expect(LiveLook.restorePlan(auto).map(\.propID) == [0x5005], "without the current state: WB only")
        let kelvinFirst = LiveLook.restorePlan(auto, current: [0x5005: PTPPack.u16(0x8007), 0xD017: PTPPack.u16(5600)])
        #expect(kelvinFirst == [PropWrite(propID: 0xD017, bytes: PTPPack.u16(6500)), PropWrite(propID: 0x5005, bytes: PTPPack.u16(2))])
        #expect(LiveLook.sameValue(0xD023, PTPPack.u16(7), PTPPack.u16(1)) && !LiveLook.sameValue(0xD023, PTPPack.u16(2), PTPPack.u16(1)))
        #expect(!LiveLook.sameValue(0xD001, PTPPack.u16(7), PTPPack.u16(1)))
    }

    @Test("Probe scopes: identity first, advertised by default, --all adds the unlisted catalog, release/format never")
    func probeScopes() {
        let adv: [UInt16] = [0xD001, 0x5005, 0xD16E, 0xD208, 0xD17F, 0xDF00, 0xD18C]
        let a = LiveProbe.codes(.advertised, advertised: adv)
        #expect(a.first == 0xD16E)
        #expect(Set(a) == [0xD16E, 0xD001, 0x5005, 0xDF00, 0xD18C])
        let all = LiveProbe.codes(.all, advertised: adv)
        #expect(all.first == 0xD16E && all.contains(0x500F) && all.contains(0xDF00))
        #expect(!all.contains(0xD208) && !all.contains(0xD17F))
        #expect(Set(all).isSuperset(of: LiveProps.lookBlock.map(\.code)))
        #expect(LiveProbe.codes(.codes([0xD208, 0xD001, 0xD208]), advertised: adv) == [0xD208, 0xD001])
        #expect(LiveHex.codes("D001, 5005,d017") == [0xD001, 0x5005, 0xD017] && LiveHex.codes("D001,zz") == nil)
    }

    @Test("Probe printing: verdicts, the watch list, decoded values, refusals, unadvertised codes")
    func probePrinting() {
        var info = PTPDeviceInfo()
        info.properties = LiveProps.lookBlock.map(\.code) + [0xD16E, 0xD307]
        info.operations = [0x1014, 0x1015, 0x1016]
        let caps = LiveCapabilities(deviceInfo: info)
        let lines = LiveProbe.summary(model: "X100VI", firmware: "1.10", usbMode: 6, caps: caps)
        #expect(lines[0] == "model X100VI · firmware 1.10 · USB mode (D16E) 6 = USB RAW CONV./BACKUP RESTORE")
        #expect(lines.contains { $0.contains("23/23 codes advertised") && $0.contains("a look can be applied live") })
        #expect(lines.contains { $0.contains("capture 0x100E: no") && $0.contains("exposure codes: none advertised") })
        #expect(lines.contains { $0.contains("D307 yes") && $0.contains("D34C no") && $0.contains("500F no") })
        let read = LiveReadResult(order: [0xD001, 0xD017, 0x500F, 0xBEEF], values: [0xD001: PTPPack.u16(11), 0xBEEF: PTPPack.string("hello")],
                                  refused: [0xD017: PTP.Response.invalidDevicePropValue, 0x500F: PTP.Response.devicePropNotSupported])
        let v = LiveProbe.valueLines(read, advertised: Set(info.properties))
        #expect(v[0].contains("D001") && v[0].contains("film simulation") && v[0].hasSuffix("Classic Chrome (11)"))
        #expect(v[1].contains("refused 0x201C InvalidDevicePropValue"))
        #expect(v[2].hasSuffix("(not advertised)"))
        #expect(v[3].contains("\"hello\""))
        #expect(LiveProbe.listLines("p", Array(0xD000...0xD010)).count == 3)
    }

    @Test("D16E read as a bitmask: 5/6/8 by name, other values by bit")
    func usbMode() {
        #expect(LiveUSBMode.label(6) == "USB RAW CONV./BACKUP RESTORE")
        #expect(LiveUSBMode.label(3) == "tether + RAW conversion")
        #expect(LiveUSBMode.label(0) == nil && LiveUSBMode.label(16) == nil)
        #expect(LiveCodec.describe(PTPPack.u16(6), for: LiveProps.usbMode) == "RAW CONV./BACKUP RESTORE (6)")
        #expect(LiveCodec.describe(PTPPack.u16(2), for: LiveProps.usbMode) == "RAW conversion (2)")
    }
}

@Suite("settings-patch (offline)")
struct SettingsPatchTests {
    @Test("--set parses like the Python patcher's N:key=value")
    func parseSet() throws {
        #expect(try FujiSettingsFile.parseSet("1:af_mode=single point") == .field(slot: 1, key: "af_mode", value: "single point"))
        #expect(try FujiSettingsFile.parseSet("C7: image_size = M") == .field(slot: 7, key: "image_size", value: "M"))
        #expect(try FujiSettingsFile.parseSet("1:af_mode=raw=2") == .field(slot: 1, key: "af_mode", value: "raw=2"))
        for bad in ["af_mode=zone", "x:af_mode=zone", "1:af_mode", "1:=zone", "1:af_mode="] {
            #expect(throws: SettingsFileError.self) { try FujiSettingsFile.parseSet(bad) }
        }
    }

    @Test("Round trip from disk: the written bytes must be the patched ones, parse, change only the edits, keep K")
    func roundTrip() throws {
        let f = try FujiSettingsFile(bytes: syntheticSettings())
        let r = try f.patched([.name(slot: 7, "DIALIN C7")])
        #expect(FujiSettingsFile.roundTripProblems(original: f, written: r.file.data, result: r).isEmpty)
        var bad = r.file.bytes
        bad[0x9000] ^= 1
        #expect(!FujiSettingsFile.roundTripProblems(original: f, written: Data(bad), result: r).isEmpty)
        #expect(FujiSettingsFile.roundTripProblems(original: f, written: Data(bad.prefix(100)), result: r).first?.contains("doesn't parse") == true)
    }
}

@Suite("Live control: the gated rehearsal camera")
struct LiveRehearsalTests {
    @Test("A Kelvin look and its undo pass every gate; the old Kelvin goes back while WB is still Kelvin")
    func kelvinRoundTrip() async throws {
        let fake = FakeLiveCamera()
        let cam = FujiCamera(transport: fake, timing: .immediate)
        try await cam.connect()
        let report = try await cam.applyLive(LiveLook.writes(for: .testLook()))   // Classic Chrome, Kelvin 5600
        #expect(report.isClean)
        let r = try await cam.restoreLive(report.before)
        #expect(r.isClean, "\(r.differences)")
        let v = await fake.values
        #expect(v[0x5005] == PTPPack.u16(2) && v[0xD017] == PTPPack.u16(6500) && v[0xD001] == PTPPack.u16(1))
        let sets = await fake.log.filter { $0.hasPrefix("set") }
        let kelvin = try #require(sets.lastIndex { $0.hasPrefix("set D017 6419") })   // 6500
        let wb = try #require(sets.lastIndex { $0.hasPrefix("set 5005 0200") })       // Auto
        #expect(kelvin < wb)
        #expect(!sets.contains { $0.hasSuffix("InvalidDevicePropValue") }, "\(sets)")
    }

    @Test("A B&W look: the planner leaves out colour-only codes, so the camera refuses nothing, and it undoes cleanly")
    func monoLook() async throws {
        let fake = FakeLiveCamera()
        let cam = FujiCamera(transport: fake, timing: .immediate)
        try await cam.connect()
        let report = try await cam.applyLive(LiveLook.writes(for: .testLook(filmSim: .acrosR, whiteBalance: .auto, kelvin: 0)))
        #expect(report.isClean)
        #expect(await fake.values[0xD001] == PTPPack.u16(14))
        let r = try await cam.restoreLive(report.before)
        let sim = await fake.values[0xD001]
        #expect(r.isClean && sim == PTPPack.u16(1))
    }

    @Test("Its gates refuse like the camera: Kelvin on Auto WB, tones under D-Range Priority, toning on colour, grain 7")
    func gates() async throws {
        var start = MockCameraLink.defaultLiveState
        start[0xD02E] = PTPPack.u16(1)
        let cam = FujiCamera(transport: FakeLiveCamera(values: start), timing: .immediate)
        try await cam.connect()
        let rep = try await cam.writeLive([
            PropWrite(propID: 0xD017, bytes: PTPPack.u16(5600)), PropWrite(propID: 0xD320, bytes: PTPPack.i16(-10)),
            PropWrite(propID: 0xD104, bytes: PTPPack.i16(20)), PropWrite(propID: 0xD023, bytes: PTPPack.u16(7)),
        ])
        #expect(rep.written.isEmpty && Set(rep.refused.values) == [PTP.Response.invalidDevicePropValue])
        #expect(rep.hints.contains { $0.contains("white balance has to be Kelvin first") })
        #expect(rep.hints.contains { $0.contains("D-Range Priority has to be Off") })
        #expect(rep.hints.contains { $0.contains("needs a B&W film simulation") })
    }
}
