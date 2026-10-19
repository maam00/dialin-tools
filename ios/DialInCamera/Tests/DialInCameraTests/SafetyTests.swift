// The safety rules for people's cameras and photos, one test (or more) per rule:
//   photos:   an import session only reads (ReadOnlyPTP); a refused operation throws before anything is sent
//   settings: a fresh backup before every write; the byte-level guard (only the chosen slots + the checksum differ);
//             protected slots; "Put my old looks back" through the same restore path, verified, same camera only;
//             an interrupted restore changes nothing and says what to do
import Foundation
import Synchronization
import Testing
@testable import DialInCamera

/// Records every transaction that reaches it (so a test can prove a refused one never did).
private final class RecordingTransport: PTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _ops: [(op: UInt16, params: [UInt32], data: Data?)] = []
    var ops: [(op: UInt16, params: [UInt32], data: Data?)] { lock.withLock { _ops } }

    func open(timeout: Duration) async throws {}
    func close() async {}
    func transact(_ operation: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult {
        lock.withLock { _ops.append((operation, params, dataOut)) }
        return PTPResult(code: PTP.Response.ok)
    }
}

@Suite("Photos are never modified: the import is read-only")
struct ReadOnlyImportTests {
    @Test("Delete, send, format, move, protect, copy…: each throws before anything is sent")
    func refusesCardWrites() async throws {
        let inner = RecordingTransport()
        let guarded = ReadOnlyPTP(inner)
        for (op, name) in ReadOnlyPTP.neverOps.sorted(by: { $0.key < $1.key }) {
            do {
                _ = try await guarded.transact(op, params: [0x0001_0001, 1], dataOut: Data([0, 1, 2, 3]), timeout: nil)
                Issue.record("\(name) went through")
            } catch let e as ImportError {
                #expect(e.description.contains("only copies photos") && e.description.contains("Nothing on the card changed"), "\(name)")
            }
            // Without a data phase too.
            await #expect(throws: ImportError.self, "\(name)") { try await guarded.transact(op, params: [1], dataOut: nil, timeout: nil) }
        }
        #expect(inner.ops.isEmpty, "nothing reached the camera")
        #expect(guarded.blocked.count == ReadOnlyPTP.neverOps.count * 2)
        for op in [PTP.Op.deleteObject, PTP.Op.sendObjectInfo, PTP.Op.sendObject, PTP.Op.formatStore, PTP.Op.moveObject,
                   PTP.Op.setObjectProtection] {
            #expect(!ReadOnlyPTP.isAllowed(op, params: [1], dataOut: nil))
        }
    }

    @Test("Property writes: only the transfer's own switches, only their values")
    func propertyWrites() async throws {
        let inner = RecordingTransport()
        let g = ReadOnlyPTP(inner)
        func set(_ prop: UInt16, _ value: Data) async -> Bool {
            (try? await g.transact(PTP.Op.setDevicePropValue, params: [UInt32(prop)], dataOut: value, timeout: nil)) != nil
        }
        #expect(await set(FujiWifiProp.forceCompression, PTPPack.u16(2)))
        #expect(await set(FujiWifiProp.forceCompression, PTPPack.u16(0)))
        #expect(await set(FujiWifiProp.realSizeInfo, PTPPack.u16(1)))
        #expect(await set(FujiWifiProp.resizeRate, PTPPack.u16(1)))
        #expect(await set(FujiWifiProp.clientState, PTPPack.u16(20)))
        #expect(await set(FujiWifiProp.remotePhotoViewExVersion, PTPPack.u32(0x0002_0001)))
        let allowed = inner.ops.count
        #expect(allowed == 6)
        #expect(!(await set(FujiWifiProp.forceCompression, PTPPack.u16(3))), "an unknown value")
        #expect(!(await set(FujiWifiProp.clientState, PTPPack.u16(6))), "remote control is not an import")
        #expect(!(await set(0xD16E, PTPPack.u16(6))), "the USB mode")
        #expect(!(await set(0xD18C, PTPPack.u16(1))), "a shooting setting (film simulation)")
        #expect(!(await set(FujiWifiProp.forceCompression, Data())), "no value")
        #expect(!(await set(FujiWifiProp.remotePhotoViewExVersion, Data(count: 8))), "too long")
        #expect(inner.ops.count == allowed, "no refused write reached the camera")
    }

