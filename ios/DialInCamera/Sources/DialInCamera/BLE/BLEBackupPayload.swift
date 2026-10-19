import Foundation
import zlib

/// Bluetooth may transport a zlib-compressed backup while FILE_INFORMATION reports
/// the expanded size. Observed on X100VI 1.10, 2026-10-13. Keep the wire bytes for
/// transport checksums and evidence; only the expanded bytes go to settings decoders.
enum BLEBackupPayload {
    static let maximumSize = 1_048_576

    /// Trust both representations together. `checksumOK` alone is caller-editable metadata.
    static func validate(_ backup: FujiBLEFlows.SettingsBackup) throws {
        let header = SettingsFileHeader(backup.data)
        guard backup.checksumOK == true, backup.expectedSum == byteSum16(backup.wireData),
              backup.computedSum == byteSum16(backup.wireData), !backup.wireData.isEmpty,
              header.magicOK, header.lengthConsistent, !header.model.isEmpty, !header.serial.isEmpty else {
            throw FujiBLEError.transfer("Fresh backup failed integrity checks. No restore request was sent.")
        }
        let decoded = try decode(backup.wireData, reportedSize: backup.reportedSize)
        guard decoded.data == backup.data, decoded.compressed == backup.compressed else {
            throw FujiBLEError.transfer("Fresh backup representations disagree. No restore request was sent.")
        }
    }

    /// Preserve the camera's transport: exact original bytes for unchanged settings, or a round-trip-checked
    /// zlib stream for edits on a compressed camera. It does not establish camera acceptance of the edited file.
    static func encode(_ data: Data, matching backup: FujiBLEFlows.SettingsBackup) throws -> Data {
        try validate(backup)
        guard data.count == backup.data.count, BackupIdentity(data).isSameCamera(as: BackupIdentity(backup.data)),
              SettingsFileHeader(data).lengthConsistent else {
            throw FujiBLEError.transfer("The edited settings do not match the fresh backup's camera and size. Nothing was uploaded.")
        }
        if data == backup.data { return backup.wireData }
        guard backup.compressed else { return data }
        return try compress(data, matchingHeader: backup.wireData.prefix(2))
    }

    /// Current physical evidence covers a 32 KiB zlib window. Preserve the CMF/FLG compression-level hint too;
    /// unfamiliar windows/flags fail instead of silently changing the format.
    static func compress(_ data: Data, matchingHeader: Data = Data([0x78, 0x9C])) throws -> Data {
        guard (1...maximumSize).contains(data.count), matchingHeader.count == 2,
              matchingHeader.first == 0x78 else {
            throw FujiBLEError.unsupported("The camera's compression format is not supported. Nothing was uploaded.")
        }
        let level: Int32
        switch matchingHeader.last {
        case 0x01: level = 1
        case 0x5E: level = 3
        case 0x9C: level = 6
        case 0xDA: level = 9
        default: throw FujiBLEError.unsupported("The camera's compression flags are not supported. Nothing was uploaded.")
        }
        var outputLength = compressBound(uLong(data.count))
        var output = [UInt8](repeating: 0, count: Int(outputLength))
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBufferPointer { dest in
                compress2(dest.baseAddress, &outputLength, input.bindMemory(to: Bytef.self).baseAddress,
                          uLong(data.count), level)
            }
        }
        guard status == Z_OK else { throw FujiBLEError.transfer("Settings compression failed. Nothing was uploaded.") }
        let wire = Data(output.prefix(Int(outputLength)))
        guard wire.prefix(2) == matchingHeader, wire.count <= maximumSize,
              try decode(wire, reportedSize: data.count).data == data else {
            throw FujiBLEError.transfer("Compressed settings failed their round-trip check. Nothing was uploaded.")
        }
        return wire
    }

    static func decode(_ wire: Data, reportedSize: Int?) throws -> (data: Data, compressed: Bool) {
        guard wire.count <= maximumSize else { throw FujiBLEError.transfer("Settings backup exceeds the size limit.") }
        let prefix = [UInt8](wire.prefix(2))
        let isZlib = prefix.count == 2 && prefix[0] & 0x0F == 8 && prefix[0] >> 4 <= 7
            && (Int(prefix[0]) * 256 + Int(prefix[1])) % 31 == 0
        guard isZlib else {
            // Preserve the pre-existing plain-file behavior. The caller checks the settings header.
            if let size = reportedSize, size > 0 {
                guard size <= wire.count else { throw FujiBLEError.transfer("Settings backup is shorter than the camera reported.") }
                return (Data(wire.prefix(size)), false)
            }
            return (wire, false)
        }
        guard prefix[1] & 0x20 == 0 else { throw FujiBLEError.transfer("Settings backup requires an unsupported compression dictionary.") }
        guard reportedSize.map({ (1...maximumSize).contains($0) }) ?? true else {
            throw FujiBLEError.transfer("Expanded settings backup size is outside the supported limit.")
        }
        var output = [UInt8](repeating: 0, count: maximumSize)
        var outputLength = uLongf(output.count)
        var inputLength = uLong(wire.count)
        let status = wire.withUnsafeBytes { input in
            output.withUnsafeMutableBufferPointer { dest in
                uncompress2(dest.baseAddress, &outputLength,
                            input.bindMemory(to: Bytef.self).baseAddress, &inputLength)
            }
        }
        guard status == Z_OK, inputLength == wire.count else {
            throw FujiBLEError.transfer("Compressed settings backup is damaged, incomplete, oversized, or has trailing data.")
        }
        let data = Data(output.prefix(Int(outputLength)))
        if let reportedSize, data.count != reportedSize {
            throw FujiBLEError.transfer("Expanded settings backup size differs from the camera's file information.")
        }
        let header = SettingsFileHeader(data)
        guard header.magicOK && header.lengthConsistent else {
            throw FujiBLEError.transfer("Compressed transfer does not contain a complete Fujifilm settings backup.")
        }
        return (data, true)
    }
}
