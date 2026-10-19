import Foundation
import Testing
@testable import DialInCamera

@Suite("Camera safety regressions", .serialized)
struct SafetyRegressionTests {
    @Test("Malformed readback stops recovery instead of restoring unrelated settings")
    func rollbackRefusesUnsafeFallback() async throws {
        let camera = FakeFujiBLECamera()
        _ = try await camera.adoptRegisteredKey(timeout: .milliseconds(10))
        let original = camera.settings
        camera.mangleNextApply { bytes in
            var out = bytes
            out[0xA0] ^= 1 // Inconsistent payload length: the fresh readback no longer parses.
            out[0x600] ^= 1 // An unrelated setting changed on the camera.
            return out
        }
        let look = Recipe(name: "Audit look", filmSim: .classicChrome, noiseReduction: -4)
        let result = try await BLESlotWriter.write([.init(slot: 7, recipe: look)], to: camera,
                                                   timing: .immediate, onBackup: { _ in })
        #expect(result.result == .notVerified)
        #expect(camera.record.restoreRequests == 1)
        #expect(camera.record.applied == 1)
        #expect(camera.settings[0x600] != original[0x600])
    }

    @Test("An incomplete JPEG is never published as an original")
    func originalMustBeComplete() async throws {
        var frames = FakeFujiWifiCamera.sampleCard(day: "2026-10-09", todayCount: 1, olderCount: 0, jpegBytes: 12000)
        let index = try #require(frames.firstIndex { $0.name.hasSuffix(".JPG") })
        frames[index].data = frames[index].data.dropLast(2) // Camera transfer ends without JPEG EOI.
        let fake = FakeFujiWifiCamera(frames: frames)
        let port = try await fake.start()
        defer { fake.stop() }
        let root = try TempDir.make("audit-original")
        defer { try? FileManager.default.removeItem(at: root) }
        let camera = ImportResizedTests.camera(port: port, size: .original)
        let items = try await camera.list(hint: ListHint(since: "2026-10-09"))
        let item = try #require(items.first { $0.kind == .jpeg })
        let dest = root.appendingPathComponent("original.JPG")
        await #expect(throws: ImportError.self) { try await OriginalJPEG.download(item, from: camera, to: dest) }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(!JPEGCheck.isComplete(dest))
        await camera.close()
    }

    @Test("A partially landed check is not verified")
    func partiallyLandedCheck() async throws {
        let a = Recipe(name: "Audit A", filmSim: .classicChrome, noiseReduction: -4)
        let b = Recipe(name: "Audit B", filmSim: .classicChrome, noiseReduction: -4)
        let camera = FakeFujiBLECamera()
        _ = try await camera.adoptRegisteredKey(timeout: .milliseconds(10))
        camera.settings = try FujiSettingsFile(camera.settings).applyingLooks([.init(slot: 3, recipe: a)]).file.data
        let result = try await BLESlotWriter.check([.init(slot: 3, recipe: a), .init(slot: 5, recipe: b)],
                                                 on: camera, timing: .immediate)
        #expect(result.result == .notVerified)
        #expect(result.verdicts.filter(\.isConfirmed).count == 1)
    }
}

@Suite("USB transaction safety")
struct USBTransactionTests {
    let look = Recipe(name: "New C3", filmSim: .classicChrome, noiseReduction: -4)

