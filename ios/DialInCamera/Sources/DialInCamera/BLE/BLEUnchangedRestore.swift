import Foundation

extension FujiBLEFlows {
    /// Supervised lab experiment only: download a fresh backup and send its exact wire bytes back
    /// over the same connection. No caller-supplied file, patching, recompression or identity normalization.
    /// The mandatory callback must durably preserve and review the backup before any restore request.
    /// Transport completion is not camera acceptance: the caller must observe the camera and independently
    /// read it over USB afterward. This does not enable BLESlotWriter or the generic compressed-file restore.
    public static func restoreFreshBackupUnchanged(
        _ gatt: any GATTClient, experimental: Bool = false,
        betweenTransfers: Duration = .milliseconds(1500),
        onSafetyBackup: @Sendable (SettingsBackup) throws -> Void,
        log: @Sendable (String) -> Void = { _ in },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> RestoreResult {
        guard experimental else { throw restoreUnsupported }
        let fresh = try await backupSettings(gatt, log: log)
        guard fresh.checksumOK == true, fresh.header.magicOK, fresh.header.lengthConsistent,
              !fresh.header.model.isEmpty, !fresh.header.serial.isEmpty,
              !fresh.wireData.isEmpty else {
            throw FujiBLEError.transfer("Fresh backup failed integrity checks. No restore request was sent.")
        }
        let decoded = try BLEBackupPayload.decode(fresh.wireData, reportedSize: fresh.reportedSize)
        guard decoded.data == fresh.data, decoded.compressed == fresh.compressed else {
            throw FujiBLEError.transfer("Fresh backup representations disagree. No restore request was sent.")
        }
        try onSafetyBackup(fresh)
        try Task.checkCancellation()
        try await Task.sleep(for: betweenTransfers)
        log("unchanged lab restore: returning the fresh backup's exact \(fresh.wireData.count) wire bytes")
        return try await restoreSettingsStandard(gatt, file: fresh.wireData, log: log, progress: progress)
    }
}
