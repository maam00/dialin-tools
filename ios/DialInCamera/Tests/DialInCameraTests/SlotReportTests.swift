// load(looks:onSlot:): per-slot verdicts as they happen, for the app's Send ceremony (a slot fills green only on
// `.confirmed`).
import Foundation
import Synchronization
import Testing
@testable import DialInCamera

/// Collects slot reports (and when they arrived) from the @Sendable callback.
final class ReportSink: Sendable {
    private let items = Mutex<[(SlotReport, ContinuousClock.Instant)]>([])
    let log: EventLog?

    init(log: EventLog? = nil) { self.log = log }

    func add(_ r: SlotReport) {
        items.withLock { $0.append((r, .now)) }
        log?.append("report \(r.slot)")
    }

    var reports: [SlotReport] { items.withLock { $0.map(\.0) } }
    var times: [ContinuousClock.Instant] { items.withLock { $0.map(\.1) } }
}

@Suite("Per-slot reports")
struct SlotReportTests {
    let looks: [Recipe] = (try? Fixture.vectors().map(\.recipe)) ?? []
    let clarityHint = "clarity skipped (camera must be in single-shot drive mode)"

    @Test("onSlot fires once per slot, in order, right after that slot's read-back and before the next slot starts")
    func liveOrdering() async throws {
        let events = EventLog()
        let fake = FakePTPCamera()
        await fake.configure { $0.eventLog = events }
        let link = CameraLink(transport: fake, timing: .immediate)
        let sink = ReportSink(log: events)
        let report = try await link.load(looks: looks, onSlot: { sink.add($0) })

        #expect(sink.reports.map(\.slot) == [1, 2, 3, 4])
        #expect(sink.reports.map(\.name) == looks.map(\.slotName))
        #expect(sink.reports.allSatisfy { $0.isConfirmed })
        let carried = report.slotReports
        #expect(sink.reports == carried, "the LoadReport carries the same verdicts")
        // All snapshots precede writes; each verdict still arrives before the next slot starts.
        var expected: [String] = []
        for s in 1...4 { expected += ["select \(s)", "readname \(s)"] }
        for s in 1...4 { expected += ["select \(s)", "readname \(s)", "report \(s)"] }
        #expect(events.all == expected)
    }

