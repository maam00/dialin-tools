// A pretend X100VI on Bluetooth, for the app's rehearsal mode and for tests. It speaks the CAMERA side of everything
// the flows use, written from the protocol description (docs/FUJIFILM-PROTOCOL.md §3), not from the client code:
//   - registration: basic (fw 1.10) checks the 4-byte pairing key on every connection and silently ignores backup /
//     restore requests without the registered key; secure (fw 1.32) wants an identification number with 0x20000000;
//   - identity: 2a00 / 2a24 / 2a26;
//   - settings backup: BACKUP_REQUEST → BACKUP_STATE, 120-byte FILE_PARTIAL_DATA chunks pulled by reads, one
//     FILE_TRANSACTION_STATE notify per chunk, the last chunk seq 0xFFFF carrying the u16 sum, FILE_INFORMATION;
//   - restore: RESTORE_REQUEST → RESTORE_STATE, setup writes, transfer started (1), one ack per 128-byte frame,
//     file received (3), applied only on FILE_TRANSFER_RESULT 03 00. It checks the upload the way the camera would:
//     the transport sums, the declared size, the same model/serial/size as its own file and the same checksum
//     constant K (FujiSettingsFile.checksumConstant); anything else ends in transaction state 0 (Error);
//   - Wi-Fi wake: SSID, FUNCTION_LAUNCH → AP_STATE 02 80 (launching) then 01 80 (launched), CAMERA_MAC_ADDRESS.
// When it applies a file it keeps its own frame counter (the block that moves with every shot) and re-stamps the
// checksum, as a camera saving its state would.
import Foundation
import Synchronization

public final class FakeFujiBLECamera: FujiBLECamera, @unchecked Sendable {
    public var isSimulated: Bool { true }
    public enum Scenario: Sendable, Equatable {
        case ok
        /// BACKUP_STATE and RESTORE_STATE answer 0 (camera in a menu / playback / low battery).
        case busy
        /// Backups work; RESTORE_STATE answers 0.
        case restoreBusy
        /// The frame write fails with an ATT error (1-based frame number): how a camera refuses a foreign file.
        case rejectsUpload(atFrame: Int)
        /// The link drops while frame N is written.
        case dropsLink(atFrame: Int)
        /// Accepts the file but only applies it after `powerCycle()`.
        case appliesAfterPowerCycle
        /// fw 1.32: secure registration, a password on its Wi-Fi, and a settings file of another size.
        case secureFirmware
        /// The key we present isn't the registered one: backup / restore requests get no answer.
        case ignoresKey
        /// Bonded to another device: connect() without pairing fails until we pair.
        case pairedElsewhere
        /// iOS still holds keys the camera dropped: every connect fails with FujiBLEError.staleBond until we pair.
        case staleBond
    }

    /// One GATT write the camera received.
    public struct Write: Sendable, Equatable {
        public var characteristic: String
        public var value: Data
    }

    /// What happened, for tests and the rehearsal log.
    public struct Record: Sendable, Equatable {
        public var connections = 0
        public var keyWrites = 0
        public var backupRequests = 0
        public var backupsServed = 0
        public var restoreRequests = 0
        public var framesReceived = 0
        public var uploadsAccepted = 0
        public var uploadsRefused = 0
        public var applied = 0
        public var discarded = 0
        public var results: [String] = []
        public var wifiLaunches = 0
        /// Every write, in order (frames included).
        public var writes: [Write] = []
        /// Exact accepted upload representation, before decompression (tests never substitute expanded bytes).
        public var uploadedWireFiles: [Data] = []
    }

    public let peripheralID = UUID(uuidString: "D1A10000-0000-4000-8000-000000007A7A")!
    public let advertisedName: String
    public let reportedModel: String
    public let firmwareOverride: String?

    private typealias Waiter = (id: Int, cont: CheckedContinuation<Data?, Never>)

    private struct State {
        var scenario: Scenario
        var settings: [UInt8]
        var compressedSettings = false
        var pending: [UInt8]?
        var standbyToken: Data
        var registeredToken: Data
        var secureRead: UInt32 = 0x0000_9607
        var isOn = true
        var pairedWithUs = false
        var frameDelay: Duration = .zero
        var chunkDelay: Duration = .zero
        var mangleNextApply: (@Sendable ([UInt8]) -> [UInt8])?

        var linkUp = false
        var keyAccepted = false
        var subscribed: Set<String> = []
        var queues: [String: [Data]] = [:]
        var waiters: [String: Waiter] = [:]
        var nextWaiter = 0

        var remembered: RememberedBLECamera?
        var rememberedToken: Data?
        var rememberedID: UInt32?

        var partialSize: UInt32?
        var transferIndex: UInt32?
        var backupArmed = false
        var chunks: [Data] = []
        var chunkIndex = 0

        var restoreArmed = false
        var receiving = false
        var declared = 0
        var received: [UInt8] = []
        var expectSeq = 0
        var fileDone = false

        var log: [String] = []
        var record = Record()

        var secure: Bool { scenario == .secureFirmware }

