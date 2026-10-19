// The last check before any settings file goes to the camera over Bluetooth (a write, a rollback, or "Put my old looks
// back"): compared byte for byte with a backup taken moments earlier on the same connection, the file may differ ONLY
// inside the records of the slots being changed (each slot's record with its preamble, `FujiSettingsFile.slotRegion`)
// and in the 16-bit checksum. Anything else (a header byte, another slot, a menu setting, the frame counter) and nothing
// is sent. So a restore can never silently revert menu changes the person made since an older backup.
//
// `UndoFile.make` builds "your old looks" the same narrow way: the camera's file as it is NOW, with only the chosen
// slots' records copied from the old backup and the checksum moved incrementally. Every other setting stays as it is.
import Foundation

public enum RestoreGuard {
    public struct Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        public var reason: String
        public var description: String { reason }
    }

    /// The bytes a restore of `slots` may change, besides the checksum.
    public static func allowedRegions(_ slots: Set<Int>, in file: FujiSettingsFile) -> [Range<Int>] {
        slots.sorted().filter { (1...7).contains($0) }.map { file.slotRegion($0) }
    }

    /// The u16 the checksum lives in (0x108; the high half of the u32 never changes).
    public static let checksumBytes = FujiSettingsFile.checksumOffset..<FujiSettingsFile.checksumOffset + 2

    /// Offsets where `candidate` differs from `fresh` outside the allowed regions (empty = safe to send).
    public static func strayOffsets(_ candidate: [UInt8], _ fresh: [UInt8], slots: Set<Int>, file: FujiSettingsFile) -> [Int] {
        let regions = allowedRegions(slots, in: file)
        var stray: [Int] = []
        for i in 0..<min(candidate.count, fresh.count) where candidate[i] != fresh[i] {
            if checksumBytes.contains(i) || regions.contains(where: { $0.contains(i) }) { continue }
            stray.append(i)
        }
        return stray
    }

    /// Throws unless `candidate` is `fresh` with changes only inside `slots`' records and the checksum, carrying the
    /// checksum the offline patcher predicts (hardware validation is a separate gate), with valid names.
    public static func check(_ candidate: Data, against fresh: Data, slots: Set<Int>) throws {
        let c = [UInt8](candidate), f = [UInt8](fresh)
        guard !slots.isEmpty, slots.allSatisfy({ (1...7).contains($0) }) else {
            throw Refusal(reason: "no slots to change (got \(slots.sorted()))")
        }
        guard c.count == f.count else {
            throw Refusal(reason: "the file is \(c.count) bytes and the camera's is \(f.count)")
        }
        let freshFile: FujiSettingsFile, candidateFile: FujiSettingsFile
        do {
            freshFile = try FujiSettingsFile(bytes: f)
            candidateFile = try FujiSettingsFile(bytes: c)
        } catch {
            throw Refusal(reason: "not an X100VI fw 1.10 settings file (\(error))")
        }
        let stray = strayOffsets(c, f, slots: slots, file: freshFile)
        guard stray.isEmpty else {
            let at = stray.prefix(4).map { String(format: "0x%X", $0) }.joined(separator: ", ")
            throw Refusal(reason: "\(stray.count) byte(s) outside \(SlotText.list(slots)) differ from the camera's file (at \(at)\(stray.count > 4 ? ", …" : ""))")
        }
        let problems = FujiSettingsFile.validate(original: freshFile, patched: candidateFile)
        guard problems.isEmpty else { throw Refusal(reason: problems.joined(separator: "; ")) }
    }
}

/// "Put my old looks back", narrowly: the camera's current file with only `slots` taken from the old backup.
public enum UndoFile {
    /// - Parameters:
    ///   - old: the backup taken before Dial In wrote (the looks to bring back).
    ///   - now: a backup taken moments ago on this connection (everything else stays as in this file).
    ///   - slots: the slots to bring back.
    /// - Returns: the file to send, or `now` itself when those slots already match the backup.
    public static func make(old: Data, onto now: Data, slots: Set<Int>) throws -> Data {
        let o = try FujiSettingsFile(old), n = try FujiSettingsFile(now)
        guard o.anchors == n.anchors else { throw SettingsFileError.invalid("the two files don't share a layout") }
        var out = n.bytes
        for s in slots.sorted() where (1...7).contains(s) {
            let r = n.slotRegion(s)
            out.replaceSubrange(r, with: o.bytes[r])
        }
        guard out != n.bytes else { return now }
        let sum = try FujiSettingsFile.expectedChecksum(original: n, patchedBytes: out)
        out[FujiSettingsFile.checksumOffset] = UInt8(sum & 0xFF)
        out[FujiSettingsFile.checksumOffset + 1] = UInt8(sum >> 8)
        return Data(out)
    }
}

/// The camera a settings backup came from, read from its header: only that body may get it back.
public struct BackupIdentity: Sendable, Equatable, Codable {
    public var model: String
    public var serial: String

    public init(model: String, serial: String) {
        self.model = model
        self.serial = serial
    }

    public init(_ data: Data) {
        let h = SettingsFileHeader(data)
        model = h.model
        serial = h.serial
    }

    /// The last four characters of the serial ("··7A7A" on screen); never the whole serial.
    public var serialSuffix: String { String(serial.suffix(4)) }

    /// Same body: same model and the same non-empty serial.
    public func isSameCamera(as other: BackupIdentity) -> Bool {
        !serial.isEmpty && serial == other.serial && model == other.model
    }
}

enum SlotText {
    /// "C3", "C3 and C5", "C1, C2 and C4".
    static func list(_ slots: Set<Int>) -> String {
        let names = slots.sorted().map { "C\($0)" }
        guard names.count > 1 else { return names.first ?? "no slot" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
