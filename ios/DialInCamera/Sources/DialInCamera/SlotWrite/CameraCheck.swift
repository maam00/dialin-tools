// Camera Check: a read-only run a tester can do on any body (docs/FUJIFILM-PROTOCOL.md §6). Pair (or reuse the pairing),
// read the identity, fingerprint the GATT table, download the settings backup THROUGH the write guard (ReadOnlyGATT),
// parse its header, and if the fw 1.10 map accepts the file, read C1 back to the tester as a sentence to confirm.
// It changes no camera setting. The only writes are the handshake (pairing key / identification number, client name,
// both on the guard's allowlist) and the backup's own requests, which go through the guard.
//
// The report carries derived facts only: never the serial, the Y number, the MAC, the SSID or the file. Slot names are
// user content and stay (the tester confirms them).
import CryptoKit
import Foundation

public enum CameraCheck {
    public enum Step: Sendable, Equatable { case connecting, identity, fingerprint, backingUp(bytes: Int), parsing, done }

    public struct Report: Codable, Sendable, Equatable {
        public var model: String?
        public var firmware: String?
        public var software: String?
        /// CAMERA_BLE_PROTOCOL_VERSION (389363e4), hex, when the body has it.
        public var bleProtocolVersion: String?
        /// From the handshake the body accepted (its GATT table), not from the firmware string.
        public var profile: FujiBLEProfile
        public var characteristicCount: Int
        /// SHA-256 of the sorted "characteristic|properties" lines.
        public var fingerprint: String
        public var fingerprintNote: String
        public var hasBackup: Bool
        public var hasRestore: Bool
        public var hasFileService: Bool
        public var fileSize: Int?
        public var transferChecksumOK: Bool?
        public var magicOK: Bool
        /// The header's model equals a known, nonempty identity model.
        public var modelOK: Bool
        /// Transfer integrity, camera identity, exact firmware and the known layout all passed.
        public var settingsLayoutSupported: Bool
        public var layoutProblem: String?
        /// Legacy report field. Always nil: the historical two-capture hypothesis cannot certify a file.
        public var checksumConstantMatchesReference: Bool?
        /// Optional for reports saved before this schema. Official compatibility never enables a writer.
        public var officialCompatibility: CameraCompatibility.Model?
        public var simulated: Bool?
        public var backupProblem: String?
        /// "Your C1 is Classic Chrome, Color +2, Grain Weak Small, …. Is that what the camera shows?"
        public var c1Sentence: String?
        public var slotNames: [String]
        public var secondsPerStep: [String: Double]
        /// Writes the guard refused (should always be empty).
        public var blockedWrites: [String]

        public var readinessText: String {
            if simulated == true { return "Rehearsal completed. This is not a check of a physical camera." }
            if let backupProblem { return "Connected, but the settings check is incomplete. \(backupProblem)" }
            if settingsLayoutSupported {
                return "Settings read successfully. Wireless look loading still needs camera validation."
            }
            return "Connected for Camera Check. Look loading has not been validated for this model and firmware."
        }
    }

    /// Historical diagnostic only; NOT a validity check. Kept for old fixture/report compatibility.
    public static let referenceChecksumConstant: UInt16 = 0xE5AE
    static let softwareRevision = FujiBLE.normalize("2a28")
    static let bleProtocolVersion = "389363e4-712e-4cf2-a72e-bfcf7fb6adc1"

