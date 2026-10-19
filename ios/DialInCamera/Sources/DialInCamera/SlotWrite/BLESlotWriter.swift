// Settings-file writes: fresh backup -> durable caller backup -> narrow patch -> guard -> upload -> read-back.
// Modified writes on real hardware remain gated until the X100VI checksum and restore are hardware-validated.
// Pairing, backup, verification and Wi-Fi wake are independent of that gate.
// A dropped upload is "not verified" unless a fresh read-back proves the old slots remain. A partial read-back
// cannot complete the shoot. Recovery merges ONLY selected slots into the camera's fresh file, under RestoreGuard;
// an unreadable merge base stops recovery. It never falls back to uploading an old whole-camera backup.
import Foundation
import Synchronization

public enum BLESlotWriter {
    public enum Step: Sendable, Equatable {
        case connecting, checkingCamera, backingUp(bytes: Int), patching, uploading(frame: Int, of: Int), verifying(bytes: Int)
        case puttingBack(frame: Int, of: Int), done
    }

    public enum Result: Sendable, Equatable { case verified, pendingPowerCycle, rolledBack, failedNothingChanged, notVerified }

    public struct Outcome: Sendable {
        public var result: Result
        public var model: String
        public var firmware: String?
        /// B0, taken first, handed to onBackup before anything was written.
        public var backup: Data
        /// The patched file we uploaded (nil when nothing was uploaded).
        public var written: Data?
        /// The verification download.
        public var after: Data?
        /// One per placement, in placement order: .confirmed / .partial(rejected: what differs) / .failed(reason).
        public var verdicts: [SlotReport]
        /// A plain log for the app's debug view.
        public var lines: [String]
    }

    /// A look that needs a value whose settings-file code isn't confirmed (ConfirmedCodes).
    public struct UnverifiedLook: Sendable, Equatable {
        public var slot: Int
        public var name: String
        public var values: [UnverifiedValue]
        public init(slot: Int, name: String, values: [UnverifiedValue]) {
            self.slot = slot
            self.name = name
            self.values = values
        }
    }

    /// The placements that need an unconfirmed code, in order (empty = all can be written).
    public static func unverified(_ placements: [FujiSettingsFile.LookPlacement], codes: ConfirmedCodes = .x100vi) -> [UnverifiedLook] {
        placements.compactMap { p in
            let values = codes.unverified(in: p.recipe)
            return values.isEmpty ? nil : UnverifiedLook(slot: p.slot, name: p.recipe.slotName, values: values)
        }
    }

    /// The plain line for refused looks: "Soft faces: This look uses a film simulation we haven't verified on your
    /// camera yet. Nothing was sent." (several: "A, B: These looks use … Nothing was sent.").
    public static func plainRefusal(_ looks: [UnverifiedLook]) -> String {
        let names = looks.map(\.name).joined(separator: ", ")
        let all = looks.flatMap(\.values)
        let sentence = looks.count == 1 ? UnverifiedValue.sentence(all) : UnverifiedValue.sentence(all, subject: "These looks", plural: true)
        return (names.isEmpty ? "" : names + ": ") + sentence + " Nothing was sent."
    }

    public enum WriteError: Error, Equatable, CustomStringConvertible, Sendable {
        /// A look needs a value whose camera code isn't confirmed. Refused before the camera is contacted (nothing read,
        /// nothing written) unless allowInferred, the developer switch.
        case unverified([UnverifiedLook])
        /// Not an X100VI, a firmware the slot map doesn't cover, or a settings file of another layout. Nothing written.
        case unsupportedCamera(String)
        /// The patcher's refusals (inferred encodings, names over the budget). Nothing written.
        case refusedLooks([String])
        /// The first backup is missing or damaged, or couldn't be kept. Nothing written.
        case backupFailed(String)
        /// The link, a busy camera, a refused upload…; the text says what state the camera is in.
        case camera(String)
        /// Slots the person marked "never touch". Refused before the camera is contacted.
        case protectedSlots([Int])
        /// The backup to put back is from another camera (serial / model) or other firmware. Nothing written.
        case differentCamera(String)
        /// The file about to be sent differs from the camera's fresh backup outside the chosen slots. Nothing written.
        case guardRefused(String)

        public var description: String {
            switch self {
            case .unsupportedCamera(let s), .backupFailed(let s), .camera(let s), .differentCamera(let s): s
            case .protectedSlots(let slots): "Refused before contacting the camera: \(SlotText.list(Set(slots))) \(slots.count == 1 ? "is" : "are") protected"
            case .guardRefused(let why): "Refused before sending anything: \(why)"
            case .refusedLooks(let r): "Refused before writing anything: " + r.joined(separator: "; ")
            case .unverified(let looks):
                "Refused before contacting the camera: " + looks.map { l in
                    "C\(l.slot) \(l.name) needs " + l.values.map(\.detail).joined(separator: ", ")
                }.joined(separator: "; ") + " (codes not verified on this camera)"
            }
        }
    }

    /// Pauses between steps. A real camera gets ~3 s after the subscriptions before a backup or restore; the fake needs none.
    public struct Timing: Sendable, Equatable {
        public var settleAfterConnect: Duration
        public var betweenSteps: Duration
        public var stateTimeout: Duration
        public var chunkTimeout: Duration
        public var ackTimeout: Duration

        public init(settleAfterConnect: Duration, betweenSteps: Duration, stateTimeout: Duration, chunkTimeout: Duration, ackTimeout: Duration) {
            self.settleAfterConnect = settleAfterConnect
            self.betweenSteps = betweenSteps
            self.stateTimeout = stateTimeout
            self.chunkTimeout = chunkTimeout
            self.ackTimeout = ackTimeout
        }

        /// A real camera: 3 s settle, 1.5 s between transfers, 10 s / 20 s / 10 s timeouts (docs/FUJIFILM-PROTOCOL.md §3.6-3.7).
        public static let real = Timing(settleAfterConnect: .seconds(3), betweenSteps: .milliseconds(1500),
                                        stateTimeout: .seconds(10), chunkTimeout: .seconds(20), ackTimeout: .seconds(10))
        /// The app's rehearsal camera: short pauses so the steps are visible, real timeouts.
        public static let rehearsal = Timing(settleAfterConnect: .milliseconds(300), betweenSteps: .milliseconds(200),
                                             stateTimeout: .seconds(10), chunkTimeout: .seconds(20), ackTimeout: .seconds(10))
        /// Tests.
        public static let immediate = Timing(settleAfterConnect: .zero, betweenSteps: .zero, stateTimeout: .milliseconds(500),
                                             chunkTimeout: .seconds(2), ackTimeout: .seconds(2))
    }

