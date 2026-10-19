import Foundation
import Synchronization
import Testing
@testable import DialInCamera

@Suite("BLE write permission binds the actual backup identity")
struct BLEExpectedIdentityTests {
    private var placement: FujiSettingsFile.LookPlacement {
        .init(slot: 7, recipe: Recipe(name: "Identity trial", filmSim: .classicChrome, whiteBalance: .daylight,
                                     noiseReduction: -4))
    }

    private func camera(experimental: Bool) async throws -> FakeFujiBLECamera {
        let camera = FakeFujiBLECamera(reportedModel: experimental ? "FF230003" : "X100VI",
                                       compressedSettings: experimental)
        _ = try await camera.adoptRegisteredKey(timeout: .milliseconds(10))
        return camera
    }

    @Test("Ordinary and experimental writes reject a different same-model body before patch or restore")
    func mismatched() async throws {
        for experimental in [false, true] {
            let camera = try await camera(experimental: experimental)
            let original = camera.settings
            let actual = BackupIdentity(original)
            let expected = BackupIdentity(model: actual.model, serial: actual.serial + "-OTHER")
            let saves = Mutex(0)
            let candidates = Mutex(0)
            let steps = Mutex<[BLESlotWriter.Step]>([])
            do {
                if experimental {
                    _ = try await BLESlotWriter.writeExperimental([placement], to: camera,
                        expectedIdentity: expected, experimental: true, timing: .immediate,
                        onSafetyBackup: { _ in saves.withLock { $0 += 1 } },
                        onPrepared: { _ in candidates.withLock { $0 += 1 } },
                        onStep: { step in steps.withLock { $0.append(step) } })
                } else {
                    _ = try await BLESlotWriter.write([placement], to: camera, expectedIdentity: expected,
                        timing: .immediate, onBackup: { _ in saves.withLock { $0 += 1 } },
                        onStep: { step in steps.withLock { $0.append(step) } })
                }
                Issue.record("The wrong paired identity reached a write.")
            } catch BLESlotWriter.WriteError.differentCamera(let reason) {
                #expect(reason.contains("paired camera"))
            }
            #expect(camera.record.backupsServed == 1 && camera.record.restoreRequests == 0)
            #expect(camera.record.applied == 0 && camera.record.uploadedWireFiles.isEmpty)
            #expect(camera.settings == original)
            #expect(saves.withLock { $0 } == 0 && candidates.withLock { $0 } == 0)
            #expect(!steps.withLock { $0.contains(.patching) })
        }
    }

    @Test("The matched actual identity still permits guarded ordinary and compressed trial writes")
    func matched() async throws {
        for experimental in [false, true] {
            let camera = try await camera(experimental: experimental)
            let expected = BackupIdentity(camera.settings)
            let saved = Mutex(false)
            let outcome: BLESlotWriter.Outcome
            if experimental {
                outcome = try await BLESlotWriter.writeExperimental([placement], to: camera,
                    expectedIdentity: expected, experimental: true, timing: .immediate,
                    onSafetyBackup: { _ in saved.withLock { $0 = true } })
            } else {
                outcome = try await BLESlotWriter.write([placement], to: camera, expectedIdentity: expected,
                    timing: .immediate, onBackup: { _ in saved.withLock { $0 = true } })
            }
            #expect(outcome.result == .verified && saved.withLock { $0 })
            #expect(camera.record.restoreRequests == 1 && camera.record.applied == 1)
        }
        #expect(!BLESlotWriter.wirelessWritesValidated)
    }

    @Test("A different body cannot satisfy the pending write's ordinary or experimental check")
    func mismatchedReadback() async throws {
        for experimental in [false, true] {
            let camera = try await camera(experimental: experimental)
            let expectedFile = try FujiSettingsFile(camera.settings).applyingLooks([placement]).file.data
            let intended = BackupIdentity(expectedFile)
            // Make another camera hold exactly the requested visible look, but carry a different header serial.
            var otherBody = expectedFile
            otherBody[0x34] ^= 1
            camera.settings = otherBody
            do {
                if experimental {
                    _ = try await BLESlotWriter.checkExperimental([placement], on: camera,
                        expectedIdentity: intended, expected: expectedFile, experimental: true, timing: .immediate)
                } else {
                    _ = try await BLESlotWriter.check([placement], on: camera, expectedIdentity: intended, timing: .immediate)
                }
                Issue.record("The wrong camera was allowed to satisfy a read-back.")
            } catch BLESlotWriter.WriteError.differentCamera(let reason) {
                #expect(reason.contains("intended for this write"))
            }
            #expect(camera.record.backupsServed == 1)
            #expect(camera.record.restoreRequests == 0 && camera.record.applied == 0)
        }
    }
}
