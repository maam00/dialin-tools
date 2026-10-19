// Write order and gating against a fake camera (no hardware). The first three tests port
// scripts/test-writer.ts check for check; the rest cover the rest of camera.ts.
import Foundation
import Testing
@testable import DialInCamera

@Suite("FujiCamera writer")
struct WriterTests {
    func connected(_ fake: FakePTPCamera, timing: FujiCamera.Timing = .immediate) async throws -> FujiCamera {
        let cam = FujiCamera(transport: fake, timing: timing)
        try await cam.connect()
        return cam
    }

    // MARK: test-writer.ts

    @Test("Clean write: name first, never D18E/D18F/D1A3/D1A4/D1A5, D191 before D190 and Off, Kelvin right after WB, film sim first")
    func cleanWrite() async throws {
        let fake = FakePTPCamera()
        let cam = try await connected(fake)
        let res = try await cam.writeSlot(3, name: "Amber Dusk", values: PresetValues(recipe: .testLook()), base: Fixture.vectorBase)
        let w = await fake.writes.map(\.propID).filter { $0 != FujiProp.slot }
        #expect(w.first == FujiProp.name, "name written first")
        #expect(!w.contains { FujiProp.neverWritten.contains($0) }, "never writes D18E/D18F/D1A3/D1A4/D1A5")
        let i191 = try #require(w.firstIndex(of: FujiProp.dRangePriority))
        let i190 = try #require(w.firstIndex(of: FujiProp.dynamicRange))
        #expect(i191 < i190, "D-Range Priority (D191) before DR (D190)")
        let slot3 = await fake.slots[3] ?? [:]
        #expect(slot3[FujiProp.dRangePriority] == Data([0, 0]), "D-Range Priority forced Off")
        let i199 = try #require(w.firstIndex(of: FujiProp.whiteBalance))
        #expect(w.firstIndex(of: FujiProp.colorTemperature) == i199 + 1, "Kelvin (D19C) right after WB (D199)")
        #expect(w.firstIndex(of: FujiProp.filmSimulation) == 1, "film sim is the first setting")
        #expect(res.mismatched.isEmpty && res.rejected.isEmpty, "clean write reads back identical")
    }

    @Test("Mono look skips colour-only props and Kelvin")
    func monoSkips() async throws {
        let fake = FakePTPCamera()
        let cam = try await connected(fake)
        try await cam.writeSlot(1, name: "Hard Noir", values: PresetValues(recipe: .testLook(filmSim: .acrosR, whiteBalance: .auto, kelvin: 0)), base: Fixture.vectorBase)
        let w = await fake.writes.map(\.propID)
        let skipped: [UInt16] = [0xD196, 0xD197, 0xD19A, 0xD19B, 0xD19F, 0xD19C]
        #expect(!skipped.contains { w.contains($0) })
    }

