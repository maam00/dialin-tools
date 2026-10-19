// A camera that isn't there: same API and timing as CameraLink, so the app runs (and demos) without hardware.
import Foundation
import Synchronization

public final class MockCameraLink: CameraLinking {
    /// What the pretend camera does.
    public enum Scenario: Sendable, Equatable {
        /// Everything works.
        case success
        /// No camera ever shows up (connect fails with `CameraError.noCamera` after `searchDelay`).
        case noCamera
        /// Camera found in the wrong USB mode.
        case needsUSBMode
        /// Cable pulled while writing this slot (1-based).
        case unplugged(atSlot: Int)
        /// The camera refuses this prop in every slot (e.g. clarity in burst mode); load still succeeds.
        case rejects(propID: UInt16)
    }

    public let model: String
    public let scenario: Scenario
    public let searchDelay: Duration
    public let perSlot: Duration

    private let broadcaster = StateBroadcaster<CameraLinkState>(.searching)
    private let connectedFlag = Mutex(false)
    private let written = Mutex<[Int: Recipe]>([:])

    /// - Parameters:
    ///   - perSlot: time per slot; ~350 ms matches the real camera (100 ms settle + 17 writes 20 ms apart + read-back).
    public init(
        scenario: Scenario = .success, model: String = "X100VI", searchDelay: Duration = .milliseconds(800),
        perSlot: Duration = .milliseconds(350)
    ) {
        self.scenario = scenario
        self.model = model
        self.searchDelay = searchDelay
        self.perSlot = perSlot
    }

    public var state: AsyncStream<CameraLinkState> { broadcaster.stream() }
    public var currentState: CameraLinkState { broadcaster.current }

    /// What the pretend camera holds now, by slot.
    public var slots: [Int: Recipe] { written.withLock { $0 } }

    public func connect() async throws {
        broadcaster.send(.searching)
        try await Task.sleep(for: searchDelay)
        switch scenario {
        case .noCamera:
            broadcaster.send(.failed(reason: CameraError.noCamera.reason))
            throw CameraError.noCamera
        case .needsUSBMode:
            broadcaster.send(.needsUSBMode)
            throw CameraError.needsUSBMode("mock")
        default:
            connectedFlag.withLock { $0 = true }
            broadcaster.send(.connected(model: model))
        }
    }

    @discardableResult
    public func load(looks: [Recipe]) async throws -> LoadReport {
        try await load(looks: looks, onSlot: { _ in })
    }

    /// Same timing and scenarios as `load(looks:)`; `onSlot` fires after each slot's (pretend) write + read-back.
    @discardableResult
    public func load(looks: [Recipe], onSlot: @Sendable (SlotReport) -> Void) async throws -> LoadReport {
        try await load(placements: looks.enumerated().map { .init(slot: $0.offset + 1, recipe: $0.element) },
                       protectedSlots: [], onBackup: { _ in }, onSlot: onSlot)
    }

    public func load(placements: [FujiSettingsFile.LookPlacement], protectedSlots: Set<Int> = [],
                     onBackup: @Sendable (SlotBackup) throws -> Void, onSlot: @Sendable (SlotReport) -> Void = { _ in }) async throws -> LoadReport {
        try SlotBackup.validateTargets(placements.map(\.slot), protected: protectedSlots)
        let looks = placements.map(\.recipe)
        guard looks.count <= 7 else {
            let e = CameraError.invalid("At most 7 looks fit (C1–C7); got \(looks.count).")
            broadcaster.send(.failed(reason: e.reason))
            throw e
        }
        if !connectedFlag.withLock({ $0 }) { try await connect() }
        var reports: [FujiCamera.WriteReport] = []
        let before = placements.map { p in
            let recipe = written.withLock { $0[p.slot] } ?? Recipe(name: "C\(p.slot)", filmSim: .provia)
            let props = SlotEncoder.writes(for: recipe).map { RawProp(id: $0.propID, bytes: $0.bytes) }
            return SlotSnapshot(slot: p.slot, name: recipe.slotName, rawProps: props)
        }
        let backup = SlotBackup(model: model, serial: "mock", firmware: "mock", slots: before)
        try onBackup(backup)
        for p in placements {
            let slot = p.slot, look = p.recipe
            broadcaster.send(.writing(slot: slot, of: looks.count))
            do {
                try await Task.sleep(for: perSlot)
            } catch {
                onSlot(SlotReport(slot: slot, name: look.slotName, verdict: .failed(reason: "cancelled")))
                broadcaster.send(.failed(reason: "cancelled"))
                throw error
            }
            if case .unplugged(let at) = scenario, at == slot {
                connectedFlag.withLock { $0 = false }
                let e = CameraError.disconnected("camera unplugged")
                onSlot(SlotReport(slot: slot, name: look.slotName, verdict: .failed(reason: e.reason)))
                broadcaster.send(.failed(reason: e.reason))
                throw e
            }
            var writes = SlotEncoder.writes(for: look)
            var rejected: [String] = []
            var hints: [String] = []
            if case .rejects(let id) = scenario, let idx = writes.firstIndex(where: { $0.propID == id }) {
                let p = writes.remove(at: idx)
                rejected.append(FujiCamera.rejectHint[id] ?? "\(hex16(id))=\(p.bytes.hexString)")
                hints.append(FujiCamera.refusalHint(id))
            }
            written.withLock { $0[slot] = look }
            let report = FujiCamera.WriteReport(
                slot: slot, name: look.slotName, written: writes, attempted: writes.count + rejected.count,
                rejected: rejected, mismatched: [], hints: hints)
            reports.append(report)
            onSlot(SlotReport(write: report))
        }
        broadcaster.send(.done)
        return LoadReport(slots: reports, backup: backup)
    }