    @Test("A refused prop → partial with the plain hint; the rest of the load continues")
    func partialRefusal() async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.rejectProps = [FujiProp.clarity] }
        let link = CameraLink(transport: fake, timing: .immediate)
        let sink = ReportSink()
        try await link.load(looks: looks, onSlot: { sink.add($0) })
        #expect(sink.reports.count == 4)
        #expect(sink.reports.allSatisfy { $0.verdict == .partial(rejected: [clarityHint]) })
        #expect(link.currentState == .done)
    }

    @Test("DR step-down and a prop that didn't stick are partial, in plain words")
    func partialPlainWords() async throws {
        let fake = FakePTPCamera()
        await fake.configure { f in
            f.rejectDRAbove = 200
            f.ignoreWrites = [FujiProp.highlight]
        }
        await fake.seed(slot: 1, recipe: Recipe(name: "Old", filmSim: .provia))
        let link = CameraLink(transport: fake, timing: .immediate)
        let sink = ReportSink()
        try await link.load(looks: [.testLook(name: "Dusk")], onSlot: { sink.add($0) })
        #expect(sink.reports == [SlotReport(
            slot: 1, name: "Dusk",
            verdict: .partial(rejected: [
                "DR stepped down to DR200 (camera ISO too low for more)",
                "highlight didn't stick (camera kept a different value)",
            ]),
            detail: sink.reports.first?.detail)])
        // The TS-style detail is unchanged.
        #expect(sink.reports.first?.detail?.mismatched == ["0xd19d wrote f6ff read 0000"])
    }

    @Test("Grain Off reading back as 7 (X100VI Off-Large) still confirms")
    func grainOffReadBack() async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.readBackOverride = [FujiProp.grain: PTPPack.u16(7)] }
        let link = CameraLink(transport: fake, timing: .immediate)
        let sink = ReportSink()
        try await link.load(looks: [Recipe(name: "No grain", filmSim: .provia, grain: .off)], onSlot: { sink.add($0) })
        #expect(sink.reports.first?.verdict == .confirmed)
        #expect(sink.reports.first?.detail?.mismatched.isEmpty == true)

        // Any other read-back of grain is still a difference.
        let other = FakePTPCamera()
        await other.configure { $0.readBackOverride = [FujiProp.grain: PTPPack.u16(2)] }
        let sink2 = ReportSink()
        try await CameraLink(transport: other, timing: .immediate)
            .load(looks: [Recipe(name: "No grain", filmSim: .provia, grain: .off)], onSlot: { sink2.add($0) })
        #expect(sink2.reports.first?.verdict == .partial(rejected: ["grain didn't stick (camera kept a different value)"]))
    }

    @Test("Unplugged mid-load: earlier slots confirmed, the broken slot failed(reason), then load throws")
    func failedSlot() async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.disconnectOnWrite = 25 }
        let link = CameraLink(transport: fake, timing: .immediate)
        let sink = ReportSink()
        await #expect(throws: CameraError.disconnected("camera unplugged")) {
            try await link.load(looks: looks, onSlot: { sink.add($0) })
        }
        #expect(sink.reports.map(\.slot) == [1, 2])
        #expect(sink.reports[0].isConfirmed)
        #expect(sink.reports[1].verdict == .failed(reason: CameraError.disconnected("camera unplugged").reason))
        #expect(sink.reports[1].name == looks[1].slotName && sink.reports[1].detail == nil)
    }

    @Test("load(looks:) is unchanged: same result, no callback needed")
    func wrapper() async throws {
        let report = try await CameraLink(transport: FakePTPCamera(), timing: .immediate).load(looks: looks)
        #expect(report.slots.count == 4 && report.slotReports.allSatisfy { $0.isConfirmed })
    }

    // MARK: Mock

    @Test("Mock: reports arrive one by one, ~perSlot apart")
    func mockLive() async throws {
        let mock = MockCameraLink(searchDelay: .milliseconds(5), perSlot: .milliseconds(40))
        let sink = ReportSink()
        let start = ContinuousClock.now
        let report = try await mock.load(looks: looks, onSlot: { sink.add($0) })
        #expect(sink.reports.map(\.slot) == [1, 2, 3, 4])
        #expect(sink.reports.allSatisfy { $0.isConfirmed })
        let carried = report.slotReports
        #expect(sink.reports == carried)
        let times = [start] + sink.times
        for (a, b) in zip(times, times.dropFirst()) { #expect(b - a >= .milliseconds(40)) }
    }

    @Test("Mock defaults to ~350 ms per slot")
    func mockDefaultTiming() {
        #expect(MockCameraLink().perSlot == .milliseconds(350))
    }

    @Test("Mock scenarios: rejects → partial, unplugged → failed then throw, noCamera → no reports")
    func mockScenarios() async throws {
        let burst = MockCameraLink(scenario: .rejects(propID: FujiProp.clarity), searchDelay: .zero, perSlot: .milliseconds(1))
        let s1 = ReportSink()
        try await burst.load(looks: looks, onSlot: { s1.add($0) })
        #expect(s1.reports.allSatisfy { $0.verdict == .partial(rejected: [clarityHint]) })

        let pulled = MockCameraLink(scenario: .unplugged(atSlot: 3), searchDelay: .zero, perSlot: .milliseconds(1))
        let s2 = ReportSink()
        await #expect(throws: CameraError.self) { try await pulled.load(looks: looks, onSlot: { s2.add($0) }) }
        #expect(s2.reports.map(\.slot) == [1, 2, 3])
        #expect(s2.reports.prefix(2).allSatisfy { $0.isConfirmed })
        #expect(s2.reports[2].verdict == .failed(reason: CameraError.disconnected("camera unplugged").reason))

        let none = MockCameraLink(scenario: .noCamera, searchDelay: .zero)
        let s3 = ReportSink()
        await #expect(throws: CameraError.noCamera) { try await none.load(looks: looks, onSlot: { s3.add($0) }) }
        #expect(s3.reports.isEmpty)
    }

    @Test("A CameraLinking conformer that only has load(looks:) still gets reports (at the end) via the default")
    func legacyConformer() async throws {
        let legacy = LegacyLink()
        let sink = ReportSink()
        let any: any CameraLinking = legacy
        let report = try await any.load(looks: looks, onSlot: { sink.add($0) })
        let carried = report.slotReports
        #expect(sink.reports == carried)
        #expect(carried.count == 4)
    }
}

/// A conformer written before `onSlot` existed.
final class LegacyLink: CameraLinking {
    let inner = MockCameraLink(searchDelay: .zero, perSlot: .zero)
    var state: AsyncStream<CameraLinkState> { inner.state }
    var currentState: CameraLinkState { inner.currentState }
    func connect() async throws { try await inner.connect() }
    @discardableResult func load(looks: [Recipe]) async throws -> LoadReport { try await inner.load(looks: looks) }
    func disconnect() async { await inner.disconnect() }
}