    @Test("DR400 refused → stepped down to DR200, and reported")
    func drStepDown() async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.rejectDRAbove = 200 }
        let cam = try await connected(fake)
        let res = try await cam.writeSlot(2, name: "Low ISO", values: PresetValues(recipe: .testLook()), base: Fixture.vectorBase)
        let dr = await fake.slots[2]?[FujiProp.dynamicRange]
        #expect(dr == PTPPack.u16(200), "DR400 refused → stepped down to DR200")
        #expect(res.rejected.contains { $0.contains("DR200") }, "step-down reported")
        #expect(res.mismatched.isEmpty, "the stepped-down value is what we verify against")
    }

    // MARK: More camera.ts behaviour

    @Test("DR refused at every level is reported as a rejection, not a crash")
    func drRefusedEntirely() async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.rejectDRAbove = 50 }
        let cam = try await connected(fake)
        let res = try await cam.writeSlot(2, name: "No DR", values: PresetValues(recipe: .testLook()), base: Fixture.vectorBase)
        #expect(res.rejected == ["0xd190=9001"])
        let drWrites = await fake.writes.filter { $0.propID == FujiProp.dynamicRange }.map(\.bytes)
        #expect(drWrites == [PTPPack.u16(400), PTPPack.u16(200), PTPPack.u16(100)])
    }

    @Test("Refused clarity uses the camera.ts hint and the rest still lands")
    func clarityHint() async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.rejectProps = [FujiProp.clarity] }
        let cam = try await connected(fake)
        let res = try await cam.writeSlot(4, name: "Burst", values: PresetValues(recipe: .testLook()), base: Fixture.vectorBase)
        #expect(res.rejected == ["clarity skipped (camera must be in single-shot drive mode)"])
        #expect(res.written.count == res.attempted - 1)
    }

    @Test("A write that answers OK but doesn't stick is caught by read-back")
    func didntStick() async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.ignoreWrites = [FujiProp.highlight] }
        await fake.seed(slot: 5, recipe: Recipe(name: "Old", filmSim: .provia))
        let cam = try await connected(fake)
        let res = try await cam.writeSlot(5, recipe: .testLook(name: "New"))
        #expect(res.mismatched == ["0xd19d wrote f6ff read 0000"])
        #expect(res.line.contains("DIDN'T STICK"))
    }

    @Test("A name that reads back different is reported")
    func nameMismatch() async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.ignoreWrites = [FujiProp.name] }
        await fake.seed(slot: 6, recipe: Recipe(name: "Old Name", filmSim: .provia))
        let cam = try await connected(fake)
        let res = try await cam.writeSlot(6, recipe: .testLook(name: "Fresh"))
        #expect(res.mismatched == ["name wrote \"Fresh\" read \"Old Name\""])
    }

    @Test("Without a base, writeSlot reads the slot first (selecting it), then selects again to write")
    func readsBaseWhenMissing() async throws {
        let fake = FakePTPCamera()
        await fake.seed(slot: 2, recipe: Recipe(name: "Before", filmSim: .astia))
        let cam = try await connected(fake)
        try await cam.writeSlot(2, recipe: .testLook())
        let selects = await fake.writes.filter { $0.propID == FujiProp.slot }
        #expect(selects == [PropWrite(propID: FujiProp.slot, bytes: PTPPack.u16(2)), PropWrite(propID: FujiProp.slot, bytes: PTPPack.u16(2))])
    }

    @Test("readSlot selects the slot, reads the name, then D18E…D1A4 — never D1A5")
    func readSlotBlock() async throws {
        let fake = FakePTPCamera()
        await fake.seed(slot: 3, recipe: .testLook(name: "Seeded"))
        let cam = try await connected(fake)
        let snap = try await cam.readSlot(3)
        let reads = await fake.reads
        #expect(reads.first == FujiProp.name)
        #expect(Array(reads.dropFirst()) == Array(FujiProp.slotBlock))
        #expect(!reads.contains(FujiProp.liveImageSize))
        #expect(snap.name == "Seeded")
        #expect(snap.recipe == .testLook(name: "Seeded"))
        let firstCommand = await fake.commands.first { $0.op == PTP.Op.setDevicePropValue }
        #expect(firstCommand?.params == [UInt32(FujiProp.slot)])
    }

    @Test("restore re-applies a non-zero D-Range Priority after the tones (keepDrPriority)")
    func restoreKeepsDrPriority() async throws {
        let fake = FakePTPCamera()
        let cam = try await connected(fake)
        var props = SlotEncoder.presetProps(PresetValues(recipe: .testLook())).map { RawProp(id: $0.propID, bytes: $0.bytes) }
        props.removeAll { $0.id == FujiProp.dRangePriority || $0.id == FujiProp.liveImageSize }
        props.append(RawProp(id: FujiProp.dRangePriority, bytes: PTPPack.u16(2)))
        let snap = SlotSnapshot(slot: 4, name: "Kept DRP", rawProps: props)
        try await cam.restore([snap])
        let drp = await fake.writes.filter { $0.propID == FujiProp.dRangePriority }.map(\.bytes)
        #expect(drp == [PTPPack.u16(0), PTPPack.u16(2)], "forced off for the tones, then the slot's own value back")
        #expect(await fake.slots[4]?[FujiProp.dRangePriority] == PTPPack.u16(2))
    }

    @Test("Slot writes are spaced: 100 ms after selecting, ≥20 ms between props (camera timing)")
    func timing() async throws {
        let fake = FakePTPCamera()
        let cam = try await connected(fake, timing: .camera)
        try await cam.writeSlot(7, recipe: .testLook(), base: Fixture.vectorBase, verify: false)
        let cmds = await fake.commands.filter { $0.op == PTP.Op.setDevicePropValue }
        #expect(cmds.count >= 3)
        #expect(cmds[1].at - cmds[0].at >= .milliseconds(100), "settle after D18C")
        for (a, b) in zip(cmds.dropFirst(), cmds.dropFirst(2)) {
            #expect(b.at - a.at >= .milliseconds(20))
        }
    }

    @Test("Slot numbers outside 1–7 are refused before touching the camera")
    func slotRange() async throws {
        let fake = FakePTPCamera()
        let cam = try await connected(fake)
        await #expect(throws: CameraError.self) { try await cam.writeSlot(8, recipe: .testLook(), base: []) }
        #expect(await fake.writes.isEmpty)
    }

    // MARK: Session, backup file, settings file

    @Test("connect: GetDeviceInfo model/props; a camera without D18C needs USB RAW CONV. mode")
    func connectGating() async throws {
        let fake = FakePTPCamera()
        let cam = try await connected(fake)
        #expect(await cam.model == "X100VI")
        #expect(await cam.canEditSlots)
        #expect(await cam.firmware == "1.32")

        let wrongMode = FakePTPCamera()
        await wrongMode.configure { $0.advertised = [0x5001, 0xD16E] }
        let cam2 = FujiCamera(transport: wrongMode, timing: .immediate)
        await #expect {
            try await cam2.connect()
        } throws: { error in
            guard case CameraError.needsUSBMode = error else { return false }
            return true
        }

        let cardReader = FakePTPCamera()
        await cardReader.configure { $0.failDeviceInfo = true }
        let cam3 = FujiCamera(transport: cardReader, timing: .immediate)
        await #expect {
            try await cam3.connect()
        } throws: { error in
            guard case CameraError.needsUSBMode = error else { return false }
            return true
        }
    }

    @Test("readAll/backup writes the same JSON shape as `npm run cam backup`")
    func backupJSONShape() async throws {
        let fake = FakePTPCamera()
        for s in 1...7 { await fake.seed(slot: s, recipe: .testLook(name: "Slot \(s)")) }
        let cam = try await connected(fake)
        let backup = try await cam.backup()
        #expect(backup.slots.map(\.slot) == Array(1...7))
        let json = try #require(try JSONSerialization.jsonObject(with: backup.jsonData()) as? [String: Any])
        #expect(Set(json.keys) == ["model", "at", "slots"])
        #expect(json["model"] as? String == "X100VI")
        let at = try #require(json["at"] as? String)
        #expect(at.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z/) != nil, "toISOString() format: \(at)")
        let slots = try #require(json["slots"] as? [[String: Any]])
        #expect(Set(slots[0].keys) == ["slot", "name", "props"])
        let props = try #require(slots[0]["props"] as? [[String: Any]])
        #expect(Set(props[0].keys) == ["id", "hex"])
        #expect(props[0]["id"] as? Int == 0xD18E, "ids are plain JSON numbers")
        #expect(props.count == 21, "D18E…D1A4 is 23 codes; a colour slot holds no mono toning (D193/D194)")
        // And a TS-written file decodes.
        let ts = #"{"model":"X100VI","at":"2026-10-09T15:04:05.123Z","slots":[{"slot":1,"name":"Warm Gold","props":[{"id":53650,"hex":"0b00"},{"id":53648,"hex":"9001"}]}]}"#
        let decoded = try SlotBackup.decode(Data(ts.utf8))
        #expect(decoded.slots[0].rawProps == [RawProp(id: 0xD192, bytes: Data([0x0B, 0])), RawProp(id: 0xD190, bytes: Data([0x90, 0x01]))])
        #expect(decoded.slots[0].values.filmSimulation == FujiFilmSim.classicChrome)
    }

    @Test("Settings file: GetObjectInfo(0)+GetObject(0) down; 1076-byte ObjectInfo + SendObject up; magic checked")
    func settingsFile() async throws {
        var file = Data("FUJIFILMX-BACKUP".utf8) + Data("0100".utf8)
        file += Data(count: 33_404 - file.count)
        let fake = FakePTPCamera()
        await fake.configure { [file] in $0.settingsFile = file }
        let cam = try await connected(fake)
        #expect(try await cam.getSettingsFile() == file)

        try await cam.putSettingsFile(file)
        let sent = await fake.commands.filter { $0.op == PTP.Op.sendObjectInfo || $0.op == PTP.Op.sendObject }
        #expect(sent.map(\.op) == [PTP.Op.sendObjectInfo, PTP.Op.sendObject])
        #expect(sent[0].params == [0, 0])
        let oi = try #require(sent[0].dataOut)
        #expect(oi.count == 1076)
        #expect([UInt8](oi[4..<6]) == [0x00, 0x50], "ObjectFormat 0x5000")
        #expect([UInt8](oi[8..<12]) == [0x7C, 0x82, 0x00, 0x00], "CompressedSize = 33404")
        #expect(oi[12...].allSatisfy { $0 == 0 })
        #expect(sent[1].params.isEmpty && sent[1].dataOut == file)

        await #expect(throws: CameraError.invalid("Not a FUJIFILMX-BACKUP file")) { try await cam.putSettingsFile(Data(count: 100)) }
    }
}
