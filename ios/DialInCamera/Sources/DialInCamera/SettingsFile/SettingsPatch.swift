// `dialin-cam settings-patch`: the offline half of a settings restore. Parses the Python patcher's --set syntax and
// re-checks a written file byte for byte (ble/fuji_ble/x100vi_settings.py `patch` + `verify`, same rules).
// Never talks to a camera and never prints the serial.
import Foundation

extension FujiSettingsFile {
    /// "1:af_mode=single point", "C7:image_size=M", "1:af_mode=raw=2" → an edit (x100vi_settings.py `_parse_set`).
    public static func parseSet(_ s: String) throws -> Edit {
        guard let colon = s.firstIndex(of: ":") else { throw SettingsFileError.invalid("--set \(s): use N:key=value, e.g. 1:af_mode=single point") }
        let slotText = s[..<colon].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "Cc"))
        let rest = s[s.index(after: colon)...]
        guard let slot = Int(slotText), let eq = rest.firstIndex(of: "=") else {
            throw SettingsFileError.invalid("--set \(s): use N:key=value, e.g. 1:af_mode=single point")
        }
        let key = rest[..<eq].trimmingCharacters(in: .whitespaces)
        let value = rest[rest.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { throw SettingsFileError.invalid("--set \(s): empty key or value") }
        return .field(slot: slot, key: key, value: value)
    }

    /// Problems with `written` (the bytes as read back from disk) as the output of `result`; empty = the round trip
    /// holds: same bytes as patched, a valid X100VI file, only the edited bytes and the checksum differ from the
    /// camera's original, and the checksum constant K is unchanged.
    public static func roundTripProblems(original: FujiSettingsFile, written: Data, result: PatchResult) -> [String] {
        let back: FujiSettingsFile
        do {
            back = try FujiSettingsFile(written)
        } catch {
            return ["the written file doesn't parse: \(error)"]
        }
        var problems: [String] = []
        if back.bytes != result.file.bytes { problems.append("the file on disk differs from the patched bytes") }
        problems += validate(original: original, patched: back, allowed: result.allowed)
        if back.checksumConstant != original.checksumConstant {
            problems.append(String(format: "K changed: 0x%04X → 0x%04X", original.checksumConstant, back.checksumConstant))
        }
        return problems
    }
}
