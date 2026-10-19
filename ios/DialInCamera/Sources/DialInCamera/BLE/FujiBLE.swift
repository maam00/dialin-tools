// Fujifilm Bluetooth LE map and pure (no CoreBluetooth I/O) helpers: UUIDs, advert decoding, the secure-status
// ack, and the file-service framing used by the settings backup.
//
// Sources (all MIT): Th0rgal/fuji-bridge FujiBridge/FujiBluetooth.swift + FujiBackup.swift (Copyright (c) 2026
// Thomas Marchand), gkoh/furble (pairing), petabyt/libfuji lib/bluetooth.c, tiredboffin/fffw ffbt/cfg/gatt-ad14d4.yaml
// (X100VI fw 1.31+ GATT), plus captures and hardware tests on our own X100VI. Protocol reference:
// docs/FUJIFILM-PROTOCOL.md §3. Our Python port: ble/fuji_ble/gatt.py.
import Foundation

public enum FujiBLE {
    /// Bluetooth SIG company ID Fujifilm uses in manufacturer data (furble Fujifilm.h:35).
    public static let companyID: UInt16 = 0x04D8

    // Services
    public static let securePairService = "123d8f06-62a1-4935-9322-833c531ee225"
    public static let basicPairService = "91f1de68-dff6-466e-8b65-ff13b0f16fb8"
    public static let configService = "4c0020fe-f3b6-40de-acc9-77d129067b14"
    public static let wifiService = "4e941240-d01d-46b9-a5ea-67636806830b"
    public static let controlService = "6514eb81-4e8f-458d-aa2a-e691336cdfac"
    public static let fileService = "af854c2e-b214-458e-97e2-912c4ecf2cb8"
    /// Advertised by a secure body in PAIRING REGISTRATION (once connected, on X100VI fw 1.32).
    public static let securePairingAdvert = "a9d2b304-e8d6-4902-8336-352b772d7597"
    /// Advertised by a bonded body looking for its phone (X100VI fw 1.32).
    public static let reconnectAdvert = "804daa8e-ffeb-4ab3-8e75-6edd7303208d"
    /// Camera info service on basic (older firmware) bodies.
    public static let cameraInfoBasicService = "117c4142-edd4-4c77-8696-dd18eebb770a"
    /// Standby service (basic): the advert of a basic body switched OFF with Bluetooth on, carrying 02 + the
    /// REGISTERED pairing key + the power-switch state. Captured from an X100VI (fw 1.10) during development; the
    /// shape is name <id>X100VI-<id> (a 4-character id), manufacturer data 04d8 02 <4-byte key> 00.
    public static let basicStartupService = "731893f9-744e-4899-b7e3-174106ff2b82"

    // Characteristics: pairing / identity
    /// R/W 4: secure status; write it back with byte 3 = 0x20.
    public static let secureStatus = "f557d96b-8284-4667-8793-b971c1deca2a"
    /// W 4: basic-firmware pairing token (from the advert).
    public static let pairingToken = "aba356eb-9633-4e60-b73f-f52516dbd671"
    /// W 30: client name the camera lists.
    public static let clientName = "85b9163e-62d1-49ff-a6f5-054b4630d4a1"
    public static let geotagInterval = "c95d91ae-b247-4d6d-8661-7dd5d6a0f85b"
    public static let timeSyncRequest = "f9150137-5d40-4801-a8dc-f7fc5b01da50"
    public static let time = "b9bfd37f-ccad-4d36-a1ee-018e792b3edf"
    /// AP state: 01 up / 00 busy.
    public static let apState = "a68e3f66-0fcc-4395-8d4c-aa980b5877fa"
    public static let functionLaunch = "600655e6-3637-42f1-8fb2-44efc5c63b13"
    public static let shutter = "7fcf49c6-4ff0-4777-a03d-1a79166af7a8"

