// Camera Check (read-only), its write guard, profile-from-the-radio, stale bonds and never presenting as FUJIFILM's app.
import CoreBluetooth
import Foundation
import Testing
@testable import DialInCamera

@Suite("Camera Check and the write guard")
struct CameraCheckTests {
    @Test("The guard refuses RESTORE_REQUEST, FILE_PARTIAL_DATA, FILE_INFORMATION and FUNCTION_LAUNCH 04 00; the camera sees nothing")
    func guardRefuses() async throws {
        let cam = FakeFujiBLECamera()
        _ = try await cam.adoptRegisteredKey(timeout: .milliseconds(10))
        try await cam.connect(pairing: false, timeout: .seconds(1))
        let before = cam.record.writes.count
        let g = ReadOnlyGATT(cam)
        let refused: [(String, Data)] = [
            (FujiBLE.restoreRequest, FujiBLE.restoreRequestSettings),
            (FujiBLE.filePartialData, Data(count: 128)),
            (FujiBLE.fileInformation, FileInformation.build(name: "backup.dat", size: 70524)),
            (FujiBLE.functionLaunch, Data([0x04, 0x00])),
            (FujiBLE.backupRequest, Data([0x02, 0x00])),
            (FujiBLE.appIdentity, Data([0x01, 0x00, 0x00])),
            (FujiWifiWake.ssidCharacteristic, Data("x".utf8)),
            (FujiBLE.locationFix, Data(count: 23)),
        ]
        for (c, v) in refused {
            await #expect(throws: FujiBLEError.self) { try await g.write(c, v) }
            await #expect(throws: FujiBLEError.self) { try await g.writeCommand(c, v) }
        }
        #expect(cam.record.writes.count == before, "nothing reached the camera")
        #expect(g.blocked.count == refused.count * 2)
        try await g.write(FujiBLE.functionLaunch, Data([0x03, 0x00]))   // image viewing: allowed
        #expect(cam.record.writes.count == before + 1)
        #expect(ReadOnlyGATT.isAllowed(FujiBLE.backupRequest, Data([1, 0])) && ReadOnlyGATT.isAllowed(FujiBLE.fileTransferResult, Data([3, 0])))
        cam.disconnect()
    }

    @Test("Camera Check on a basic body: allowlisted writes only, C1 read back, no serial in the report")
    func basic() async throws {
        let cam = FakeFujiBLECamera()
        _ = try await cam.adoptRegisteredKey(timeout: .milliseconds(10))
        let r = try await CameraCheck.run(on: cam, pairing: false, timing: .immediate)
        for w in cam.record.writes { #expect(ReadOnlyGATT.isAllowed(w.characteristic, w.value), "\(w.characteristic) \(w.value.hexString)") }
        #expect(cam.record.restoreRequests == 0 && cam.record.applied == 0)
        #expect(r.model == "X100VI" && r.firmware == "1.10" && r.profile == .basic)
        #expect(r.settingsLayoutSupported && r.magicOK && r.modelOK && r.transferChecksumOK == true && r.fileSize == 70524)
        #expect(r.checksumConstantMatchesReference == nil, "a historical checksum constant is not validity evidence")
        #expect(r.simulated == true && r.readinessText.contains("Rehearsal"))
        #expect(r.hasBackup && r.hasRestore && r.hasFileService && r.characteristicCount > 20 && r.fingerprint.count == 64)
        #expect(r.slotNames.first == "Harbor color")
        #expect(r.c1Sentence == "Your C1 is Classic Chrome, Color +1, Grain Weak Small, Color Chrome Weak, Color Chrome FX Blue Off, White balance Daylight R+2 B\u{2212}3, DR200, Highlight \u{2212}0.5, Shadow +1, Sharpness \u{2212}1, Clarity 0, High ISO NR \u{2212}4. Is that what the camera shows?")
        #expect(r.blockedWrites.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        for secret in ["REHEARSAL", "7A7A", "FUJIFILM-X100VI", "02-00-5E", "02:00:5E"] { #expect(!json.contains(secret), "\(secret)") }
        #expect(!(await cam.isLinkUp))
    }

    @Test("Camera Check on newer firmware: secure profile, layout not supported, still read-only")
    func secure() async throws {
        let cam = FakeFujiBLECamera(scenario: .secureFirmware)
        let r = try await CameraCheck.run(on: cam, pairing: true, timing: .immediate)
        for w in cam.record.writes { #expect(ReadOnlyGATT.isAllowed(w.characteristic, w.value), "\(w.characteristic) \(w.value.hexString)") }
        #expect(!cam.record.writes.contains { $0.characteristic == FujiBLE.appIdentity })
        #expect(r.profile == .secure && r.firmware == "1.32")
        #expect(!r.settingsLayoutSupported && r.layoutProblem != nil && r.magicOK && r.fileSize == 71548)
        #expect(r.c1Sentence == nil && r.slotNames.isEmpty, "do not guess offsets on unmapped firmware")
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!json.contains("REHEARSAL") && !json.contains("rehearsal24"))
    }

    @Test("The fingerprint depends on the table, not its order")
    func fingerprint() {
        let a = [GATTEntry(service: "180a", characteristic: "2a24", properties: ["read"]),
                 GATTEntry(service: FujiBLE.fileService, characteristic: FujiBLE.filePartialData, properties: ["write", "read"])]
        #expect(CameraCheck.fingerprint(a) == CameraCheck.fingerprint(a.reversed()))
        #expect(CameraCheck.fingerprint(a) != CameraCheck.fingerprint(Array(a.prefix(1))))
    }

    @Test("recipe(slot:) reads back every sample look")
    func readBack() throws {
        let f = try FujiSettingsFile(FakeFujiBLECamera.sampleSettings())
        for (i, look) in FakeFujiBLECamera.sampleLooks.enumerated() {
            var want = look
            if look.filmSim.isMonochrome { want.color = 0; want.colorChrome = .off; want.colorChromeFxBlue = .off; want.wbShiftR = 0; want.wbShiftB = 0 }
            #expect(f.recipe(slot: i + 1) == want, "C\(i + 1)")
        }
    }
}

@Suite("Pairing hygiene")
struct PairingHygieneTests {
    @Test("Registration never writes the app-identity characteristic (8b5ecf55), even when the body has it")
    func neverAppIdentity() async throws {
        let g = FakeGATT()
        await g.configure { $0.present.insert(FujiBLE.appIdentity) }
        _ = try await FujiBLEFlows.register(g, clientName: "Dial In", pause: .milliseconds(1))
        #expect(await !g.writes.contains { $0.0 == FujiBLE.appIdentity })
    }

