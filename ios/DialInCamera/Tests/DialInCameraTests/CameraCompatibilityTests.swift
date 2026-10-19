import Foundation
import Testing
@testable import DialInCamera

@Suite("Compatibility evidence boundaries", .serialized)
struct CameraCompatibilityTests {
    @Test func officialSupportIsSeparateFromOurDecoder() {
        #expect(CameraCompatibility.model("Fujifilm X-T5")?.listedForXApp == true)
        #expect(CameraCompatibility.model("X100VI")?.desktopBackupOnly == true)
        #expect(CameraCompatibility.model("X-T3")?.listedForXApp == false)
        #expect(CameraCompatibility.model("X-T3")?.listedForDesktopBackup == true)
        #expect(CameraCompatibility.model("X-T1")?.listedForDesktopBackup == false)
        #expect(CameraCompatibility.model("X100V") != CameraCompatibility.model("X100VI"))
        #expect(CameraCompatibility.model("X100VI Prototype") == nil)
        #expect(!CameraCompatibility.hasSettingsDecoder(model: "X-T5", firmware: "1.10"))
        #expect(!CameraCompatibility.hasSettingsDecoder(model: "X100VI", firmware: "1.11"))
        for firmware in ["1.10.1", "1.10 beta", "unidentified 1.10", "1.10/1.32"] {
            #expect(!CameraCompatibility.hasSettingsDecoder(model: "X100VI", firmware: firmware))
            #expect(BLESlotWriter.normalizeFirmware(firmware) == nil)
        }
        #expect(CameraCompatibility.hasSettingsDecoder(model: "FUJIFILM X100VI", firmware: " Ver01.10 "))
        #expect(!BLESlotWriter.supportedFirmware.contains("1.11"))
        #expect(!BLESlotWriter.wirelessWritesValidated)
    }

    @Test func reportErrorsDoNotLeakDeviceDetails() {
        for error in [FujiBLEError.disconnected("SECRET_SERIAL"), .unexpected("SECRET_SERIAL"), .staleBond("SECRET_SERIAL")] {
            #expect(!CameraCheck.backupFailureMessage(error).contains("SECRET_SERIAL"))
        }
    }

    @Test func cancellationDoesNotStartABackupOrProduceSuccess() async throws {
        let camera = FakeFujiBLECamera()
        let task = Task {
            try await CameraCheck.run(on: camera, pairing: true,
                timing: .init(settleAfterConnect: .seconds(30), betweenSteps: .zero, stateTimeout: .seconds(1),
                              chunkTimeout: .seconds(1), ackTimeout: .seconds(1)))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(camera.record.backupRequests == 0 && camera.record.restoreRequests == 0)
        #expect(!(await camera.isLinkUp))
    }

    @Test(arguments: ["1.11", "1.32", ""])
    func sameSizedFileOnUnknownFirmwareIsNotDecoded(firmware: String) async throws {
        let camera = FakeFujiBLECamera(firmwareOverride: firmware)
        let r = try await CameraCheck.run(on: camera, pairing: true, timing: .immediate)
        #expect(r.transferChecksumOK == true && r.fileSize == FujiSettingsFile.fw110Size)
        #expect(!r.settingsLayoutSupported && r.c1Sentence == nil && r.slotNames.isEmpty)
        #expect(camera.record.restoreRequests == 0)
    }

    @Test(arguments: ["X-T5", ""])
    func mismatchedOrMissingIdentityIsNotDecoded(model: String) async throws {
        let camera = FakeFujiBLECamera(reportedModel: model)
        let r = try await CameraCheck.run(on: camera, pairing: true, timing: .immediate)
        #expect(!r.modelOK && !r.settingsLayoutSupported && r.c1Sentence == nil && r.slotNames.isEmpty)
        #expect(camera.record.restoreRequests == 0)
    }

    @Test func movedPayloadIsRefusedEvenWithConsistentTotalLength() throws {
        var bytes = FakeFujiBLECamera.sampleSettings()
        bytes.replaceSubrange(0x98..<0x9C, with: PTPPack.u32(0xAC))
        bytes.replaceSubrange(0xA0..<0xA4, with: PTPPack.u32(UInt32(bytes.count - 0xAC)))
        #expect(throws: SettingsFileError.self) { try FujiSettingsFile(bytes) }
    }

    @Test func failedBackupStillPreservesReadOnlyDiscoveryReport() async throws {
        let camera = FakeFujiBLECamera(scenario: .busy, reportedModel: "X-T5", firmwareOverride: "4.31")
        let r = try await CameraCheck.run(on: camera, pairing: true, timing: .immediate)
        #expect(r.model == "X-T5" && r.firmware == "4.31" && r.characteristicCount > 0)
        #expect(r.backupProblem != nil && r.fileSize == nil && !r.settingsLayoutSupported)
        #expect(r.officialCompatibility?.listedForXApp == true)
        #expect(camera.record.restoreRequests == 0)
        #expect(!(await camera.isLinkUp))
    }

    @Test func pairingReadDoesNotGuessSlotNamesOrModel() async throws {
        let newer = FakeFujiBLECamera(firmwareOverride: "1.32")
        _ = try await newer.connect(pairing: true, timeout: .seconds(1))
        newer.disconnect()
        let result = try await BLESlotWriter.readSlots(from: newer, timing: .immediate)
        #expect(result.names.isEmpty && !result.backup.isEmpty && result.firmware == "1.32")
        let unidentified = FakeFujiBLECamera(reportedModel: "")
        _ = try await unidentified.connect(pairing: true, timeout: .seconds(1))
        unidentified.disconnect()
        await #expect(throws: BLESlotWriter.WriteError.backupFailed("The backup does not match the camera's reported identity. Try Camera Check.")) {
            try await BLESlotWriter.readSlots(from: unidentified, timing: .immediate)
        }
        #expect(newer.record.restoreRequests == 0 && unidentified.record.restoreRequests == 0)
    }

    @Test(arguments: ["X-T5", "X100V", ""])
    func usbDoesNotSendX100VIPlanToAnotherModel(model: String) async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.model = model }
        let link = CameraLink(transport: fake, timing: .immediate)
        await #expect(throws: CameraError.self) {
            try await link.load(placements: [.init(slot: 7, recipe: .init(name: "Look", filmSim: .classicChrome))],
                                protectedSlots: [], onBackup: { _ in }, onSlot: { _ in })
        }
        #expect(await fake.writes.isEmpty, "refuse before even selecting a slot")
        #expect(await link.lastBackup == nil)
        await link.disconnect()
    }
}