        /// A notification: to a waiting reader, else queued. Dropped when nobody subscribed (as on a camera).
        mutating func push(_ key: String, _ v: [UInt8]) -> (CheckedContinuation<Data?, Never>, Data)? {
            guard linkUp, subscribed.contains(key) else { return nil }
            if let w = waiters.removeValue(forKey: key) { return (w.cont, Data(v)) }
            queues[key, default: []].append(Data(v))
            return nil
        }
    }

    private let state: Mutex<State>

    /// `settings`: the camera's whole settings file (default: `sampleSettings()`, or a 1.32-sized file for
    /// `.secureFirmware`).
    public init(scenario: Scenario = .ok, settings: Data? = nil, standbyToken: Data = Data([0x11, 0x22, 0x33, 0x44]),
                frameDelay: Duration = .zero, chunkDelay: Duration = .zero, name: String = "7A7AX100VI-7A7A",
                reportedModel: String = "X100VI", firmwareOverride: String? = nil, compressedSettings: Bool = false) {
        let file = settings ?? (scenario == .secureFirmware ? Self.secureSampleSettings() : Self.sampleSettings())
        var s = State(scenario: scenario, settings: [UInt8](file), standbyToken: standbyToken, registeredToken: standbyToken)
        s.frameDelay = frameDelay
        s.chunkDelay = chunkDelay
        s.compressedSettings = compressedSettings
        state = Mutex(s)
        advertisedName = name
        self.reportedModel = reportedModel
        self.firmwareOverride = firmwareOverride
    }

    // MARK: Knobs

    public var scenario: Scenario {
        get { state.withLock { $0.scenario } }
        set { state.withLock { $0.scenario = newValue } }
    }

    /// The camera's current settings file (what a backup serves).
    public var settings: Data {
        get { state.withLock { Data($0.settings) } }
        set { state.withLock { $0.settings = [UInt8](newValue) } }
    }

    /// A file accepted under `.appliesAfterPowerCycle`, waiting for `powerCycle()`.
    public var pendingSettings: Data? { state.withLock { $0.pending.map { Data($0) } } }

    /// The registered key a switched-off body broadcasts (and accepts).
    public var standbyToken: Data {
        get { state.withLock { $0.standbyToken } }
        set { state.withLock { $0.standbyToken = newValue; $0.registeredToken = newValue } }
    }

    public var frameDelay: Duration {
        get { state.withLock { $0.frameDelay } }
        set { state.withLock { $0.frameDelay = newValue } }
    }

    public var chunkDelay: Duration {
        get { state.withLock { $0.chunkDelay } }
        set { state.withLock { $0.chunkDelay = newValue } }
    }

    /// Switched off (Bluetooth standby): scans hear only the standby advert.
    public var isOn: Bool {
        get { state.withLock { $0.isOn } }
        set { state.withLock { $0.isOn = newValue } }
    }

    /// Test hook: the next accepted upload is passed through this before the camera stores it (a camera that applies
    /// something other than what it was sent). Cleared after one use.
    public func mangleNextApply(_ f: @escaping @Sendable ([UInt8]) -> [UInt8]) {
        state.withLock { $0.mangleNextApply = f }
    }

    public var record: Record { state.withLock { $0.record } }
    public var log: [String] { state.withLock { $0.log } }

    /// Off and on: drops the link and applies a pending file (`.appliesAfterPowerCycle`).
    public func powerCycle() {
        let waiters = state.withLock { s -> [CheckedContinuation<Data?, Never>] in
            if let p = s.pending { s.settings = p; s.pending = nil; s.log.append("power cycle: applied the pending settings") }
            else { s.log.append("power cycle") }
            return Self.dropLink(&s)
        }
        waiters.forEach { $0.resume(returning: nil) }
    }

    /// A shot moved the frame counter: change [0xF71E, 0xF72A) and re-stamp the checksum (K unchanged).
    public func bumpFrameCounter() {
        state.withLock { s in
            guard s.settings.count > FujiSettingsFile.frameCounterBlock.upperBound else { return }
            var b = s.settings
            let lo = FujiSettingsFile.frameCounterBlock.lowerBound
            let n = Int(b[lo]) | Int(b[lo + 1]) << 8
            b[lo] = UInt8((n + 1) & 0xFF)
            b[lo + 1] = UInt8(((n + 1) >> 8) & 0xFF)
            s.settings = Self.restamp(b, from: s.settings)
            s.log.append("frame counter → \(n + 1)")
        }
    }

    // MARK: Sample files

    /// A synthetic 70,524-byte X100VI fw 1.10 settings file (fake serial) whose C1–C7 hold seven decodable looks:
    /// "Harbor color", "Sunny faces", "Deep blue sea", "Old fisherman", "Faded dock", "Hard noon B&W", "Gritty B&W".
    public static func sampleSettings() -> Data {
        let base = syntheticBase()
        guard let file = try? FujiSettingsFile(bytes: base),
              let patched = try? file.applyingLooks(sampleLooks.enumerated().map { .init(slot: $0.offset + 1, recipe: $0.element) }) else {
            return Data(base)
        }
        return patched.file.data
    }