    /// Decoder eligibility only. A matching GATT table on 1.11 does not validate its file layout or writes.
    public static let supportedFirmware: Set<String> = ["1.10"]

    /// Known display aliases only. Extra version components or suffixes must not inherit an approved profile.
    public static func normalizeFirmware(_ raw: String?) -> String? {
        guard let raw,
              let m = raw.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /(?i)(?:ver\s*)?(\d+)\.(\d+)/),
              let major = Int(m.1) else { return nil }
        return "\(major).\(m.2)"
    }

    /// Real backups disagree with the old whole-payload checksum model. Counter exclusion candidates now fit both
    /// captures, but neither a controlled slot edit nor an accepted modified restore has validated them yet.
    public static let wirelessWritesValidated = false
    public static let validationMessage = "Wireless look loading is still being validated on the X100VI. Use a USB-C cable for looks. Bluetooth pairing and wireless photo import are available."

    static func requireValidatedWrites(isSimulated: Bool) throws {
        guard isSimulated || wirelessWritesValidated else { throw WriteError.unsupportedCamera(validationMessage) }
    }

    // MARK: Write

    /// - Parameter protectedSlots: slots the person marked "never touch": a placement into one is refused before the
    ///   camera is contacted.
    public static func write(
        _ placements: [FujiSettingsFile.LookPlacement], to camera: any FujiBLECamera,
        expectedIdentity: BackupIdentity? = nil, allowInferred: Bool = false,
        codes: ConfirmedCodes = .x100vi, protectedSlots: Set<Int> = [], timing: Timing = .real,
        onBackup: @Sendable (Data) throws -> Void, onStep: @escaping @Sendable (Step) -> Void = { _ in }
    ) async throws -> Outcome {
        try await write(placements, to: camera, allowInferred: allowInferred, codes: codes, protectedSlots: protectedSlots,
                        timing: timing, onBackup: onBackup, onStep: onStep, tamper: nil, expectedIdentity: expectedIdentity)
    }

    /// Supervised hardware trial. Exactly one selected slot, mandatory durable preservation of BOTH backup
    /// representations, and exact slot-record verification. This does not change the production validation gate.
    public static func writeExperimental(
        _ placements: [FujiSettingsFile.LookPlacement], to camera: any FujiBLECamera,
        expectedIdentity: BackupIdentity? = nil, experimental: Bool = false,
        allowInferred: Bool = false, codes: ConfirmedCodes = .x100vi, protectedSlots: Set<Int> = [], timing: Timing = .real,
        onSafetyBackup: @escaping @Sendable (FujiBLEFlows.SettingsBackup) throws -> Void,
        onPrepared: @escaping @Sendable (Data) throws -> Void = { _ in },
        onStep: @escaping @Sendable (Step) -> Void = { _ in }
    ) async throws -> Outcome {
        guard experimental, placements.count == 1 else {
            throw WriteError.refusedLooks(["The Bluetooth hardware trial must be explicitly enabled and select exactly one slot."])
        }
        return try await write(placements, to: camera, allowInferred: allowInferred, codes: codes,
                               protectedSlots: protectedSlots, timing: timing, onBackup: { _ in },
                               onStep: onStep, tamper: nil, experimental: true, onSafetyBackup: onSafetyBackup,
                               onPrepared: onPrepared, expectedIdentity: expectedIdentity)
    }

    /// `tamper` (tests only) changes the patched file just before the guard, to prove the guard stops a bad file.
    static func write(
        _ placements: [FujiSettingsFile.LookPlacement], to camera: any FujiBLECamera, allowInferred: Bool,
        codes: ConfirmedCodes, protectedSlots: Set<Int>, timing: Timing, onBackup: @Sendable (Data) throws -> Void,
        onStep: @escaping @Sendable (Step) -> Void, tamper: (@Sendable (Data) -> Data)?, experimental: Bool = false,
        onSafetyBackup: (@Sendable (FujiBLEFlows.SettingsBackup) throws -> Void)? = nil,
        onPrepared: (@Sendable (Data) throws -> Void)? = nil, expectedIdentity: BackupIdentity? = nil
    ) async throws -> Outcome {
        let log = LineLog()
        defer { camera.disconnect() }
        try Task.checkCancellation()
        guard !placements.isEmpty else { throw WriteError.refusedLooks(["no looks to write"]) }
        let slots = placements.map(\.slot)
        guard Set(slots).count == slots.count, slots.allSatisfy({ (1...7).contains($0) }) else {
            throw WriteError.refusedLooks(["slots must be distinct, 1…7 (got \(slots))"])
        }
        // 0: never a protected slot, checked before the camera is contacted.
        let refusedSlots = slots.filter(protectedSlots.contains).sorted()
        guard refusedSlots.isEmpty else { throw WriteError.protectedSlots(refusedSlots) }
        // 0: only confirmed codes, checked before the camera is contacted (step 5 checks again, byte by byte).
        if !allowInferred {
            let refused = unverified(placements, codes: codes)
            guard refused.isEmpty else { throw WriteError.unverified(refused) }
        }

        // 1–2: connect and check the body.
        if !experimental { try requireValidatedWrites(isSimulated: camera.isSimulated) }
        let (reportedModel, firmware) = try await connectAndCheck(camera, timing: timing, log: log, onStep: onStep, experimental: experimental)

        // 3: B0.
        let b0 = try await backup(camera, timing: timing, log: log, onStep: onStep, what: "B0 (the undo file)") { b in
            WriteError.backupFailed("Couldn't read the camera's settings first (\(b)). Nothing was written.")
        }
        guard b0.checksumOK == true else {
            throw WriteError.backupFailed("The camera's settings arrived damaged or unchecked (transfer sum \(b0.checksumOK.map { $0 ? "ok" : "wrong" } ?? "missing")). Nothing was written.")
        }
        try validateFreshBackup(b0, reportedModel: reportedModel)
        if let expectedIdentity, !expectedIdentity.isSameCamera(as: BackupIdentity(b0.data)) {
            throw WriteError.differentCamera("The fresh backup is not from the paired camera approved for these slots. Nothing was written. Pair the intended camera and try again.")
        }
        let model = experimental ? b0.header.model : reportedModel
        // 4: the caller keeps the undo file before anything is written.
        do {
            try Task.checkCancellation()
            try onSafetyBackup?(b0)
            try onBackup(b0.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WriteError.backupFailed("Couldn't keep the backup of your camera's settings (\(error)). Nothing was written.")
        }
        log.add("B0 kept: \(b0.data.count) bytes, \(b0.header.model) \(b0.chunks) chunks")

        // 5: patch.
        onStep(.patching)
        let original: FujiSettingsFile
        do {
            original = try FujiSettingsFile(b0.data)
        } catch {
            throw WriteError.unsupportedCamera("This camera's settings file isn't the layout Dial In knows (\(error)). Nothing was written.")
        }
        let plan: LookSlotMap.Plan
        do {
            plan = try LookSlotMap.edits(for: placements, in: original, allowInferred: allowInferred)
        } catch {
            throw WriteError.refusedLooks(["\(error)"])
        }
        guard plan.refused.isEmpty else { throw WriteError.refusedLooks(plan.refused) }
        let total = plan.names.reduce(0) { $0 + $1.count }
        guard total <= FujiSettingsFile.nameBudget else {
            throw WriteError.refusedLooks(["the seven names would total \(total) characters; the camera refuses more than about \(FujiSettingsFile.nameBudget)"])
        }
        let patch: FujiSettingsFile.LookPatch
        do {
            patch = try original.applyingLooks(placements, allowInferred: allowInferred)
        } catch {
            throw WriteError.refusedLooks(["\(error)"])
        }
        patch.lines.forEach(log.add)
        let written = tamper?(patch.file.data) ?? patch.file.data

        // 5b: the byte-level guard against the fresh backup: only the chosen slots' records and the checksum differ.
        do {
            try RestoreGuard.check(written, against: b0.data, slots: Set(slots))
        } catch {
            throw WriteError.guardRefused("\(error). Nothing was written.")
        }
        log.add("guard: only \(SlotText.list(Set(slots))) and the checksum differ from the fresh backup")
        let wire = try BLEBackupPayload.encode(written, matching: b0)
        log.add("upload representation: \(written.count) settings bytes → \(wire.count) \(b0.compressed ? "zlib" : "plain") wire bytes")
        do {
            try Task.checkCancellation()
            try onPrepared?(written)
        } catch is CancellationError { throw CancellationError() }
        catch { throw WriteError.backupFailed("Couldn't keep the exact prepared trial file (\(error)). Nothing was written.") }

        // 6: upload.
        try await Task.sleep(for: timing.betweenSteps)
        try Task.checkCancellation()
        do {
            let r = try await FujiBLEFlows.restoreSettingsStandard(
                camera, file: wire, stateTimeout: timing.stateTimeout, ackTimeout: timing.ackTimeout, log: log.add,
                progress: { sent, of in onStep(.uploading(frame: sent, of: of)) })
            log.add("uploaded \(r.framesSent) frames; final state \(r.finalState?.hexString ?? "none")")
        } catch {
            log.add("upload failed: \(error)")
            var confirm: Data?
            if await camera.isLinkUp {
                try? await Task.sleep(for: timing.betweenSteps)
                if let check = try? await FujiBLEFlows.backupSettings(camera, stateTimeout: timing.stateTimeout, chunkTimeout: timing.chunkTimeout,
                    log: log.add, progress: { onStep(.verifying(bytes: $0)) }), check.checksumOK == true {
                    confirm = check.data
                }
                if let confirm { log.add(sameSlots(confirm, b0.data) ? "confirmed: the camera's slots are as before" : "WARNING: the camera's slots changed after a failed upload") }
            }
            let unchanged = !Task.isCancelled && confirm.map { matchesReadback($0, expected: b0.data, exact: experimental) } == true
            let reason = unchanged ? uploadFailure(error)
                : "Sending stopped and the camera's settings could not be verified. Your backup is saved. Check the camera before sending again."
            onStep(.done)
            return Outcome(result: unchanged ? .failedNothingChanged : .notVerified, model: model, firmware: firmware, backup: b0.data, written: written,
                           after: confirm, verdicts: placements.map { SlotReport(slot: $0.slot, name: $0.recipe.slotName, verdict: .failed(reason: reason)) },
                           lines: log.lines)
        }

        // 7: read it back and judge.
        try? await Task.sleep(for: timing.betweenSteps)
        let b1: FujiBLEFlows.SettingsBackup
        do {
            b1 = try await backupAgain(camera, timing: timing, log: log, onStep: onStep)
        } catch {
            throw WriteError.camera("The looks were sent, but the camera couldn't be read back to check them (\(error)). Your old settings are saved on the phone: turn the camera off and on, then check again, or tap Put my old looks back.")
        }
        let judgement = judge(placements, sent: patch.file, before: original, after: b1.data, log: log, exact: experimental)
        switch judgement.result {
        case .verified, .pendingPowerCycle, .notVerified:
            onStep(.done)
            return Outcome(result: judgement.result, model: model, firmware: firmware, backup: b0.data, written: written,
                           after: b1.data, verdicts: judgement.verdicts, lines: log.lines)
        default:
            break
        }

        // Something else landed: put the camera back as it was.
        log.add("the camera holds something other than what was sent: restoring the backup")
        let undo: Data
        do {
            // Only our selected slots, on the same body. An unreadable file cannot be a safe merge base.
            guard BackupIdentity(b0.data).isSameCamera(as: BackupIdentity(b1.data)) else {
                throw WriteError.differentCamera("The recovery read-back is not from the backed-up camera.")
            }
            undo = try UndoFile.make(old: b0.data, onto: b1.data, slots: Set(slots))
            try RestoreGuard.check(undo, against: b1.data, slots: Set(slots))
        } catch {
            log.add("Recovery refused: the fresh file cannot safely preserve unrelated settings. \(error)")
            onStep(.done)
            return Outcome(result: .notVerified, model: model, firmware: firmware, backup: b0.data, written: written,
                           after: b1.data, verdicts: judgement.verdicts, lines: log.lines)
        }
        do {
            let undoWire = try BLEBackupPayload.encode(undo, matching: b1)
            try onSafetyBackup?(b1)
            try await Task.sleep(for: timing.betweenSteps)
            try Task.checkCancellation()
            _ = try await FujiBLEFlows.restoreSettingsStandard(
                camera, file: undoWire, stateTimeout: timing.stateTimeout, ackTimeout: timing.ackTimeout, log: log.add,
                progress: { sent, of in onStep(.puttingBack(frame: sent, of: of)) })
            try? await Task.sleep(for: timing.betweenSteps)
            let b2 = try await backupAgain(camera, timing: timing, log: log, onStep: onStep)
            guard matchesReadback(b2.data, expected: undo, exact: experimental) else {
                throw WriteError.camera("The camera didn't take the looks as sent, and putting the old settings back didn't fully work. Your backup is saved on the phone. \(restoreRecovery)")
            }
            log.add("rolled back: only the selected slots are as before; unrelated settings preserved")
            onStep(.done)
            return Outcome(result: .rolledBack, model: model, firmware: firmware, backup: b0.data, written: written, after: b2.data,
                           verdicts: judgement.verdicts.map { v in
                               SlotReport(slot: v.slot, name: v.name, verdict: .failed(reason: "the camera stored something else; put back as it was"))
                           }, lines: log.lines)
        } catch let e as WriteError {
            throw e
        } catch {
            throw WriteError.camera("The camera didn't take the looks as sent, and putting the old settings back failed (\(error)). Your backup is saved on the phone. \(restoreRecovery)")
        }
    }

    // MARK: Check again

    /// "Check again" after a power cycle: connect, back up, verdicts for the placements against the new file.
    /// .verified only when every slot is confirmed, .pendingPowerCycle when none landed, .notVerified for a partial result.
    public static func check(
        _ placements: [FujiSettingsFile.LookPlacement], on camera: any FujiBLECamera,
        expectedIdentity: BackupIdentity? = nil, timing: Timing = .real,
        onStep: @escaping @Sendable (Step) -> Void = { _ in }
    ) async throws -> Outcome {
        let log = LineLog()
        defer { camera.disconnect() }
        let (model, firmware) = try await connectAndCheck(camera, timing: timing, log: log, onStep: onStep)
        let b = try await backup(camera, timing: timing, log: log, onStep: onStep, what: "the check") { e in
            WriteError.camera("Couldn't read the camera's settings (\(e)).")
        }
        let file: FujiSettingsFile
        do { file = try FujiSettingsFile(b.data) } catch {
            throw WriteError.unsupportedCamera("This camera's settings file isn't the layout Dial In knows (\(error)).")
        }
        guard b.checksumOK == true else { throw WriteError.backupFailed("The verification backup arrived damaged. Nothing is marked verified.") }
        if let expectedIdentity, !expectedIdentity.isSameCamera(as: BackupIdentity(b.data)) {
            throw WriteError.differentCamera("The verification backup is not from the paired camera intended for this write. Nothing is marked verified.")
        }
        let verdicts = placements.map { verdict($0, in: file) }
        let landed = verdicts.filter { if case .failed = $0.verdict { false } else { true } }
        onStep(.done)
        return Outcome(result: verdicts.allSatisfy(\.isConfirmed) && !verdicts.isEmpty ? .verified : (landed.isEmpty ? .pendingPowerCycle : .notVerified), model: model, firmware: firmware, backup: b.data,
                       written: nil, after: b.data, verdicts: verdicts, lines: log.lines)
    }

    // MARK: Put my old looks back

    /// The result of putting a backup's slots back.
    public struct RestoreOutcome: Sendable {
        public enum Result: Sendable, Equatable {
            /// Every chosen slot holds the backup's look again, nothing else moved.
            case verified
            /// They already did: nothing was sent.
            case alreadyThere
            /// Sent, not applied yet: switch the camera off and on, then put them back again (it will say alreadyThere).
            case pendingPowerCycle
            /// The upload stopped before the camera applied anything. The plain line says what to do.
            case failedNothingChanged(String)
            /// Applied, but the read-back doesn't match (or couldn't be read). The plain line says what to do.
            case notVerified(String)
        }

        public var result: Result
        /// The slots that were put back, ascending.
        public var slots: [Int]
        public var model: String
        public var firmware: String?
        /// The camera's file just before (handed to onFresh before anything was sent).
        public var fresh: Data
        /// What was sent (nil when nothing was).
        public var written: Data?
        /// The verification download (nil when there was none).
        public var after: Data?
        public var lines: [String]
    }

    /// The plain recovery line after a restore that didn't finish.
    public static let restoreRecovery = "Turn the camera off and on, then tap Put my old looks back."

    /// "Put my old looks back": bring `slots` of an earlier settings backup back into the camera, through the same
    /// Bluetooth restore path and as narrowly as a write. Refused (nothing read or written) for protected slots; refused
    /// (nothing written) when the backup is from another camera (header serial / model) or firmware.
    /// - Parameters:
    ///   - backup: the stored backup (taken before Dial In wrote).
    ///   - backupFirmware: the firmware it was taken on, when known (a different one now is refused).
    ///   - onFresh: keeps the camera's file as it is right now, before anything is sent (so this is undoable too).
    public static func restore(
        _ backup: Data, slots: Set<Int>, to camera: any FujiBLECamera, backupFirmware: String? = nil,
        protectedSlots: Set<Int> = [], timing: Timing = .real, onFresh: @Sendable (Data) throws -> Void,
        onStep: @escaping @Sendable (Step) -> Void = { _ in }
    ) async throws -> RestoreOutcome {
        try await restore(backup, slots: slots, to: camera, backupFirmware: backupFirmware, protectedSlots: protectedSlots,
                          timing: timing, onFresh: onFresh, onStep: onStep, experimental: false, onSafetyBackup: nil)
    }

    /// Trial recovery always merges one selected slot onto a fresh same-body backup. It never replays a whole file.
    public static func restoreExperimental(
        _ backup: Data, slots: Set<Int>, to camera: any FujiBLECamera, experimental: Bool = false,
        backupFirmware: String? = nil, protectedSlots: Set<Int> = [], timing: Timing = .real,
        onSafetyBackup: @escaping @Sendable (FujiBLEFlows.SettingsBackup) throws -> Void,
        onStep: @escaping @Sendable (Step) -> Void = { _ in }
    ) async throws -> RestoreOutcome {
        guard experimental, slots.count == 1 else {
            throw WriteError.refusedLooks(["The Bluetooth hardware trial must be explicitly enabled and select exactly one slot."])
        }
        return try await restore(backup, slots: slots, to: camera, backupFirmware: backupFirmware,
                                 protectedSlots: protectedSlots, timing: timing, onFresh: { _ in }, onStep: onStep,
                                 experimental: true, onSafetyBackup: onSafetyBackup)
    }

    private static func restore(
        _ backup: Data, slots: Set<Int>, to camera: any FujiBLECamera, backupFirmware: String?,
        protectedSlots: Set<Int>, timing: Timing, onFresh: @Sendable (Data) throws -> Void,
        onStep: @escaping @Sendable (Step) -> Void, experimental: Bool,
        onSafetyBackup: (@Sendable (FujiBLEFlows.SettingsBackup) throws -> Void)?
    ) async throws -> RestoreOutcome {
        let log = LineLog()
        defer { camera.disconnect() }
        try Task.checkCancellation()
        guard !slots.isEmpty, slots.allSatisfy({ (1...7).contains($0) }) else {
            throw WriteError.refusedLooks(["slots must be 1…7 (got \(slots.sorted()))"])
        }
        let refusedSlots = slots.filter(protectedSlots.contains).sorted()
        guard refusedSlots.isEmpty else { throw WriteError.protectedSlots(refusedSlots) }
        let stored = BackupIdentity(backup)
        let storedFile: FujiSettingsFile
        do { storedFile = try FujiSettingsFile(backup) } catch {
            throw WriteError.unsupportedCamera("This backup isn't a file Dial In can put back (\(error)). Nothing was written.")
        }
        guard !stored.serial.isEmpty else {
            throw WriteError.differentCamera("This backup doesn't say which camera it came from, so Dial In won't put it back. Nothing was written.")
        }

        if !experimental { try requireValidatedWrites(isSimulated: camera.isSimulated) }
        let (reportedModel, firmware) = try await connectAndCheck(camera, timing: timing, log: log, onStep: onStep, experimental: experimental)
        if let was = normalizeFirmware(backupFirmware), let now = firmware, was != now {
            throw WriteError.differentCamera("This backup was made on firmware \(was), and the camera now runs \(now). Nothing was written.")
        }
        let fresh = try await Self.backup(camera, timing: timing, log: log, onStep: onStep, what: "the camera now") { b in
            WriteError.backupFailed("Couldn't read the camera's settings first (\(b)). Nothing was written.")
        }
        guard fresh.checksumOK == true else {
            throw WriteError.backupFailed("The camera's settings arrived damaged. Nothing was written.")
        }
        try validateFreshBackup(fresh, reportedModel: reportedModel)
        let model = experimental ? fresh.header.model : reportedModel
        let here = BackupIdentity(fresh.data)
        guard stored.isSameCamera(as: here) else {
            let theirs = stored.model.isEmpty ? "another camera" : "\(stored.model) ··\(stored.serialSuffix)"
            let mine = here.model.isEmpty ? "this one" : "this \(here.model) is ··\(here.serialSuffix)"
            throw WriteError.differentCamera("This backup is from \(theirs), and \(mine). A backup only goes back to the camera it came from. Nothing was written.")
        }
        let now: FujiSettingsFile
        do { now = try FujiSettingsFile(fresh.data) } catch {
            throw WriteError.unsupportedCamera("This camera's settings file isn't the layout Dial In knows (\(error)). Nothing was written.")
        }
        do {
            try Task.checkCancellation()
            try onSafetyBackup?(fresh)
            try onFresh(fresh.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WriteError.backupFailed("Couldn't keep a backup of your camera's settings first (\(error)). Nothing was written.")
        }
        log.add("fresh backup kept: \(fresh.data.count) bytes, same camera ··\(here.serialSuffix)")

        onStep(.patching)
        let undo: Data
        do {
            undo = try UndoFile.make(old: backup, onto: fresh.data, slots: slots)
        } catch {
            throw WriteError.unsupportedCamera("Couldn't line the backup up with the camera's file (\(error)). Nothing was written.")
        }
        let ordered = slots.sorted()
        if undo == fresh.data {
            log.add("\(SlotText.list(slots)) already hold the backup's looks: nothing to send")
            onStep(.done)
            return RestoreOutcome(result: .alreadyThere, slots: ordered, model: model, firmware: firmware, fresh: fresh.data,
                                  written: nil, after: fresh.data, lines: log.lines)
        }
        do {
            try RestoreGuard.check(undo, against: fresh.data, slots: slots)
        } catch {
            throw WriteError.guardRefused("\(error). Nothing was written.")
        }
        for s in ordered { log.add("C\(s) \"\(now.name(slot: s))\" → \"\(storedFile.name(slot: s))\"") }

        let wire = try BLEBackupPayload.encode(undo, matching: fresh)
        try await Task.sleep(for: timing.betweenSteps)
        try Task.checkCancellation()
        do {
            let r = try await FujiBLEFlows.restoreSettingsStandard(
                camera, file: wire, stateTimeout: timing.stateTimeout, ackTimeout: timing.ackTimeout, log: log.add,
                progress: { sent, of in onStep(.puttingBack(frame: sent, of: of)) })
            log.add("uploaded \(r.framesSent) frames; final state \(r.finalState?.hexString ?? "none")")
        } catch {
            log.add("upload failed: \(error)")
            var confirm: Data?
            if await camera.isLinkUp {
                try? await Task.sleep(for: timing.betweenSteps)
                if let check = try? await FujiBLEFlows.backupSettings(camera, stateTimeout: timing.stateTimeout, chunkTimeout: timing.chunkTimeout,
                    log: log.add, progress: { onStep(.verifying(bytes: $0)) }), check.checksumOK == true {
                    confirm = check.data
                }
            }
            onStep(.done)
            let result: RestoreOutcome.Result = !Task.isCancelled && confirm.map { matchesReadback($0, expected: fresh.data, exact: experimental) } == true
                ? .failedNothingChanged(restoreFailure(error))
                : .notVerified("The restore stopped and the camera could not be verified. Your backup is saved. " + restoreRecovery)
            return RestoreOutcome(result: result, slots: ordered, model: model, firmware: firmware,
                                  fresh: fresh.data, written: undo, after: confirm, lines: log.lines)
        }

        try? await Task.sleep(for: timing.betweenSteps)
        let after: FujiBLEFlows.SettingsBackup
        do {
            after = try await backupAgain(camera, timing: timing, log: log, onStep: onStep)
        } catch {
            log.add("read-back failed: \(error)")
            onStep(.done)
            return RestoreOutcome(result: .notVerified("Your old looks were sent, but the camera couldn't be read back to check. \(restoreRecovery)"),
                                  slots: ordered, model: model, firmware: firmware, fresh: fresh.data, written: undo, after: nil, lines: log.lines)
        }
        let result = judgeRestore(slots: ordered, sent: undo, fresh: fresh.data, stored: storedFile, after: after.data, log: log, exact: experimental)
        onStep(.done)
        return RestoreOutcome(result: result, slots: ordered, model: model, firmware: firmware, fresh: fresh.data, written: undo,
                              after: after.data, lines: log.lines)
    }

    /// Every restored slot holds the sent record (or the same name and look, if the camera re-stamped a byte), and
    /// every other slot is as it was.
    private static func judgeRestore(slots: [Int], sent: Data, fresh: Data, stored: FujiSettingsFile, after data: Data, log: LineLog, exact: Bool = false) -> RestoreOutcome.Result {
        guard BackupIdentity(fresh).isSameCamera(as: BackupIdentity(data)) else {
            return .notVerified("The recovery read-back has a different camera identity. " + restoreRecovery)
        }
        guard let after = try? FujiSettingsFile(data), let sentFile = try? FujiSettingsFile(sent),
              let freshFile = try? FujiSettingsFile(fresh) else {
            log.add("the read-back isn't a file Dial In reads")
            return .notVerified("The camera's settings came back in a form Dial In can't check. \(restoreRecovery)")
        }
        func region(_ f: FujiSettingsFile, _ s: Int) -> ArraySlice<UInt8> { f.bytes[f.slotRegion(s)] }
        let others = (1...7).filter { !slots.contains($0) }.filter { region(after, $0) != region(freshFile, $0) }
        var landed: [Int] = [], missing: [Int] = []
        for s in slots {
            if region(after, s) == region(sentFile, s) {
                landed.append(s)
            } else if !exact, after.name(slot: s) == stored.name(slot: s), let want = stored.recipe(slot: s), after.recipe(slot: s) == want {
                log.add("C\(s): same name and look, a byte re-stamped by the camera")
                landed.append(s)
            } else {
                missing.append(s)
            }
        }
        for s in slots { log.add("C\(s) now \"\(after.name(slot: s))\"") }
        if !others.isEmpty { log.add("other slots changed: \(others.map { "C\($0)" }.joined(separator: ", "))") }
        let outside = readbackOutsideDifferences(after: after, sent: sentFile)
        if exact, !outside.isEmpty {
            log.add("recovery read-back changed \(outside.count) byte(s) outside the selected slot records")
            return .notVerified("The old slot was sent, but unrelated camera state differs. " + restoreRecovery)
        }
        if missing.isEmpty && others.isEmpty {
            log.add("verified: \(SlotText.list(Set(slots))) hold the backup's looks again")
            return .verified
        }
        if others.isEmpty && slots.allSatisfy({ region(after, $0) == region(freshFile, $0) }) {
            log.add("the camera still holds the newer looks: it may apply them after it is switched off and on")
            return .pendingPowerCycle
        }
        return .notVerified("The camera didn't take all of it. \(restoreRecovery)")
    }

    private static func restoreFailure(_ error: any Error) -> String {
        if let e = error as? FujiBLEError {
            switch e {
            case .busy: return "The camera was busy, so nothing changed. Leave its menus and playback, then tap Put my old looks back."
            case .disconnected: return "The Bluetooth link dropped while putting your looks back, so nothing changed. \(restoreRecovery)"
            default: return "Putting your looks back stopped, so nothing changed. \(restoreRecovery)"
            }
        }
        return "Putting your looks back stopped, so nothing changed. \(restoreRecovery)"
    }

    // MARK: Read

    /// The camera's current C1–C7 (names) with one backup: pairing shows "what's on your camera" and tells the planner.
    public static func readSlots(
        from camera: any FujiBLECamera, timing: Timing = .real, onStep: @escaping @Sendable (Step) -> Void = { _ in }
    ) async throws -> (backup: Data, names: [String], model: String, firmware: String?) {
        let log = LineLog()
        defer { camera.disconnect() }
        let (model, firmware) = try await connectAndCheck(camera, timing: timing, log: log, onStep: onStep, requireSupported: false)
        let b = try await backup(camera, timing: timing, log: log, onStep: onStep, what: "C1–C7") { e in
            WriteError.camera("Couldn't read the camera's settings (\(e)).")
        }
        guard b.checksumOK == true else { throw WriteError.backupFailed("The camera's settings arrived damaged. Try again.") }
        guard !CameraCompatibility.modelKey(model).isEmpty,
              CameraCompatibility.modelKey(b.header.model) == CameraCompatibility.modelKey(model) else {
            throw WriteError.backupFailed("The backup does not match the camera's reported identity. Try Camera Check.")
        }
        // Pairing must not feed guessed slot names to the planner on an unfamiliar firmware/layout.
        let names = CameraCompatibility.hasSettingsDecoder(model: model, firmware: firmware)
            ? ((try? FujiSettingsFile(b.data).names) ?? []) : []
        onStep(.done)
        return (b.data, names, model, firmware)
    }

    /// Pairing/read preparation for the explicit trial. The BLE product ID remains a transport identity;
    /// the decoded backup must independently identify the supported X100VI layout and firmware.
    public static func readSlotsExperimental(
        from camera: any FujiBLECamera, experimental: Bool = false, timing: Timing = .real,
        onSafetyBackup: @Sendable (FujiBLEFlows.SettingsBackup) throws -> Void,
        onStep: @escaping @Sendable (Step) -> Void = { _ in }
    ) async throws -> (backup: Data, names: [String], model: String, firmware: String?) {
        guard experimental else { throw WriteError.unsupportedCamera(validationMessage) }
        let log = LineLog()
        defer { camera.disconnect() }
        try Task.checkCancellation()
        let (reported, firmware) = try await connectAndCheck(camera, timing: timing, log: log, onStep: onStep, experimental: true)
        let b = try await backup(camera, timing: timing, log: log, onStep: onStep, what: "trial C1–C7") { e in
            WriteError.backupFailed("Couldn't read the camera's settings (\(e)).")
        }
        try validateFreshBackup(b, reportedModel: reported)
        try Task.checkCancellation()
        try onSafetyBackup(b)
        let names = try FujiSettingsFile(b.data).names
        onStep(.done)
        return (b.data, names, b.header.model, firmware)
    }

    /// Check a trial after restart against the precise expanded file we sent, including hidden slot bytes.
    /// A recipe alone is insufficient evidence that recovery or a wireless write preserved all slot state.
    public static func checkExperimental(
        _ placements: [FujiSettingsFile.LookPlacement], on camera: any FujiBLECamera,
        expectedIdentity: BackupIdentity? = nil, expected: Data,
        experimental: Bool = false, timing: Timing = .real,
        onStep: @escaping @Sendable (Step) -> Void = { _ in }
    ) async throws -> Outcome {
        guard experimental, placements.count == 1, let placement = placements.first,
              (1...7).contains(placement.slot) else {
            throw WriteError.refusedLooks(["A trial check needs exactly one slot and its saved transmitted settings file."])
        }
        let sent = try FujiSettingsFile(expected)
        if let expectedIdentity, !expectedIdentity.isSameCamera(as: BackupIdentity(expected)) {
            throw WriteError.differentCamera("The saved trial file does not belong to the paired camera intended for this write. Nothing is marked verified.")
        }
        guard sent.mismatches(slot: placement.slot, against: placement.recipe).isEmpty else {
            throw WriteError.refusedLooks(["The saved trial file does not contain the requested look. Nothing is marked verified."])
        }
        let log = LineLog()
        defer { camera.disconnect() }
        try Task.checkCancellation()
        let (reported, firmware) = try await connectAndCheck(camera, timing: timing, log: log, onStep: onStep, experimental: true)
        let b = try await backup(camera, timing: timing, log: log, onStep: onStep, what: "trial check") { e in
            WriteError.backupFailed("Couldn't read back the trial (\(e)).")
        }
        try validateFreshBackup(b, reportedModel: reported)
        if let expectedIdentity, !expectedIdentity.isSameCamera(as: BackupIdentity(b.data)) {
            throw WriteError.differentCamera("The trial read-back is not from the paired camera intended for this write. Nothing is marked verified.")
        }
        guard BackupIdentity(expected).isSameCamera(as: BackupIdentity(b.data)) else {
            throw WriteError.differentCamera("The trial read-back is from a different camera. Nothing is marked verified.")
        }
        let judgement = judge(placements, sent: sent, before: sent, after: b.data, log: log, exact: true)
        onStep(.done)
        return Outcome(result: judgement.result == .verified ? .verified : .notVerified, model: b.header.model,
                       firmware: firmware, backup: b.data, written: expected, after: b.data,
                       verdicts: judgement.verdicts, lines: log.lines)
    }

    /// What `slot` holds versus `recipe`, as a verdict (the decode side of the writer).
    public static func verdict(_ p: FujiSettingsFile.LookPlacement, in file: FujiSettingsFile) -> SlotReport {
        let mm = file.mismatches(slot: p.slot, against: p.recipe)
        let name = p.recipe.slotName
        if mm.isEmpty { return SlotReport(slot: p.slot, name: name, verdict: .confirmed) }
        if file.name(slot: p.slot) != name {
            return SlotReport(slot: p.slot, name: name, verdict: .failed(reason: "C\(p.slot) holds \"\(file.name(slot: p.slot))\", not this look"))
        }
        return SlotReport(slot: p.slot, name: name, verdict: .partial(rejected: mm))
    }

    // MARK: Internals

    final class LineLog: Sendable {
        private let store = Mutex<[String]>([])
        var lines: [String] { store.withLock { $0 } }
        func add(_ s: String) { store.withLock { $0.append(s) } }
    }

    private static func connectAndCheck(
        _ camera: any FujiBLECamera, timing: Timing, log: LineLog, onStep: @Sendable (Step) -> Void,
        requireSupported: Bool = true, experimental: Bool = false
    ) async throws -> (String, String?) {
        onStep(.connecting)
        let reg: FujiBLEFlows.Registration
        do {
            reg = try await camera.connect(pairing: false, timeout: .seconds(30))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WriteError.camera(connectFailure(error))
        }
        log.add("registered: \(reg.mode)")
        onStep(.checkingCamera)
        let id = await camera.identity()
        let model = id["model"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let firmware = normalizeFirmware(id["firmware"])
        log.add("identity: \(id["device_name"] ?? "?") model \(model.isEmpty ? "?" : model) firmware \(id["firmware"] ?? "?")")
        // This exact transport ID was observed on the paired X100VI 1.10. It is NOT a global model alias.
        let trialProductID = experimental && model == "FF230003"
        if !model.isEmpty && CameraCompatibility.modelKey(model) != CameraCompatibility.modelKey(FujiSettingsFile.model) && !trialProductID {
            throw WriteError.unsupportedCamera("This is a \(model). Dial In writes looks into an X100VI only. Nothing was written.")
        }
        if requireSupported, (model.isEmpty || firmware == nil) {
            throw WriteError.unsupportedCamera("The camera model and firmware could not be identified. Nothing was written.")
        }
        if requireSupported, let firmware, !supportedFirmware.contains(firmware) {
            throw WriteError.unsupportedCamera("Bluetooth looks need firmware 1.10 for now; this X100VI runs \(firmware). Nothing was written.")
        }
        try await Task.sleep(for: timing.settleAfterConnect)
        try Task.checkCancellation()
        return (model, firmware)
    }

    private static func validateFreshBackup(_ backup: FujiBLEFlows.SettingsBackup, reportedModel: String) throws {
        do {
            try BLEBackupPayload.validate(backup)
            guard CameraCompatibility.modelKey(backup.header.model) == "X100VI",
                  (reportedModel == "FF230003" || CameraCompatibility.modelKey(reportedModel) == "X100VI") else {
                throw WriteError.differentCamera("The fresh settings backup does not match the supported camera. Nothing was written.")
            }
            _ = try FujiSettingsFile(backup.data)
        } catch let error as WriteError { throw error }
        catch { throw WriteError.backupFailed("Fresh settings integrity failed (\(error)). Nothing was written.") }
    }

    private static func backup(
        _ camera: any FujiBLECamera, timing: Timing, log: LineLog, onStep: @escaping @Sendable (Step) -> Void, what: String,
        wrap: (String) -> WriteError
    ) async throws -> FujiBLEFlows.SettingsBackup {
        onStep(.backingUp(bytes: 0))
        do {
            let b = try await FujiBLEFlows.backupSettings(camera, stateTimeout: timing.stateTimeout, chunkTimeout: timing.chunkTimeout,
                                                          log: log.add, progress: { onStep(.backingUp(bytes: $0)) })
            log.add("\(what): \(b.data.count) bytes, sum \(b.checksumOK.map { $0 ? "ok" : "WRONG" } ?? "missing"), \(b.seqReport)")
            return b
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as FujiBLEError {
            throw wrap(plain(e))
        } catch {
            throw wrap("\(error)")
        }
    }

    /// B1 / B2: one reconnect if the link went away after the upload (the camera may drop it while it applies).
    private static func backupAgain(_ camera: any FujiBLECamera, timing: Timing, log: LineLog, onStep: @escaping @Sendable (Step) -> Void) async throws -> FujiBLEFlows.SettingsBackup {
        for attempt in 1...2 {
            if !(await camera.isLinkUp) {
                log.add("reconnecting to read the camera back")
                try await camera.connect(pairing: false, timeout: .seconds(30))
                try? await Task.sleep(for: timing.settleAfterConnect)
            }
            do {
                let b = try await FujiBLEFlows.backupSettings(camera, stateTimeout: timing.stateTimeout, chunkTimeout: timing.chunkTimeout,
                                                              log: log.add, progress: { onStep(.verifying(bytes: $0)) })
                guard b.checksumOK == true else { throw FujiBLEError.transfer("the read-back arrived damaged") }
                return b
            } catch {
                log.add("read-back attempt \(attempt) failed: \(error)")
                if attempt == 2 { throw error }
                camera.disconnect()
                try? await Task.sleep(for: timing.betweenSteps)
            }
        }
        throw FujiBLEError.unexpected("unreachable")
    }

    private struct Judgement { var result: Result; var verdicts: [SlotReport] }

    private static func judge(_ placements: [FujiSettingsFile.LookPlacement], sent: FujiSettingsFile, before: FujiSettingsFile,
                              after data: Data, log: LineLog, exact: Bool = false) -> Judgement {
        guard BackupIdentity(before.data).isSameCamera(as: BackupIdentity(data)) else {
            log.add("The read-back identity differs from the camera backed up before writing.")
            return Judgement(result: .notVerified, verdicts: placements.map {
                SlotReport(slot: $0.slot, name: $0.recipe.slotName, verdict: .failed(reason: "camera identity could not be verified"))
            })
        }
        guard let after = try? FujiSettingsFile(data) else {
            log.add("the read-back isn't an X100VI fw 1.10 file")
            return Judgement(result: .rolledBack, verdicts: placements.map { SlotReport(slot: $0.slot, name: $0.recipe.slotName, verdict: .failed(reason: "unreadable read-back")) })
        }
        let placed = Set(placements.map(\.slot))
        let verdicts = placements.map { p -> SlotReport in
            let v = verdict(p, in: after)
            if exact, after.bytes[after.slotRegion(p.slot)] != sent.bytes[sent.slotRegion(p.slot)], v.isConfirmed {
                return SlotReport(slot: p.slot, name: p.recipe.slotName,
                                  verdict: .failed(reason: "The visible look matches, but the complete saved slot differs from the transmitted file."))
            }
            return v
        }
        let otherChanged = (1...7).filter { !placed.contains($0) }.filter { s in
            let r = after.slotRegion(s)
            return Array(after.bytes[r]) != Array(sent.bytes[r])
        }
        // Outside C1–C7: report, never act on (counters a camera re-stamps).
        let outside = readbackOutsideDifferences(after: after, sent: sent)
        if !outside.isEmpty {
            log.add("note: \(outside.count) byte(s) outside C1–C7 differ from what was sent, from " + String(format: "0x%X", outside[0]) + " (camera state; left alone)")
        }
        let nothingLanded = placements.allSatisfy { p in
            let r = after.slotRegion(p.slot)
            return Array(after.bytes[r]) == Array(before.bytes[r])
        }
        let allConfirmed = verdicts.allSatisfy(\.isConfirmed)
        for v in verdicts { log.add("C\(v.slot) \(v.name): \(v.verdict)") }
        if !otherChanged.isEmpty { log.add("other slots changed: \(otherChanged.map { "C\($0)" }.joined(separator: ", "))") }
        if exact, !outside.isEmpty {
            log.add("trial is not verified: unrelated settings differ; saved state must be reviewed before another write")
            return Judgement(result: .notVerified, verdicts: placements.map {
                SlotReport(slot: $0.slot, name: $0.recipe.slotName, verdict: .failed(reason: "The read-back changed unrelated camera state. The wireless trial is not verified."))
            })
        }
        if allConfirmed && otherChanged.isEmpty { return Judgement(result: .verified, verdicts: verdicts) }
        if nothingLanded && otherChanged.isEmpty {
            log.add("the camera still holds the old looks: it may apply them after it is switched off and on")
            return Judgement(result: .pendingPowerCycle, verdicts: placements.map {
                SlotReport(slot: $0.slot, name: $0.recipe.slotName, verdict: .failed(reason: "not applied yet: switch the camera off and on, then check again"))
            })
        }
        let namesLanded = verdicts.allSatisfy { if case .failed = $0.verdict { false } else { true } }
        if namesLanded && otherChanged.isEmpty { return Judgement(result: .notVerified, verdicts: verdicts) }
        return Judgement(result: .rolledBack, verdicts: verdicts)
    }

    /// Report all non-slot differences except the existing counter span and low checksum word. Do not normalize
    /// identity/header bytes, guess new counter ranges, or excuse hidden bytes within the chosen slot.
    private static func readbackOutsideDifferences(after: FujiSettingsFile, sent: FujiSettingsFile) -> [Int] {
        guard after.bytes.count == sent.bytes.count else { return [min(after.bytes.count, sent.bytes.count)] }
        let regions = (1...7).map { after.slotRegion($0) }
        return after.bytes.indices.filter { i in
            after.bytes[i] != sent.bytes[i] && !regions.contains(where: { $0.contains(i) })
                && !FujiSettingsFile.frameCounterBlock.contains(i) && !RestoreGuard.checksumBytes.contains(i)
        }
    }

    /// C1–C7 (and their preambles) byte-identical.
    static func sameSlots(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, BackupIdentity(a).isSameCamera(as: BackupIdentity(b)),
              let fa = try? FujiSettingsFile(a), (try? FujiSettingsFile(b)) != nil else { return false }
        let r = fa.slotRegion(1).lowerBound..<a.count
        return a[r] == b[r]
    }

    private static func matchesReadback(_ data: Data, expected: Data, exact: Bool) -> Bool {
        guard sameSlots(data, expected) else { return false }
        guard exact else { return true }
        guard let after = try? FujiSettingsFile(data), let sent = try? FujiSettingsFile(expected) else { return false }
        return readbackOutsideDifferences(after: after, sent: sent).isEmpty
    }

    private static func plain(_ e: FujiBLEError) -> String {
        switch e {
        case .busy: "the camera is busy: leave its menus and playback"
        case .transfer(let s) where s.hasPrefix("No answer to the backup request"):
            "the camera didn't answer: it may not accept this phone's key (pair again)"
        default: e.description
        }
    }

    private static func connectFailure(_ error: any Error) -> String {
        guard let e = error as? FujiBLEError else { return "Couldn't reach the camera over Bluetooth (\(error))." }
        switch e {
        case .notFound: return "No camera found. Switch it on with Bluetooth on, and keep it close."
        case .pairedElsewhere: return "The camera is paired with another phone. Pair it with Dial In first."
        case .notPaired: return "The camera wants to be paired first."
        case .bluetoothOff: return "Bluetooth is off on this iPhone."
        case .unauthorized: return "Dial In isn't allowed to use Bluetooth. Allow it in Settings."
        default: return "Couldn't connect to the camera (\(e))."
        }
    }

    private static func uploadFailure(_ error: any Error) -> String {
        if let e = error as? FujiBLEError {
            switch e {
            case .busy: return "The camera was busy, so nothing changed. Leave its menus and playback, then send again."
            case .disconnected: return "The Bluetooth link dropped while sending, so nothing changed. Send again."
            case .transfer(let s) where s.contains("rejected frame"):
                return "The camera refused the file, so nothing changed."
            case .transfer(let s) where s.contains("reported Error"):
                return "The camera refused the file at the end, so nothing changed."
            case .transfer(let s) where s.hasPrefix("No RESTORE_STATE"):
                return "The camera didn't answer the send request, so nothing changed. It may not accept this phone's key: pair again."
            default: return "Sending stopped (\(e)), so nothing changed."
            }
        }
        return "Sending stopped (\(error)), so nothing changed."
    }
}
