// The API the app uses: find the camera, then load looks into C1…Cn with per-slot progress.
import Foundation
import Synchronization

/// What the camera link is doing, for the UI.
public enum CameraLinkState: Sendable, Equatable, CustomStringConvertible {
    /// Looking for a Fujifilm camera on USB.
    case searching
    /// Found one, but it isn't in USB RAW CONV./BACKUP RESTORE mode. Show the menu path.
    case needsUSBMode
    /// Ready. `model` is what the camera calls itself ("X100VI").
    case connected(model: String)
    /// Writing look `slot` of `of` into C`slot` (1-based). Drive the dial-click animation from this.
    case writing(slot: Int, of: Int)
    /// All looks are in the camera.
    case done
    case failed(reason: String)

    public var description: String {
        switch self {
        case .searching: "searching"
        case .needsUSBMode: "needsUSBMode"
        case .connected(let model): "connected(\(model))"
        case .writing(let slot, let of): "writing(\(slot)/\(of))"
        case .done: "done"
        case .failed(let reason): "failed(\(reason))"
        }
    }
}

/// Result of `load(looks:)`.
public struct LoadReport: Sendable, Equatable {
    /// One report per slot written, C1 first.
    public var slots: [FujiCamera.WriteReport]
    /// What those slots held before we wrote them (same JSON as `npm run cam backup`). Keep it to undo.
    public var backup: SlotBackup

    public init(slots: [FujiCamera.WriteReport], backup: SlotBackup) {
        self.slots = slots
        self.backup = backup
    }

    /// True when every prop landed and read back identical.
    public var isClean: Bool { slots.allSatisfy(\.isClean) }

    /// The per-slot verdicts (the same ones `load(looks:onSlot:)` delivered as it went), C1 first.
    public var slotReports: [SlotReport] { slots.map(SlotReport.init(write:)) }
}

/// One slot's verdict, delivered by `load(looks:onSlot:)` as soon as that slot's write and read-back finish.
/// Fill the slot green only on `.confirmed`.
public struct SlotReport: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// Every prop was accepted and read back as written (grain Off reading back as 6/7 counts as written).
        case confirmed
        /// Written, but not exactly as asked. `rejected` are plain-language notes, refusals first
        /// ("clarity skipped (camera must be in single-shot drive mode)", "DR stepped down to DR200 (…)"),
        /// then read-back differences ("highlight didn't stick (…)").
        case partial(rejected: [String])
        /// The slot couldn't be written (camera unplugged, refused the slot or name, cancelled …). `load` throws after this.
        case failed(reason: String)
    }

    /// 1–7.
    public var slot: Int
    /// The camera-safe name written (or attempted) for this slot.
    public var name: String
    public var verdict: Verdict
    /// Full write detail (nil when the slot failed before a write report existed).
    public var detail: FujiCamera.WriteReport?

    public init(slot: Int, name: String, verdict: Verdict, detail: FujiCamera.WriteReport? = nil) {
        self.slot = slot
        self.name = name
        self.verdict = verdict
        self.detail = detail
    }

    /// Verdict for a completed write: confirmed when clean, otherwise partial with its plain hints.
    public init(write: FujiCamera.WriteReport) {
        let notes = write.hints.isEmpty ? write.rejected + write.mismatched : write.hints
        self.init(slot: write.slot, name: write.name, verdict: write.isClean ? .confirmed : .partial(rejected: notes), detail: write)
    }

    public var isConfirmed: Bool { verdict == .confirmed }
}

