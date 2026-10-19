// The BLE conversations, written against a small GATT protocol so they run against a fake camera in tests.
//
// Registration: ble/fuji_ble/client.py `identify` + `subscribe_many` (from fuji-bridge FujiBluetooth.swift:185-260,
// furble FujifilmSecure.cpp:117-141, libfuji bluetooth.c:453-501).
// Settings backup: client.py `backup_once` (from fuji-bridge FujiBackup.swift:35-97), documented in
// docs/FUJIFILM-PROTOCOL.md §3.6.
@preconcurrency import CoreBluetooth
import Foundation
import Synchronization

/// The GATT operations the flows need. `FujiBluetoothLink` provides them over CoreBluetooth.
public protocol GATTClient: AnyObject, Sendable {
    func has(_ characteristic: String) async -> Bool
    func read(_ characteristic: String) async throws -> Data
    func write(_ characteristic: String, _ value: Data) async throws
    /// Write without response (ATT Write Command). Default: a normal write.
    func writeCommand(_ characteristic: String, _ value: Data) async throws
    /// Best effort: true if the characteristic exists and can notify/indicate.
    @discardableResult func subscribe(_ characteristic: String) async -> Bool
    /// Next value the body pushes on this characteristic (buffered FIFO), or nil after the timeout.
    func nextValue(_ characteristic: String, timeout: Duration) async -> Data?
    /// Drop buffered notifications (stale values from before a request).
    func drain(_ characteristic: String) async -> [Data]
    var isLinkUp: Bool { get async }
    /// Negotiated ATT write-with-response payload capacity, when the transport exposes it.
    var maximumWriteLength: Int? { get async }
}

extension GATTClient {
    public func writeCommand(_ characteristic: String, _ value: Data) async throws { try await write(characteristic, value) }
    public var maximumWriteLength: Int? { get async { nil } }
}

public enum FujiBLEFlows {
    public struct Registration: Sendable, Equatable {
        /// "secure" | "basic" | "none"
        public var mode: String
        public var statusBefore: Data?
        public var statusWritten: Data?
        public var clientName: String
        public var pairingPromptSeen: Bool
        public var subscribed: [String]
        public var missing: [String]
        /// Secure bodies: the identification number we wrote (save it; it is reused on every connection).
        public var identificationNumber: UInt32? = nil
        /// Basic bodies: the serial (2a25), read before sending the pairing key.
        public var serialRead: String? = nil
    }

    public struct SettingsBackup: Sendable, Equatable {
        /// File name the camera reports ("backup.dat").
        public var name: String
        /// Expanded settings file for decoding. Transport checksums cover wireData instead.
        public var data: Data
        /// Exactly the received file bytes, excluding BLE framing/checksum trailers.
        public var wireData: Data
        public var compressed: Bool
        public var reportedSize: Int?
        public var expectedSum: Int?
        public var computedSum: Int
        /// Nil when the camera sent no checksum trailer.
        public var checksumOK: Bool?
        public var chunks: Int
        public var seqReport: String
        public var seconds: Double
        public var header: SettingsFileHeader
    }

    /// ATT "insufficient authentication" (5) or "insufficient encryption" (15): the bond isn't there yet
    /// (fuji-bridge FujiWake.isPairingPending).
    public static func isPairingPending(_ error: any Error) -> Bool {
        if let e = error as? FujiBLEError, e == .notPaired { return true }
        let ns = error as NSError
        return ns.domain == CBATTErrorDomain
            && (ns.code == CBATTError.Code.insufficientEncryption.rawValue || ns.code == CBATTError.Code.insufficientAuthentication.rawValue)
    }