    /// The looks in `sampleSettings()`, C1 first (every value's encoding verified on a real file).
    public static let sampleLooks: [Recipe] = [
        Recipe(name: "Harbor color", filmSim: .classicChrome, grain: .weakSmall, colorChrome: .weak, whiteBalance: .daylight,
               wbShiftR: 2, wbShiftB: -3, dynamicRange: .dr200, highlight: -0.5, shadow: 1, color: 1, sharpness: -1,
               noiseReduction: -4, clarity: 0),
        Recipe(name: "Sunny faces", filmSim: .proNegStd, whiteBalance: .auto, wbShiftR: 1, wbShiftB: -1, shadow: -1,
               noiseReduction: -4, clarity: -1),
        Recipe(name: "Deep blue sea", filmSim: .velvia, colorChromeFxBlue: .strong, whiteBalance: .daylight, wbShiftB: 1,
               highlight: 0.5, shadow: 1, color: 3, sharpness: 1, noiseReduction: -4, clarity: 1),
        Recipe(name: "Old fisherman", filmSim: .realaAce, grain: .weakLarge, whiteBalance: .kelvin, kelvin: 4350, wbShiftR: 1,
               wbShiftB: -2, dynamicRange: .dr400, highlight: -1, shadow: 0.5, color: 1, sharpness: -1, noiseReduction: -4,
               clarity: 2),
        Recipe(name: "Faded dock", filmSim: .nostalgicNeg, grain: .weakSmall, whiteBalance: .kelvin, kelvin: 6300, wbShiftR: 2,
               wbShiftB: -4, dynamicRange: .dr200, highlight: -1, shadow: -1, color: -1, sharpness: -2, noiseReduction: -4,
               clarity: -2),
        Recipe(name: "Hard noon B&W", filmSim: .acrosR, grain: .strongSmall, highlight: 2, shadow: 2, sharpness: 1,
               noiseReduction: -4, clarity: 2),
        Recipe(name: "Gritty B&W", filmSim: .acrosYe, grain: .strongLarge, dynamicRange: .dr200, highlight: 1.5, shadow: 1.5,
               sharpness: 2, noiseReduction: -4, clarity: 3),
    ]

    /// A newer-firmware file: same header, another size (the fw 1.10 slot map doesn't apply).
    public static func secureSampleSettings() -> Data {
        var b = [UInt8](sampleSettings())
        b += [UInt8](repeating: 0x5A, count: 1024)
        let length = b.count - 0xA8
        for i in 0..<4 { b[0xA0 + i] = UInt8(truncatingIfNeeded: length >> (8 * i)) }
        return Data(Self.restamp(b, from: nil, k: 0xE5AE))
    }