    @Test("Reads pass through; a read with a data phase from us doesn't")
    func reads() async throws {
        let inner = RecordingTransport()
        let g = ReadOnlyPTP(inner)
        for op in [PTP.Op.getDeviceInfo, PTP.Op.getStorageIDs, PTP.Op.getObjectHandles, PTP.Op.getObjectInfo, PTP.Op.getObject,
                   PTP.Op.getPartialObject, PTP.Op.getThumb, PTP.Op.getDevicePropValue, PTP.Op.getObjectPropValue] {
            _ = try await g.transact(op, params: [1], dataOut: nil, timeout: nil)
        }
        #expect(inner.ops.count == 9)
        await #expect(throws: ImportError.self) { try await g.transact(PTP.Op.getObject, params: [1], dataOut: Data([1]), timeout: nil) }
        await #expect(throws: ImportError.self) { try await g.transact(0x9999, params: [], dataOut: nil, timeout: nil) }
        #expect(inner.ops.count == 9)
        #expect(ReadOnlyPTP.guarding(g) === g, "never wrapped twice")
    }

    @Test("A whole Wi-Fi import sends only allowlisted commands and changes nothing on the card")
    func wifiImportIsReadOnly() async throws {
        let run = try await WifiRun(behavior: .init(), olderCount: 1, todayCount: 3)
        defer { run.cleanup() }
        let before = run.fake.frames.map { ($0.name, $0.data) }
        let s = try await run.importAll()
        await run.cam.close()
        #expect(s.saved.count == 4)                                  // 3 JPEGs + 1 RAF today
        try run.expectFilesIdentical(s)
        let record = try await run.recordAfterClose()
        for c in record.commands where c.op != PTP.Op.openSession && c.op != PTP.Op.closeSession {
            if c.op == PTP.Op.setDevicePropValue {
                #expect(ReadOnlyPTP.allowedPropWrites.keys.contains(UInt16(truncatingIfNeeded: c.params.first ?? 0)))
            } else {
                #expect(ReadOnlyPTP.readOps.contains(c.op), "0x\(String(c.op, radix: 16)) isn't a read")
            }
        }
        for p in record.sets { #expect(ReadOnlyPTP.isAllowed(PTP.Op.setDevicePropValue, params: [UInt32(p.prop)], dataOut: p.value)) }
        #expect(!record.commands.contains { ReadOnlyPTP.neverOps[$0.op] != nil })
        #expect(await run.cam.refusedOperations.isEmpty)
        #expect(run.fake.frames.map { ($0.name, $0.data) }.elementsEqual(before, by: { $0 == $1 }), "the card is as it was")
    }

    @Test("A USB card import (PTPCardSource over any transport) sends only reads")
    func usbImportIsReadOnly() async throws {
        let fake = FakeUSBCard(files: [
            .init(handle: 0x20, name: "DSCF0001.JPG", data: SyntheticJPEG.make(dateTimeOriginal: exifDate("2026-10-09"), payloadBytes: 40_000),
                  date: ptpDate("2026-10-09")),
        ])
        let root = try TempDir.make("usb-ro")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try await PhotoImporter.run(source: PTPCardSource(transport: fake, layout: .standard, route: .usb),
                                            library: ImportLibrary(root: root), options: ImportOptions(since: "2026-10-09"))
        #expect(s.saved.count == 1)
        #expect(fake.log.allSatisfy { ReadOnlyPTP.readOps.contains($0.op) })
    }
}

// MARK: - Camera settings

/// A paired (adopted) pretend camera, as after the app's pairing.
private func pairedCamera(_ scenario: FakeFujiBLECamera.Scenario = .ok) async throws -> FakeFujiBLECamera {
    let cam = FakeFujiBLECamera(scenario: scenario)
    _ = try await cam.adoptRegisteredKey(timeout: .milliseconds(10))
    return cam
}

/// The person changes a menu setting on the camera (a byte outside C1–C7), as the camera would store it.
@discardableResult
private func changeMenu(_ cam: FakeFujiBLECamera, at offset: Int = 0x9000) -> UInt8 {
    var b = [UInt8](cam.settings)
    b[offset] &+= 1
    cam.settings = Data(FakeFujiBLECamera.restamp(b, from: [UInt8](cam.settings)))
    return b[offset]
}

private let sunrise = Recipe(name: "Morning sand", filmSim: .classicChrome, grain: .weakSmall, whiteBalance: .daylight,
                             wbShiftR: 1, wbShiftB: -2, highlight: -0.5, shadow: 0.5, color: 1, noiseReduction: -4, clarity: 1)
private let dusk = Recipe(name: "Dusk faces", filmSim: .realaAce, whiteBalance: .kelvin, kelvin: 6300, wbShiftR: 1, wbShiftB: -2,
                          dynamicRange: .dr200, highlight: -0.5, shadow: 0.5, color: 1, noiseReduction: -4, clarity: -1)
private func placements() -> [FujiSettingsFile.LookPlacement] { [.init(slot: 3, recipe: sunrise), .init(slot: 5, recipe: dusk)] }

private final class Box<T: Sendable>: Sendable {
    let value: Mutex<T?> = Mutex(nil)
    func set(_ v: T) { value.withLock { $0 = v } }
    var get: T? { value.withLock { $0 } }
}

@Suite("Camera settings: back up, patch narrowly, verify")
struct SettingsSafetyTests {
    @Test("Guard: a real patch passes; a byte outside the chosen slots is refused")
    func guardBasics() throws {
        let fresh = FakeFujiBLECamera.sampleSettings()
        let patch = try FujiSettingsFile(fresh).applyingLooks(placements())
        try RestoreGuard.check(patch.file.data, against: fresh, slots: [3, 5])
        // The same patch claimed for C3 only: C5's bytes are now "outside".
        #expect(throws: RestoreGuard.Refusal.self) { try RestoreGuard.check(patch.file.data, against: fresh, slots: [3]) }
        // One stray byte in C2 (a slot we weren't asked to change), checksum kept consistent.
        let file = try FujiSettingsFile(patch.file.data)
        var stray = file.bytes
        stray[file.anchors[1] + 0x64] &+= 1
        let fixed = FakeFujiBLECamera.restamp(stray, from: file.bytes)
        do {
            try RestoreGuard.check(Data(fixed), against: fresh, slots: [3, 5])
            Issue.record("a C2 byte went through")
        } catch let r as RestoreGuard.Refusal {
            #expect(r.reason.contains("outside C3 and C5"))
        }
    }

