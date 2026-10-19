// The X100VI (fw 1.10) whole-camera settings file, "FUJIFILMX-BACKUP": header, checksum, C1–C7 decode, safe patcher.
// Offline only: this file never talks to a camera (FujiCamera.getSettingsFile / putSettingsFile move the bytes).
//
// Transport and checksum (docs/FUJIFILM-PROTOCOL.md §2.10, §4.6):
//   - Desktop backup/restore moves the file verbatim: backup = GetObjectInfo(0) + GetObject(0); restore =
//     SendObjectInfo([0,0], 1076-byte ObjectInfo, format 0x5000) + SendObject. The file's checksum appears to be
//     computed and validated by the camera, not the computer (hypothesis); the "0100" version at 0x10 is checked first.
//   - The X100VI file checksum is NOT hardware-validated. The incremental sum below is a hypothesis for
//     narrow slot edits. Two real backups from different days disagree under a whole-payload sum; excluding two
//     candidate counter regions fits both, but those files contain no slot changes.
//     BLESlotWriter refuses modified settings writes on real hardware until independent evidence validates it.
// Slot geometry and look encodings: ble/maps/x100vi-fw110.json (verified against PTP read-back). The non-look per-slot
// fields here are helios' X-T5 offsets moved by the X100VI's measured shift; all but three are hypotheses until a
// one-setting diff on the X100VI confirms them, so patching them needs `allowHypothesis`.
import Foundation

public enum SettingsFileError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let why): "Settings file: \(why)"
        }
    }
}

public struct FujiSettingsFile: Sendable, Equatable {
    public static let magic = Array("FUJIFILMX-BACKUP".utf8)
    public static let model = "X100VI"
    public static let fw110Size = 70524
    public static let checksumOffset = 0x108
    public static let slotStride = 0x400
    public static let nameRel = 0x1E5
    public static let nameFieldLength = 26
    public static let nameMaxLength = 25
    /// The X-T5 refuses a restore when the seven names total more than about this (helios); assume the same here.
    public static let nameBudget = 95

    public let bytes: [UInt8]
    public let version: String
    public let payloadStart: Int
    public let payloadLength: Int
    /// Absolute start of C1…C7 (the last seven 0x400-aligned blocks; C1 = 0xF800 on fw 1.10).
    public let anchors: [Int]

    public init(_ data: Data) throws { try self.init(bytes: [UInt8](data)) }

    public init(bytes b: [UInt8]) throws {
        guard b.count > 0xA8, Array(b[0..<16]) == Self.magic else { throw SettingsFileError.invalid("not a FUJIFILMX-BACKUP file") }
        let version = String(decoding: b[0x10..<0x14], as: UTF8.self)
        guard version == "0100" else { throw SettingsFileError.invalid("version \"\(version)\"; only 0100 is understood") }
        let model = Self.cString(b, 0x14, 32)
        guard model == Self.model else { throw SettingsFileError.invalid("this is a \(model) file; the offsets here are for the X100VI") }
        let start = Int(LE.u32(b, 0x98)), length = Int(LE.u32(b, 0xA0))
        guard start == 0xA8 else { throw SettingsFileError.invalid("payload start differs from the fw 1.10 layout") }
        guard start + length == b.count else { throw SettingsFileError.invalid("header payload length doesn't match the file size (truncated?)") }
        guard b.count == Self.fw110Size else {
            throw SettingsFileError.invalid("\(b.count) bytes; the slot map is for the \(Self.fw110Size)-byte fw 1.10 file")
        }
        let last = (b.count - 1) / Self.slotStride * Self.slotStride
        bytes = b
        self.version = version
        payloadStart = start
        payloadLength = length
        anchors = (0..<7).map { last - (6 - $0) * Self.slotStride }
    }

    static func cString(_ b: [UInt8], _ o: Int, _ limit: Int) -> String {
        let end = b[o..<min(b.count, o + limit)].firstIndex(of: 0) ?? min(b.count, o + limit)
        return String(decoding: b[o..<end], as: UTF8.self)
    }

    public var data: Data { Data(bytes) }

    // MARK: Checksum

