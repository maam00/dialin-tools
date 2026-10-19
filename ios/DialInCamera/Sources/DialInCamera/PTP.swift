// PTP (ISO 15740) basics: opcodes, response codes, the 12-byte container, little-endian datasets.
// Container layout and the dataset reader are ported from FilmKit's vendor/container.ts and binary.ts
// (https://github.com/eggricesoy/filmkit, MIT, Copyright (c) 2026 eggricesoy).
import Foundation

public enum PTP {
    /// Standard operation codes (constants.ts `PTPOp`) plus the Fuji vendor ones we know about.
    public enum Op {
        public static let getDeviceInfo: UInt16 = 0x1001
        public static let openSession: UInt16 = 0x1002
        public static let closeSession: UInt16 = 0x1003
        public static let getStorageIDs: UInt16 = 0x1004
        public static let getObjectHandles: UInt16 = 0x1007
        public static let getObjectInfo: UInt16 = 0x1008
        public static let getObject: UInt16 = 0x1009
        public static let sendObjectInfo: UInt16 = 0x100C
        public static let sendObject: UInt16 = 0x100D
        public static let getDevicePropDesc: UInt16 = 0x1014
        public static let getDevicePropValue: UInt16 = 0x1015
        public static let setDevicePropValue: UInt16 = 0x1016
        public static let fujiSendObjectInfo: UInt16 = 0x900C
        public static let fujiSendObject2: UInt16 = 0x900D
    }

    /// Response codes (constants.ts `PTPResp`, plus the ones docs/FUJIFILM-PROTOCOL.md Appendix A names).
    public enum Response {
        public static let ok: UInt16 = 0x2001
        public static let generalError: UInt16 = 0x2002
        public static let sessionNotOpen: UInt16 = 0x2003
        public static let invalidTransactionID: UInt16 = 0x2004
        public static let operationNotSupported: UInt16 = 0x2005
        public static let parameterNotSupported: UInt16 = 0x2006
        public static let incompleteTransfer: UInt16 = 0x2007
        public static let invalidStorageID: UInt16 = 0x2008
        public static let invalidObjectHandle: UInt16 = 0x2009
        public static let devicePropNotSupported: UInt16 = 0x200A
        public static let storeFull: UInt16 = 0x200C
        public static let accessDenied: UInt16 = 0x200F
        public static let deviceBusy: UInt16 = 0x2019
        public static let invalidDevicePropValue: UInt16 = 0x201C
        public static let sessionAlreadyOpen: UInt16 = 0x201E

        /// constants.ts `respName`: a name for known codes, else 0xXXXX.
        public static func name(_ code: UInt16) -> String {
            let names: [UInt16: String] = [
                ok: "OK", generalError: "GeneralError", sessionNotOpen: "SessionNotOpen",
                invalidTransactionID: "InvalidTransactionID", operationNotSupported: "OperationNotSupported",
                parameterNotSupported: "ParameterNotSupported", incompleteTransfer: "IncompleteTransfer",
                invalidStorageID: "InvalidStorageID", invalidObjectHandle: "InvalidObjectHandle",
                devicePropNotSupported: "DevicePropNotSupported", storeFull: "StoreFull", accessDenied: "AccessDenied",
                deviceBusy: "DeviceBusy", invalidDevicePropValue: "InvalidDevicePropValue",
                sessionAlreadyOpen: "SessionAlreadyOpen",
            ]
            return names[code] ?? String(format: "0x%04X", code)
        }
    }

    public enum ContainerType {
        public static let command: UInt16 = 1
        public static let data: UInt16 = 2
        public static let response: UInt16 = 3
        public static let event: UInt16 = 4
    }

    /// USB vendor ID for Fujifilm (X100VI PID 0x0305; match on the vendor only, §3).
    public static let fujifilmVendorID = 0x04CB
}

// MARK: - Container

public enum PTPError: Error, CustomStringConvertible, Equatable {
    case containerTooShort(Int)
    case badLength(Int)
    case unexpectedContainer(UInt16)
    case truncated(String)

    public var description: String {
        switch self {
        case .containerTooShort(let n): "Container too short: \(n) bytes"
        case .badLength(let n): "Container length field \(n) is invalid"
        case .unexpectedContainer(let t): "Expected a RESPONSE container, got type \(t)"
        case .truncated(let what): "PTP dataset ended early while reading \(what)"
        }
    }
}

/// One PTP container: `u32 length, u16 type, u16 code, u32 transactionID, ≤5×u32 params | payload` (LE).
public struct PTPContainer: Equatable, Sendable {
    public static let headerSize = 12