    @Test("Guard refuses a menu byte, the header, the frame counter, the checksum's high half, a size change, a wrong checksum")
    func guardRefusals() throws {
        let fresh = FakeFujiBLECamera.sampleSettings()
        let base = try FujiSettingsFile(fresh).applyingLooks(placements()).file.bytes
        func restamped(_ edit: (inout [UInt8]) -> Void) -> Data {
            var b = base
            edit(&b)
            return Data(FakeFujiBLECamera.restamp(b, from: base))
        }
        let cases: [(String, Data)] = [
            ("a menu setting", restamped { $0[0x9000] &+= 1 }),
            ("the header (serial)", restamped { $0[0x40] &+= 1 }),
            ("the frame counter", restamped { $0[FujiSettingsFile.frameCounterBlock.lowerBound] &+= 1 }),
            ("the checksum's high half", { var b = base; b[FujiSettingsFile.checksumOffset + 2] &+= 1; return Data(b) }()),
            ("a size change", Data(base + [0])),
            ("a wrong checksum", { var b = base; b[FujiSettingsFile.checksumOffset] &+= 1; return Data(b) }()),
        ]
        for (what, data) in cases {
            #expect(throws: RestoreGuard.Refusal.self, "\(what)") { try RestoreGuard.check(data, against: fresh, slots: [3, 5]) }
        }
    }