    // Characteristics: settings backup (fuji-bridge FujiBackup.swift; docs/FUJIFILM-PROTOCOL.md §3.3)
    /// W 2: 1 = settings, 2 = IPTC.
    public static let backupRequest = "f14e7a88-6f57-4872-a69b-b47ef3295c9b"
    /// R/Ind: 1 = ready to transfer, 0 = busy.
    public static let backupState = "11438c83-cfb0-4511-841b-759e0d2321c8"
    public static let fileTransferIndex = "051dd980-df9d-4472-a2e1-35811dd24ee1"
    /// R/W 44: name[40], u32 size.
    public static let fileInformation = "c922ac69-9480-4348-8f4b-9ee29bc30d1d"
    public static let filePartialSize = "7f3400fe-17e7-4b80-8a0e-81b0343c1b49"
    /// R/W 248: u16 seq, u32 len, data.
    public static let filePartialData = "ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea"
    /// W 2: 03 00 finish, 00 00 error.
    public static let fileTransferResult = "68052e8a-fb91-404f-8847-0eb4be24308c"
    /// N 4: u16 state (1 first chunk, 2 next chunk, 3 finished).
    public static let fileTransactionState = "2e27ed9f-5506-41cd-ba48-dac06669ad95"

    // Restore, identity, time and location (docs/FUJIFILM-PROTOCOL.md §3.3). Python: gatt.py.
    /// W 2: restore request, u16 LE 1 = settings restore, 2 = IPTC.
    public static let restoreRequest = "f1897eb9-a9aa-40f0-8ce6-2fa7915bc459"
    /// R/Ind 2: restore state, u16 1 = ready to receive, 0 = busy.
    public static let restoreState = "4b3a413c-230f-42bc-b3ed-b1db2eadee82"
    /// Standard serial-number string; read before the pairing key on basic bodies.
    public static let serialNumber = sig("2a25")
    /// The camera's Wi-Fi address ("-" separated); used as the BSSID when joining its network.
    public static let cameraMacAddress = "49a12959-dfaa-4eb2-89ce-62548ad948f3"
    /// App-identity characteristic (newer bodies), where a connecting app identifies itself. Dial In NEVER writes it
    /// (it doesn't present as FUJIFILM's app; the read-only guard refuses it too). Named only so code can refuse it.
    public static let appIdentity = "8b5ecf55-fc6b-40d0-b4c1-76f64e5453c7"
    /// UTC time and time zone (12 bytes).
    public static let utcTimeAndZone = "c52edbce-1fe2-4ecc-9483-907e6592be9e"
    /// Location fix (23 bytes, `encodeLocation`).
    public static let locationFix = "0f36ec14-29e5-411a-a1b6-64ee8383f090"
    /// The camera asks for a location here.
    public static let locationRequest = "ad06c7b7-f41a-46f4-a29a-712055319122"
    public static let transferState = "bd17ba04-b76b-4892-a545-b73ba1f74dae"

    // Standard device information
    public static let deviceName = sig("2a00")
    public static let modelNumber = sig("2a24")
    public static let firmwareRevision = sig("2a26")

    /// What libfuji subscribes to on a secure body, in its order (bluetooth.c:483-501; same in fuji-bridge
    /// FujiBluetooth.swift:75-80, client.py SECURE_SUBSCRIPTIONS). Two are absent on X100VI 1.31+; that's fine.
    public static let subscriptions: [String] = [
        apState,
        "bd17ba04-b76b-4892-a545-b73ba1f74dae",
        timeSyncRequest,
        "ad06c7b7-f41a-46f4-a29a-712055319122",
        "7170fd5a-56d9-4c19-b043-7a7047d8e1a0",
        "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4",
        "75823784-fbb7-4b71-abae-cd9a34072e3c",
        "e6692c5c-b7cd-44f4-95fc-eda07ce32560",
        "aab609c4-94dd-4d89-bc60-665d5090b828",
        "2a125640-706d-4dd1-b420-c0f4ab93c361",
        "82a9f452-c5ce-4ef5-8203-3fc9a47f8171",
        "deef7187-3f43-4364-9e22-11a8c8a15951",
        geotagInterval,
    ]