    @Test func failedBackupPreventsEveryWrite() async throws {
        let fake = FakePTPCamera()
        let link = CameraLink(transport: fake, timing: .immediate)
        await #expect(throws: CocoaError.self) {
            try await link.load(placements: [.init(slot: 3, recipe: look)], protectedSlots: [],
                onBackup: { _ in throw CocoaError(.fileWriteOutOfSpace) }, onSlot: { _ in })
        }
        #expect(try await link.fujiCamera.readSlot(3).name == "C3")
        #expect(await link.lastBackup?.slots.map(\.slot) == [3])
    }

    @Test func exactTargetsAndSameCameraRestore() async throws {
        let fake = FakePTPCamera()
        let link = CameraLink(transport: fake, timing: .immediate)
        let before = try await link.load(placements: [.init(slot: 3, recipe: look)], protectedSlots: [1, 2],
                                        onBackup: { #expect($0.slots.map(\.slot) == [3]) }, onSlot: { _ in }).backup
        #expect(try await link.fujiCamera.readSlot(1).name == "C1")
        #expect(try await link.fujiCamera.readSlot(2).name == "C2")
        #expect(try await link.fujiCamera.readSlot(3).name == look.slotName)
        let restored = try await link.restore(before, protectedSlots: [], onBackup: { #expect($0.slots.first?.name == "New C3") })
        #expect(restored.isClean)
        #expect(try await link.fujiCamera.readSlot(3).name == "C3")
        var foreign = before
        foreign.serial = "another body"
        await #expect(throws: CameraError.self) { try await link.restore(foreign, protectedSlots: [], onBackup: { _ in Issue.record("foreign backup") }) }
        await #expect(throws: CameraError.self) { try await link.restore(before, protectedSlots: [3], onBackup: { _ in Issue.record("protected slot") }) }
    }

    @Test func invalidDestinationsNeverConnect() async {
        let fake = FakePTPCamera()
        let link = CameraLink(transport: fake, timing: .immediate)
        for slots in [[0], [8], [3, 3], []] {
            await #expect(throws: CameraError.self) {
                try await link.load(placements: slots.map { .init(slot: $0, recipe: look) }, protectedSlots: [], onBackup: { _ in }, onSlot: { _ in })
            }
        }
        #expect(await fake.commands.isEmpty)
    }

    @Test func realWirelessWritesRequireHardwareEvidence() throws {
        #expect(throws: BLESlotWriter.WriteError.self) { try BLESlotWriter.requireValidatedWrites(isSimulated: false) }
        try BLESlotWriter.requireValidatedWrites(isSimulated: true)
    }
}

extension SafetyRegressionTests {
    @Test func aDifferentCameraReadbackCannotVerifyTheWrite() async throws {
        let camera = FakeFujiBLECamera()
        _ = try await camera.adoptRegisteredKey(timeout: .zero)
        camera.mangleNextApply { data in var changed = data; changed[0x34] ^= 1; return changed }
        let result = try await BLESlotWriter.write([.init(slot: 7, recipe: Recipe(name: "Identity", filmSim: .classicChrome, noiseReduction: -4))],
            to: camera, timing: .immediate, onBackup: { _ in })
        #expect(result.result == .notVerified)
        #expect(result.verdicts.allSatisfy { !$0.isConfirmed })
        #expect(camera.record.restoreRequests == 1, "do not attempt recovery on a different identity")
    }

    @Test func mockUSBRecoveryExercisesTheSameAPI() async throws {
        let link = MockCameraLink(searchDelay: .zero, perSlot: .zero)
        let report = try await link.load(placements: [.init(slot: 3, recipe: Recipe(name: "New C3", filmSim: .classicChrome))],
            protectedSlots: [1, 2], onBackup: { _ in }, onSlot: { _ in })
        let restored = try await link.restore(report.backup, protectedSlots: [1, 2], onBackup: { _ in })
        #expect(restored.isClean && link.slots[3]?.name == "C3")
    }
}

@Suite("Restore evidence integrity")
struct RestoreEvidenceTests {
    @Test func sameSlotsRequiresReadableSameIdentity() {
        let original = FakeFujiBLECamera().settings
        var other = original; other[0x34] ^= 1
        #expect(!BLESlotWriter.sameSlots(original, other))
        #expect(!BLESlotWriter.sameSlots(Data([1, 2]), Data([1, 2])))
        #expect(BLESlotWriter.sameSlots(original, original))
    }

    @Test func recoveryCannotVerifyADifferentCameraIdentity() async throws {
        let camera = FakeFujiBLECamera()
        _ = try await camera.adoptRegisteredKey(timeout: .zero)
        let old = camera.settings
        camera.settings = try FujiSettingsFile(old).applyingLooks([.init(slot: 7,
            recipe: Recipe(name: "New", filmSim: .classicChrome, noiseReduction: -4))]).file.data
        camera.mangleNextApply { data in var result = data; result[0x34] ^= 1; return result }
        let result = try await BLESlotWriter.restore(old, slots: [7], to: camera, timing: .immediate, onFresh: { _ in })
        if case .notVerified = result.result {} else { Issue.record("Foreign read-back must not verify recovery") }
        #expect(camera.record.restoreRequests == 1)
    }
}