    @Test("Writer: a patched file with an out-of-slot byte is refused, and nothing is sent")
    func writerGuard() async throws {
        let cam = try await pairedCamera()
        let before = cam.settings
        do {
            _ = try await BLESlotWriter.write(placements(), to: cam, allowInferred: false, codes: .x100vi, protectedSlots: [],
                                              timing: .immediate, onBackup: { _ in }, onStep: { _ in }, tamper: { d in
                var b = [UInt8](d)
                b[0x9000] &+= 1                               // a menu byte, far from C3 and C5
                return Data(FakeFujiBLECamera.restamp(b, from: [UInt8](d)))
            })
            Issue.record("the tampered file went through")
        } catch BLESlotWriter.WriteError.guardRefused(let why) {
            #expect(why.contains("outside C3 and C5") && why.contains("Nothing was written"))
        }
        #expect(cam.record.restoreRequests == 0 && cam.record.framesReceived == 0 && cam.settings == before)
    }

    @Test("Writer: a fresh backup right before every write, so a menu change made since an older backup survives")
    func freshBackupEveryWrite() async throws {
        let cam = try await pairedCamera()
        let older = try await BLESlotWriter.readSlots(from: cam, timing: .immediate).backup
        let changed = changeMenu(cam)                  // after the older backup: the person changed a menu
        let atWrite = cam.settings
        #expect(atWrite != older)
        let handed = Box<Data>()
        let out = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { handed.set($0) })
        #expect(out.result == .verified)
        #expect(handed.get == atWrite && out.backup == atWrite, "B0 is the camera's file at write time, not the older one")
        #expect(cam.settings[0x9000] == changed, "the menu change is still on the camera")
        let now = try FujiSettingsFile(cam.settings)
        #expect(now.mismatches(slot: 3, against: sunrise).isEmpty && now.mismatches(slot: 5, against: dusk).isEmpty)
        // Two writes, two fresh backups: the second B0 holds the first write's looks.
        let second = try await BLESlotWriter.write([.init(slot: 6, recipe: sunrise)], to: cam, timing: .immediate, onBackup: { _ in })
        #expect(try FujiSettingsFile(second.backup).name(slot: 3) == "Morning sand")
        #expect(cam.record.backupRequests >= 5)
    }

    @Test("Protected slots: the writer refuses before contacting the camera")
    func protectedWrite() async throws {
        let cam = try await pairedCamera()
        do {
            _ = try await BLESlotWriter.write(placements(), to: cam, protectedSlots: [1, 2, 3], timing: .immediate,
                                              onBackup: { _ in Issue.record("no backup expected") })
            Issue.record("expected a refusal")
        } catch BLESlotWriter.WriteError.protectedSlots(let slots) {
            #expect(slots == [3])
            #expect(BLESlotWriter.WriteError.protectedSlots(slots).description.contains("C3 is protected"))
        }
        #expect(cam.record.connections == 0 && cam.record.backupRequests == 0 && cam.record.restoreRequests == 0)
        // Outside the protected ones it writes as usual.
        let out = try await BLESlotWriter.write(placements(), to: cam, protectedSlots: [1, 2], timing: .immediate, onBackup: { _ in })
        #expect(out.result == .verified)
    }