    /// The `syntheticSettings` shape: seeded payload, header, seven names, K = 0xE5AE (the real body's constant).
    static func syntheticBase(seed: UInt64 = 24, k: UInt16 = 0xE5AE) -> [UInt8] {
        var stateLCG = seed
        var b = [UInt8](repeating: 0, count: FujiSettingsFile.fw110Size)
        for i in 0xA8..<b.count {
            stateLCG = stateLCG &* 6364136223846793005 &+ 1442695040888963407
            b[i] = UInt8(truncatingIfNeeded: stateLCG >> 33)
        }
        b.replaceSubrange(0..<16, with: FujiSettingsFile.magic)
        b.replaceSubrange(0x10..<0x14, with: Array("0100".utf8))
        b.replaceSubrange(0x14..<0x34, with: Array("X100VI".utf8) + [UInt8](repeating: 0, count: 26))
        b.replaceSubrange(0x34..<0x54, with: Array("DIALINREHEARSAL1".utf8) + [UInt8](repeating: 0, count: 16))
        func put32(_ o: Int, _ v: Int) { for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        put32(0x98, 0xA8)
        put32(0xA0, b.count - 0xA8)
        put32(0x108, 0)
        for (i, look) in sampleLooks.enumerated() {
            let a = 0xF800 + i * 0x400
            var field = Array(look.slotName.utf8)
            field += [UInt8](repeating: 0, count: FujiSettingsFile.nameFieldLength - field.count)
            b.replaceSubrange(a + FujiSettingsFile.nameRel..<a + FujiSettingsFile.nameRel + FujiSettingsFile.nameFieldLength, with: field)
            b[a + 0x2F] = 0; b[a + 0x31] = 1; b[a + 0x32] = 2; b[a + 0x84] = 3
        }
        b[FujiSettingsFile.frameCounterBlock.lowerBound] = 0x2C
        b[FujiSettingsFile.frameCounterBlock.lowerBound + 1] = 0x01
        return restamp(b, from: nil, k: k)
    }

    /// The checksum constant of any FUJIFILMX-BACKUP-shaped file: stored u16 @0x108 − Σ payload except [0x108, 0x10C).
    static func constantK(_ b: [UInt8]) -> UInt16? {
        guard b.count > 0x10C else { return nil }
        let start = Int(LE.u32(b, 0x98))
        guard start < b.count else { return nil }
        var sum = 0
        for i in start..<b.count where !(0x108..<0x10C).contains(i) { sum += Int(b[i]) }
        return UInt16(truncatingIfNeeded: Int(LE.u16(b, 0x108)) - sum)
    }

    /// Fix the stored checksum so the file carries K (`from`'s K, or `k`).
    static func restamp(_ b: [UInt8], from: [UInt8]?, k: UInt16? = nil) -> [UInt8] {
        guard let want = k ?? from.flatMap(constantK), b.count > 0x10C else { return b }
        var out = b
        let start = Int(LE.u32(out, 0x98))
        var sum = 0
        for i in start..<out.count where !(0x108..<0x10C).contains(i) { sum += Int(out[i]) }
        let v = UInt16(truncatingIfNeeded: sum + Int(want))
        out[0x108] = UInt8(v & 0xFF)
        out[0x109] = UInt8(v >> 8)
        return out
    }

    // MARK: FujiBLECamera

    public func power() async -> BluetoothPower { .on }

    public func scan(for duration: Duration) async throws -> [FujiBLESighting] {
        try? await Task.sleep(for: min(duration, .milliseconds(300)))
        return [sighting()]
    }

    private func sighting() -> FujiBLESighting {
        let (on, secure, token, pairedElsewhere) = state.withLock { ($0.isOn, $0.secure, $0.standbyToken, $0.scenario == .pairedElsewhere && !$0.pairedWithUs) }
        let advert: FujiAdvert = if secure {
            FujiAdvert(kind: .reconnect, tag: "7A7AX")
        } else if !on {
            FujiAdvert(kind: .basicStandby, tag: token.hexString, token: token)
        } else {
            FujiAdvert(kind: pairedElsewhere ? .reconnect : .basic, tag: "")
        }
        return FujiBLESighting(id: peripheralID, name: advertisedName, rssi: -52, advert: advert, lastSeen: Date())
    }

    public func adoptRegisteredKey(timeout: Duration) async throws -> AdoptedKey {
        let secure = state.withLock { $0.secure }
        guard !secure else {
            try? await Task.sleep(for: min(timeout, .milliseconds(300)))
            throw FujiBLEError.notFound
        }
        try? await Task.sleep(for: min(timeout, .milliseconds(300)))
        let token = state.withLock { s -> Data in
            s.rememberedToken = s.standbyToken
            s.remembered = RememberedBLECamera(peripheralID: peripheralID, name: advertisedName, mode: "basic",
                                               tokenHex: s.standbyToken.hexString, identificationNumber: nil, adopted: true)
            s.log.append("adopt: heard the standby advert, key \(s.standbyToken.hexString)")
            return s.standbyToken
        }
        return AdoptedKey(name: advertisedName, token: token, peripheralID: peripheralID)
    }

    @discardableResult
    public func connect(pairing: Bool, timeout: Duration) async throws -> FujiBLEFlows.Registration {
        enum Plan { case basic(Data?), secure(UInt32?), refused(FujiBLEError) }
        let plan: Plan = state.withLock { s in
            if s.scenario == .pairedElsewhere && !pairing && !s.pairedWithUs {
                return .refused(.pairedElsewhere(advertisedName))
            }
            if s.scenario == .staleBond && !pairing && !s.pairedWithUs {
                return .refused(.staleBond(advertisedName))
            }
            if s.secure && !pairing && s.remembered?.mode == "basic" {
                return .refused(.profileChanged)
            }
            if s.secure {
                if !pairing && s.rememberedID == nil { return .refused(.notPaired) }
                return .secure(pairing ? nil : s.rememberedID)
            }
            if pairing {
                // PAIRING REGISTRATION: the camera makes a new key and advertises it; it becomes the registered one.
                let fresh = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
                s.registeredToken = fresh
                s.standbyToken = fresh
                return .basic(fresh)
            }
            return .basic(s.rememberedToken)
        }
        if case .refused(let e) = plan { throw e }
        state.withLock { s in
            s.linkUp = true
            s.keyAccepted = false
            s.subscribed = []
            s.queues = [:]
            s.record.connections += 1
            s.log.append("connected\(pairing ? " (pairing registration)" : "")")
        }
        let token: Data?, storedID: UInt32?
        switch plan {
        case .basic(let t): token = t; storedID = nil
        case .secure(let id): token = nil; storedID = id
        case .refused: token = nil; storedID = nil
        }
        let reg = try await FujiBLEFlows.register(self, clientName: "Dial In", token: token, identificationNumber: storedID,
                                                  pairingAttempts: 0, pause: .zero)
        state.withLock { s in
            if pairing { s.pairedWithUs = true }
            if let token { s.rememberedToken = token }
            if let n = reg.identificationNumber { s.rememberedID = n }
            let adopted = pairing ? false : (s.remembered?.adopted ?? false)
            s.remembered = RememberedBLECamera(peripheralID: peripheralID, name: advertisedName, mode: reg.mode,
                                               tokenHex: token?.hexString, identificationNumber: reg.identificationNumber, adopted: adopted)
        }
        return reg
    }

    public func identity() async -> [String: String] { await FujiBLEFlows.identity(self) }

    public func disconnect() {
        let waiters = state.withLock { s -> [CheckedContinuation<Data?, Never>] in
            guard s.linkUp else { return [] }
            s.log.append("disconnected")
            return Self.dropLink(&s)
        }
        waiters.forEach { $0.resume(returning: nil) }
    }

    public var remembered: RememberedBLECamera? { state.withLock { $0.remembered } }

    public func forget() {
        state.withLock { s in
            s.remembered = nil
            s.rememberedToken = nil
            s.rememberedID = nil
        }
    }

    private static func dropLink(_ s: inout State) -> [CheckedContinuation<Data?, Never>] {
        s.linkUp = false
        s.keyAccepted = false
        s.subscribed = []
        s.queues = [:]
        if s.restoreArmed || s.receiving || s.fileDone { s.record.discarded += 1 }
        s.backupArmed = false
        s.restoreArmed = false
        s.receiving = false
        s.fileDone = false
        let w = s.waiters.values.map(\.cont)
        s.waiters = [:]
        return w
    }

    // MARK: GATT (the camera's side)

    /// Service of each characteristic the fake offers (from ble/fuji_ble/gatt.py's tables).
    private static let serviceOf: [String: String] = [
        FujiBLE.pairingToken: FujiBLE.basicPairService, FujiBLE.clientName: FujiBLE.basicPairService,
        FujiBLE.secureStatus: FujiBLE.securePairService,
        FujiBLE.deviceName: FujiBLE.normalize("1800"), FujiBLE.modelNumber: FujiBLE.normalize("180a"),
        FujiBLE.firmwareRevision: FujiBLE.normalize("180a"), FujiBLE.serialNumber: FujiBLE.normalize("180a"),
        FujiBLE.backupRequest: FujiBLE.controlService, FujiBLE.restoreRequest: FujiBLE.controlService,
        FujiBLE.functionLaunch: FujiBLE.controlService,
        FujiBLE.backupState: FujiBLE.configService, FujiBLE.restoreState: FujiBLE.configService, FujiBLE.apState: FujiBLE.configService,
        FujiBLE.transferState: FujiBLE.configService, FujiBLE.timeSyncRequest: FujiBLE.configService,
        FujiBLE.locationRequest: FujiBLE.configService,
        FujiWifiWake.ssidCharacteristic: FujiBLE.wifiService, FujiWifiWake.passwordCharacteristic: FujiBLE.wifiService,
        FujiBLE.geotagInterval: FujiBLE.wifiService, "aab609c4-94dd-4d89-bc60-665d5090b828": FujiBLE.wifiService,
        FujiBLE.cameraMacAddress: FujiBLE.cameraInfoBasicService,
        FujiBLE.time: "e872b11f-0000-0000-0000-000000000000", FujiBLE.utcTimeAndZone: "e872b11f-0000-0000-0000-000000000000",
        FujiBLE.locationFix: "3b46ec2b-0000-0000-0000-000000000000",
    ]

    public func gattTable() async -> [GATTEntry] {
        let (up, secure) = state.withLock { ($0.linkUp, $0.secure) }
        guard up else { return [] }
        let extra: Set<String> = secure ? [FujiBLE.secureStatus, FujiWifiWake.passwordCharacteristic]
            : [FujiBLE.pairingToken, FujiBLE.serialNumber]
        return Self.common.union(extra).map { c in
            let props: [String] = if Self.notifiable.contains(c) {
                ["read", c == FujiBLE.fileTransactionState ? "notify" : "indicate"]
            } else if [FujiBLE.deviceName, FujiBLE.modelNumber, FujiBLE.firmwareRevision, FujiBLE.serialNumber,
                       FujiBLE.cameraMacAddress, FujiWifiWake.passwordCharacteristic].contains(c) {
                ["read"]
            } else {
                ["read", "write"]
            }
            return GATTEntry(service: Self.serviceOf[c] ?? FujiBLE.fileService, characteristic: c, properties: props)
        }.sorted { ($0.service, $0.characteristic) < ($1.service, $1.characteristic) }
    }

    private static let common: Set<String> = [
        FujiBLE.clientName, FujiBLE.deviceName, FujiBLE.modelNumber, FujiBLE.firmwareRevision,
        FujiBLE.backupRequest, FujiBLE.backupState, FujiBLE.restoreRequest, FujiBLE.restoreState,
        FujiBLE.filePartialSize, FujiBLE.fileTransferIndex, FujiBLE.fileInformation, FujiBLE.filePartialData,
        FujiBLE.fileTransferResult, FujiBLE.fileTransactionState, FujiWifiWake.ssidCharacteristic, FujiBLE.functionLaunch,
        FujiBLE.apState, FujiBLE.cameraMacAddress, FujiBLE.utcTimeAndZone, FujiBLE.locationFix,
        FujiBLE.locationRequest, FujiBLE.transferState, FujiBLE.timeSyncRequest, FujiBLE.time, FujiBLE.geotagInterval,
        "aab609c4-94dd-4d89-bc60-665d5090b828",
    ]
    private static let notifiable: Set<String> = [
        FujiBLE.apState, FujiBLE.transferState, FujiBLE.timeSyncRequest, FujiBLE.locationRequest,
        FujiWifiWake.ssidCharacteristic, "aab609c4-94dd-4d89-bc60-665d5090b828", FujiBLE.geotagInterval,
        FujiBLE.fileTransactionState, FujiBLE.backupState, FujiBLE.restoreState,
    ]

    public func has(_ characteristic: String) async -> Bool {
        let key = FujiBLE.normalize(characteristic)
        let secure = state.withLock { $0.secure }
        if Self.common.contains(key) { return true }
        if secure { return key == FujiBLE.secureStatus || key == FujiWifiWake.passwordCharacteristic }
        return key == FujiBLE.pairingToken || key == FujiBLE.serialNumber
    }

    public var isLinkUp: Bool { get async { state.withLock { $0.linkUp } } }

    public func subscribe(_ characteristic: String) async -> Bool {
        let key = FujiBLE.normalize(characteristic)
        guard await has(key) else { return false }
        return state.withLock { s in
            guard s.linkUp, Self.notifiable.contains(key) else { return false }
            s.subscribed.insert(key)
            return true
        }
    }

    public func drain(_ characteristic: String) async -> [Data] {
        let key = FujiBLE.normalize(characteristic)
        return state.withLock { $0.queues.removeValue(forKey: key) ?? [] }
    }

    public func nextValue(_ characteristic: String, timeout: Duration) async -> Data? {
        let key = FujiBLE.normalize(characteristic)
        let id = state.withLock { s -> Int in s.nextWaiter += 1; return s.nextWaiter }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let (now, superseded): (Data??, CheckedContinuation<Data?, Never>?) = state.withLock { s in
                if var q = s.queues[key], !q.isEmpty {
                    let v = q.removeFirst()
                    s.queues[key] = q
                    return (.some(v), nil)
                }
                if timeout <= .zero || !s.linkUp { return (.some(nil), nil) }
                let old = s.waiters.removeValue(forKey: key)?.cont
                s.waiters[key] = (id, cont)
                return (.none, old)
            }
            superseded?.resume(returning: nil)
            if let now {
                cont.resume(returning: now)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                let w = self.state.withLock { s -> CheckedContinuation<Data?, Never>? in
                    guard s.waiters[key]?.id == id else { return nil }
                    return s.waiters.removeValue(forKey: key)?.cont
                }
                w?.resume(returning: nil)
            }
        }
    }