    /// iOS / macOS still hold keys the camera dropped: CBError.peerRemovedPairingInformation (14, "Peer removed pairing
    /// information"), also seen reported as ATT code 14 (docs/FUJIFILM-PROTOCOL.md §3.5). Only Forget This Device clears it.
    public static func isStaleBond(_ error: (any Error)?) -> Bool {
        guard let error else { return false }
        if let e = error as? FujiBLEError, case .staleBond = e { return true }
        let ns = error as NSError
        if ns.domain == CBErrorDomain && ns.code == CBError.Code.peerRemovedPairingInformation.rawValue { return true }
        if ns.domain == CBATTErrorDomain && ns.code == 14 { return true }
        return ns.localizedDescription.localizedCaseInsensitiveContains("removed pairing information")
    }

    /// The first encrypted read starts OS pairing. macOS fails it at once with "Encryption is insufficient" while the
    /// user compares the 6-digit code, and dropping the link makes the camera show "pairing canceled". So keep the link
    /// and ask again (fuji-bridge FujiBluetooth.swift:230-246: 30 tries, 2 s apart).
    public static func readThroughPairing(
        _ gatt: any GATTClient, _ characteristic: String, attempts: Int = 30, pause: Duration = .seconds(2),
        onPrompt: @Sendable () -> Void = {}
    ) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await gatt.read(characteristic)
            } catch where isPairingPending(error) {
                attempt += 1
                if attempt == 1 { onPrompt() }
                if attempt > attempts { throw FujiBLEError.notPaired }
                try await Task.sleep(for: pause)
            }
        }
    }

    /// Per-connection handshake (docs/FUJIFILM-PROTOCOL.md §3.4-3.5; Python client.py `identify`).
    /// Secure bodies (fw 1.30+): read the identification number (f557d96b), write back the saved id or the
    /// value OR 0x20000000 (the same bytes as the "byte 3 = 0x20" rule on a first pairing). Basic bodies (fw 1.10/1.11):
    /// read the serial (2a25), write the 4-byte pairing key from the PAIRING REGISTRATION advert — every connection.
    /// Then the client name, UTF-8 + NUL; then the subscriptions (libfuji's list). It never writes the app-identity
    /// characteristic (8b5ecf55): Dial In doesn't present as FUJIFILM's app.
    public static func register(
        _ gatt: any GATTClient, clientName: String, token: Data? = nil, identificationNumber: UInt32? = nil,
        pairingAttempts: Int = 30, pause: Duration = .seconds(2), log: @Sendable (String) -> Void = { _ in },
        onPrompt: @Sendable () -> Void = {}
    ) async throws -> Registration {
        let promptSeen = Mutex(false)
        var reg = Registration(mode: "none", clientName: clientName, pairingPromptSeen: false, subscribed: [], missing: [])
        if await gatt.has(FujiBLE.secureStatus) {
            let status = try await readThroughPairing(gatt, FujiBLE.secureStatus, attempts: pairingAttempts, pause: pause) {
                promptSeen.withLock { $0 = true }
                onPrompt()
            }
            reg.statusBefore = status
            let id = try FujiBLE.identificationNumber(status, stored: identificationNumber)
            let ack = PTPPack.u32(id)
            try await gatt.write(FujiBLE.secureStatus, ack)
            reg.statusWritten = ack
            reg.identificationNumber = id
            reg.mode = "secure"
            log("identification number \(status.hexString) → \(ack.hexString)")
        } else if await gatt.has(FujiBLE.pairingToken) {
            guard let token, token.count == 4 else {
                throw FujiBLEError.pairingKeyMissing
            }
            if await gatt.has(FujiBLE.serialNumber), let serial = try? await gatt.read(FujiBLE.serialNumber) {
                reg.serialRead = String(decoding: serial.prefix { $0 != 0 }, as: UTF8.self)
            }
            try await gatt.write(FujiBLE.pairingToken, token)
            reg.mode = "basic"
            log("basic pairing key sent")
        } else {
            throw FujiBLEError.unsupported("This camera's Bluetooth registration method is not supported yet.")
        }
        // 85b9163e, max 0x1E bytes: UTF-8 + NUL.
        try await gatt.write(FujiBLE.clientName, FujiBLE.encodeClientName(clientName))
        log("identified as \"\(clientName)\"")
        // Some newer bodies also offer the app-identity characteristic (8b5ecf55). Dial In never presents as FUJIFILM's
        // app, so it never writes it.
        // TODO(newer bodies): test registration without 8b5ecf55 on a body that offers it.
        for u in FujiBLE.subscriptions {
            if await gatt.subscribe(u) { reg.subscribed.append(u) } else { reg.missing.append(u) }
        }
        reg.pairingPromptSeen = promptSeen.withLock { $0 }
        return reg
    }

    /// Device name, model and firmware from the standard characteristics, when present.
    public static func identity(_ gatt: any GATTClient) async -> [String: String] {
        var out: [String: String] = [:]
        for (key, uuid) in [("device_name", FujiBLE.deviceName), ("model", FujiBLE.modelNumber), ("firmware", FujiBLE.firmwareRevision)] {
            guard await gatt.has(uuid), let v = try? await gatt.read(uuid) else { continue }
            out[key] = String(decoding: v.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Download the whole-camera settings file over BLE (client.py `backup_once`):
    /// 1 subscribe FILE_TRANSACTION_STATE + BACKUP_STATE, 2 write BACKUP_REQUEST 01 00, 3 wait ≤10 s for BACKUP_STATE 1,
    /// 4 write FILE_PARTIAL_SIZE u32 120 and FILE_TRANSFER_INDEX u32 0, 5 on each state 1/2 read FILE_PARTIAL_DATA,
    /// 6 on state 3 verify the sum, read FILE_INFORMATION, write FILE_TRANSFER_RESULT 03 00 (00 00 on any error).
    public static func backupSettings(
        _ gatt: any GATTClient, partialSize: UInt32 = FujiBLE.backupPartialSize, stateTimeout: Duration = .seconds(10),
        chunkTimeout: Duration = .seconds(20), log: @Sendable (String) -> Void = { _ in },
        progress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> SettingsBackup {
        for needed in [FujiBLE.backupRequest, FujiBLE.backupState, FujiBLE.filePartialData, FujiBLE.fileTransactionState] {
            guard await gatt.has(needed) else {
                throw FujiBLEError.unsupported("This camera doesn't offer the Bluetooth settings backup (no \(needed)).")
            }
        }
        let started = ContinuousClock.now
        var asm = BackupAssembler()
        do {
            guard await gatt.subscribe(FujiBLE.fileTransactionState) else {
                throw FujiBLEError.unsupported("FILE_TRANSACTION_STATE can't notify on this camera.")
            }
            guard await gatt.subscribe(FujiBLE.backupState) else {
                throw FujiBLEError.unsupported("BACKUP_STATE can't notify on this camera. No backup request was sent.")
            }
            for u in [FujiBLE.fileTransactionState, FujiBLE.backupState] {
                for v in await gatt.drain(u) { log("dropped stale \(u.prefix(8)) \(v.hexString)") }
            }
            try await gatt.write(FujiBLE.backupRequest, FujiBLE.backupRequestSettings)
            log("BACKUP_REQUEST = 01 00")
            try await waitBackupReady(gatt, timeout: stateTimeout, log: log)
            try await gatt.write(FujiBLE.filePartialSize, PTPPack.u32(partialSize))
            try await gatt.write(FujiBLE.fileTransferIndex, PTPPack.u32(0))
            while true {
                guard let value = await gatt.nextValue(FujiBLE.fileTransactionState, timeout: chunkTimeout) else {
                    if !(await gatt.isLinkUp) {
                        throw FujiBLEError.disconnected("after \(asm.data.count) bytes")
                    }
                    throw FujiBLEError.transfer(
                        "No transfer-state notification for \(chunkTimeout) after \(asm.data.count) bytes (\(asm.seqs.count) chunks).")
                }
                let st = try TransactionState.parse(value)
                log("backup transaction state \(value.hexString)")
                switch st.state {
                case 1, 2:
                    let raw = try await gatt.read(FujiBLE.filePartialData)
                    let chunk = try asm.add(raw)
                    log("backup chunk seq \(chunk.seq), payload \(chunk.length), total \(asm.data.count) wire bytes")
                    progress(asm.data.count)
                case 3:
                    if asm.checksumOK == false {
                        log("backup rejected: \(asm.seqReport); \(asm.data.count) wire bytes")
                        throw FujiBLEError.checksum(expected: asm.expectedSum ?? 0, got: asm.sum16)
                    }
                    if asm.checksumOK == nil { log("warning: the last chunk carried no checksum (no seq 0xFFFF); can't verify the data") }
                    var name = "backup.dat"
                    var size: Int?
                    if await gatt.has(FujiBLE.fileInformation) {
                        do {
                            let info = try FileInformation.parse(try await gatt.read(FujiBLE.fileInformation))
                            if !info.name.isEmpty { name = info.name }
                            size = info.size
                        } catch {
                            log("warning: couldn't read FILE_INFORMATION: \(error)")
                        }
                    }
                    let payload = try BLEBackupPayload.decode(asm.data, reportedSize: size)
                    let data = payload.data
                    if payload.compressed { log("expanded zlib settings backup: \(asm.data.count) wire bytes → \(data.count) settings bytes") }
                    do {
                        try await gatt.write(FujiBLE.fileTransferResult, FujiBLE.transferResultOK)
                    } catch {
                        log("warning: couldn't write FILE_TRANSFER_RESULT 03 00: \(error)")
                    }
                    let elapsed = ContinuousClock.now - started
                    return SettingsBackup(
                        name: name, data: data, wireData: asm.data, compressed: payload.compressed,
                        reportedSize: size, expectedSum: asm.expectedSum, computedSum: asm.sum16,
                        checksumOK: asm.checksumOK, chunks: asm.seqs.count, seqReport: asm.seqReport,
                        seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                        header: SettingsFileHeader(data))
                default:
                    throw FujiBLEError.transfer("The camera ended the transfer (state \(st.state), \(value.hexString)).")
                }
            }
        } catch {
            if await gatt.isLinkUp {
                try? await gatt.write(FujiBLE.fileTransferResult, FujiBLE.transferResultError)
            }
            throw error
        }
    }

    /// Wait for BACKUP_STATE = 1. A 0 means busy; keep listening until the timeout (the camera may follow with a 1).
    /// If nothing arrives, read the characteristic once (client.py fallback — our inference, not in the references).
    static func waitBackupReady(_ gatt: any GATTClient, timeout: Duration, log: @Sendable (String) -> Void) async throws {
        let deadline = ContinuousClock.now + timeout
        var busySeen = false
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, let value = await gatt.nextValue(FujiBLE.backupState, timeout: remaining) else { break }
            log("BACKUP_STATE = \(value.hexString)")
            if value.first == 1 { return }
            busySeen = true
        }
        if !(await gatt.isLinkUp) { throw FujiBLEError.disconnected("while waiting for the camera to prepare the backup") }
        if busySeen { throw FujiBLEError.busy }
        log("warning: no BACKUP_STATE indication within \(timeout); reading it directly (fallback, not in the references)")
        let value = try await gatt.read(FujiBLE.backupState)
        guard value.first == 1 else {
            throw FujiBLEError.transfer("No answer to the backup request (BACKUP_STATE reads \(value.hexString)). Is the camera in a menu or playback?")
        }
    }

    /// Restore is EXPERIMENTAL: it needs the explicit opt-in (`experimental: true`, CLI
    /// --i-understand-this-is-experimental). It speaks the standard restore protocol unless a profile is given, and a profile
    /// must carry a restore request (FujiBLERestore.swift). Without those, this is the error.
    public static let restoreUnsupported = FujiBLEError.unsupported(
        "Bluetooth restore is experimental: pass the explicit opt-in (it rewrites every camera setting). A custom profile must carry a restore request. USB alternative: FujiCamera.putSettingsFile.")
}