    @Test("UndoFile: only the chosen slots come from the old file; every other byte is the camera's now")
    func undoFile() throws {
        let old = FakeFujiBLECamera.sampleSettings()
        let written = try FujiSettingsFile(old).applyingLooks(placements()).file.bytes
        var nowBytes = written
        nowBytes[0x9000] &+= 1
        let now = Data(FakeFujiBLECamera.restamp(nowBytes, from: written))
        let undo = try UndoFile.make(old: old, onto: now, slots: [3, 5])
        let u = try FujiSettingsFile(undo), o = try FujiSettingsFile(old), n = try FujiSettingsFile(now)
        for s in [3, 5] { #expect(u.bytes[u.slotRegion(s)] == o.bytes[o.slotRegion(s)]) }
        for s in [1, 2, 4, 6, 7] { #expect(u.bytes[u.slotRegion(s)] == n.bytes[n.slotRegion(s)]) }
        #expect(u.bytes[0x9000] == n.bytes[0x9000])
        try RestoreGuard.check(undo, against: now, slots: [3, 5])
        #expect(u.checksumConstant == n.checksumConstant)
        #expect(try UndoFile.make(old: now, onto: now, slots: [3]) == now, "nothing to change: the same file")
    }
}

@Suite("Put my old looks back (rehearsal camera)")
struct PutOldLooksBackTests {
    /// A camera that got C3 + C5 from Dial In; returns it and the pre-write backup.
    private func cameraAfterWrite(_ scenario: FakeFujiBLECamera.Scenario = .ok) async throws -> (FakeFujiBLECamera, Data) {
        let cam = try await pairedCamera()
        let out = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in })
        #expect(out.result == .verified)
        cam.scenario = scenario
        return (cam, out.backup)
    }