    private func text(_ s: String, pad: Int = 0) -> Data {
        var d = Data(s.utf8)
        if d.count < pad { d.append(Data(count: pad - d.count)) }
        return d
    }

    public func read(_ characteristic: String) async throws -> Data {
        let key = FujiBLE.normalize(characteristic)
        let (up, secure) = state.withLock { ($0.linkUp, $0.secure) }
        guard up else { throw FujiBLEError.disconnected("link already closed") }
        guard await has(key) else { throw FujiBLEError.missingCharacteristic(key) }
        switch key {
        case FujiBLE.serialNumber: return text("7A7AREHEARSAL")
        case FujiBLE.deviceName: return text(advertisedName)
        case FujiBLE.modelNumber: return text(reportedModel)
        case FujiBLE.firmwareRevision: return text(firmwareOverride ?? (secure ? "1.32" : "1.10"))
        case FujiBLE.secureStatus: return PTPPack.u32(state.withLock { $0.secureRead })
        case FujiBLE.backupState:
            return state.withLock { s in Data([s.keyAccepted && s.backupArmed && s.scenario != .busy ? 1 : 0, 0]) }
        case FujiBLE.restoreState:
            return state.withLock { s in Data([s.keyAccepted && s.restoreArmed ? 1 : 0, 0]) }
        case FujiBLE.fileInformation:
            return state.withLock { FileInformation.build(name: FujiBLE.backupFileName, size: $0.settings.count) }
        case FujiWifiWake.ssidCharacteristic: return text("FUJIFILM-X100VI-7A7A", pad: 32)
        case FujiWifiWake.passwordCharacteristic: return text("rehearsal24", pad: 20)
        case FujiBLE.cameraMacAddress: return text("02-00-5E-7A-7A-01")
        case FujiBLE.filePartialData:
            let delay = state.withLock { $0.chunkDelay }
            if delay > .zero { try? await Task.sleep(for: delay) }
            let (chunk, deliver) = state.withLock { s -> (Data?, (CheckedContinuation<Data?, Never>, Data)?) in
                guard s.backupArmed, s.chunkIndex < s.chunks.count else { return (nil, nil) }
                let c = s.chunks[s.chunkIndex]
                s.chunkIndex += 1
                let next: [UInt8] = s.chunkIndex < s.chunks.count
                    ? [2, 0, UInt8(s.chunkIndex & 0xFF), UInt8((s.chunkIndex >> 8) & 0xFF)] : [3, 0, 0xFF, 0xFF]
                return (c, s.push(FujiBLE.fileTransactionState, next))
            }
            if let deliver { deliver.0.resume(returning: deliver.1) }
            return chunk ?? Data()
        default:
            return Data()
        }
    }

