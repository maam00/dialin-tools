// The Camera Check write guard, enforced in code: wraps any GATT client and lets through
// only the writes a read-only check needs. Everything else throws before it reaches the inner client.
//   allowed: pairing (aba356eb key, f557d96b identification number, 85b9163e client name); BACKUP_REQUEST f14e7a88 = 01 00;
//            FILE_PARTIAL_SIZE 7f3400fe; FILE_TRANSFER_INDEX 051dd980; FILE_TRANSFER_RESULT 68052e8a;
//            FUNCTION_LAUNCH 600655e6 = 03 00 (image viewing) only
//   refused: everything else, notably RESTORE_REQUEST f1897eb9, FILE_PARTIAL_DATA ac0c799a, FILE_INFORMATION c922ac69,
//            firmware update, power, movie, shooting, SSID, location, and the app-identity characteristic (8b5ecf55)
// Reads, subscriptions and notifications pass through.
import Foundation
import Synchronization

public final class ReadOnlyGATT: GATTClient, Sendable {
    public let inner: any GATTClient
    private let blockedLog = Mutex<[String]>([])

    public init(_ inner: any GATTClient) { self.inner = inner }

    /// Characteristic → the only values allowed (nil = any value).
    public static let allowedWrites: [String: Set<Data>?] = [
        FujiBLE.pairingToken: nil,
        FujiBLE.secureStatus: nil,
        FujiBLE.clientName: nil,
        FujiBLE.backupRequest: [FujiBLE.backupRequestSettings],
        FujiBLE.filePartialSize: nil,
        FujiBLE.fileTransferIndex: nil,
        FujiBLE.fileTransferResult: nil,
        FujiBLE.functionLaunch: [PTPPack.u16(Int(FujiWifiWake.inCameraViewing))],
    ]

    /// Every write the guard refused, in order ("f1897eb9 01 00").
    public var blocked: [String] { blockedLog.withLock { $0 } }

    public static func isAllowed(_ characteristic: String, _ value: Data) -> Bool {
        guard let rule = allowedWrites[FujiBLE.normalize(characteristic)] else { return false }
        guard let values = rule else { return true }
        return values.contains(value)
    }

    private func check(_ characteristic: String, _ value: Data) throws {
        guard Self.isAllowed(characteristic, value) else {
            let key = FujiBLE.normalize(characteristic)
            blockedLog.withLock { $0.append("\(key.prefix(8)) \(value.hexString)") }
            throw FujiBLEError.unsupported("Camera Check is read-only: refused a write to \(key.prefix(8)) (\(value.hexString)).")
        }
    }

    public func write(_ characteristic: String, _ value: Data) async throws {
        try check(characteristic, value)
        try await inner.write(characteristic, value)
    }

    public func writeCommand(_ characteristic: String, _ value: Data) async throws {
        try check(characteristic, value)
        try await inner.writeCommand(characteristic, value)
    }

    public func has(_ characteristic: String) async -> Bool { await inner.has(characteristic) }
    public func read(_ characteristic: String) async throws -> Data { try await inner.read(characteristic) }
    @discardableResult public func subscribe(_ characteristic: String) async -> Bool { await inner.subscribe(characteristic) }
    public func nextValue(_ characteristic: String, timeout: Duration) async -> Data? { await inner.nextValue(characteristic, timeout: timeout) }
    public func drain(_ characteristic: String) async -> [Data] { await inner.drain(characteristic) }
    public var isLinkUp: Bool { get async { await inner.isLinkUp } }
}