    public var storedChecksum: UInt16 { LE.u16(bytes, Self.checksumOffset) }

    /// Σ of every payload byte except the 4-byte field at 0x108.
    public var coveredSum: Int {
        var s = 0
        for i in payloadStart..<bytes.count where !(Self.checksumOffset..<Self.checksumOffset + 4).contains(i) { s += Int(bytes[i]) }
        return s
    }

    /// K in stored = (coveredSum + K) mod 2¹⁶. Compare across captures; equality alone does not prove which bytes are covered.
    public var checksumConstant: UInt16 { UInt16(truncatingIfNeeded: Int(storedChecksum) - coveredSum) }

    /// Candidate checksum under the incremental-sum hypothesis. Not evidence that the camera will accept it.
    public static func expectedChecksum(original: FujiSettingsFile, patchedBytes: [UInt8]) throws -> UInt16 {
        let p = try FujiSettingsFile(bytes: patchedBytes)
        return UInt16(truncatingIfNeeded: Int(original.storedChecksum) + p.coveredSum - original.coveredSum)
    }

    // MARK: Slots

    public func name(slot: Int) -> String {
        let at = anchors[slot - 1] + Self.nameRel
        return Self.cString(bytes, at, Self.nameFieldLength)
    }

    public var names: [String] { (1...7).map { name(slot: $0) } }

    /// The parts of the look this decoder reads (the full map is ble/maps/x100vi-fw110.json).
    public struct Look: Sendable, Equatable {
        public var filmSimCode: Int?
        public var dynamicRange: Int?
        public var highlight: Double
        public var shadow: Double
        public var sharpness: Int
        public var clarity: Int
        public var noiseReduction: Int
        public var colorChrome: Int
        public var colorChromeFxBlue: Int
        public var kelvin: Int
        /// The WB mode byte as stored (X-T5 code table: 0 Auto, 3 Daylight, 0x0A Kelvin …).
        public var whiteBalanceRaw: Int
    }

    /// PTP film-sim code → X100VI blob code (ble/fuji_ble/correlate.py `X100VI_FILM_SIM`; 7 observed, rest inferred).
    public static let filmSimToBlob: [Int: Int] = [
        1: 1, 2: 4, 3: 2, 4: 14, 5: 13, 6: 9, 7: 11, 8: 10, 9: 12, 10: 6, 11: 15, 12: 22, 13: 24, 14: 23, 15: 25,
        16: 19, 17: 16, 18: 20, 19: 17, 20: 18,
    ]

    public func look(slot: Int) -> Look {
        let a = anchors[slot - 1]
        let film = Int(bytes[a + 0x64])
        let dr = [0: 0, 1: 100, 2: 200, 3: 400][Int(bytes[a + 0x74])]
        return Look(
            filmSimCode: Self.filmSimToBlob.first(where: { $0.value == film })?.key, dynamicRange: dr,
            highlight: Double(bytes[a + 0x7B]) * 0.5 - 2, shadow: Double(bytes[a + 0x7D]) * 0.5 - 2,
            sharpness: 4 - Int(bytes[a + 0x79]), clarity: Int(bytes[a + 0x2E]) - 6, noiseReduction: Int(bytes[a + 0x2B]) - 4,
            colorChrome: Int(bytes[a + 0x7F]), colorChromeFxBlue: Int(bytes[a + 0x80]),
            kelvin: Int(LE.u16(bytes, a - 0x74)), whiteBalanceRaw: Int(bytes[a - 0x0F]))
    }

    /// A per-slot setting outside the look.
    public struct SlotField: Sendable {
        public enum Status: String, Sendable { case consistent, hypothesis }
        public var key: String
        public var rel: Int
        public var codes: [Int: String]
        public var status: Status
        public var evidence: String
    }

