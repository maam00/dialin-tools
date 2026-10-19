import Foundation
import Synchronization
import Testing
@testable import DialInCamera

@Suite("Explicit compressed Bluetooth slot trial")
struct BLEExperimentalSlotTests {
    private var look: FujiSettingsFile.LookPlacement {
        .init(slot: 7, recipe: Recipe(name: "BLE trial", filmSim: .classicChrome, whiteBalance: .daylight,
                                     wbShiftR: 2, wbShiftB: -3, sharpness: 1, noiseReduction: -4))
    }

    private func paired(_ scenario: FakeFujiBLECamera.Scenario = .ok, model: String = "FF230003",
                        firmware: String? = nil) async throws -> FakeFujiBLECamera {
        let camera = FakeFujiBLECamera(scenario: scenario, reportedModel: model, firmwareOverride: firmware,
                                       compressedSettings: true)
        _ = try await camera.adoptRegisteredKey(timeout: .milliseconds(10))
        return camera
    }

    @Test("Fresh compressed backup is kept before one-slot upload; wire framing and exact slot readback agree")
    func compressedWrite() async throws {
        let camera = try await paired()
        let before = camera.settings
        let saved = Mutex<[FujiBLEFlows.SettingsBackup]>([])
        let outcome = try await BLESlotWriter.writeExperimental([look], to: camera, experimental: true,
            timing: .immediate, onSafetyBackup: { backup in
                #expect(camera.record.restoreRequests == 0)
                #expect(backup.compressed && backup.data == before)
                let decoded = try BLEBackupPayload.decode(backup.wireData, reportedSize: backup.data.count)
                #expect(decoded.data == before)
                saved.withLock { $0.append(backup) }
            })
        #expect(outcome.result == .verified && outcome.verdicts.allSatisfy(\.isConfirmed))
        #expect(outcome.model == "X100VI" && outcome.firmware == "1.10")
        let written = try #require(outcome.written)
        let wire = try #require(camera.record.uploadedWireFiles.first)
        #expect(wire != written && wire.prefix(2) == saved.withLock { $0[0].wireData.prefix(2) })
        #expect(try BLEBackupPayload.decode(wire, reportedSize: written.count).data == written)
        #expect(camera.record.framesReceived == FujiBLE.restoreFrames(wire).count)
        let information = try #require(camera.record.writes.first { $0.characteristic == FujiBLE.fileInformation })
        #expect(try FileInformation.parse(information.value).size == wire.count)
        try RestoreGuard.check(camera.settings, against: before, slots: [7])
        #expect(!BLESlotWriter.wirelessWritesValidated)
    }