/// The surface the app codes against; `CameraLink` (real) and `MockCameraLink` (no hardware) both provide it.
public protocol CameraLinking: AnyObject, Sendable {
    /// A fresh stream per access. It yields the current state first, then every change.
    var state: AsyncStream<CameraLinkState> { get }
    /// The latest state, synchronously.
    var currentState: CameraLinkState { get }
    /// Find the camera and open a session. Throws `CameraError`.
    func connect() async throws
    /// Write looks into C1…C`looks.count` (max 7), in order. Connects first if needed.
    @discardableResult func load(looks: [Recipe]) async throws -> LoadReport
    /// Same as `load(looks:)`, plus `onSlot` right after each slot's write + read-back completes (in slot order, before
    /// the next slot starts). A slot that fails gets a `.failed` report, then `load` throws.
    @discardableResult func load(looks: [Recipe], onSlot: @Sendable (SlotReport) -> Void) async throws -> LoadReport
    /// Explicit destinations. Saves every target snapshot before any write; a failing persistence callback aborts.
    @discardableResult func load(placements: [FujiSettingsFile.LookPlacement], protectedSlots: Set<Int>,
        onBackup: @Sendable (SlotBackup) throws -> Void, onSlot: @Sendable (SlotReport) -> Void) async throws -> LoadReport
    /// Restore only the recorded slots, after verifying camera identity and saving a fresh undo.
    @discardableResult func restore(_ backup: SlotBackup, protectedSlots: Set<Int>,
        onBackup: @Sendable (SlotBackup) throws -> Void) async throws -> LoadReport
    /// Apply a look to the camera's CURRENT shooting state (the live C0 codes), leaving C1–C7 alone. Reads the live
    /// values first and hands them to `onSnapshot` before anything is written (persist them: they are the undo), writes
    /// `LiveLook.writes(for:)` (only the codes in `only`, when given) with read-back, then reads the look again.
    /// Same USB mode as `load`. Exposure, drive and AF can't go live on the X100VI (it has no USB tether mode).
    @discardableResult
    func applyLookLive(_ recipe: Recipe, only codes: Set<UInt16>?, onSnapshot: @Sendable (LiveSnapshot) throws -> Void) async throws -> LiveLookReport
    /// Put a snapshot from `applyLookLive` (or `dialin-cam props --read --json`) back. Only the codes the apply wrote,
    /// when the snapshot lists them.
    @discardableResult func restoreLive(_ snapshot: LiveSnapshot) async throws -> LiveRestoreReport
    /// Close the session (the camera's buttons are locked while it's open).
    func disconnect() async
}

extension CameraLinking {
    public func load(placements: [FujiSettingsFile.LookPlacement], protectedSlots: Set<Int> = [],
                     onBackup: @Sendable (SlotBackup) throws -> Void, onSlot: @Sendable (SlotReport) -> Void = { _ in }) async throws -> LoadReport {
        throw CameraError.invalid("This camera link does not support backed-up, targeted slot writes.")
    }
    public func restore(_ backup: SlotBackup, protectedSlots: Set<Int> = [],
                        onBackup: @Sendable (SlotBackup) throws -> Void) async throws -> LoadReport {
        throw CameraError.invalid("This camera link does not support restoring slots.")
    }
    /// `applyLookLive(_:only:onSnapshot:)` without a snapshot callback (the report's `before` is the undo).
    @discardableResult
    public func applyLookLive(_ recipe: Recipe, only codes: Set<UInt16>? = nil) async throws -> LiveLookReport {
        try await applyLookLive(recipe, only: codes, onSnapshot: { _ in })
    }

    /// Fallback for conformers that predate live looks.
    @discardableResult
    public func applyLookLive(_ recipe: Recipe, only codes: Set<UInt16>?, onSnapshot: @Sendable (LiveSnapshot) throws -> Void) async throws -> LiveLookReport {
        throw CameraError.invalid("This camera link can't apply looks live.")
    }

    @discardableResult
    public func restoreLive(_ snapshot: LiveSnapshot) async throws -> LiveRestoreReport {
        throw CameraError.invalid("This camera link can't restore live looks.")
    }
}

extension CameraLinking {
    /// Fallback for conformers that predate `onSlot`: runs `load(looks:)` and reports every slot at the end.
    /// `CameraLink` and `MockCameraLink` override this with live, per-slot reports.
    @discardableResult
    public func load(looks: [Recipe], onSlot: @Sendable (SlotReport) -> Void) async throws -> LoadReport {
        let report = try await load(looks: looks)
        report.slotReports.forEach(onSlot)
        return report
    }
}

