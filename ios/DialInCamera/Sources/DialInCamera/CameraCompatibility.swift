// Official app compatibility is research evidence, not permission to write camera settings.
// Sources: FUJIFILM's published compatibility charts for its phone app (XApp) and for Tether App backup/restore,
// https://www.fujifilm-x.com/en-us/support/compatibility/software/ (checked 2026-10-13).
import Foundation

public enum CameraCompatibility {
    public struct Model: Codable, Sendable, Equatable {
        public var name: String
        public var listedForXApp: Bool
        public var listedForDesktopBackup: Bool
        public var desktopBackupOnly: Bool
    }

    /// Deliberately independent of firmware/profile detection and every write gate.
    public static let models: [Model] = {
        let phoneApp: Set<String> = ["GFX100 II", "GFX100", "GFX100S II", "GFX100S", "GFX50S II", "GFX 50R", "GFX100RF",
            "X-H2S", "X-H2", "X-Pro3", "X-T5", "X-T4", "X-S20", "X-S10", "X-T50", "X-T30 III", "X-T30 II",
            "X-E5", "X-E4", "X-M5", "X100VI", "X100V"]
        let backupOnly: Set<String> = ["X-T50", "X-T30 II", "X-T30", "X-T20", "X-E5", "X-E4", "X-E3", "X100VI", "X100V", "X100F"]
        let desktopBackup = phoneApp.subtracting(["X-T30 III"]).union(backupOnly).union(["GFX 50S", "X-H1", "X-Pro2", "X-T3", "X-T2"])
        return phoneApp.union(desktopBackup).union(["X-T1"]).sorted().map {
            Model(name: $0, listedForXApp: phoneApp.contains($0), listedForDesktopBackup: desktopBackup.contains($0),
                  desktopBackupOnly: backupOnly.contains($0))
        }
    }()

    /// Formatting aliases only. Never prefix-match (X100V and X100VI must remain distinct).
    public static func modelKey(_ raw: String?) -> String {
        var text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("FUJIFILM") { text.removeFirst("FUJIFILM".count) }
        return text.filter { !$0.isWhitespace && $0 != "-" }
    }

    public static func model(_ raw: String?) -> Model? {
        let key = modelKey(raw)
        return models.first { modelKey($0.name) == key }
    }

    /// A decoding profile, NOT an accepted-modified-restore record. Matching size alone is insufficient.
    public static func hasSettingsDecoder(model: String?, firmware: String?) -> Bool {
        modelKey(model) == "X100VI" && BLESlotWriter.normalizeFirmware(firmware) == "1.10"
    }

    /// The current app's planner/recipe encoder describes this model only. USB discovery can remain generic,
    /// but another body must not receive X100VI recipes merely because it advertises D18C.
    public static func requireRecipeModel(_ model: String) throws {
        guard modelKey(model) == "X100VI" else {
            let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CameraError.invalid("Dial In hasn't validated look loading for \(name.isEmpty ? "this camera" : name) yet. Run Camera Check in Settings. Nothing was written.")
        }
    }
}