    /// Backup framing constants (FujiBackup.swift:7-13).
    public static let backupPartialSize: UInt32 = 120
    public static let lastSeq: UInt16 = 0xFFFF
    public static let backupRequestSettings = Data([0x01, 0x00])
    public static let transferResultOK = Data([0x03, 0x00])
    public static let transferResultError = Data([0x00, 0x00])
    /// FILE_PARTIAL_DATA is 248 bytes (gatt-ad14d4.yaml:392) minus the 6-byte header.
    public static let maxChunkPayload = 0xF8 - 6
    /// Historical restore-request/ready candidates, from before the restore pair was identified: restoreRequest
    /// f1897eb9 and restoreState 4b3a413c; the rest are AP launch, firmware update, movie, power and log transfer.
    public static let restoreRequestCandidates = [
        "f1897eb9-a9aa-40f0-8ce6-2fa7915bc459", "2674f0b0-f909-4e73-8656-338e9c74457f", "43070f6c-51e0-4887-86a7-5f762bda5791",
        "861442ab-b94e-4935-90d9-41e291d91374", "fb15c357-364f-49d3-b5c5-1e32c0ded038", "b1307521-7ac5-4199-aaee-9d094781ce69",
    ]
    public static let restoreStateCandidates = ["2f6cb772-1d69-448e-8819-fe6b5c20b094", "4b3a413c-230f-42bc-b3ed-b1db2eadee82"]

    // Registration and restore constants (docs/FUJIFILM-PROTOCOL.md §3.5, §3.7).
    /// Flag OR-ed into a secure body's identification number before it is written back (07 96 00 00 → 07 96 00 20).
    public static let clientIDFlag: UInt32 = 0x2000_0000
    /// FILE_PARTIAL_SIZE both ways; a restore frame is 6 + 120 + 2 = 128 bytes.
    public static let restoreChunk = 120
    public static let restoreRequestSettings = Data([0x01, 0x00])
    /// Transfer result written to FILE_TRANSFER_RESULT: fail, cancel, end.
    public static let resultFail = Data([0x00, 0x00])
    public static let resultCancel = Data([0x02, 0x00])
    public static let resultEnd = Data([0x03, 0x00])
    /// Transfer progress on FILE_TRANSACTION_STATE, u16 state (+ u16 seq): 0 error, 1 started, 2 sending, 3 file received.
    public static let tsError: UInt16 = 0, tsStart: UInt16 = 1, tsTransferring: UInt16 = 2, tsFileDone: UInt16 = 3
    /// File name written to FILE_INFORMATION for a settings restore.
    public static let backupFileName = "backup.dat"

    /// The client name as written to 85b9163e: UTF-8 plus one NUL, trimmed on a character boundary to fit 30.
    public static func encodeClientName(_ name: String, maxLength: Int = 0x1E) -> Data {
        var n = name
        while n.utf8.count + 1 > maxLength { n.removeLast() }
        return Data(n.utf8) + Data([0])
    }

    /// Secure bodies: our id is the saved one, else the u32 read from the identification-number characteristic
    /// (f557d96b) OR 0x20000000. 07 96 00 00 → 07 96 00 20.
    public static func identificationNumber(_ read: Data, stored: UInt32? = nil) throws -> UInt32 {
        if let stored, stored != 0 { return stored }
        guard read.count == 4 else { throw FujiBLEError.unexpected("identification number was \(read.count) bytes (\(read.hexString)); expected 4") }
        return LE.u32([UInt8](read), 0) | clientIDFlag
    }

    /// Restore upload frames: u16 seq, u32 size, data, u16 checksum. seq 0,1,2,… and 0xFFFF on the last frame; the last
    /// frame's data ends with the u16 sum of every file byte (size counts it) and its trailer repeats the sum; every
    /// other trailer is 0 (docs/FUJIFILM-PROTOCOL.md §3.7). Python: gatt.py (golden vectors in
    /// Fixtures/xapp-restore-vectors.json).
    public static func restoreFrames(_ data: Data, chunk: Int = restoreChunk) -> [Data] {
        let bytes = [UInt8](data)
        let count = (bytes.count + chunk - 1) / chunk
        let sum = UInt16(byteSum16(data))
        return (0..<count).map { i in
            let piece = Data(bytes[(i * chunk)..<min((i + 1) * chunk, bytes.count)])
            var d = Data()
            if i == count - 1 {
                var body = piece
                body.appendLE16(sum)
                d.appendLE16(lastSeq)
                d.appendLE32(UInt32(body.count))
                d.append(body)
                d.appendLE16(sum)
            } else {
                d.appendLE16(UInt16(truncatingIfNeeded: i))
                d.appendLE32(UInt32(piece.count))
                d.append(piece)
                d.appendLE16(0)
            }
            return d
        }
    }

