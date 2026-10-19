// C1–C7 snapshot in the exact JSON shape `npm run cam backup` writes (scripts/cam.ts):
// { "model": "X100VI", "at": "2026-10-09T15:04:05.123Z", "slots": [ { "slot": 1, "name": "…", "props": [ { "id": 53646, "hex": "0b00" } ] } ] }
// Files are interchangeable between the TypeScript tools and dialin-cam / the app.
import Foundation

/// One slot as read from the camera.
public struct SlotSnapshot: Codable, Equatable, Hashable, Sendable {
    public var slot: Int
    public var name: String
    public var props: [Prop]

    public struct Prop: Codable, Equatable, Hashable, Sendable {
        /// Property code as a plain JSON number (e.g. 53650 = 0xD192), as camera.ts writes it.
        public var id: Int
        /// Raw little-endian bytes, lowercase hex.
        public var hex: String

        public init(id: Int, hex: String) {
            self.id = id
            self.hex = hex
        }
    }

    public init(slot: Int, name: String, props: [Prop]) {
        self.slot = slot
        self.name = name
        self.props = props
    }

    public init(slot: Int, name: String, rawProps: [RawProp]) {
        self.init(slot: slot, name: name, props: rawProps.map { Prop(id: Int($0.id), hex: $0.bytes.hexString) })
    }

    /// The props as raw bytes (unparseable hex entries are dropped).
    public var rawProps: [RawProp] {
        props.compactMap { p in
            guard let id = UInt16(exactly: p.id), let bytes = Data(hexString: p.hex) else { return nil }
            return RawProp(id: id, bytes: bytes)
        }
    }

    /// What the slot holds, decoded (FilmKit `translatePresetToUI`).
    public var values: PresetValues { PresetValues(props: rawProps) }

    /// The slot as a `Recipe`, when our schema can express it.
    public var recipe: Recipe? { Recipe(name: name, values: values) }

    /// cam.ts `print`: `C3 "Warm Gold"  Classic Chrome · DR400 · …`
    public var line: String { "C\(slot) \"\(name)\"  \(values.summary)" }
}

/// The backup file.
public struct SlotBackup: Codable, Equatable, Sendable {
    public var model: String
    /// ISO-8601 with milliseconds, UTC (JavaScript `toISOString()`).
    public var at: String
    public var serial: String?
    public var firmware: String?
    public var slots: [SlotSnapshot]

    public init(model: String, at: String = SlotBackup.timestamp(), serial: String? = nil, firmware: String? = nil, slots: [SlotSnapshot]) {
        self.model = model
        self.at = at
        self.serial = serial
        self.firmware = firmware
        self.slots = slots
    }

    public static func validateTargets(_ slots: [Int], protected: Set<Int>) throws {
        guard !slots.isEmpty, slots.count <= 7, Set(slots).count == slots.count,
              slots.allSatisfy({ (1...7).contains($0) }) else {
            throw CameraError.invalid("Choose distinct slots from C1 to C7. Nothing was written.")
        }
        guard Set(slots).isDisjoint(with: protected) else {
            throw CameraError.invalid("A chosen slot is protected. Nothing was written.")
        }
    }

    public func requireSameCamera(as fresh: SlotBackup) throws {
        guard let serial, !serial.isEmpty, let firmware, !firmware.isEmpty,
              serial == fresh.serial, model == fresh.model, firmware == fresh.firmware else {
            throw CameraError.invalid("This backup needs the same camera and firmware, with a verified serial number. Nothing was written.")
        }
    }

    /// `new Date().toISOString()`.
    public static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// cam.ts `backupPath` stamp: `2026-10-09-15-04-05` (UTC).
    public static func fileStamp(_ date: Date = Date()) -> String {
        String(timestamp(date).prefix(19)).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "T", with: "-")
    }

    /// Pretty JSON, 2-space indent like `JSON.stringify(x, null, 2)`.
    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> SlotBackup {
        try JSONDecoder().decode(SlotBackup.self, from: data)
    }
}
