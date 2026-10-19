// The Bluetooth slot writer against the pretend camera (FakeFujiBLECamera, which speaks the camera's side from the
// protocol description): backup first, patch, restore, read back, verdicts; and every way it can go wrong.
import Foundation
import Synchronization
import Testing
@testable import DialInCamera

private let shade = Recipe(name: "Shade at noon", filmSim: .classicChrome, grain: .weakSmall, colorChrome: .strong,
                           whiteBalance: .daylight, wbShiftR: 2, wbShiftB: -4, highlight: 1, shadow: -1.5, color: 2,
                           sharpness: -1, noiseReduction: -4, clarity: 2)
private let pier = Recipe(name: "Pier at dusk", filmSim: .realaAce, whiteBalance: .kelvin, kelvin: 6300, wbShiftR: 1, wbShiftB: -2,
                          dynamicRange: .dr200, highlight: -0.5, shadow: 0.5, color: 1, noiseReduction: -4, clarity: -1)
private let neg = Recipe(name: "Classic Neg", filmSim: .classicNeg, whiteBalance: .auto, color: 1, noiseReduction: -4)

private func placements() -> [FujiSettingsFile.LookPlacement] { [.init(slot: 3, recipe: shade), .init(slot: 5, recipe: pier)] }

/// A paired (adopted) fake, as after the app's pairing.
private func pairedCamera(_ scenario: FakeFujiBLECamera.Scenario = .ok) async throws -> FakeFujiBLECamera {
    let cam = FakeFujiBLECamera(scenario: scenario)
    if scenario != .secureFirmware && scenario != .pairedElsewhere {
        _ = try await cam.adoptRegisteredKey(timeout: .milliseconds(10))
    } else {
        try await cam.connect(pairing: true, timeout: .seconds(1))
        cam.disconnect()
    }
    return cam
}

private final class Steps: Sendable {
    let all = Mutex<[BLESlotWriter.Step]>([])
    func add(_ s: BLESlotWriter.Step) { all.withLock { $0.append(s) } }
    var list: [BLESlotWriter.Step] { all.withLock { $0 } }
}

@Suite("Bluetooth slot writer")
struct BLESlotWriterTests {
    @Test("Happy path: backup handed over before any restore write, chosen slots verified, the rest byte-identical")
    func happy() async throws {
        let cam = try await pairedCamera()
        let before = cam.settings
        let steps = Steps()
        let restoresAtBackup = Mutex<Int?>(nil)
        let out = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { data in
            restoresAtBackup.withLock { $0 = cam.record.restoreRequests }
            #expect(data == before)
        }, onStep: steps.add)
        #expect(restoresAtBackup.withLock { $0 } == 0)
        #expect(out.result == .verified)
        #expect(out.model == "X100VI" && out.firmware == "1.10")
        #expect(out.verdicts.map(\.slot) == [3, 5] && out.verdicts.allSatisfy(\.isConfirmed))
        #expect(out.backup == before)
        let now = try FujiSettingsFile(cam.settings)
        let old = try FujiSettingsFile(before)
        #expect(now.mismatches(slot: 3, against: shade).isEmpty && now.mismatches(slot: 5, against: pier).isEmpty)
        for s in [1, 2, 4, 6, 7] { #expect(Array(now.bytes[now.slotRegion(s)]) == Array(old.bytes[old.slotRegion(s)]), "C\(s)") }
        #expect(now.names[2] == "Shade at noon" && now.names[4] == "Pier at dusk" && now.names[0] == "Harbor color")
        #expect(now.checksumConstant == old.checksumConstant)
        #expect(cam.record.applied == 1 && cam.record.framesReceived == 588)
        #expect(steps.list.contains(.uploading(frame: 588, of: 588)) && steps.list.last == .done)
        #expect(!(await cam.isLinkUp))
    }