    public func write(_ characteristic: String, _ value: Data) async throws {
        let key = FujiBLE.normalize(characteristic)
        guard state.withLock({ $0.linkUp }) else { throw FujiBLEError.disconnected("link already closed") }
        guard await has(key) else { throw FujiBLEError.missingCharacteristic(key) }
        state.withLock { $0.record.writes.append(Write(characteristic: key, value: value)) }
        let b = [UInt8](value)
        if key == FujiBLE.filePartialData {
            try await receiveFrame(b)
            return
        }
        var deliveries: [(CheckedContinuation<Data?, Never>, Data)] = []
        state.withLock { s in
            func push(_ c: String, _ v: [UInt8]) { if let d = s.push(c, v) { deliveries.append(d) } }
            switch key {
            case FujiBLE.pairingToken:
                s.record.keyWrites += 1
                s.keyAccepted = s.scenario != .ignoresKey && value == s.registeredToken
                s.log.append("pairing key \(value.hexString) \(s.keyAccepted ? "accepted" : "not the registered one: ignoring this client")")
            case FujiBLE.secureStatus:
                s.record.keyWrites += 1
                let id = b.count == 4 ? LE.u32(b, 0) : 0
                s.keyAccepted = s.scenario != .ignoresKey && id & FujiBLE.clientIDFlag != 0
                s.log.append("identification number \(value.hexString)")
            case FujiBLE.backupRequest:
                s.record.backupRequests += 1
                guard s.keyAccepted else { s.log.append("backup request ignored (not registered)"); return }
                let busy = s.scenario == .busy
                s.backupArmed = !busy
                push(FujiBLE.backupState, busy ? [0, 0] : [1, 0])
            case FujiBLE.restoreRequest:
                s.record.restoreRequests += 1
                guard s.keyAccepted else { s.log.append("restore request ignored (not registered)"); return }
                let busy = s.scenario == .busy || s.scenario == .restoreBusy
                s.restoreArmed = !busy && value == FujiBLE.restoreRequestSettings
                push(FujiBLE.restoreState, s.restoreArmed ? [1, 0] : [0, 0])
            case FujiBLE.filePartialSize:
                s.partialSize = b.count >= 4 ? LE.u32(b, 0) : nil
            case FujiBLE.fileTransferIndex:
                s.transferIndex = b.count >= 4 ? LE.u32(b, 0) : nil
                if s.backupArmed && !s.restoreArmed && s.partialSize == 120 && s.transferIndex == 0 {
                    let wire = s.compressedSettings ? (try? BLEBackupPayload.compress(Data(s.settings))) : Data(s.settings)
                    guard let wire else { return }
                    s.chunks = Self.backupChunks([UInt8](wire))
                    s.chunkIndex = 0
                    push(FujiBLE.fileTransactionState, [1, 0, 0, 0])
                }
            case FujiBLE.fileInformation where s.restoreArmed:
                guard let info = try? FileInformation.parse(value), value.count == 44, info.name == FujiBLE.backupFileName,
                      s.partialSize == 120, s.transferIndex == 0 else {
                    s.log.append("restore setup refused")
                    push(FujiBLE.fileTransactionState, [0, 0, 0xFF, 0xFF])
                    return
                }
                s.declared = info.size
                s.receiving = true
                s.received = []
                s.expectSeq = 0
                push(FujiBLE.fileTransactionState, [1, 0, 0, 0])
            case FujiBLE.fileTransferResult:
                s.record.results.append(value.hexString)
                if s.backupArmed && !s.restoreArmed {
                    s.backupArmed = false
                    if value == FujiBLE.transferResultOK { s.record.backupsServed += 1 }
                    return
                }
                if value == FujiBLE.resultEnd && s.fileDone {
                    Self.apply(&s)
                } else if s.restoreArmed || s.receiving || s.fileDone {
                    s.record.discarded += 1
                    s.log.append("restore ended with \(value.hexString): nothing applied")
                }
                s.restoreArmed = false
                s.receiving = false
                s.fileDone = false
            case FujiBLE.functionLaunch:
                s.record.wifiLaunches += 1
                if s.scenario == .busy {
                    push(FujiBLE.apState, [0x00, 0x80])
                } else {
                    push(FujiBLE.apState, [0x02, 0x80])
                    push(FujiBLE.apState, [0x01, 0x80])
                }
            default:
                break
            }
        }
        deliveries.forEach { $0.0.resume(returning: $0.1) }
    }