    public func restore(_ backup: SlotBackup, protectedSlots: Set<Int> = [],
                        onBackup: @Sendable (SlotBackup) throws -> Void) async throws -> LoadReport {
        try SlotBackup.validateTargets(backup.slots.map(\.slot), protected: protectedSlots)
        try backup.requireSameCamera(as: SlotBackup(model: model, serial: "mock", firmware: "mock", slots: []))
        let placements = try backup.slots.map { slot -> FujiSettingsFile.LookPlacement in
            guard !slot.props.isEmpty, let recipe = slot.recipe else { throw CameraError.invalid("The saved look is incomplete.") }
            return .init(slot: slot.slot, recipe: recipe)
        }
        return try await load(placements: placements, protectedSlots: protectedSlots, onBackup: onBackup, onSlot: { _ in })
    }

    // MARK: Live looks

    /// A plausible live state: Provia, DR100, grain Off (reads 6), Auto WB, everything else at zero.
    public static let defaultLiveState: [UInt16: Data] = [
        LiveProps.filmSimulation.code: PTPPack.u16(1), LiveProps.dRangePriority.code: PTPPack.u16(0),
        LiveProps.dynamicRange.code: PTPPack.u16(100), LiveProps.grain.code: PTPPack.u16(6),
        LiveProps.colorChrome.code: PTPPack.u16(1), LiveProps.colorChromeFxBlue.code: PTPPack.u16(1),
        LiveProps.smoothSkin.code: PTPPack.u16(1), LiveProps.whiteBalance.code: PTPPack.u16(2),
        LiveProps.colorTemperature.code: PTPPack.u16(6500), LiveProps.wbShiftR.code: PTPPack.i16(0),
        LiveProps.wbShiftB.code: PTPPack.i16(0), LiveProps.highlight.code: PTPPack.i16(0), LiveProps.shadow.code: PTPPack.i16(0),
        LiveProps.color.code: PTPPack.i16(0), LiveProps.sharpness.code: PTPPack.i16(0), LiveProps.noiseReduction.code: PTPPack.u16(0x2000),
        LiveProps.clarity.code: PTPPack.i16(0), LiveProps.monoWarmCool.code: PTPPack.i16(0), LiveProps.monoMagentaGreen.code: PTPPack.i16(0),
    ]

    private let live = Mutex<[UInt16: Data]>(MockCameraLink.defaultLiveState)

    /// What the pretend camera's live look holds now.
    public var liveState: [UInt16: Data] { live.withLock { $0 } }

    /// `.rejects(propID:)` applies to the live twin of a slot code too (D1A2 clarity → D032).
    private func refuses(_ code: UInt16) -> Bool {
        guard case .rejects(let id) = scenario else { return false }
        return id == code || LiveProps.liveCodeForSlotCode[id] == code
    }

    private func mockWrite(_ plan: [PropWrite]) -> LiveWriteReport {
        LiveWriteReport(entries: plan.map { w in
            if refuses(w.propID) {
                return LiveWriteEntry(code: w.propID, sent: w.bytes, landed: nil, response: PTP.Response.invalidDevicePropValue, readBack: nil)
            }
            live.withLock { $0[w.propID] = w.bytes }
            return LiveWriteEntry(code: w.propID, sent: w.bytes, landed: w.bytes, response: PTP.Response.ok, readBack: w.bytes)
        })
    }

    @discardableResult
    public func applyLookLive(_ recipe: Recipe, only codes: Set<UInt16>?, onSnapshot: @Sendable (LiveSnapshot) throws -> Void) async throws -> LiveLookReport {
        let plan = LiveLook.plan(for: recipe, only: codes)
        guard !plan.isEmpty else { throw CameraError.invalid("Nothing to write: --only matched none of this look's codes.") }
        if !connectedFlag.withLock({ $0 }) { try await connect() }
        let snapshot = LiveSnapshot(model: model, firmware: "mock", usbMode: 6, values: liveState, touched: plan.map(\.propID))
        try onSnapshot(snapshot)
        try await Task.sleep(for: perSlot)
        if case .unplugged = scenario {
            connectedFlag.withLock { $0 = false }
            let e = CameraError.disconnected("camera unplugged")
            broadcaster.send(.failed(reason: e.reason))
            throw e
        }
        let write = mockWrite(plan)
        return LiveLookReport(before: snapshot, planned: plan, skipped: [], write: write, after: liveState)
    }

    @discardableResult
    public func restoreLive(_ snapshot: LiveSnapshot) async throws -> LiveRestoreReport {
        if !connectedFlag.withLock({ $0 }) { try await connect() }
        let now = liveState
        let planned = LiveLook.restorePlan(snapshot, current: now)
        let first = planned.filter { w in !(now[w.propID].map { LiveLook.sameValue(w.propID, $0, w.bytes) } ?? false) }
        let write = mockWrite(first)
        let after = liveState
        let differences = planned.filter { w in !(after[w.propID].map { LiveLook.sameValue(w.propID, $0, w.bytes) } ?? false) }
            .map { "\(LiveHex.code($0.propID)) \(LiveProbe.label($0.propID)) still differs" }
        return LiveRestoreReport(planned: planned, alreadyRight: planned.filter { !first.contains($0) }.map(\.propID), write: write,
                                 retry: nil, after: after, differences: differences)
    }

    public func disconnect() async {
        connectedFlag.withLock { $0 = false }
    }
}