    /// Fingerprint of a GATT table (fffw hashes UUID + flags + length; CoreBluetooth gives no lengths).
    public static func fingerprint(_ table: [GATTEntry]) -> String {
        let lines = table.map { "\($0.characteristic)|\($0.properties.sorted().joined(separator: ","))" }.sorted()
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func run(on camera: any FujiBLECamera, pairing: Bool, timing: BLESlotWriter.Timing = .real,
                           onStep: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> Report {
        defer { camera.disconnect() }
        var seconds: [String: Double] = [:]
        let clock = ContinuousClock()
        func timed<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
            let t0 = clock.now
            defer {
                let d = clock.now - t0
                seconds[name] = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            }
            return try await body()
        }

        onStep(.connecting)
        let reg = try await timed("connect") { try await camera.connect(pairing: pairing, timeout: .seconds(30)) }
        let guarded = ReadOnlyGATT(camera)
        try await Task.sleep(for: timing.settleAfterConnect)

        onStep(.identity)
        let (model, firmware, software, protocolVersion) = await timed("identity") { () async -> (String?, String?, String?, String?) in
            func text(_ uuid: String) async -> String? {
                guard await guarded.has(uuid), let v = try? await guarded.read(uuid) else { return nil }
                let t = String(decoding: v.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
            var pv: String?
            if await guarded.has(bleProtocolVersion), let v = try? await guarded.read(bleProtocolVersion) { pv = v.hexString }
            return (await text(FujiBLE.modelNumber), await text(FujiBLE.firmwareRevision), await text(softwareRevision), pv)
        }

        onStep(.fingerprint)
        let table = await timed("fingerprint") { await camera.gattTable() }
        let chars = Set(table.map { FujiBLE.normalize($0.characteristic) })
        func has(_ c: String) async -> Bool { table.isEmpty ? await guarded.has(c) : chars.contains(FujiBLE.normalize(c)) }
        let hasBackup = await has(FujiBLE.backupRequest)
        let hasRestore = await has(FujiBLE.restoreRequest)
        let hasFile = await has(FujiBLE.filePartialData)

        var report = Report(
            model: model, firmware: firmware, software: software, bleProtocolVersion: protocolVersion,
            profile: FujiBLEProfile(rawValue: reg.mode) ?? camera.remembered?.profile ?? .unknown,
            characteristicCount: table.count, fingerprint: fingerprint(table),
            fingerprintNote: "SHA-256 of sorted characteristic UUID + properties; CoreBluetooth reports no maximum lengths, so unlike fffw's hash lengths aren't covered.",
            hasBackup: hasBackup, hasRestore: hasRestore, hasFileService: hasFile, fileSize: nil, transferChecksumOK: nil,
            magicOK: false, modelOK: false, settingsLayoutSupported: false, layoutProblem: nil,
            checksumConstantMatchesReference: nil, c1Sentence: nil, slotNames: [], secondsPerStep: [:], blockedWrites: [])
        report.officialCompatibility = CameraCompatibility.model(model)
        report.simulated = camera.isSimulated

        if hasBackup {
            onStep(.backingUp(bytes: 0))
            try await Task.sleep(for: timing.betweenSteps)
            do {
                let backup = try await timed("backup") {
                    try await FujiBLEFlows.backupSettings(guarded, stateTimeout: timing.stateTimeout, chunkTimeout: timing.chunkTimeout,
                                                          progress: { onStep(.backingUp(bytes: $0)) })
                }
                onStep(.parsing)
                let header = SettingsFileHeader(backup.data)
                report.fileSize = backup.data.count
                report.transferChecksumOK = backup.checksumOK
                report.magicOK = header.magicOK
                report.modelOK = header.magicOK && !CameraCompatibility.modelKey(model).isEmpty
                    && CameraCompatibility.modelKey(header.model) == CameraCompatibility.modelKey(model)
                do {
                    guard backup.checksumOK == true else {
                        throw SettingsFileError.invalid("The backup transfer could not be verified. Retry Camera Check.")
                    }
                    guard report.modelOK else {
                        throw SettingsFileError.invalid("The backup does not match the camera's reported identity.")
                    }
                    guard CameraCompatibility.hasSettingsDecoder(model: model, firmware: firmware) else {
                        throw SettingsFileError.invalid("No verified decoder for this model and firmware yet.")
                    }
                    let file = try FujiSettingsFile(backup.data)
                    report.settingsLayoutSupported = true
                    report.slotNames = file.names
                    if let c1 = file.lookDescription(slot: 1) {
                        report.c1Sentence = "Your C1 is \(c1). Is that what the camera shows?"
                    } else {
                        report.c1Sentence = "Your C1 (\"\(file.name(slot: 1))\") holds a setting this map can't name yet."
                    }
                } catch {
                    report.layoutProblem = "\(error)"
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // Preserve the model/profile/fingerprint even when a new body cannot complete this transfer.
                // This partial report is the useful evidence for the next targeted investigation.
                report.backupProblem = backupFailureMessage(error)
            }
        } else {
            report.backupProblem = "This connection does not expose a settings-backup request."
        }
        report.secondsPerStep = seconds
        report.blockedWrites = guarded.blocked
        onStep(.done)
        return report
    }

    /// Shared reports must not embed peripheral names, raw payloads or other device details from an error.
    static func backupFailureMessage(_ error: any Error) -> String {
        guard let error = error as? FujiBLEError else { return "The settings backup did not complete. Reconnect and try again." }
        switch error {
        case .busy: return "The camera is busy. Leave its menus and playback, then try again."
        case .missingCharacteristic: return "The camera is missing a required backup characteristic."
        case .timeout: return "The camera did not complete the backup in time."
        case .disconnected: return "The Bluetooth connection ended during backup."
        case .framing, .transfer, .checksum: return "The backup transfer failed its integrity checks."
        case .staleBond, .profileChanged, .notPaired, .pairedElsewhere: return "Pair the camera with Dial In again."
        default: return "The settings backup did not complete. Reconnect and try again."
        }
    }
}