    /// One restore frame: u16 seq | u32 size | data | u16 trailer; the last (seq 0xFFFF) carries the sum twice.
    private func receiveFrame(_ b: [UInt8]) async throws {
        enum Fault { case reject(Int), drop(Int) }
        let (frameNo, fault, delay): (Int, Fault?, Duration) = state.withLock { s in
            guard s.receiving else { return (0, nil, .zero) }
            let n = s.expectSeq + 1
            switch s.scenario {
            case .rejectsUpload(let at) where at == n: return (n, .reject(n), .zero)
            case .dropsLink(let at) where at == n: return (n, .drop(n), .zero)
            default: return (n, nil, s.frameDelay)
            }
        }
        guard frameNo > 0 else { return }   // not receiving: a stray write, ignored
        switch fault {
        case .reject(let n)?:
            state.withLock { s in
                s.receiving = false
                s.record.uploadsRefused += 1
                s.log.append("frame \(n): refused (ATT error, simulated)")
            }
            throw FujiBLEError.transfer("ATT error 0x80 on frame \(n) (simulated)")
        case .drop(let n)?:
            let waiters = state.withLock { s -> [CheckedContinuation<Data?, Never>] in
                s.log.append("frame \(n): the link dropped (simulated)")
                return Self.dropLink(&s)
            }
            waiters.forEach { $0.resume(returning: nil) }
            throw FujiBLEError.disconnected("link lost on frame \(n) (simulated)")
        case nil:
            break
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        let delivery = state.withLock { s -> (CheckedContinuation<Data?, Never>, Data)? in
            func fail(_ why: String) -> (CheckedContinuation<Data?, Never>, Data)? {
                s.receiving = false
                s.record.uploadsRefused += 1
                s.log.append("restore refused: \(why)")
                return s.push(FujiBLE.fileTransactionState, [0, 0, 0xFF, 0xFF])
            }
            guard b.count >= 8 else { return fail("short frame") }
            s.record.framesReceived += 1
            let seq = LE.u16(b, 0), size = Int(LE.u32(b, 2))
            guard b.count == 6 + size + 2 else { return fail("frame length \(b.count) vs size \(size)") }
            let data = Array(b[6..<(6 + size)]), trailer = LE.u16(b, 6 + size)
            if seq != FujiBLE.lastSeq {
                guard Int(seq) == s.expectSeq, trailer == 0, size == 120 else { return fail("seq \(seq) size \(size) trailer \(trailer)") }
                s.received += data
                s.expectSeq += 1
                return s.push(FujiBLE.fileTransactionState, [2, 0, UInt8(seq & 0xFF), UInt8(seq >> 8)])
            }
            guard size >= 2 else { return fail("terminal frame missing checksum") }
            let body = Array(data.prefix(size - 2))
            s.received += body
            let want = UInt16(byteSum16(Data(s.received)))
            let inData = LE.u16(Array(data.suffix(2)), 0)
            guard inData == want, trailer == want else { return fail("transport sums") }
            guard s.received.count == s.declared else { return fail("size \(s.received.count), declared \(s.declared)") }
            let wire = Data(s.received)
            guard let decoded = try? BLEBackupPayload.decode(wire, reportedSize: s.settings.count),
                  decoded.compressed == s.compressedSettings else { return fail("wire compression format") }
            s.received = [UInt8](decoded.data)
            guard s.received.count == s.settings.count, Array(s.received[0..<0x54]) == Array(s.settings[0..<0x54]) else {
                return fail("not this body's file (model, serial or size)")
            }
            guard let kIn = Self.constantK(s.received), kIn == Self.constantK(s.settings) else {
                return fail("checksum: the file doesn't carry this body's constant")
            }
            s.receiving = false
            s.fileDone = true
            s.record.uploadsAccepted += 1
            s.record.uploadedWireFiles.append(wire)
            return s.push(FujiBLE.fileTransactionState, [3, 0, 0xFF, 0xFF])
        }
        if let delivery { delivery.0.resume(returning: delivery.1) }
    }

    private static func apply(_ s: inout State) {
        var file = s.received
        // The camera keeps its own frame counter and re-stamps its checksum when it saves.
        let block = FujiSettingsFile.frameCounterBlock
        if file.count == s.settings.count, file.count > block.upperBound {
            file.replaceSubrange(block, with: s.settings[block])
            file = restamp(file, from: s.settings)
        }
        if let mangle = s.mangleNextApply {
            file = restamp(mangle(file), from: s.settings)
            s.mangleNextApply = nil
        }
        s.record.applied += 1
        if s.scenario == .appliesAfterPowerCycle {
            s.pending = file
            s.log.append("restore accepted; applies at the next power cycle")
        } else {
            s.settings = file
            s.log.append("restore applied")
        }
    }

    /// The download's chunks: 120 file bytes each, the last one seq 0xFFFF with the u16 sum of every byte appended.
    static func backupChunks(_ file: [UInt8]) -> [Data] {
        let chunk = Int(FujiBLE.backupPartialSize)
        let count = max(1, (file.count + chunk - 1) / chunk)
        let sum = UInt16(byteSum16(Data(file)))
        return (0..<count).map { i in
            var piece = Data(file[(i * chunk)..<min((i + 1) * chunk, file.count)])
            if i == count - 1 {
                piece.appendLE16(sum)
                return FileChunk.build(seq: FujiBLE.lastSeq, payload: piece)
            }
            return FileChunk.build(seq: UInt16(truncatingIfNeeded: i), payload: piece)
        }
    }
}