public actor CameraLink: CameraLinking {
    private let camera: FujiCamera
    private let searchTimeout: Duration
    private let broadcaster: StateBroadcaster<CameraLinkState>
    private var connected = false

    /// The slots as they were before the most recent `load` (persist it if you want an undo).
    public private(set) var lastBackup: SlotBackup?

    /// - Parameters:
    ///   - transport: usually `ImageCaptureTransport()`; tests pass a fake.
    ///   - searchTimeout: how long `connect()` waits for a camera before failing with `CameraError.noCamera`.
    public init(
        transport: any PTPTransport, timing: FujiCamera.Timing = .camera, searchTimeout: Duration = .seconds(60),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        camera = FujiCamera(transport: transport, timing: timing, log: log)
        self.searchTimeout = searchTimeout
        broadcaster = StateBroadcaster(.searching)
    }

    /// The real thing: USB via ImageCaptureCore.
    @MainActor
    public static func usb(searchTimeout: Duration = .seconds(60), log: @escaping @Sendable (String) -> Void = { _ in }) -> CameraLink {
        let transport = ImageCaptureTransport()
        transport.startBrowsing()
        return CameraLink(transport: transport, searchTimeout: searchTimeout, log: log)
    }

    public nonisolated var state: AsyncStream<CameraLinkState> { broadcaster.stream() }
    public nonisolated var currentState: CameraLinkState { broadcaster.current }

    /// Direct access for advanced use (backups, settings file, restore).
    public nonisolated var fujiCamera: FujiCamera { camera }

    public func connect() async throws {
        broadcaster.send(.searching)
        do {
            try await camera.connect(timeout: searchTimeout)
            connected = true
            broadcaster.send(.connected(model: await camera.model))
        } catch let error as CameraError {
            if case .needsUSBMode = error { broadcaster.send(.needsUSBMode) } else { broadcaster.send(.failed(reason: error.reason)) }
            throw error
        } catch {
            broadcaster.send(.failed(reason: "\(error)"))
            throw error
        }
    }

    @discardableResult
    public func load(looks: [Recipe]) async throws -> LoadReport {
        try await load(looks: looks, onSlot: { _ in })
    }

    @discardableResult
    public func load(looks: [Recipe], onSlot: @Sendable (SlotReport) -> Void) async throws -> LoadReport {
        try await load(placements: looks.enumerated().map { .init(slot: $0.offset + 1, recipe: $0.element) },
                       protectedSlots: [], onBackup: { _ in }, onSlot: onSlot)
    }

    public func load(placements: [FujiSettingsFile.LookPlacement], protectedSlots: Set<Int> = [],
                     onBackup: @Sendable (SlotBackup) throws -> Void, onSlot: @Sendable (SlotReport) -> Void = { _ in }) async throws -> LoadReport {
        try SlotBackup.validateTargets(placements.map(\.slot), protected: protectedSlots)
        if !connected { try await connect() }
        try CameraCompatibility.requireRecipeModel(await camera.model)
        let targets = placements.sorted { $0.slot < $1.slot }
        let backup = try await snapshot(targets.map(\.slot))
        lastBackup = backup
        guard let serial = backup.serial, !serial.isEmpty, let firmware = backup.firmware, !firmware.isEmpty else {
            throw CameraError.invalid("The camera's identity could not be backed up. Nothing was written.")
        }
        for (target, snapshot) in zip(targets, backup.slots) {
            // Conditional properties may be unreadable while inactive (e.g. Kelvin with Auto WB).
            // Require the fields needed to restore the OLD look, not fields only the new look activates.
            let needed = Set(SlotEncoder.writes(for: snapshot.values).map(\.propID))
            guard needed.isSubset(of: Set(snapshot.rawProps.map(\.id))) else {
                throw CameraError.invalid("C\(target.slot) could not be fully backed up. Nothing was written.")
            }
        }
        try onBackup(backup) // Durable barrier: no name or value is written before this returns.
        var reports: [FujiCamera.WriteReport] = []
        for (p, before) in zip(targets, backup.slots) {
            try Task.checkCancellation()
            broadcaster.send(.writing(slot: p.slot, of: targets.count))
            do {
                let report = try await camera.writeSlot(p.slot, recipe: p.recipe, base: before.rawProps)
                reports.append(report)
                onSlot(SlotReport(write: report))
            } catch {
                onSlot(SlotReport(slot: p.slot, name: p.recipe.slotName, verdict: .failed(reason: Self.reason(error))))
                if !(error is CancellationError) { connected = false }
                throw fail(error)
            }
        }
        broadcaster.send(.done)
        return LoadReport(slots: reports, backup: backup)
    }

    private func snapshot(_ slots: [Int]) async throws -> SlotBackup {
        var before: [SlotSnapshot] = []
        for slot in slots { before.append(try await camera.readSlot(slot)) }
        let info = await camera.deviceInfo
        return SlotBackup(model: info.model, serial: info.serialNumber, firmware: info.deviceVersion, slots: before)
    }

    public func restore(_ backup: SlotBackup, protectedSlots: Set<Int> = [],
                        onBackup: @Sendable (SlotBackup) throws -> Void) async throws -> LoadReport {
        try SlotBackup.validateTargets(backup.slots.map(\.slot), protected: protectedSlots)
        if !connected { try await connect() }
        try CameraCompatibility.requireRecipeModel(await camera.model)
        let fresh = try await snapshot(backup.slots.map(\.slot))
        try backup.requireSameCamera(as: fresh)
        guard backup.slots.allSatisfy({ !$0.props.isEmpty && $0.rawProps.count == $0.props.count }) else {
            throw CameraError.invalid("The saved slot backup is incomplete. Nothing was written.")
        }
        lastBackup = fresh
        try onBackup(fresh)
        let reports = try await camera.restore(backup.slots)
        broadcaster.send(.done)
        return LoadReport(slots: reports, backup: fresh)
    }

    /// The live look as it was before the most recent `applyLookLive` (kept even when the apply failed part-way).
    public private(set) var lastLiveSnapshot: LiveSnapshot?

    @discardableResult
    public func applyLookLive(_ recipe: Recipe, only codes: Set<UInt16>?, onSnapshot: @Sendable (LiveSnapshot) throws -> Void) async throws -> LiveLookReport {
        let plan = LiveLook.plan(for: recipe, only: codes)
        guard !plan.isEmpty else { throw fail(CameraError.invalid("Nothing to write: --only matched none of this look's codes.")) }
        if !connected { try await connect() }
        try CameraCompatibility.requireRecipeModel(await camera.model)
        let seen = LockedValue<LiveSnapshot?>(nil)
        do {
            let report = try await camera.applyLive(plan) { snap in
                seen.value = snap
                try onSnapshot(snap)
            }
            lastLiveSnapshot = report.before
            return report
        } catch {
            if let s = seen.value { lastLiveSnapshot = s }
            if !(error is CancellationError) && !Self.isInputError(error) { connected = false }
            throw fail(error)
        }
    }

    @discardableResult
    public func restoreLive(_ snapshot: LiveSnapshot) async throws -> LiveRestoreReport {
        if !connected { try await connect() }
        try CameraCompatibility.requireRecipeModel(await camera.model)
        do {
            return try await camera.restoreLive(snapshot)
        } catch {
            if !(error is CancellationError) && !Self.isInputError(error) { connected = false }
            throw fail(error)
        }
    }

    public func disconnect() async {
        connected = false
        await camera.disconnect()
    }

    static func isInputError(_ error: any Error) -> Bool {
        if case .invalid = error as? CameraError { return true }
        return false
    }

    private func fail(_ error: any Error) -> any Error {
        broadcaster.send(.failed(reason: Self.reason(error)))
        return error
    }

    static func reason(_ error: any Error) -> String {
        (error as? CameraError)?.reason ?? (error is CancellationError ? "cancelled" : "\(error)")
    }
}

/// Multicast state: each `stream()` starts with the current value.
final class StateBroadcaster<Value: Sendable>: Sendable {
    private struct Box {
        var current: Value
        var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    }

    private let box: Mutex<Box>

    init(_ initial: Value) { box = Mutex(Box(current: initial)) }

    var current: Value { box.withLock { $0.current } }

    func stream() -> AsyncStream<Value> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Value>.makeStream()
        continuation.onTermination = { [weak self] _ in
            self?.box.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        box.withLock { b in
            b.continuations[id] = continuation
            continuation.yield(b.current)
        }
        return stream
    }

    func send(_ value: Value) {
        box.withLock { b in
            b.current = value
            for c in b.continuations.values { c.yield(value) }
        }
    }

    func finish() {
        box.withLock { b in
            for c in b.continuations.values { c.finish() }
            b.continuations.removeAll()
        }
    }
}