    public var type: UInt16
    public var code: UInt16
    public var transactionID: UInt32
    public var params: [UInt32]
    public var payload: Data

    public init(type: UInt16, code: UInt16, transactionID: UInt32, params: [UInt32] = [], payload: Data = Data()) {
        self.type = type
        self.code = code
        self.transactionID = transactionID
        self.params = params
        self.payload = payload
    }

    public static func command(_ code: UInt16, transactionID: UInt32, params: [UInt32] = []) -> PTPContainer {
        PTPContainer(type: PTP.ContainerType.command, code: code, transactionID: transactionID, params: params)
    }

    public static func data(_ code: UInt16, transactionID: UInt32, payload: Data) -> PTPContainer {
        PTPContainer(type: PTP.ContainerType.data, code: code, transactionID: transactionID, payload: payload)
    }

    /// container.ts `packContainer`: at most 5 params; params and payload are concatenated after the header.
    public func pack() -> Data {
        let ps = params.prefix(5)
        var out = Data(capacity: Self.headerSize + ps.count * 4 + payload.count)
        out.appendLE32(UInt32(Self.headerSize + ps.count * 4 + payload.count))
        out.appendLE16(type)
        out.appendLE16(code)
        out.appendLE32(transactionID)
        for p in ps { out.appendLE32(p) }
        out.append(payload)
        return out
    }

    /// container.ts `unpackContainer`: DATA keeps everything after the header as payload; RESPONSE (and, here,
    /// COMMAND/EVENT) parse up to 5 u32 params.
    public static func unpack(_ raw: Data) throws -> PTPContainer {
        let b = [UInt8](raw)
        guard b.count >= headerSize else { throw PTPError.containerTooShort(b.count) }
        let type = LE.u16(b, 4)
        let code = LE.u16(b, 6)
        let tid = LE.u32(b, 8)
        let rest = Array(b[headerSize...])
        if type == PTP.ContainerType.data {
            return PTPContainer(type: type, code: code, transactionID: tid, payload: Data(rest))
        }
        var params: [UInt32] = []
        var off = 0
        while off + 4 <= rest.count && params.count < 5 {
            params.append(LE.u32(rest, off))
            off += 4
        }
        return PTPContainer(type: type, code: code, transactionID: tid, params: params)
    }

    /// container.ts `containerLength`: the length field, or nil if fewer than 4 bytes.
    public static func length(of raw: Data) -> Int? {
        let b = [UInt8](raw.prefix(4))
        guard b.count == 4 else { return nil }
        return Int(LE.u32(b, 0))
    }
}

// MARK: - Little-endian helpers

enum LE {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}