    @Test("Profile comes from the advert")
    func profile() {
        #expect(FujiAdvert(kind: .securePairing, tag: "").profile == .secure)
        #expect(FujiAdvert(kind: .reconnect, tag: "").profile == .secure)
        #expect(FujiAdvert(kind: .basicPairing, tag: "").profile == .basic)
        #expect(FujiAdvert(kind: .basic, tag: "").profile == .basic)
        #expect(FujiAdvert(kind: .basicStandby, tag: "").profile == .basic)
        #expect(FujiAdvert(kind: .other, tag: "").profile == .unknown)
        #expect(RememberedBLECamera(peripheralID: nil, name: "x", mode: "secure", tokenHex: nil, identificationNumber: 1, adopted: false).profile == .secure)
    }

    @Test("Stale bonds are recognised from CoreBluetooth's errors and explained")
    func staleBond() async throws {
        #expect(FujiBLEFlows.isStaleBond(NSError(domain: CBErrorDomain, code: CBError.Code.peerRemovedPairingInformation.rawValue)))
        #expect(FujiBLEFlows.isStaleBond(NSError(domain: CBATTErrorDomain, code: 14)))
        #expect(!FujiBLEFlows.isStaleBond(NSError(domain: CBATTErrorDomain, code: CBATTError.Code.insufficientEncryption.rawValue)))
        #expect(FujiBLEError.staleBond("X100VI").description.contains("Forget This Device"))
        let cam = FakeFujiBLECamera(scenario: .staleBond)
        await #expect(throws: FujiBLEError.staleBond("7A7AX100VI-7A7A")) { try await cam.connect(pairing: false, timeout: .seconds(1)) }
        _ = try await cam.connect(pairing: true, timeout: .seconds(1))
        cam.disconnect()
    }

    @Test("A remembered basic key on a body that now pairs securely: profileChanged")
    func profileChanged() async throws {
        let cam = FakeFujiBLECamera()
        _ = try await cam.adoptRegisteredKey(timeout: .milliseconds(10))
        cam.scenario = .secureFirmware
        await #expect(throws: FujiBLEError.profileChanged) { try await cam.connect(pairing: false, timeout: .seconds(1)) }
        #expect(FujiBLEError.profileChanged.description == "Your camera's firmware changed how it pairs. Pair it again.")
    }
}