    @Test("Busy camera: refused before anything is written")
    func busy() async throws {
        let cam = try await pairedCamera(.busy)
        await #expect(throws: BLESlotWriter.WriteError.self) {
            try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in })
        }
        #expect(cam.record.restoreRequests == 0 && cam.record.applied == 0)
    }

    @Test("Busy at the restore: nothing changed, confirmed by a backup")
    func restoreBusy() async throws {
        let cam = try await pairedCamera(.restoreBusy)
        let before = cam.settings
        let out = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in })
        #expect(out.result == .failedNothingChanged)
        #expect(out.after == before && cam.settings == before)
        #expect(out.verdicts.allSatisfy { if case .failed = $0.verdict { true } else { false } })
    }

    @Test("A rejected frame: nothing changed")
    func rejected() async throws {
        let cam = try await pairedCamera(.rejectsUpload(atFrame: 200))
        let before = cam.settings
        let out = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in })
        #expect(out.result == .failedNothingChanged && cam.settings == before && cam.record.applied == 0)
        #expect(cam.record.results.contains(FujiBLE.resultCancel.hexString))
        #expect(out.after == before)
    }

    @Test("The link drops mid-upload: camera state is unknown until read-back")
    func dropped() async throws {
        let cam = try await pairedCamera(.dropsLink(atFrame: 300))
        let before = cam.settings
        let out = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in })
        #expect(out.result == .notVerified && cam.settings == before && cam.record.applied == 0)
        #expect(out.after == nil)
        #expect(out.verdicts.allSatisfy { if case .failed(let reason) = $0.verdict { !reason.contains("nothing changed") } else { false } })
    }

    @Test("Applies after a power cycle: pending, then check() says verified")
    func powerCycle() async throws {
        let cam = try await pairedCamera(.appliesAfterPowerCycle)
        let out = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in })
        #expect(out.result == .pendingPowerCycle)
        #expect(cam.pendingSettings != nil)
        cam.powerCycle()
        let again = try await BLESlotWriter.check(placements(), on: cam, timing: .immediate)
        #expect(again.result == .verified && again.verdicts.allSatisfy(\.isConfirmed))
    }

    @Test("Recovery restores selected slots and preserves an unrelated slot change")
    func rollback() async throws {
        let cam = try await pairedCamera()
        let before = cam.settings
        cam.mangleNextApply { b in
            var b = b
            b[0xF800 + 0x64] = 4   // C1's film sim → Velvia: a slot we never touched
            return b
        }
        let out = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in })
        #expect(out.result == .rolledBack)
        #expect(!BLESlotWriter.sameSlots(cam.settings, before))
        #expect(cam.settings[0xF800 + 0x64] == 4, "recovery must not change unselected C1")
        let old = try FujiSettingsFile(before), current = try FujiSettingsFile(cam.settings)
        for placement in placements() {
            #expect(current.bytes[current.slotRegion(placement.slot)] == old.bytes[old.slotRegion(placement.slot)])
        }
        #expect(cam.record.applied == 2)
        #expect(out.lines.contains { $0.contains("rolled back") })
    }

    @Test("Newer (secure) firmware: refused before any write")
    func secure() async throws {
        let cam = try await pairedCamera(.secureFirmware)
        do {
            _ = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in Issue.record("no backup expected") })
            Issue.record("expected unsupportedCamera")
        } catch BLESlotWriter.WriteError.unsupportedCamera(let why) {
            #expect(why.contains("1.32"))
        }
        #expect(cam.record.restoreRequests == 0 && cam.record.backupRequests == 0)
    }

    @Test("An unconfirmed value is refused before the camera is contacted, and written with allowInferred")
    func inferred() async throws {
        let cam = try await pairedCamera()
        do {
            _ = try await BLESlotWriter.write([.init(slot: 7, recipe: neg)], to: cam, codes: oct9Codes, timing: .immediate, onBackup: { _ in })
            Issue.record("expected a refusal")
        } catch BLESlotWriter.WriteError.unverified(let looks) {
            #expect(looks == [.init(slot: 7, name: neg.slotName, values: [.filmSimulation(.classicNeg)])])
            #expect(BLESlotWriter.plainRefusal(looks)
                == "\(neg.slotName): This look uses a film simulation we haven't verified on your camera yet. Nothing was sent.")
        }
        #expect(cam.record.restoreRequests == 0 && cam.record.backupRequests == 0, "nothing read, nothing written")
        let out = try await BLESlotWriter.write([.init(slot: 7, recipe: neg)], to: cam, allowInferred: true, timing: .immediate, onBackup: { _ in })
        #expect(out.result == .verified)
    }

    @Test("onBackup throwing aborts before any write")
    func backupThrows() async throws {
        struct DiskFull: Error {}
        let cam = try await pairedCamera()
        let before = cam.settings
        await #expect(throws: BLESlotWriter.WriteError.self) {
            try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in throw DiskFull() })
        }
        #expect(cam.record.restoreRequests == 0 && cam.settings == before)
    }

    @Test("A shot between the backups (frame counter moved) doesn't fail the verification")
    func frameCounter() async throws {
        let cam = try await pairedCamera()
        let out = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in cam.bumpFrameCounter() })
        #expect(out.result == .verified)
        let block = FujiSettingsFile.frameCounterBlock
        #expect(Array(cam.settings[block]) != Array(out.backup[block]))
    }

    @Test("A key the camera ignores: a clear camera error, nothing written")
    func ignoresKey() async throws {
        let cam = try await pairedCamera(.ignoresKey)
        do {
            _ = try await BLESlotWriter.write(placements(), to: cam, timing: .immediate, onBackup: { _ in })
            Issue.record("expected an error")
        } catch BLESlotWriter.WriteError.backupFailed(let why) {
            #expect(why.contains("pair again"))
        }
        #expect(cam.record.applied == 0)
    }

    @Test("Names over the budget are refused; distinct slots 1…7 only")
    func guards() async throws {
        let cam = try await pairedCamera()
        let long = (1...7).map { FujiSettingsFile.LookPlacement(slot: $0, recipe: Recipe(name: "Fourteen chars", filmSim: .velvia, noiseReduction: -4)) }
        await #expect(throws: BLESlotWriter.WriteError.self) { try await BLESlotWriter.write(long, to: cam, timing: .immediate, onBackup: { _ in }) }
        await #expect(throws: BLESlotWriter.WriteError.self) {
            try await BLESlotWriter.write([.init(slot: 3, recipe: shade), .init(slot: 3, recipe: pier)], to: cam, timing: .immediate, onBackup: { _ in })
        }
        #expect(cam.record.restoreRequests == 0)
    }

    @Test("readSlots: names, model and firmware from one backup")
    func readSlots() async throws {
        let cam = try await pairedCamera()
        let r = try await BLESlotWriter.readSlots(from: cam, timing: .immediate)
        #expect(r.names == FakeFujiBLECamera.sampleLooks.map(\.slotName))
        #expect(r.model == "X100VI" && r.firmware == "1.10" && r.backup == cam.settings)
        #expect(cam.record.restoreRequests == 0)
    }

    @Test("Firmware strings normalise")
    func firmware() {
        #expect(BLESlotWriter.normalizeFirmware("1.10") == "1.10")
        #expect(BLESlotWriter.normalizeFirmware("Ver1.32") == "1.32")
        #expect(BLESlotWriter.normalizeFirmware("01.10") == "1.10")
        #expect(BLESlotWriter.normalizeFirmware("X100VI") == nil)
    }
}