    /// AP_STATE (u16 LE): 0x8001 up / 0x8003 up for a queued transfer → up (true), 0x8000 off → not (false),
    /// 0x8002 starting → keep waiting (nil). Older readings: first byte 01 up, 00 busy.
    public static func apStateUp(_ v: Data) -> Bool? {
        let b = [UInt8](v)
        if b.count >= 2 {
            switch LE.u16(b, 0) {
            case 0x8001, 0x8003: return true
            case 0x8000: return false
            case 0x8002: return nil
            default: break
            }
        }
        guard let first = b.first else { return nil }
        return first != 0
    }

    /// Location fix (23 bytes): i32 lat·1e7, i32 lon·1e7, i32 altitude m,
    /// i32 speed m/s·100, u16 year, u8 month, day, hour, minute, second of the fix in UTC.
    public static func encodeLocation(latitude: Double, longitude: Double, altitude: Double = 0, speed: Double = 0,
                                      time: Date = Date()) -> Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: time)
        var d = Data()
        for v in [latitude * 1e7, longitude * 1e7, altitude, speed * 100] {
            d.appendLE32(UInt32(bitPattern: Int32(v.rounded())))
        }
        d.appendLE16(UInt16(c.year ?? 0))
        d.append(contentsOf: [c.month, c.day, c.hour, c.minute, c.second].map { UInt8($0 ?? 0) })
        return d
    }

    /// Full lowercase 128-bit form of a 16- or 32-bit SIG UUID; 128-bit input is just lowercased.
    public static func normalize(_ uuid: String) -> String {
        let s = uuid.trimmingCharacters(in: .whitespaces).lowercased()
        switch s.count {
        case 4: return "0000\(s)-0000-1000-8000-00805f9b34fb"
        case 8: return "\(s)-0000-1000-8000-00805f9b34fb"
        default: return s
        }
    }

    static func sig(_ short: String) -> String { normalize(short) }

    /// STATUS goes back with its last byte set to 0x20 (fuji-bridge FujiBluetooth.swift:255-260,
    /// furble FujifilmSecure.cpp:122: 07960000 → 07960020).
    public static func ackSecureStatus(_ status: Data) throws -> Data {
        guard status.count == 4 else { throw FujiBLEError.unexpected("secure status was \(status.count) bytes (\(status.hexString)); expected 4") }
        var b = [UInt8](status)
        b[3] = 0x20
        return Data(b)
    }
}

// MARK: - Advertisements

/// Which Bluetooth protocol a body speaks, read from its ADVERT (docs/FUJIFILM-PROTOCOL.md §3.1-3.2): never inferred from the
/// model or the firmware string (new X100VIs ship an unlisted 1.32).
public enum FujiBLEProfile: String, Codable, Sendable {
    /// Older firmware (X100VI 1.10/1.11): a 4-byte pairing key re-sent on every connection, no OS bond, an open AP.
    case basic
    /// Newer firmware (X100VI 1.30+): an OS bond (6-digit compare) and an identification number; a WPA2 AP.
    case secure
    case unknown
}

