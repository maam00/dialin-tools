// CoreBluetooth central for Fujifilm bodies: scan (company 0x04D8), connect, pair/register, settings backup.
//
// Structure ported from Th0rgal/fuji-bridge FujiBridge/FujiBluetooth.swift (MIT, Copyright (c) 2026 Thomas Marchand),
// which pairs with and wakes an X100VI (fw 1.32). Changes: notifications are buffered FIFO per characteristic (the
// backup gets one transaction-state notify per chunk), all services are discovered (device info included), the
// handshake/backup run through `FujiBLEFlows`, restore is EXPERIMENTAL and speaks the standard restore protocol by
// default (FujiBLERestore.swift, docs/FUJIFILM-PROTOCOL.md §3.7), and a basic-profile body's pairing key is remembered (older firmware,
// e.g. X100VI 1.10) as is a secure body's identification number.
//
// All mutable state lives on `queue`; public async methods hop onto it.
@preconcurrency import CoreBluetooth
import Foundation
import Synchronization

/// Bluetooth power/permission, in the terms the UI needs.
public enum BluetoothPower: Sendable, Equatable {
    case unknown, on, off, denied, unsupported
}

/// One Fujifilm body heard over the air.
public struct FujiBLESighting: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var rssi: Int
    public var advert: FujiAdvert
    public var lastSeen: Date

    /// The protocol the advert says this body speaks.
    public var profile: FujiBLEProfile { advert.profile }
}