@Suite("Pretend Bluetooth camera")
struct FakeFujiBLECameraTests {
    @Test("Its sample file is a valid fw 1.10 file holding the seven sample looks")
    func sample() throws {
        let f = try FujiSettingsFile(FakeFujiBLECamera.sampleSettings())
        #expect(f.names == ["Harbor color", "Sunny faces", "Deep blue sea", "Old fisherman", "Faded dock", "Hard noon B&W", "Gritty B&W"])
        for (i, look) in FakeFujiBLECamera.sampleLooks.enumerated() {
            #expect(f.mismatches(slot: i + 1, against: look).isEmpty)
            #expect(FujiSettingsFile.inferredValues(for: look).isEmpty)
        }
        #expect(throws: SettingsFileError.self) { try FujiSettingsFile(FakeFujiBLECamera.secureSampleSettings()) }
    }

    @Test("Adopt returns the standby key; the next connect presents it and the camera answers")
    func adopt() async throws {
        let cam = FakeFujiBLECamera()
        cam.isOn = false
        let sightings = try await cam.scan(for: .milliseconds(10))
        #expect(sightings.first?.advert.kind == .basicStandby)
        let key = try await cam.adoptRegisteredKey(timeout: .milliseconds(10))
        #expect(key.token == Data([0x11, 0x22, 0x33, 0x44]))
        #expect(cam.remembered?.adopted == true && cam.remembered?.mode == "basic")
        cam.isOn = true
        let reg = try await cam.connect(pairing: false, timeout: .seconds(1))
        #expect(reg.mode == "basic")
        let b = try await FujiBLEFlows.backupSettings(cam, stateTimeout: .milliseconds(500))
        #expect(b.checksumOK == true && b.data == cam.settings && b.chunks == 588)
        cam.disconnect()
    }