/// What a Fujifilm advertisement says about the body (fuji-bridge `FujiAdvert`).
public struct FujiAdvert: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Bonded to a phone/computer and waiting for it: connect with the existing bond.
        case reconnect
        /// Secure pairing mode: connecting starts an OS pairing prompt.
        case securePairing
        /// Older firmware in pairing mode: carries the token to write back.
        case basicPairing
        /// Older firmware, registered (not pairing): advertises the FILE_TRANSFER service, maybe no manufacturer data
        /// at all. Connect with the saved pairing key.
        case basic
        /// Older firmware, camera switched OFF (Bluetooth standby). Not connectable for us; `token` is the REGISTERED key.
        case basicStandby
        case other
    }

    public var kind: Kind
    /// Short serial secure bodies advertise ("1D7B8"), or the basic token in hex.
    public var tag: String
    public var token: Data?

    public init(kind: Kind, tag: String, token: Data? = nil) {
        self.kind = kind
        self.tag = tag
        self.token = token
    }

    /// A basic body must actually enter registration and advertise its key.
    /// Secure bodies may keep their reconnect advert while in the pairing menu.
    var allowsPairingAttempt: Bool {
        switch kind {
        case .basicPairing: token?.count == 4
        case .securePairing, .reconnect: true
        case .basic, .basicStandby, .other: false
        }
    }

    /// The protocol this advert says the body speaks.
    public var profile: FujiBLEProfile {
        switch kind {
        case .securePairing, .reconnect: .secure
        case .basicPairing, .basic, .basicStandby: .basic
        case .other: .unknown
        }
    }

    /// `manufacturer` is CoreBluetooth's manufacturer data (company ID first, little-endian).
    public static func parse(manufacturer: Data?, services: [String]) -> FujiAdvert? {
        let basicBody = services.map(FujiBLE.normalize).contains(FujiBLE.fileService)
        guard let data = manufacturer, data.count >= 3 else {
            return basicBody ? FujiAdvert(kind: .basic, tag: "") : nil
        }
        let bytes = [UInt8](data)
        guard UInt16(bytes[0]) | UInt16(bytes[1]) << 8 == FujiBLE.companyID else {
            return basicBody ? FujiAdvert(kind: .basic, tag: "") : nil
        }
        let type = bytes[2]
        let rest = Array(bytes.dropFirst(3))
        if type == 0x02, rest.count >= 4 {
            let token = Data(rest.prefix(4))
            let standby = services.map(FujiBLE.normalize).contains(FujiBLE.basicStartupService)
            return FujiAdvert(kind: standby ? .basicStandby : .basicPairing, tag: token.hexString, token: token)
        }
        let text = String(decoding: rest.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
        let svc = services.map(FujiBLE.normalize)
        if basicBody { return FujiAdvert(kind: .basic, tag: text) }
        if svc.contains(FujiBLE.securePairingAdvert) { return FujiAdvert(kind: .securePairing, tag: text) }
        // Both seen from a bonded X100VI (fw 1.32): 804daa8e, then 123d8f06 once the phone's Bluetooth went off.
        if svc.contains(FujiBLE.reconnectAdvert) || svc.contains(FujiBLE.securePairService) {
            return FujiAdvert(kind: .reconnect, tag: text)
        }
        return FujiAdvert(kind: .other, tag: text)
    }
}

// MARK: - File-service framing

/// One FILE_PARTIAL_DATA value: u16 seq, u32 len, len bytes (FujiBackup.swift:99-107).
public struct FileChunk: Equatable, Sendable {
    public var seq: UInt16
    public var length: Int
    public var payload: Data
    public var isLast: Bool { seq == FujiBLE.lastSeq }

    public static func parse(_ raw: Data) throws -> FileChunk {
        let b = [UInt8](raw)
        guard b.count >= 6 else { throw FujiBLEError.framing("chunk shorter than its 6-byte header: \(raw.hexString)") }
        let seq = LE.u16(b, 0)
        let length = Int(LE.u32(b, 2))
        guard 6 + length <= b.count else {
            throw FujiBLEError.framing("chunk says len=\(length) but only \(b.count - 6) data bytes arrived (seq \(seq))")
        }
        return FileChunk(seq: seq, length: length, payload: Data(b[6..<(6 + length)]))
    }

    public static func build(seq: UInt16, payload: Data) -> Data {
        var d = Data()
        d.appendLE16(seq)
        d.appendLE32(UInt32(payload.count))
        d.append(payload)
        return d
    }
}

/// FILE_TRANSACTION_STATE: u16 state, then aux bytes (fuji-bridge's fake puts the chunk index there; libfuji saw ff ff).
public struct TransactionState: Equatable, Sendable {
    public var state: UInt16
    public var aux: Data

    public static func parse(_ raw: Data) throws -> TransactionState {
        let b = [UInt8](raw)
        guard b.count >= 2 else { throw FujiBLEError.framing("transaction state shorter than 2 bytes: \(raw.hexString)") }
        return TransactionState(state: LE.u16(b, 0), aux: Data(b[2...]))
    }
}

