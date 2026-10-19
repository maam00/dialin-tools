// The photo-import guard, enforced in code: "Your photos stay on the card. Dial In only copies them."
// Wraps any PTP transport for an import session (Wi-Fi or USB) and lets through only what copying needs. Everything
// else throws BEFORE it reaches the inner transport, so a refused operation never goes on the wire.
//   allowed, no data phase from us:
//     GetDeviceInfo 1001 · GetStorageIDs 1004 · GetStorageInfo 1005 · GetNumObjects 1006 · GetObjectHandles 1007 ·
//     GetObjectInfo 1008 · GetObject 1009 · GetThumb 100A · GetDevicePropDesc 1014 · GetDevicePropValue 1015 ·
//     GetPartialObject 101B · MTP GetObjectPropValue 9803 (size / name / date) ·
//     Fujifilm gallery reads 9050 9053 9054 9055 (FujiWifiHandshake step 5, the gallery sequence)
//   allowed SetDevicePropValue 1016 (the transfer's own session switches, never a shooting setting, never storage):
//     D226 ImageForceCompression 0/1/2 · D227 real size 0/1 · D22E resize rate 0/1 · DF01 client state 2/20 ·
//     DF28 the version echo (4 bytes, the value the camera just gave us)
//   refused: everything else, notably DeleteObject 100B, SendObjectInfo 100C, SendObject 100D, FormatStore 100F,
//            SetObjectProtection 1012, MoveObject 1019, CopyObject 101A, Fujifilm SendObjectInfo/SendObject 900C/900D,
//            MTP SetObjectPropValue 9804, any other property write, and any data phase on a non-property op.
// OpenSession / CloseSession are the transport's own (FujiPTPIPTransport.open/close), not sent through `transact`.
import Foundation
import Synchronization

extension PTP.Op {
    public static let getStorageInfo: UInt16 = 0x1005
    public static let getNumObjects: UInt16 = 0x1006
    public static let initiateCapture: UInt16 = 0x100E
    public static let formatStore: UInt16 = 0x100F
    public static let resetDevice: UInt16 = 0x1010
    public static let setObjectProtection: UInt16 = 0x1012
    public static let powerDown: UInt16 = 0x1013
    public static let resetDevicePropValue: UInt16 = 0x1017
    public static let moveObject: UInt16 = 0x1019
    public static let copyObject: UInt16 = 0x101A
    /// MTP SetObjectPropValue (renames, dates, protection on MTP bodies).
    public static let setObjectPropValue: UInt16 = 0x9804
}

public final class ReadOnlyPTP: PTPTransport, Sendable {
    public let inner: any PTPTransport
    private let blockedLog = Mutex<[String]>([])

    /// Wraps `transport` unless it is already guarded.
    public static func guarding(_ transport: any PTPTransport) -> ReadOnlyPTP {
        transport as? ReadOnlyPTP ?? ReadOnlyPTP(transport)
    }

    public init(_ inner: any PTPTransport) { self.inner = inner }

    /// Operations that only read (no data phase from us).
    public static let readOps: Set<UInt16> = [
        PTP.Op.getDeviceInfo, PTP.Op.getStorageIDs, PTP.Op.getStorageInfo, PTP.Op.getNumObjects, PTP.Op.getObjectHandles,
        PTP.Op.getObjectInfo, PTP.Op.getObject, PTP.Op.getThumb, PTP.Op.getDevicePropDesc, PTP.Op.getDevicePropValue,
        PTP.Op.getPartialObject, PTP.Op.getObjectPropValue,
        PTP.Op.fujiGetImageImportFolders, PTP.Op.fujiGetImageImportDates, PTP.Op.fujiGetExtensionObjectInfo,
        PTP.Op.fujiGetExtensionThumb,
    ]

    /// Property → the only u16 values allowed (nil = any value of `anyValueLength` bytes: the DF28 echo).
    public static let allowedPropWrites: [UInt16: Set<Int>?] = [
        FujiWifiProp.forceCompression: [0, 1, 2],
        FujiWifiProp.realSizeInfo: [0, 1],
        FujiWifiProp.resizeRate: [0, 1],
        FujiWifiProp.clientState: [FujiWifiProp.clientStateViewAll, FujiWifiProp.clientStateGallery],
        FujiWifiProp.remotePhotoViewExVersion: nil,
    ]

    /// The operations that could change or remove what's on the card, named for the refusal (all refused anyway).
    public static let neverOps: [UInt16: String] = [
        PTP.Op.deleteObject: "DeleteObject", PTP.Op.sendObjectInfo: "SendObjectInfo", PTP.Op.sendObject: "SendObject",
        PTP.Op.initiateCapture: "InitiateCapture", PTP.Op.formatStore: "FormatStore", PTP.Op.resetDevice: "ResetDevice",
        PTP.Op.setObjectProtection: "SetObjectProtection", PTP.Op.powerDown: "PowerDown",
        PTP.Op.resetDevicePropValue: "ResetDevicePropValue", PTP.Op.moveObject: "MoveObject", PTP.Op.copyObject: "CopyObject",
        PTP.Op.fujiSendObjectInfo: "SendObjectInfo (Fujifilm)", PTP.Op.fujiSendObject2: "SendObject (Fujifilm)",
        PTP.Op.setObjectPropValue: "SetObjectPropValue",
    ]

    /// Nil when allowed, else why not (one plain clause).
    public static func refusal(_ op: UInt16, params: [UInt32], dataOut: Data?) -> String? {
        if let name = neverOps[op] { return "\(name) could change what's on the card" }
        if op == PTP.Op.setDevicePropValue {
            guard let prop = params.first.map({ UInt16(truncatingIfNeeded: $0) }), let rule = allowedPropWrites[prop] else {
                return String(format: "SetDevicePropValue 0x%04X isn't one the transfer needs", params.first ?? 0)
            }
            guard let data = dataOut, !data.isEmpty else { return "a property write without a value" }
            guard let values = rule else { return data.count <= 4 ? nil : "a property value longer than 4 bytes" }
            let b = [UInt8](data)
            guard b.count == 2, values.contains(Int(LE.u16(b, 0))) else {
                return String(format: "0x%04X = ", prop) + data.hexString + " isn't a value the transfer uses"
            }
            return nil
        }
        guard readOps.contains(op) else { return String(format: "operation 0x%04X isn't a read", op) }
        if let dataOut, !dataOut.isEmpty { return String(format: "operation 0x%04X with data from us", op) }
        return nil
    }

    public static func isAllowed(_ op: UInt16, params: [UInt32], dataOut: Data?) -> Bool {
        refusal(op, params: params, dataOut: dataOut) == nil
    }

    /// Every refused operation, in order ("0x100B DeleteObject could change what's on the card").
    public var blocked: [String] { blockedLog.withLock { $0 } }

    public func open(timeout: Duration) async throws { try await inner.open(timeout: timeout) }
    public func close() async { await inner.close() }

    public func transact(_ operation: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult {
        if let why = Self.refusal(operation, params: params, dataOut: dataOut) {
            blockedLog.withLock { $0.append(String(format: "0x%04X ", operation) + why) }
            throw ImportError.unsupported("Dial In only copies photos, so it refused this (\(why)). Nothing on the card changed.")
        }
        return try await inner.transact(operation, params: params, dataOut: dataOut, timeout: timeout)
    }
}