    static let xt5 = "helios X-T5 map"
    /// Mirrors ble/fuji_ble/x100vi_settings.py `EXT_FIELDS` (the single-byte, named-code subset).
    public static let slotFields: [SlotField] = [
        SlotField(key: "image_size", rel: 0x2F, codes: [0: "L", 1: "M", 2: "S"], status: .consistent,
                  evidence: "\(xt5) +0x26 moved +9 like NR/clarity; 0 = L on 7/7 with D18E = L 3:2"),
        SlotField(key: "aspect_ratio", rel: 0x31, codes: [1: "3:2", 2: "16:9", 3: "1:1"], status: .consistent,
                  evidence: "\(xt5) +0x28 +9; 1 = 3:2 on 7/7 with D18E = L 3:2"),
        SlotField(key: "image_quality", rel: 0x32, codes: [0: "Fine", 1: "Normal", 2: "Fine+RAW", 3: "Normal+RAW", 4: "RAW"],
                  status: .consistent, evidence: "\(xt5) +0x29 +9; 2 on 7/7 with D18F = 4"),
        SlotField(key: "af_mode", rel: 0x84, codes: [2: "Single point", 3: "Zone", 0: "Wide/Tracking"], status: .hypothesis,
                  evidence: "\(xt5) +0x6C +0x18, right after smooth skin; ALL = 0 + flag at +0x88"),
        SlotField(key: "af_all", rel: 0x88, codes: [0: "off", 1: "on"], status: .hypothesis, evidence: "\(xt5) +0x70 +0x18"),
        SlotField(key: "self_timer", rel: 0x9E, codes: [0: "Off", 1: "2s", 2: "10s"], status: .hypothesis, evidence: "\(xt5) +0x86 +0x18"),
        SlotField(key: "raw_recording", rel: 0x101, codes: [0: "Uncompressed", 1: "Lossless compressed", 2: "Compressed"],
                  status: .hypothesis, evidence: "\(xt5) +0xE9 +0x18"),
        SlotField(key: "heif", rel: 0x103, codes: [0: "JPEG", 1: "HEIF"], status: .hypothesis, evidence: "\(xt5) +0xEB +0x18"),
    ]

    public static func slotField(_ key: String) -> SlotField? { slotFields.first { $0.key == key } }

    /// Raw byte and decoded name of a per-slot field.
    public func value(_ key: String, slot: Int) -> (raw: Int, name: String)? {
        guard let f = Self.slotField(key) else { return nil }
        let raw = Int(bytes[anchors[slot - 1] + f.rel])
        return (raw, f.codes[raw] ?? "?raw=\(raw)")
    }

    // MARK: Patch

    public enum Edit: Sendable, Equatable {
        case name(slot: Int, String)
        /// A per-slot field by name ("Single point") or raw ("raw=2").
        case field(slot: Int, key: String, value: String)
    }

    public struct PatchResult: Sendable {
        public var file: FujiSettingsFile
        public var lines: [String]
        public var allowed: Set<Int>
    }