    @Test("Pairing registers a fresh key; the old adopted key no longer works")
    func pairing() async throws {
        let cam = FakeFujiBLECamera()
        let old = try await cam.adoptRegisteredKey(timeout: .milliseconds(10))
        let reg = try await cam.connect(pairing: true, timeout: .seconds(1))
        #expect(reg.mode == "basic")
        #expect(cam.remembered?.adopted == false && cam.remembered?.tokenHex != old.token.hexString)
        cam.disconnect()
    }

    @Test("Secure firmware registers with an identification number; paired-elsewhere refuses until we pair")
    func secureAndElsewhere() async throws {
        let s = FakeFujiBLECamera(scenario: .secureFirmware)
        await #expect(throws: FujiBLEError.self) { try await s.connect(pairing: false, timeout: .seconds(1)) }
        let reg = try await s.connect(pairing: true, timeout: .seconds(1))
        #expect(reg.mode == "secure" && reg.identificationNumber == 0x2000_9607)
        #expect(await s.identity()["firmware"] == "1.32")
        s.disconnect()
        let e = FakeFujiBLECamera(scenario: .pairedElsewhere)
        await #expect(throws: FujiBLEError.pairedElsewhere("7A7AX100VI-7A7A")) { try await e.connect(pairing: false, timeout: .seconds(1)) }
        _ = try await e.connect(pairing: true, timeout: .seconds(1))
        e.disconnect()
        _ = try await e.connect(pairing: false, timeout: .seconds(1))
        e.disconnect()
    }

    @Test("Wi-Fi wake over the fake: open network on fw 1.10, password on 1.32")
    func wifi() async throws {
        let cam = FakeFujiBLECamera()
        _ = try await cam.adoptRegisteredKey(timeout: .milliseconds(10))
        try await cam.connect(pairing: false, timeout: .seconds(1))
        let creds = try await FujiWifiWake.run(cam, apTimeout: .seconds(1))
        #expect(creds.ssid == "FUJIFILM-X100VI-7A7A" && creds.password.isEmpty && !creds.hidden)
        #expect(creds.bssid == "02:00:5E:7A:7A:01")
        #expect(cam.record.wifiLaunches == 1)
        cam.disconnect()
        let s = FakeFujiBLECamera(scenario: .secureFirmware)
        try await s.connect(pairing: true, timeout: .seconds(1))
        let c2 = try await FujiWifiWake.run(s, apTimeout: .seconds(1))
        #expect(c2.password == "rehearsal24" && c2.hidden)
        s.disconnect()
    }

    @Test("It refuses an upload that isn't its own kind of file (another body's K)")
    func refusesForeignFile() async throws {
        let cam = FakeFujiBLECamera()
        _ = try await cam.adoptRegisteredKey(timeout: .milliseconds(10))
        try await cam.connect(pairing: false, timeout: .seconds(1))
        var foreign = [UInt8](cam.settings)
        foreign[0x9000] &+= 1   // payload changed, checksum not fixed → a different K
        await #expect(throws: FujiBLEError.self) {
            try await FujiBLEFlows.restoreSettingsStandard(cam, file: Data(foreign), stateTimeout: .milliseconds(500), ackTimeout: .milliseconds(500))
        }
        #expect(cam.record.applied == 0 && cam.record.uploadsRefused == 1)
        cam.disconnect()
    }
}