    @Test("Default off, multiple slots, protected slots and failed durable save prevent restore")
    func refusal() async throws {
        let disabled = try await paired()
        await #expect(throws: BLESlotWriter.WriteError.self) {
            _ = try await BLESlotWriter.writeExperimental([look], to: disabled, timing: .immediate,
                                                          onSafetyBackup: { _ in })
        }
        #expect(disabled.record.connections == 0)
        let many = try await paired()
        await #expect(throws: BLESlotWriter.WriteError.self) {
            _ = try await BLESlotWriter.writeExperimental([look, .init(slot: 6, recipe: look.recipe)], to: many,
                                                          experimental: true, timing: .immediate, onSafetyBackup: { _ in })
        }
        #expect(many.record.connections == 0)
        let protected = try await paired()
        await #expect(throws: BLESlotWriter.WriteError.self) {
            _ = try await BLESlotWriter.writeExperimental([look], to: protected, experimental: true,
                                                          protectedSlots: [7], timing: .immediate, onSafetyBackup: { _ in })
        }
        #expect(protected.record.connections == 0)
        let unsaved = try await paired()
        await #expect(throws: BLESlotWriter.WriteError.self) {
            _ = try await BLESlotWriter.writeExperimental([look], to: unsaved, experimental: true,
                timing: .immediate, onSafetyBackup: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        }
        #expect(unsaved.record.restoreRequests == 0)
    }

    @Test("Unfamiliar firmware or BLE product ID cannot inherit the trial profile")
    func cameraProfile() async throws {
        for camera in [try await paired(model: "FF230004"), try await paired(firmware: "1.11")] {
            await #expect(throws: BLESlotWriter.WriteError.self) {
                _ = try await BLESlotWriter.writeExperimental([look], to: camera, experimental: true,
                                                              timing: .immediate, onSafetyBackup: { _ in })
            }
            #expect(camera.record.backupRequests == 0 && camera.record.restoreRequests == 0)
        }
    }

    @Test("Compressed selected-slot recovery retains newer unselected settings and keeps a fresh safety file")
    func recovery() async throws {
        let camera = try await paired()
        let old = camera.settings
        var fresh = try FujiSettingsFile(old).applyingLooks([
            look, .init(slot: 1, recipe: Recipe(name: "New C1", filmSim: .classicChrome, whiteBalance: .daylight, noiseReduction: -4))
        ]).file.data
        fresh[0xEC] ^= 1 // A newer unrelated setting, not replayed from the stored undo file.
        // Keep the fake camera's checksum model consistent after the synthetic menu change.
        let parsed = try FujiSettingsFile(fresh)
        let sum = try FujiSettingsFile.expectedChecksum(original: try FujiSettingsFile(old), patchedBytes: parsed.bytes)
        fresh[FujiSettingsFile.checksumOffset] = UInt8(sum & 0xFF)
        fresh[FujiSettingsFile.checksumOffset + 1] = UInt8(sum >> 8)
        camera.settings = fresh
        let freshReference = fresh
        let saved = Mutex<Data?>(nil)
        let result = try await BLESlotWriter.restoreExperimental(old, slots: [7], to: camera, experimental: true,
            backupFirmware: "1.10", timing: .immediate, onSafetyBackup: { backup in
                #expect(backup.compressed && camera.record.restoreRequests == 0)
                saved.withLock { $0 = backup.data }
            })
        #expect(result.result == .verified && saved.withLock { $0 == freshReference })
        let expected = try UndoFile.make(old: old, onto: fresh, slots: [7])
        #expect(camera.settings == expected && camera.settings[0xEC] == fresh[0xEC])
        #expect(try BLEBackupPayload.decode(try #require(camera.record.uploadedWireFiles.first), reportedSize: expected.count).data == expected)
        try RestoreGuard.check(camera.settings, against: fresh, slots: [7])
    }

    @Test("A matching visible look with a changed hidden byte is never called verified")
    func hiddenState() async throws {
        let camera = try await paired()
        let old = camera.settings
        camera.mangleNextApply { bytes in
            var modified = bytes
            modified[0x1106A] ^= 1 // inactive monochrome memory while Classic Chrome is selected
            return modified
        }
        let outcome = try await BLESlotWriter.writeExperimental([look], to: camera, experimental: true,
                                                                timing: .immediate, onSafetyBackup: { _ in })
        #expect(outcome.result != .verified)
        if outcome.result == .rolledBack { #expect(BLESlotWriter.sameSlots(camera.settings, old)) }
    }

    @Test("An unrelated non-counter change stops trial verification without normalizing it away")
    func globalState() async throws {
        let camera = try await paired()
        camera.mangleNextApply { bytes in var modified = bytes; modified[0xEC] ^= 1; return modified }
        let outcome = try await BLESlotWriter.writeExperimental([look], to: camera, experimental: true,
                                                                timing: .immediate, onSafetyBackup: { _ in })
        #expect(outcome.result == .notVerified && camera.record.restoreRequests == 1)
        #expect(!outcome.verdicts.allSatisfy { $0.isConfirmed })
    }

    @Test("Cancellation after saving the backup propagates before every restore request")
    func cancelledBeforeWrite() async throws {
        let camera = try await paired()
        let task = Task {
            try await BLESlotWriter.writeExperimental([look], to: camera, experimental: true, timing: .immediate,
                onSafetyBackup: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(camera.record.restoreRequests == 0 && camera.record.applied == 0)
    }

    @Test("Failure to durably keep the exact prepared file prevents mutation")
    func preparedFileFailure() async throws {
        let camera = try await paired()
        await #expect(throws: BLESlotWriter.WriteError.self) {
            _ = try await BLESlotWriter.writeExperimental([look], to: camera, experimental: true, timing: .immediate,
                onSafetyBackup: { _ in }, onPrepared: { _ in throw CocoaError(.fileWriteNoPermission) })
        }
        #expect(camera.record.restoreRequests == 0 && camera.record.applied == 0)
    }

    @Test("Trial pairing and post-restart check require the supported fresh backup and exact saved slot bytes")
    func readAndCheck() async throws {
        let camera = try await paired()
        let read = try await BLESlotWriter.readSlotsExperimental(from: camera, experimental: true,
                                                                 timing: .immediate, onSafetyBackup: { _ in })
        #expect(read.model == "X100VI" && read.names.count == 7 && read.backup == camera.settings)
        let outcome = try await BLESlotWriter.writeExperimental([look], to: camera, experimental: true,
                                                                timing: .immediate, onSafetyBackup: { _ in })
        let expected = try #require(outcome.written)
        let check = try await BLESlotWriter.checkExperimental([look], on: camera, expected: expected,
                                                              experimental: true, timing: .immediate)
        #expect(check.result == .verified)
        var hidden = camera.settings
        hidden[0x1106A] ^= 1
        camera.settings = hidden
        let changed = try await BLESlotWriter.checkExperimental([look], on: camera, expected: expected,
                                                                experimental: true, timing: .immediate)
        #expect(changed.result == .notVerified)
    }
}