    /// Apply edits to a camera-made file, fix the checksum incrementally, and check the round trip. Throws instead
    /// of returning anything the camera might misread.
    public func patched(_ edits: [Edit], allowHypothesis: Bool = false) throws -> PatchResult {
        var out = bytes
        var lines: [String] = []
        var allowed = Set<Int>()
        func slotAnchor(_ s: Int) throws -> Int {
            guard (1...7).contains(s) else { throw SettingsFileError.invalid("slot \(s) is not 1…7") }
            return anchors[s - 1]
        }
        for e in edits {
            switch e {
            case .name(let s, let name):
                let a = try slotAnchor(s)
                guard !name.isEmpty, name.count <= Self.nameMaxLength, name.unicodeScalars.allSatisfy({ (0x20..<0x7F).contains($0.value) }) else {
                    throw SettingsFileError.invalid("name \"\(name)\": 1…\(Self.nameMaxLength) printable ASCII characters")
                }
                let at = a + Self.nameRel
                let old = Self.cString(out, at, Self.nameFieldLength)
                var field = Array(name.utf8)
                field += [UInt8](repeating: 0, count: Self.nameFieldLength - field.count)
                out.replaceSubrange(at..<at + Self.nameFieldLength, with: field)
                allowed.formUnion(at..<at + Self.nameFieldLength)
                lines.append("C\(s) name \"\(old)\" → \"\(name)\"")
            case .field(let s, let key, let value):
                let a = try slotAnchor(s)
                guard let f = Self.slotField(key) else { throw SettingsFileError.invalid("unknown per-slot field \(key)") }
                if f.status == .hypothesis && !allowHypothesis {
                    throw SettingsFileError.invalid("\(key) is a hypothesis (X-T5 offset moved to the X100VI, unconfirmed); pass allowHypothesis")
                }
                let raw: Int
                if value.lowercased().hasPrefix("raw="), let r = Int(value.dropFirst(4)) {
                    raw = r
                } else if let r = f.codes.first(where: { $0.value.lowercased() == value.lowercased() })?.key {
                    raw = r
                } else {
                    throw SettingsFileError.invalid("\(key): \"\(value)\" isn't one of \(f.codes.values.sorted()) (or raw=N)")
                }
                guard (0...255).contains(raw) else { throw SettingsFileError.invalid("\(key): raw \(raw) doesn't fit a byte") }
                let at = a + f.rel
                lines.append("C\(s) \(key) \(f.codes[Int(out[at])] ?? "raw \(out[at])") → \(f.codes[raw] ?? "raw \(raw)")"
                    + (f.status == .hypothesis ? "  [HYPOTHESIS]" : ""))
                out[at] = UInt8(raw)
                allowed.insert(at)
            }
        }
        let interim = try FujiSettingsFile(bytes: out)
        let total = interim.names.reduce(0) { $0 + $1.count }
        guard total <= Self.nameBudget else {
            throw SettingsFileError.invalid("the seven names would total \(total) characters; restores refuse above ~\(Self.nameBudget)")
        }
        let sum = try Self.expectedChecksum(original: self, patchedBytes: out)
        out[Self.checksumOffset] = UInt8(sum & 0xFF)
        out[Self.checksumOffset + 1] = UInt8(sum >> 8)
        let fixed = try FujiSettingsFile(bytes: out)
        lines.append(String(format: "checksum 0x%04X → 0x%04X (incremental 16-bit byte sum @ 0x108)", storedChecksum, sum))
        let problems = Self.validate(original: self, patched: fixed, allowed: allowed)
        guard problems.isEmpty else { throw SettingsFileError.invalid("round-trip check failed: " + problems.joined(separator: "; ")) }
        return PatchResult(file: fixed, lines: lines, allowed: allowed)
    }

    /// Problems with `patched` as an edit of camera-made `original`; empty = consistent.
    public static func validate(original: FujiSettingsFile, patched: FujiSettingsFile, allowed: Set<Int>? = nil) -> [String] {
        var problems: [String] = []
        if original.bytes.count != patched.bytes.count || original.bytes[0..<original.payloadStart] != patched.bytes[0..<patched.payloadStart] {
            problems.append("size or header changed")
        }
        if original.bytes[checksumOffset + 2..<checksumOffset + 4] != patched.bytes[checksumOffset + 2..<checksumOffset + 4] {
            problems.append("the checksum field's high half changed")
        }
        if let want = try? expectedChecksum(original: original, patchedBytes: patched.bytes), want != patched.storedChecksum {
            problems.append(String(format: "checksum 0x%04X, expected 0x%04X", patched.storedChecksum, want))
        }
        if let allowed {
            let stray = (0..<min(original.bytes.count, patched.bytes.count)).filter {
                original.bytes[$0] != patched.bytes[$0] && !allowed.contains($0) && !(checksumOffset..<checksumOffset + 2).contains($0)
            }
            if !stray.isEmpty { problems.append("bytes changed outside the edits at " + stray.prefix(8).map { String(format: "0x%X", $0) }.joined(separator: ", ")) }
        }
        for a in patched.anchors {
            let field = Array(patched.bytes[a + nameRel..<a + nameRel + nameFieldLength])
            let text = field.prefix { $0 != 0 }
            if !field[text.count...].allSatisfy({ $0 == 0 }) || !text.allSatisfy({ (0x20..<0x7F).contains($0) }) {
                problems.append(String(format: "name field at 0x%X isn't a zero-padded ASCII name", a + nameRel))
            }
        }
        return problems
    }
}