/// FILE_INFORMATION: char name[40], u32 size (libfuji bluetooth.c:32-38).
public enum FileInformation {
    public static func parse(_ raw: Data) throws -> (name: String, size: Int) {
        let b = [UInt8](raw)
        guard b.count >= 44 else { throw FujiBLEError.framing("file information shorter than 44 bytes: \(raw.hexString)") }
        let name = String(decoding: b[0..<40].prefix { $0 != 0 }, as: UTF8.self)
        return (name, Int(LE.u32(b, 40)))
    }

    public static func build(name: String, size: Int) -> Data {
        var raw = Array(name.utf8.prefix(39))
        raw += [UInt8](repeating: 0, count: 40 - raw.count)
        var d = Data(raw)
        d.appendLE32(UInt32(truncatingIfNeeded: size))
        return d
    }
}

/// u16 sum of all data bytes, as in the last chunk's trailer (FujiBackup.swift:10-11).
public func byteSum16(_ data: Data) -> Int { data.reduce(0) { $0 + Int($1) } & 0xFFFF }

/// Reassembles FILE_PARTIAL_DATA chunks exactly as fuji-bridge FujiBackup.run does, and records the sequence numbers
/// (client.py BackupAssembler) so a real run tells us how the camera numbers them.
public struct BackupAssembler: Sendable {
    public private(set) var data = Data()
    public private(set) var sum = 0
    public private(set) var expectedSum: Int?
    public private(set) var seqs: [UInt16] = []
    public private(set) var finished = false

    public init() {}

    @discardableResult
    public mutating func add(_ raw: Data) throws -> FileChunk {
        let ch = try FileChunk.parse(raw)
        seqs.append(ch.seq)
        if ch.isLast {
            // The final piece ends with the checksum of everything before it.
            let body = ch.payload.dropLast(2)
            let tail = [UInt8](ch.payload.suffix(2))
            data.append(body)
            sum += body.reduce(0) { $0 + Int($1) }
            if tail.count == 2 { expectedSum = Int(tail[0]) | Int(tail[1]) << 8 }
            finished = true
        } else {
            data.append(ch.payload)
            sum += ch.payload.reduce(0) { $0 + Int($1) }
        }
        return ch
    }

    public var sum16: Int { sum & 0xFFFF }

    /// Nil when no 0xFFFF chunk (so no checksum) arrived.
    public var checksumOK: Bool? { expectedSum.map { $0 == sum16 } }

    /// "N chunks, seq a..b, consecutive, ended with 0xFFFF" (client.py `seq_report`).
    public var seqReport: String {
        guard !seqs.isEmpty else { return "no chunks" }
        let body = seqs.filter { $0 != FujiBLE.lastSeq }
        var notes = ["\(seqs.count) chunks"]
        if let first = body.first, let last = body.last {
            notes.append("seq \(first)..\(last)")
            let consecutive = zip(body, body.dropFirst()).allSatisfy { $1 == $0 &+ 1 }
            if consecutive {
                notes.append("consecutive")
            } else {
                let jumps = zip(body, body.dropFirst()).filter { $1 != $0 &+ 1 }.count
                notes.append("NOT consecutive (\(jumps) jumps)")
            }
        }
        notes.append(seqs.last == FujiBLE.lastSeq ? "ended with 0xFFFF" : "NO 0xFFFF terminator seen")
        return notes.joined(separator: ", ")
    }
}

/// Header of the whole-camera settings file (helios FUJI_BLOB_FORMAT.md:48-66; client.py `sniff_backup_header`).
public struct SettingsFileHeader: Equatable, Sendable {
    public var magicOK: Bool
    public var size: Int
    public var version = ""
    public var model = ""
    public var serial = ""
    public var payloadStart = 0
    public var payloadLength = 0
    public var lengthConsistent = false

    public init(_ data: Data) {
        let d = [UInt8](data)
        size = d.count
        magicOK = d.count >= 16 && Data(d[0..<16]) == FujiCamera.settingsMagic
        guard magicOK, d.count >= 0xA8 else { return }
        func cstr(_ r: Range<Int>) -> String { String(decoding: d[r].prefix { $0 != 0 }, as: UTF8.self) }
        version = String(decoding: d[0x10..<0x14], as: UTF8.self)
        model = cstr(0x14..<0x34)
        serial = cstr(0x34..<0x54)
        payloadStart = Int(LE.u32(d, 0x98))
        payloadLength = Int(LE.u32(d, 0xA0))
        lengthConsistent = payloadStart + payloadLength == d.count
    }
}