    @Test("The old looks come back, read back and verified; a menu change made since survives; the fresh file is kept first")
    func putBack() async throws {
        let (cam, b0) = try await cameraAfterWrite()
        let changed = changeMenu(cam)
        let beforeRestore = cam.settings
        let kept = Box<Data>()
        let restoresAtFresh = Mutex<Int?>(nil)
        let out = try await BLESlotWriter.restore(b0, slots: [3, 5], to: cam, backupFirmware: "1.10", timing: .immediate,
                                                  onFresh: { d in
                                                      restoresAtFresh.withLock { $0 = cam.record.restoreRequests }
                                                      kept.set(d)
                                                  })
        #expect(out.result == .verified)
        #expect(kept.get == beforeRestore && restoresAtFresh.withLock { $0 } == 1, "kept before anything was sent")
        let now = try FujiSettingsFile(cam.settings), old = try FujiSettingsFile(b0)
        for s in 1...7 { #expect(now.bytes[now.slotRegion(s)] == old.bytes[old.slotRegion(s)], "C\(s)") }
        #expect(now.names[2] == "Deep blue sea" && now.names[4] == "Faded dock")
        #expect(cam.settings[0x9000] == changed, "everything else stays as the camera has it now")
        #expect(out.slots == [3, 5] && out.lines.contains { $0.contains("verified") })
    }

    @Test("Already there: nothing is sent")
    func alreadyThere() async throws {
        let cam = try await pairedCamera()
        let b = cam.settings
        let out = try await BLESlotWriter.restore(b, slots: [3, 5], to: cam, timing: .immediate, onFresh: { _ in })
        #expect(out.result == .alreadyThere && out.written == nil)
        #expect(cam.record.restoreRequests == 0)
    }

    @Test("Another camera's backup is refused (serial), before anything is written")
    func otherCamera() async throws {
        let (cam, b0) = try await cameraAfterWrite()
        var other = [UInt8](b0)
        other.replaceSubrange(0x34..<0x44, with: Array("SOMEONEELSES9F31".utf8))
        let foreign = Data(FakeFujiBLECamera.restamp(other, from: [UInt8](b0)))
        let before = cam.settings
        do {
            _ = try await BLESlotWriter.restore(foreign, slots: [3], to: cam, timing: .immediate, onFresh: { _ in Issue.record("no fresh backup kept") })
            Issue.record("expected a refusal")
        } catch BLESlotWriter.WriteError.differentCamera(let why) {
            #expect(why.contains("··9F31") && why.contains("··SAL1") && why.contains("Nothing was written"))
        }
        #expect(cam.record.restoreRequests == 1 && cam.settings == before, "only the earlier write's restore")
    }

    @Test("A backup from other firmware, or with no serial, is refused")
    func firmwareAndSerial() async throws {
        let (cam, b0) = try await cameraAfterWrite()
        await #expect(throws: BLESlotWriter.WriteError.differentCamera("This backup was made on firmware 1.11, and the camera now runs 1.10. Nothing was written.")) {
            try await BLESlotWriter.restore(b0, slots: [3], to: cam, backupFirmware: "Ver1.11", timing: .immediate, onFresh: { _ in })
        }
        var blank = [UInt8](b0)
        blank.replaceSubrange(0x34..<0x54, with: [UInt8](repeating: 0, count: 32))
        let noSerial = Data(FakeFujiBLECamera.restamp(blank, from: [UInt8](b0)))
        await #expect(throws: BLESlotWriter.WriteError.self) {
            try await BLESlotWriter.restore(noSerial, slots: [3], to: cam, timing: .immediate, onFresh: { _ in })
        }
        #expect(cam.record.restoreRequests == 1)
    }

    @Test("A protected slot is refused before the camera is contacted")
    func protectedRestore() async throws {
        let (cam, b0) = try await cameraAfterWrite()
        let connections = cam.record.connections
        await #expect(throws: BLESlotWriter.WriteError.protectedSlots([3])) {
            try await BLESlotWriter.restore(b0, slots: [3, 5], to: cam, protectedSlots: [1, 2, 3], timing: .immediate, onFresh: { _ in })
        }
        #expect(cam.record.connections == connections)
    }

    @Test("The link drops mid-transfer: unverified state and recovery steps")
    func interrupted() async throws {
        let (cam, b0) = try await cameraAfterWrite(.dropsLink(atFrame: 200))
        let before = cam.settings
        let out = try await BLESlotWriter.restore(b0, slots: [3, 5], to: cam, timing: .immediate, onFresh: { _ in })
        guard case .notVerified(let line) = out.result else { Issue.record("got \(out.result)"); return }
        #expect(line.contains("could not be verified") && line.hasSuffix(BLESlotWriter.restoreRecovery))
        #expect(BLESlotWriter.restoreRecovery == "Turn the camera off and on, then tap Put my old looks back.")
        #expect(cam.settings == before)
        // Then, as the steps say: off and on, and again.
        cam.scenario = .ok
        cam.powerCycle()
        let again = try await BLESlotWriter.restore(b0, slots: [3, 5], to: cam, timing: .immediate, onFresh: { _ in })
        #expect(again.result == .verified)
    }

    @Test("Applies after a power cycle: pending, then 'already there' after the restart")
    func pendingThenThere() async throws {
        let (cam, b0) = try await cameraAfterWrite(.appliesAfterPowerCycle)
        let out = try await BLESlotWriter.restore(b0, slots: [3, 5], to: cam, timing: .immediate, onFresh: { _ in })
        #expect(out.result == .pendingPowerCycle)
        cam.powerCycle()
        let again = try await BLESlotWriter.restore(b0, slots: [3, 5], to: cam, timing: .immediate, onFresh: { _ in })
        #expect(again.result == .alreadyThere)
        #expect(try FujiSettingsFile(cam.settings).names[2] == "Deep blue sea")
    }

    @Test("A camera that stores something else after the undo: not verified, with the recovery steps")
    func notVerified() async throws {
        let (cam, b0) = try await cameraAfterWrite()
        cam.mangleNextApply { b in
            var b = b
            b[0xF800 + 0x64] = 4   // C1, a slot we didn't put back
            return b
        }
        let out = try await BLESlotWriter.restore(b0, slots: [3, 5], to: cam, timing: .immediate, onFresh: { _ in })
        guard case .notVerified(let line) = out.result else { Issue.record("got \(out.result)"); return }
        #expect(line.hasSuffix(BLESlotWriter.restoreRecovery))
    }

    @Test("Backup identity: serial suffix only, same camera = same model and serial")
    func identity() {
        let a = BackupIdentity(FakeFujiBLECamera.sampleSettings())
        #expect(a.model == "X100VI" && a.serial == "DIALINREHEARSAL1" && a.serialSuffix == "SAL1")
        #expect(a.isSameCamera(as: a))
        #expect(!a.isSameCamera(as: BackupIdentity(model: "X100VI", serial: "OTHER")))
        #expect(!BackupIdentity(model: "X100VI", serial: "").isSameCamera(as: BackupIdentity(model: "X100VI", serial: "")))
    }
}