extension Data {
    mutating func appendLE16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func appendLE32(_ v: UInt32) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)])
    }

    /// Lowercase hex, no separators (Buffer.toString("hex")).
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// Parse lowercase/uppercase hex ("0a00ff"). Nil on odd length or a bad digit.
    public init?(hexString: String) {
        let s = Array(hexString.utf8)
        guard s.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(s.count / 2)
        func nib(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        var i = 0
        while i < s.count {
            guard let hi = nib(s[i]), let lo = nib(s[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self.init(out)
    }
}

/// binary.ts pack helpers. Values wrap like DataView.setInt16/setUint16 (ToInt16/ToUint16).
public enum PTPPack {
    public static func u16(_ v: Int) -> Data { var d = Data(); d.appendLE16(UInt16(truncatingIfNeeded: v)); return d }
    public static func i16(_ v: Int) -> Data { u16(v) }
    public static func u32(_ v: UInt32) -> Data { var d = Data(); d.appendLE32(v); return d }

    /// binary.ts `packPTPString`: u8 count (characters incl. NUL), UTF-16LE characters, NUL. Empty → [0].
    public static func string(_ s: String) -> Data {
        if s.isEmpty { return Data([0]) }
        let units = Array(s.utf16)
        var d = Data([UInt8(truncatingIfNeeded: units.count + 1)])
        for u in units { d.appendLE16(u) }
        d.appendLE16(0)
        return d
    }
}

// MARK: - Dataset reader

/// binary.ts `PTPReader`: a cursor over a little-endian PTP dataset.
public struct PTPReader {
    private let b: [UInt8]
    public private(set) var position = 0

    public init(_ data: Data) { b = [UInt8](data) }

    public var remaining: Int { b.count - position }

    private mutating func need(_ n: Int, _ what: String) throws {
        guard position + n <= b.count else { throw PTPError.truncated(what) }
    }

    public mutating func u8() throws -> UInt8 { try need(1, "u8"); defer { position += 1 }; return b[position] }
    public mutating func u16() throws -> UInt16 { try need(2, "u16"); defer { position += 2 }; return LE.u16(b, position) }
    public mutating func u32() throws -> UInt32 { try need(4, "u32"); defer { position += 4 }; return LE.u32(b, position) }
    public mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    /// PTP string: u8 numChars (incl. NUL), then numChars × UCS-2LE; NULs are dropped.
    public mutating func string() throws -> String {
        let n = Int(try u8())
        if n == 0 { return "" }
        var units: [UInt16] = []
        for _ in 0..<n {
            let ch = try u16()
            if ch != 0 { units.append(ch) }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// u32 count, then count × u16.
    public mutating func u16Array() throws -> [UInt16] {
        let n = Int(try u32())
        guard n <= remaining / 2 else { throw PTPError.truncated("u16 array of \(n)") }
        return try (0..<n).map { _ in try u16() }
    }
}

/// binary.ts `parsePTPStringRaw`.
public func parsePTPString(_ data: Data) -> String {
    var r = PTPReader(data)
    return (try? r.string()) ?? ""
}

/// GetDeviceInfo dataset (ISO 15740 §5.5.1), as camera.ts reads it.
public struct PTPDeviceInfo: Sendable, Equatable {
    public var standardVersion: UInt16 = 0
    public var vendorExtensionID: UInt32 = 0
    public var vendorExtensionVersion: UInt16 = 0
    public var vendorExtensionDescription = ""
    public var functionalMode: UInt16 = 0
    public var operations: [UInt16] = []
    public var events: [UInt16] = []
    public var properties: [UInt16] = []
    public var captureFormats: [UInt16] = []
    public var imageFormats: [UInt16] = []
    public var manufacturer = ""
    public var model = ""
    public var deviceVersion = ""
    public var serialNumber = ""

    public init() {}

    /// Parses as far as the data goes; model/firmware/serial stay empty if the dataset is short.
    public init(parsing data: Data) throws {
        var r = PTPReader(data)
        standardVersion = try r.u16()
        vendorExtensionID = try r.u32()
        vendorExtensionVersion = try r.u16()
        vendorExtensionDescription = try r.string()
        functionalMode = try r.u16()
        operations = try r.u16Array()
        events = try r.u16Array()
        properties = try r.u16Array()
        captureFormats = try r.u16Array()
        imageFormats = try r.u16Array()
        manufacturer = try r.string()
        model = try r.string()
        deviceVersion = (try? r.string()) ?? ""
        serialNumber = (try? r.string()) ?? ""
    }

    /// Builds the dataset (for fakes and tests).
    public func encoded() -> Data {
        var d = Data()
        d.appendLE16(standardVersion)
        d.appendLE32(vendorExtensionID)
        d.appendLE16(vendorExtensionVersion)
        d.append(PTPPack.string(vendorExtensionDescription))
        d.appendLE16(functionalMode)
        for list in [operations, events, properties, captureFormats, imageFormats] {
            d.appendLE32(UInt32(list.count))
            for v in list { d.appendLE16(v) }
        }
        d.append(PTPPack.string(manufacturer))
        d.append(PTPPack.string(model))
        d.append(PTPPack.string(deviceVersion))
        d.append(PTPPack.string(serialNumber))
        return d
    }
}

// MARK: - Property values

/// A property value as read from the camera: the raw bytes plus camera.ts `decode()`'s interpretation.
public struct RawProp: Equatable, Hashable, Sendable {
    public var id: UInt16
    public var bytes: Data

    public init(id: UInt16, bytes: Data) {
        self.id = id
        self.bytes = bytes
    }

    public enum Value: Equatable, Sendable {
        case int(Int)
        case string(String)
        case hex(String)
    }

    /// camera.ts `decode`: a PTP string if the length byte fits, else int16 / int32 / u8, else hex.
    public var value: Value {
        let b = [UInt8](bytes)
        if b.count >= 3 {
            let n = Int(b[0])
            let expected = 1 + n * 2
            if n >= 2 && (expected == b.count || expected == b.count + 1) { return .string(parsePTPString(bytes)) }
        }
        switch b.count {
        case 2: return .int(Int(Int16(bitPattern: LE.u16(b, 0))))
        case 4: return .int(Int(Int32(bitPattern: LE.u32(b, 0))))
        case 1: return .int(Int(b[0]))
        default: return .hex(bytes.hexString)
        }
    }

    /// The numeric value, if the bytes decode as a number (FilmKit `prop()`).
    public var intValue: Int? { if case .int(let v) = value { v } else { nil } }
    public var stringValue: String? { if case .string(let s) = value { s } else { nil } }
}