/// Slot names inside a settings file, for the bodies whose layout is known: records are the last seven 0x400-aligned
/// blocks, the name sits at +0x1E5 on an X100VI (fw 1.10, decoded from a real file; ble/maps/x100vi-fw110.json) and
/// +0x1CF on an X-T5 (helios). Empty for other models. Display only (settings-put preflight).
public enum SettingsFileNames {
    public static func read(_ data: Data) -> [String] {
        let h = SettingsFileHeader(data)
        let rel: Int
        switch h.model {
        case "X100VI": rel = 0x1E5
        case "X-T5": rel = 0x1CF
        default: return []
        }
        let d = [UInt8](data)
        guard h.magicOK, d.count > 8 * 0x400 else { return [] }
        let first = ((d.count - 1) / 0x400) * 0x400 - 6 * 0x400
        return (0..<7).map { k in
            let a = first + k * 0x400 + rel
            guard a + 26 <= d.count else { return "?" }
            return String(decoding: d[a..<(a + 26)].prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

// MARK: - Errors

public enum FujiBLEError: Error, Equatable, CustomStringConvertible, Sendable {
    case bluetoothOff
    case unauthorized
    case bluetoothUnsupported
    case notFound
    /// The body is bonded to another device (e.g. a phone running FUJIFILM's app) and ignores this one.
    case pairedElsewhere(String)
    /// Encrypted link required and this device isn't paired.
    case notPaired
    /// Basic firmware needs its saved four-byte pairing key before any authenticated camera operation.
    case pairingKeyMissing
    case missingCharacteristic(String)
    case timeout(String)
    /// BACKUP_STATE 0: the camera is in a menu / playback / busy.
    case busy
    case disconnected(String)
    case framing(String)
    case transfer(String)
    case checksum(expected: Int, got: Int)
    case unexpected(String)
    /// Not implemented (restore) until the protocol is captured.
    case unsupported(String)
    /// iOS still holds pairing keys the camera dropped (camera reset, pairing deleted, firmware update): CoreBluetooth
    /// says "Peer removed pairing information". No API clears it; the user must Forget This Device. Carries the name.
    case staleBond(String)
    /// This device remembers a basic-profile key, but the camera now advertises the secure profile (a firmware update
    /// changed how it pairs). Pair again.
    case profileChanged

    public var description: String {
        switch self {
        case .bluetoothOff: "Bluetooth is off on this device."
        case .unauthorized: "This app isn't allowed to use Bluetooth (Settings › Privacy › Bluetooth)."
        case .bluetoothUnsupported: "This device has no Bluetooth LE."
        case .notFound: "No Fujifilm camera advertising nearby. Is the camera on, with Bluetooth ON?"
        case .pairedElsewhere(let name): "\(name) is paired with another device and won't accept this one. Pair it with this device first (camera: PAIRING REGISTRATION)."
        case .notPaired: "The camera wants a paired (encrypted) link. Put it in PAIRING REGISTRATION and pair."
        case .pairingKeyMissing: "This device has no valid pairing key for the camera. Open PAIRING REGISTRATION on the camera, then pair with Dial In."
        case .missingCharacteristic(let u): "The camera has no characteristic \(u)."
        case .timeout(let what): "Timed out \(what)."
        case .busy: "The camera is busy. Unplug its USB cable if one is attached, leave its menus and playback, then try again."
        case .disconnected(let why): "Bluetooth link dropped: \(why)."
        case .framing(let what): "The camera sent a malformed piece of the backup (\(what))."
        case .transfer(let what): what
        case .checksum(let expected, let got): String(format: "The backup arrived damaged (checksum %04X, expected %04X).", got, expected)
        case .unexpected(let what): what
        case .unsupported(let what): what
        case .staleBond(let name):
            "This iPhone still holds an old pairing for \(name) that the camera no longer has. Open Settings › Bluetooth, tap (i) next to \(name), tap Forget This Device, then pair again."
        case .profileChanged: "Your camera's firmware changed how it pairs. Pair it again."
        }
    }
}