public final class FujiBluetoothLink: NSObject, FujiBLECamera, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    /// Name the camera lists for this client (≤30 bytes).
    public let clientName: String
    private let log: @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "co.dialin.camera.ble")
    private var central: CBCentralManager?
    private var found: [UUID: (peripheral: CBPeripheral, sighting: FujiBLESighting)] = [:]
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var stateWaiters: [CheckedContinuation<CBManagerState, Never>] = []
    private var connectWaiter: CheckedContinuation<Void, any Error>?
    private var connectToken: UUID?
    private var discoverWaiter: CheckedContinuation<Void, any Error>?
    private var discoverToken: UUID?
    private var pendingServices = 0
    private var readWaiters = BLERequestRegistry<CheckedContinuation<Data, any Error>>()
    private var writeWaiters = BLERequestRegistry<CheckedContinuation<Void, any Error>>()
    private var valueWaiters = BLERequestRegistry<CheckedContinuation<Data?, Never>>()
    private var notificationWaiters = BLERequestRegistry<CheckedContinuation<Bool, Never>>()
    private var buffered: [String: [Data]] = [:]
    private var linkUp = false
    private var scanning = false

    private static let rememberIDKey = "DialInBLECameraID"
    private static let rememberTagKey = "DialInBLECameraTag"
    /// Basic-profile bodies (firmware before the secure profile, e.g. X100VI 1.10/1.11) advertise a 4-byte token only
    /// in PAIRING REGISTRATION and want it on every later connection (furble FujifilmBasic.cpp:57-83 keeps it in NVS).
    private static let rememberTokenKey = "DialInBLECameraToken"
    /// Secure bodies: the identification number derived once (read | 0x20000000) and written on every connection.
    private static let rememberIdentificationKey = "DialInBLECameraIdentification"
    /// The camera's advertised name (a reconnecting body is matched by name when it has no key in its advert).
    private static let rememberNameKey = "DialInBLECameraName"
    /// "basic" | "secure", after the first successful handshake.
    private static let rememberModeKey = "DialInBLECameraMode"
    /// The key came from `adoptRegisteredKey` (the standby advert), not a PAIRING REGISTRATION of this device.
    private static let rememberAdoptedKey = "DialInBLECameraAdopted"

    public init(clientName: String = "Dial In", log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.clientName = clientName
        self.log = log
        super.init()
    }

    // MARK: Power

    public func power() async -> BluetoothPower {
        switch await poweredState() {
        case .poweredOn: .on
        case .poweredOff: .off
        case .unauthorized: .denied
        case .unsupported: .unsupported
        default: .unknown
        }
    }

    private func requireOn() async throws {
        try Task.checkCancellation()
        let state = await poweredState()
        try Task.checkCancellation()
        switch state {
        case .poweredOn: return
        case .unauthorized: throw FujiBLEError.unauthorized
        case .unsupported: throw FujiBLEError.bluetoothUnsupported
        default: throw FujiBLEError.bluetoothOff
        }
    }

    /// Creating the central triggers the permission prompt; its state is unknown until the first callback.
    private func poweredState() async -> CBManagerState {
        await withCheckedContinuation { (cont: CheckedContinuation<CBManagerState, Never>) in
            queue.async {
                let c = self.ensureCentral()
                if c.state != .unknown && c.state != .resetting {
                    cont.resume(returning: c.state)
                } else {
                    self.stateWaiters.append(cont)
                }
            }
        }
    }

    private func ensureCentral() -> CBCentralManager {
        if let central { return central }
        let c = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        central = c
        return c
    }

    // MARK: Scan

    /// Listen for `duration` and return every Fujifilm body heard (strongest first).
    public func scan(for duration: Duration) async throws -> [FujiBLESighting] {
        try await requireOn()
        startScan()
        defer { stopScan() }
        try await Task.sleep(for: duration)
        try Task.checkCancellation()
        return queue.sync { found.values.map(\.sighting) }.sorted { $0.rssi > $1.rssi }
    }

    private func startScan() {
        queue.async {
            guard let c = self.central, c.state == .poweredOn, !self.scanning else { return }
            self.scanning = true
            // Unfiltered + duplicates: lastSeen stays fresh and an advert change (pairing mode) shows at once.
            // Fujifilm bodies are picked out by company ID 0x04D8 in didDiscover.
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    private func stopScan() {
        queue.async {
            self.scanning = false
            if let c = self.central, c.state == .poweredOn { c.stopScan() }
        }
    }

    // MARK: Connect + register

    /// Find the camera (a connected/remembered body first, else the strongest), connect, discover, and run the
    /// handshake. With `pairing`, wait for registration: basic bodies advertise a key; secure bodies use the OS
    /// pairing prompt. A secure X100VI can drop the link when the code is confirmed; reconnect and retry (3 attempts).
    @discardableResult
    public func connect(pairing: Bool = false, timeout: Duration = .seconds(30)) async throws -> FujiBLEFlows.Registration {
        try await requireOn()
        let pairingSeen = Mutex(false)
        var lastError: any Error = FujiBLEError.notFound
        for attempt in 1...3 {
            try Task.checkCancellation()
            let pickTimeout: Duration = attempt == 1 ? (pairing ? .seconds(120) : timeout) : .seconds(30)
            let (target, advert) = try await pick(timeout: pickTimeout, pairing: pairing && attempt == 1)
            let name = queue.sync { target.name } ?? "Fujifilm"
            log("camera \(name) \(advert.kind.rawValue) \(advert.tag), attempt \(attempt)")
            let remembered = isKnown(queue.sync { target.identifier }, tag: advert.tag)
            // A remembered basic key, but the body now advertises the secure profile: a firmware update changed how it
            // pairs, and the old key is dead (docs/FUJIFILM-PROTOCOL.md §3.1).
            if !pairing, advert.tag != "connected", advert.profile == .secure,
               rememberedBasic(id: queue.sync { target.identifier }, name: name) {
                throw FujiBLEError.profileChanged
            }
            do {
                try await connectPeripheral(target, timeout: .seconds(15))
            } catch FujiBLEError.timeout(let what) {
                // A bonded body advertises for its own phone and never answers anyone else.
                if advert.kind == .reconnect && !remembered && !pairingSeen.withLock({ $0 }) {
                    throw FujiBLEError.pairedElsewhere(name)
                }
                lastError = FujiBLEError.timeout(what)
                if pairingSeen.withLock({ $0 }) { continue }
                throw lastError
            }
            do {
                try await discover(timeout: .seconds(15))
                try Task.checkCancellation()
                let id = queue.sync { target.identifier }
                let token = advert.token ?? rememberedToken(id) ?? rememberedToken(named: name)
                let storedID = rememberedIdentification(id)
                let reg = try await FujiBLEFlows.register(self, clientName: clientName, token: token, identificationNumber: storedID,
                                                          log: log) {
                    pairingSeen.withLock { $0 = true }
                    self.log("PAIRING: confirm the same 6-digit code on this device and on the camera (MENU/OK).")
                }
                try Task.checkCancellation()
                remember(id, tag: advert.tag)
                let d = UserDefaults.standard
                if let fresh = advert.token {
                    d.set(fresh.hexString, forKey: Self.rememberTokenKey)
                    d.set(false, forKey: Self.rememberAdoptedKey)
                } else if let token, d.string(forKey: Self.rememberTokenKey) == nil {
                    d.set(token.hexString, forKey: Self.rememberTokenKey)
                }
                if let n = reg.identificationNumber { d.set(Int(n), forKey: Self.rememberIdentificationKey) }
                if name != "Fujifilm" { d.set(name, forKey: Self.rememberNameKey) }
                if reg.mode != "none" { d.set(reg.mode, forKey: Self.rememberModeKey) }
                return reg
            } catch {
                disconnect()
                if error is CancellationError { throw error }
                lastError = error
                let dropped = if case FujiBLEError.disconnected = error { true } else { false }
                guard pairingSeen.withLock({ $0 }) || dropped || FujiBLEFlows.isPairingPending(error), attempt < 3 else { throw error }
                log("link lost (\(error)); reconnecting, attempt \(attempt + 1) of 3")
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw lastError
    }

    /// Download the whole-camera settings file (the ~33 KB FUJIFILMX-BACKUP the camera sends over Bluetooth). Connects (and
    /// registers) first if needed; drops the link afterwards.
    public func backupSettings(pairing: Bool = false, progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> FujiBLEFlows.SettingsBackup {
        if !(await isLinkUp) { try await connect(pairing: pairing) }
        defer { disconnect() }
        return try await FujiBLEFlows.backupSettings(self, log: log, progress: progress)
    }

    /// Device name / model / firmware over the open link.
    public func identity() async -> [String: String] { await FujiBLEFlows.identity(self) }

    /// Explicit one-slot hardware trial using this paired link. Mandatory callback keeps both original backup
    /// representations before mutation; the production wireless-write gate remains unchanged.
    public func writeLooksExperimental(
        _ placements: [FujiSettingsFile.LookPlacement], experimental: Bool = false,
        allowInferred: Bool = false, protectedSlots: Set<Int> = [], timing: BLESlotWriter.Timing = .real,
        onSafetyBackup: @escaping @Sendable (FujiBLEFlows.SettingsBackup) throws -> Void,
        onPrepared: @escaping @Sendable (Data) throws -> Void = { _ in },
        onStep: @escaping @Sendable (BLESlotWriter.Step) -> Void = { _ in }
    ) async throws -> BLESlotWriter.Outcome {
        try await BLESlotWriter.writeExperimental(placements, to: self, experimental: experimental,
                                                 allowInferred: allowInferred, protectedSlots: protectedSlots,
                                                 timing: timing, onSafetyBackup: onSafetyBackup, onPrepared: onPrepared, onStep: onStep)
    }

    /// Selected-slot recovery merges onto a fresh same-body file and preserves its compressed wire format.
    /// Whole-file `restoreSettings` below remains separately guarded and does not inherit this trial bypass.
    public func restoreLooksExperimental(
        _ backup: Data, slots: Set<Int>, experimental: Bool = false, backupFirmware: String? = nil,
        protectedSlots: Set<Int> = [], timing: BLESlotWriter.Timing = .real,
        onSafetyBackup: @escaping @Sendable (FujiBLEFlows.SettingsBackup) throws -> Void,
        onStep: @escaping @Sendable (BLESlotWriter.Step) -> Void = { _ in }
    ) async throws -> BLESlotWriter.RestoreOutcome {
        try await BLESlotWriter.restoreExperimental(backup, slots: slots, to: self, experimental: experimental,
                                                   backupFirmware: backupFirmware, protectedSlots: protectedSlots,
                                                   timing: timing, onSafetyBackup: onSafetyBackup, onStep: onStep)
    }

    /// EXPERIMENTAL: upload a whole settings file. Needs `experimental: true`. Without a profile this speaks the
    /// standard restore (`FujiBLEFlows.restoreSettingsStandard`); with one, the profile must carry a restore request.
    /// Order: connect + register, SAFETY backup over the same link (handed to `onSafetyBackup` before anything is
    /// written), same-body check, upload, then (verifyAfter) download again and compare.
    @discardableResult
    public func restoreSettings(
        _ file: Data, profile: FujiBLEFlows.RestoreProfile? = nil, experimental: Bool = false, verifyAfter: Bool = true,
        onSafetyBackup: @Sendable (Data) throws -> Void = { _ in }, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> FujiBLEFlows.RestoreResult {
        guard experimental, profile.map(\.hasRequest) ?? true else { throw FujiBLEFlows.restoreUnsupported }
        let header = SettingsFileHeader(file)
        guard header.magicOK else { throw FujiBLEError.unsupported("Not a FUJIFILMX-BACKUP file; refusing to send it.") }
        if !(await isLinkUp) { try await connect() }
        defer { disconnect() }
        log("safety backup over this link before any restore write")
        let safety = try await FujiBLEFlows.backupSettings(self, log: log)
        try onSafetyBackup(safety.data)
        guard !safety.compressed else {
            throw FujiBLEError.unsupported("This camera transfers compressed settings. The experimental restore must preserve and validate that wire format before uploading; no restore request was sent.")
        }
        guard safety.header.model == header.model, safety.header.serial == header.serial else {
            throw FujiBLEError.unsupported("The file is from \(header.model) \(header.serial) but this camera is \(safety.header.model) \(safety.header.serial). Restore only a backup from this same camera.")
        }
        try await Task.sleep(for: .milliseconds(1500))
        var result = if let profile {
            try await FujiBLEFlows.restoreSettings(self, file: file, profile: profile, log: log, progress: progress)
        } else {
            try await FujiBLEFlows.restoreSettingsStandard(self, file: file, log: log, progress: progress)
        }
        if verifyAfter, await isLinkUp {
            try? await Task.sleep(for: .milliseconds(1500))
            if let again = try? await FujiBLEFlows.backupSettings(self, log: log) {
                result.verifiedIdentical = again.data == file
                log(again.data == file ? "post-restore check: the camera serves exactly the file we sent"
                    : "post-restore check: the camera's file differs from what we sent (counters are expected; slots are not)")
            } else {
                log("post-restore download failed; power-cycle and back up again to compare")
            }
        }
        return result
    }

    // MARK: Adopt + remembered camera (FujiBLECamera)

    /// Listen for a switched-off basic body's standby advert (02 + its REGISTERED key, docs/FUJIFILM-PROTOCOL.md §3.2,
    /// §3.4) and keep that key as ours, so the next `connect()` presents it instead of a fresh PAIRING REGISTRATION (which
    /// would replace the phone app's pairing). Only listens; the strongest standby advert wins (Python `adopt`).
    public func adoptRegisteredKey(timeout: Duration = .seconds(20)) async throws -> AdoptedKey {
        try await requireOn()
        let started = Date()
        startScan()
        defer { stopScan() }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let best: FujiBLESighting? = queue.sync {
                found.values.map(\.sighting)
                    .filter { $0.advert.kind == .basicStandby && $0.advert.token != nil && $0.lastSeen >= started }
                    .max { $0.rssi < $1.rssi }
            }
            if let best, let token = best.advert.token {
                // Give other bodies a moment to be heard too, then take the strongest.
                try? await Task.sleep(for: .milliseconds(600))
                let final: FujiBLESighting = queue.sync {
                    found.values.map(\.sighting)
                        .filter { $0.advert.kind == .basicStandby && $0.advert.token != nil && $0.lastSeen >= started }
                        .max { $0.rssi < $1.rssi }
                } ?? best
                let key = final.advert.token ?? token
                let d = UserDefaults.standard
                d.set(final.id.uuidString, forKey: Self.rememberIDKey)
                d.set(key.hexString, forKey: Self.rememberTokenKey)
                d.set(key.hexString, forKey: Self.rememberTagKey)
                d.set(final.name, forKey: Self.rememberNameKey)
                d.set(true, forKey: Self.rememberAdoptedKey)
                d.set("basic", forKey: Self.rememberModeKey)
                d.removeObject(forKey: Self.rememberIdentificationKey)
                log("ADOPTED the registered pairing key \(key.hexString) of \(final.name) (camera off: its standby advert)")
                return AdoptedKey(name: final.name, token: key, peripheralID: final.id)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FujiBLEError.notFound
    }

    public var remembered: RememberedBLECamera? {
        let d = UserDefaults.standard
        let id = d.string(forKey: Self.rememberIDKey).flatMap(UUID.init(uuidString:))
        let token = d.string(forKey: Self.rememberTokenKey)
        let n = d.integer(forKey: Self.rememberIdentificationKey)
        guard id != nil || token != nil || n != 0 else { return nil }
        return RememberedBLECamera(
            peripheralID: id, name: d.string(forKey: Self.rememberNameKey) ?? d.string(forKey: Self.rememberTagKey) ?? "Fujifilm",
            mode: d.string(forKey: Self.rememberModeKey) ?? (token != nil ? "basic" : n != 0 ? "secure" : ""),
            tokenHex: token, identificationNumber: n == 0 ? nil : UInt32(truncatingIfNeeded: n),
            adopted: d.bool(forKey: Self.rememberAdoptedKey))
    }

    public func gattTable() async -> [GATTEntry] {
        queue.sync {
            characteristics.values.map { chr in
                GATTEntry(service: chr.service?.uuid.uuidString ?? "", characteristic: chr.uuid.uuidString,
                          properties: Self.propertyNames(chr.properties))
            }.sorted { ($0.service, $0.characteristic) < ($1.service, $1.characteristic) }
        }
    }

    static func propertyNames(_ p: CBCharacteristicProperties) -> [String] {
        let all: [(CBCharacteristicProperties, String)] = [
            (.broadcast, "broadcast"), (.read, "read"), (.writeWithoutResponse, "writeWithoutResponse"), (.write, "write"),
            (.notify, "notify"), (.indicate, "indicate"), (.authenticatedSignedWrites, "authenticatedSignedWrites"),
            (.extendedProperties, "extendedProperties"), (.notifyEncryptionRequired, "notifyEncryptionRequired"),
            (.indicateEncryptionRequired, "indicateEncryptionRequired"),
        ]
        return all.filter { p.contains($0.0) }.map(\.1)
    }

    public func forget() {
        let d = UserDefaults.standard
        for k in [Self.rememberIDKey, Self.rememberTagKey, Self.rememberTokenKey, Self.rememberIdentificationKey,
                  Self.rememberNameKey, Self.rememberModeKey, Self.rememberAdoptedKey] {
            d.removeObject(forKey: k)
        }
    }

    private func rememberedBasic(id: UUID, name: String) -> Bool {
        let d = UserDefaults.standard
        guard d.string(forKey: Self.rememberModeKey) == "basic" || (d.string(forKey: Self.rememberModeKey) == nil
            && d.string(forKey: Self.rememberTokenKey) != nil && d.integer(forKey: Self.rememberIdentificationKey) == 0) else { return false }
        if d.string(forKey: Self.rememberIDKey) == id.uuidString { return true }
        return name != "Fujifilm" && d.string(forKey: Self.rememberNameKey) == name
    }

    /// The adopted key when the switched-on body turns up under another identifier than its standby advert did
    /// (matched by name).
    private func rememberedToken(named name: String) -> Data? {
        let d = UserDefaults.standard
        guard !name.isEmpty, name != "Fujifilm", d.string(forKey: Self.rememberNameKey) == name else { return nil }
        return d.string(forKey: Self.rememberTokenKey).flatMap(Data.init(hexString:))
    }

    private func rememberedIdentification(_ id: UUID) -> UInt32? {
        guard UserDefaults.standard.string(forKey: Self.rememberIDKey) == id.uuidString else { return nil }
        let n = UserDefaults.standard.integer(forKey: Self.rememberIdentificationKey)
        return n == 0 ? nil : UInt32(truncatingIfNeeded: n)
    }

    private func rememberedToken(_ id: UUID) -> Data? {
        guard UserDefaults.standard.string(forKey: Self.rememberIDKey) == id.uuidString else { return nil }
        return UserDefaults.standard.string(forKey: Self.rememberTokenKey).flatMap(Data.init(hexString:))
    }

    /// Drop the link.
    public func disconnect() {
        queue.async {
            self.scanning = false
            self.central?.stopScan()
            if let p = self.peripheral, let c = self.central { c.cancelPeripheralConnection(p) }
            self.peripheral = nil
            self.linkUp = false
            self.connectToken = nil
            self.discoverToken = nil
            let failure = FujiBLEError.disconnected("connection was closed")
            self.connectWaiter?.resume(throwing: failure)
            self.connectWaiter = nil
            self.discoverWaiter?.resume(throwing: failure)
            self.discoverWaiter = nil
            self.readWaiters.takeAll().forEach { $0.resume(throwing: failure) }
            self.writeWaiters.takeAll().forEach { $0.resume(throwing: failure) }
            self.valueWaiters.takeAll().forEach { $0.resume(returning: nil) }
            self.notificationWaiters.takeAll().forEach { $0.resume(returning: false) }
        }
    }

    // MARK: Picking a body

    private func isKnown(_ id: UUID, tag: String) -> Bool {
        let d = UserDefaults.standard
        if d.string(forKey: Self.rememberIDKey) == id.uuidString { return true }
        guard !tag.isEmpty, tag != "connected" else { return false }
        return d.string(forKey: Self.rememberTagKey) == tag
    }

    private func remember(_ id: UUID, tag: String) {
        let d = UserDefaults.standard
        d.set(id.uuidString, forKey: Self.rememberIDKey)
        if !tag.isEmpty && tag != "connected" { d.set(tag, forKey: Self.rememberTagKey) }
    }

    /// A body already connected to this device, else the remembered one, else the most recently heard
    /// (fuji-bridge `pick`). In pairing mode require a basic pairing advert; secure reconnect adverts remain eligible
    /// because an X100VI (fw 1.32) in PAIRING REGISTRATION keeps advertising 123d8f06 like a bonded body.
    private func pick(timeout: Duration, pairing: Bool) async throws -> (CBPeripheral, FujiAdvert) {
        try Task.checkCancellation()
        let remembered = UserDefaults.standard.string(forKey: Self.rememberIDKey).flatMap(UUID.init(uuidString:))
        startScan()
        defer { stopScan() }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let choice: (CBPeripheral, FujiAdvert)? = queue.sync {
                if !pairing, let c = central {
                    let services = [FujiBLE.configService, FujiBLE.controlService, FujiBLE.securePairService].map { CBUUID(string: $0) }
                    if let already = c.retrieveConnectedPeripherals(withServices: services).first {
                        return (already, FujiAdvert(kind: .reconnect, tag: "connected"))
                    }
                }
                let fresh = Date().addingTimeInterval(-20)
                // A switched-off basic body only sends its standby advert: never try to connect to it.
                var candidates = found.values.filter { $0.sighting.lastSeen > fresh && $0.sighting.advert.kind != .basicStandby }
                    .sorted { $0.sighting.lastSeen > $1.sighting.lastSeen }
                if pairing {
                    candidates = candidates.filter { $0.sighting.advert.allowsPairingAttempt }
                    let p = candidates.filter { $0.sighting.advert.kind == .securePairing || $0.sighting.advert.kind == .basicPairing }
                    if !p.isEmpty { candidates = p }
                }
                if let known = candidates.first(where: { $0.peripheral.identifier == remembered }) {
                    return (known.peripheral, known.sighting.advert)
                }
                return candidates.first.map { ($0.peripheral, $0.sighting.advert) }
            }
            if let choice { return choice }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FujiBLEError.notFound
    }

    private func connectPeripheral(_ target: CBPeripheral, timeout: Duration) async throws {
        let box = UncheckedBox(target)
        let token = UUID()
        let cancelled = Mutex(false)
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard !cancelled.withLock({ $0 }) else { cont.resume(throwing: CancellationError()); return }
                guard let c = self.central else { cont.resume(throwing: FujiBLEError.bluetoothOff); return }
                self.scanning = false
                c.stopScan()
                self.peripheral = box.value
                box.value.delegate = self
                self.connectWaiter?.resume(throwing: FujiBLEError.unexpected("connection superseded"))
                self.connectWaiter = cont
                self.connectToken = token
                c.connect(box.value, options: nil)
                self.queue.asyncAfter(deadline: .now() + seconds(timeout)) {
                    guard self.connectToken == token, let waiter = self.connectWaiter else { return }
                    self.connectToken = nil
                    self.connectWaiter = nil
                    c.cancelPeripheralConnection(box.value)
                    waiter.resume(throwing: FujiBLEError.timeout("connecting over Bluetooth"))
                }
            }
          }
        }, onCancel: {
            cancelled.withLock { $0 = true }
            self.queue.async {
                guard self.connectToken == token else { return }
                self.connectToken = nil
                self.connectWaiter?.resume(throwing: CancellationError())
                self.connectWaiter = nil
                self.central?.cancelPeripheralConnection(box.value)
            }
        })
        try Task.checkCancellation()
        log("connected")
    }

    private func discover(timeout: Duration) async throws {
        let token = UUID()
        let cancelled = Mutex(false)
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard !cancelled.withLock({ $0 }) else { cont.resume(throwing: CancellationError()); return }
                guard let peripheral = self.peripheral, peripheral.state == .connected else {
                    cont.resume(throwing: FujiBLEError.disconnected("link already closed")); return
                }
                self.characteristics = [:]
                self.buffered = [:]
                self.discoverWaiter = cont
                self.discoverToken = token
                peripheral.discoverServices(nil)
                self.queue.asyncAfter(deadline: .now() + seconds(timeout)) {
                    guard self.discoverToken == token, let waiter = self.discoverWaiter else { return }
                    self.discoverToken = nil
                    self.discoverWaiter = nil
                    waiter.resume(throwing: FujiBLEError.timeout("discovering Bluetooth services"))
                }
            }
          }
        }, onCancel: {
            cancelled.withLock { $0 = true }
            self.queue.async {
                guard self.discoverToken == token else { return }
                self.discoverToken = nil
                self.discoverWaiter?.resume(throwing: CancellationError())
                self.discoverWaiter = nil
                if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
            }
        })
        try Task.checkCancellation()
        log("\(queue.sync { characteristics.count }) characteristics")
    }

    // MARK: GATTClient

    public var isLinkUp: Bool {
        get async { queue.sync { linkUp && peripheral?.state == .connected } }
    }

    public var maximumWriteLength: Int? {
        get async { queue.sync { peripheral?.state == .connected ? peripheral?.maximumWriteValueLength(for: .withResponse) : nil } }
    }

    public func has(_ characteristic: String) async -> Bool {
        let key = FujiBLE.normalize(characteristic)
        return queue.sync { characteristics[key] != nil }
    }

    public func read(_ characteristic: String) async throws -> Data {
        let key = FujiBLE.normalize(characteristic)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
            queue.async {
                guard let p = self.peripheral, let chr = self.characteristics[key] else {
                    cont.resume(throwing: FujiBLEError.missingCharacteristic(key))
                    return
                }
                // A read on a dropped link never answers; fail now so the caller can reconnect.
                guard p.state == .connected else {
                    cont.resume(throwing: FujiBLEError.disconnected("link already closed"))
                    return
                }
                let pending = self.readWaiters.insert(cont, for: key)
                pending.previous?.resume(throwing: FujiBLEError.unexpected("read superseded"))
                p.readValue(for: chr)
                // A secure read can sit behind the OS pairing prompt; give the user time to answer it.
                self.queue.asyncAfter(deadline: .now() + 30) {
                    self.readWaiters.take(key, token: pending.token)?.resume(throwing: FujiBLEError.timeout("reading \(key)"))
                }
            }
        }
    }

    public func write(_ characteristic: String, _ value: Data) async throws {
        let key = FujiBLE.normalize(characteristic)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard let p = self.peripheral, let chr = self.characteristics[key] else {
                    cont.resume(throwing: FujiBLEError.missingCharacteristic(key))
                    return
                }
                guard p.state == .connected else {
                    cont.resume(throwing: FujiBLEError.disconnected("link already closed"))
                    return
                }
                guard value.count <= p.maximumWriteValueLength(for: .withResponse) else {
                    cont.resume(throwing: FujiBLEError.transfer("The Bluetooth write is larger than this connection supports (\(value.count) bytes)."))
                    return
                }
                let pending = self.writeWaiters.insert(cont, for: key)
                pending.previous?.resume(throwing: FujiBLEError.unexpected("write superseded"))
                p.writeValue(value, for: chr, type: .withResponse)
                self.queue.asyncAfter(deadline: .now() + 10) {
                    self.writeWaiters.take(key, token: pending.token)?.resume(throwing: FujiBLEError.timeout("writing \(key)"))
                }
            }
        }
    }

    /// Write without response, waiting (≤1 s) for CoreBluetooth's outgoing queue to have room.
    public func writeCommand(_ characteristic: String, _ value: Data) async throws {
        let key = FujiBLE.normalize(characteristic)
        for _ in 0..<200 {
            let ready: Bool? = queue.sync {
                guard let p = peripheral, characteristics[key] != nil, p.state == .connected else { return nil }
                return p.canSendWriteWithoutResponse
            }
            guard let ready else {
                throw (queue.sync { characteristics[key] } == nil) ? FujiBLEError.missingCharacteristic(key) : FujiBLEError.disconnected("link already closed")
            }
            if ready { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        queue.sync {
            if let p = peripheral, let chr = characteristics[key], p.state == .connected {
                p.writeValue(value, for: chr, type: .withoutResponse)
            }
        }
    }

    @discardableResult
    public func subscribe(_ characteristic: String) async -> Bool {
        let key = FujiBLE.normalize(characteristic)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async {
                guard let p = self.peripheral, p.state == .connected, let chr = self.characteristics[key],
                      chr.properties.contains(.notify) || chr.properties.contains(.indicate) else {
                    cont.resume(returning: false)
                    return
                }
                if chr.isNotifying { cont.resume(returning: true); return }
                let pending = self.notificationWaiters.insert(cont, for: key)
                pending.previous?.resume(returning: false)
                p.setNotifyValue(true, for: chr)
                self.queue.asyncAfter(deadline: .now() + 10) {
                    if let waiter = self.notificationWaiters.take(key, token: pending.token) {
                        self.log("notification subscription timed out: \(key.prefix(8))")
                        waiter.resume(returning: false)
                    }
                }
            }
        }
    }

    public func nextValue(_ characteristic: String, timeout: Duration) async -> Data? {
        let key = FujiBLE.normalize(characteristic)
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            queue.async {
                if var q = self.buffered[key], !q.isEmpty {
                    let v = q.removeFirst()
                    self.buffered[key] = q
                    cont.resume(returning: v)
                    return
                }
                if timeout <= .zero || !self.linkUp {
                    cont.resume(returning: nil)
                    return
                }
                let pending = self.valueWaiters.insert(cont, for: key)
                pending.previous?.resume(returning: nil)
                self.queue.asyncAfter(deadline: .now() + seconds(timeout)) {
                    self.valueWaiters.take(key, token: pending.token)?.resume(returning: nil)
                }
            }
        }
    }

    public func drain(_ characteristic: String) async -> [Data] {
        let key = FujiBLE.normalize(characteristic)
        return queue.sync { buffered.removeValue(forKey: key) ?? [] }
    }

    // MARK: CBCentralManagerDelegate (on `queue`)

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        if state != .unknown && state != .resetting {
            let waiters = stateWaiters
            stateWaiters.removeAll()
            waiters.forEach { $0.resume(returning: state) }
        }
        if state != .poweredOn { scanning = false }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        guard let advert = FujiAdvert.parse(manufacturer: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, services: services) else { return }
        let heard = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let previous = found[peripheral.identifier]?.sighting
        let sighting = FujiBLESighting(
            id: peripheral.identifier, name: heard ?? previous?.name ?? "Fujifilm", rssi: RSSI.intValue, advert: advert, lastSeen: Date())
        found[peripheral.identifier] = (peripheral, sighting)
        if previous?.advert != advert || previous?.name != sighting.name {
            log("heard \(sighting.name) \(advert.kind.rawValue) \(advert.tag) rssi \(sighting.rssi)")
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { central.cancelPeripheralConnection(peripheral); return }
        linkUp = true
        connectToken = nil
        connectWaiter?.resume()
        connectWaiter = nil
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let failure = FujiBLEFlows.isStaleBond(error) ? FujiBLEError.staleBond(peripheral.name ?? "the camera")
            : FujiBLEError.disconnected(error.map { "\($0.localizedDescription)" } ?? "failed to connect")
        connectWaiter?.resume(throwing: failure)
        connectWaiter = nil
        connectToken = nil
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let why = error.map { $0.localizedDescription } ?? "closed"
        log("disconnected: \(why)")
        linkUp = false
        let failure = FujiBLEFlows.isStaleBond(error) ? FujiBLEError.staleBond(peripheral.name ?? "the camera") : FujiBLEError.disconnected(why)
        connectWaiter?.resume(throwing: failure)
        connectWaiter = nil
        connectToken = nil
        discoverWaiter?.resume(throwing: failure)
        discoverWaiter = nil
        discoverToken = nil
        readWaiters.takeAll().forEach { $0.resume(throwing: failure) }
        writeWaiters.takeAll().forEach { $0.resume(throwing: failure) }
        valueWaiters.takeAll().forEach { $0.resume(returning: nil) }
        notificationWaiters.takeAll().forEach { $0.resume(returning: false) }
    }

    // MARK: CBPeripheralDelegate (on `queue`)

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let key = FujiBLE.normalize(characteristic.uuid.uuidString)
        let ready = error == nil && characteristic.isNotifying
        if !ready { log("notification subscription refused: \(key.prefix(8))") }
        notificationWaiters.take(key)?.resume(returning: ready)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let services = peripheral.services ?? []
        if let error {
            discoverWaiter?.resume(throwing: FujiBLEFlows.isStaleBond(error) ? FujiBLEError.staleBond(peripheral.name ?? "the camera") : error)
            discoverWaiter = nil
            discoverToken = nil
            return
        }
        pendingServices = services.count
        if services.isEmpty {
            discoverWaiter?.resume()
            discoverWaiter = nil
            discoverToken = nil
        }
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        if let error {
            discoverWaiter?.resume(throwing: FujiBLEFlows.isStaleBond(error) ? FujiBLEError.staleBond(peripheral.name ?? "the camera") : error)
            discoverWaiter = nil
            discoverToken = nil
            return
        }
        for chr in service.characteristics ?? [] {
            let key = FujiBLE.normalize(chr.uuid.uuidString)
            if characteristics[key] == nil { characteristics[key] = chr }
        }
        pendingServices -= 1
        if pendingServices <= 0 {
            discoverWaiter?.resume()
            discoverWaiter = nil
            discoverToken = nil
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let key = FujiBLE.normalize(characteristic.uuid.uuidString)
        let value = characteristic.value ?? Data()
        if let waiter = readWaiters.take(key) {
            if let error {
                waiter.resume(throwing: FujiBLEFlows.isStaleBond(error) ? FujiBLEError.staleBond(peripheral.name ?? "the camera") : error)
            } else {
                waiter.resume(returning: value)
            }
            return
        }
        guard error == nil else { return }
        if let waiter = valueWaiters.take(key) {
            waiter.resume(returning: value)
        } else {
            buffered[key, default: []].append(value)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let key = FujiBLE.normalize(characteristic.uuid.uuidString)
        guard let waiter = writeWaiters.take(key) else { return }
        if let error {
            waiter.resume(throwing: FujiBLEFlows.isStaleBond(error) ? FujiBLEError.staleBond(peripheral.name ?? "the camera") : error)
        } else {
            waiter.resume()
        }
    }
}

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
