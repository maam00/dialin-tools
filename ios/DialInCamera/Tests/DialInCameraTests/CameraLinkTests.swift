// The app-facing API: state stream + load(looks:), real (over the fake camera) and mock.
import Foundation
import Testing
@testable import DialInCamera

/// Collects states from a stream until `stop` matches.
func collect(_ stream: AsyncStream<CameraLinkState>, until stop: @escaping @Sendable (CameraLinkState) -> Bool) -> Task<[CameraLinkState], Never> {
    Task {
        var out: [CameraLinkState] = []
        for await s in stream {
            out.append(s)
            if stop(s) { break }
        }
        return out
    }
}

func isTerminal(_ s: CameraLinkState) -> Bool {
    switch s {
    case .done, .failed, .needsUSBMode: true
    default: false
    }
}

@Suite("CameraLink")
struct CameraLinkTests {
    let looks: [Recipe] = (try? Fixture.vectors().map(\.recipe)) ?? []

    @Test("load: searching → connected → writing(1…n of n) → done, with each look in its slot and an undo backup")
    func loadStates() async throws {
        let fake = FakePTPCamera()
        for s in 1...4 { await fake.seed(slot: s, recipe: Recipe(name: "Old \(s)", filmSim: .provia)) }
        let link = CameraLink(transport: fake, timing: .immediate)
        let states = collect(link.state) { if case .done = $0 { true } else { false } }
        let report = try await link.load(looks: looks)
        #expect(await states.value == [
            .searching, .searching, .connected(model: "X100VI"),
            .writing(slot: 1, of: 4), .writing(slot: 2, of: 4), .writing(slot: 3, of: 4), .writing(slot: 4, of: 4), .done,
        ])
        #expect(report.isClean)
        #expect(report.slots.map(\.name) == looks.map(\.slotName))
        #expect(report.backup.slots.map(\.name) == ["Old 1", "Old 2", "Old 3", "Old 4"])
        let cam = link.fujiCamera
        for (i, look) in looks.enumerated() {
            #expect(try await cam.readSlot(i + 1).recipe?.filmSim == look.filmSim)
        }
        #expect(link.currentState == .done)
        #expect(await link.lastBackup == report.backup)
    }

    @Test("connect on a camera in the wrong USB mode → needsUSBMode")
    func needsUSBMode() async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.advertised = [0x5001] }
        let link = CameraLink(transport: fake, timing: .immediate)
        await #expect(throws: CameraError.self) { try await link.connect() }
        #expect(link.currentState == .needsUSBMode)
    }

    @Test("Unplugged mid-load → failed(reason) and the error is thrown")
    func unplugged() async throws {
        let fake = FakePTPCamera()
        await fake.configure { $0.disconnectOnWrite = 25 }
        let link = CameraLink(transport: fake, timing: .immediate)
        await #expect(throws: CameraError.disconnected("camera unplugged")) { try await link.load(looks: looks) }
        guard case .failed(let reason) = link.currentState else { Issue.record("expected failed, got \(link.currentState)"); return }
        #expect(reason.contains("disconnected"))
    }

    @Test("More than 7 looks is refused")
    func tooMany() async {
        let link = CameraLink(transport: FakePTPCamera(), timing: .immediate)
        let eight = Array(repeating: Recipe(name: "x", filmSim: .provia), count: 8)
        await #expect(throws: CameraError.self) { try await link.load(looks: eight) }
    }

    @Test("Each state stream starts with the current state")
    func streamStartsWithCurrent() async throws {
        let link = CameraLink(transport: FakePTPCamera(), timing: .immediate)
        try await link.connect()
        var it = link.state.makeAsyncIterator()
        #expect(await it.next() == .connected(model: "X100VI"))
    }

    // MARK: Mock

    @Test("MockCameraLink: realistic timing, same states, remembers what it holds")
    func mockSuccess() async throws {
        let mock = MockCameraLink(searchDelay: .milliseconds(20), perSlot: .milliseconds(30))
        let states = collect(mock.state) { if case .done = $0 { true } else { false } }
        let start = ContinuousClock.now
        let report = try await mock.load(looks: looks)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(20 + 4 * 30))
        #expect(await states.value.suffix(5) == [.writing(slot: 1, of: 4), .writing(slot: 2, of: 4), .writing(slot: 3, of: 4), .writing(slot: 4, of: 4), .done])
        #expect(report.slots.count == 4 && report.isClean)
        #expect(mock.slots[3] == looks[2])
    }

    @Test("MockCameraLink failure scenarios")
    func mockFailures() async throws {
        let none = MockCameraLink(scenario: .noCamera, searchDelay: .milliseconds(5))
        await #expect(throws: CameraError.noCamera) { try await none.connect() }
        let mode = MockCameraLink(scenario: .needsUSBMode, searchDelay: .milliseconds(5))
        await #expect(throws: CameraError.self) { try await mode.connect() }
        #expect(mode.currentState == .needsUSBMode)
        let pulled = MockCameraLink(scenario: .unplugged(atSlot: 2), searchDelay: .milliseconds(5), perSlot: .milliseconds(5))
        await #expect(throws: CameraError.self) { try await pulled.load(looks: looks) }
        #expect(pulled.slots.keys.sorted() == [1])
        let burst = MockCameraLink(scenario: .rejects(propID: FujiProp.clarity), searchDelay: .milliseconds(5), perSlot: .milliseconds(5))
        let report = try await burst.load(looks: looks)
        #expect(!report.isClean)
        #expect(report.slots[0].rejected == ["clarity skipped (camera must be in single-shot drive mode)"])
    }
}
