// Wi-Fi listing on a big card, from the first physical Mac run (2026-10-15, X100VI fw 1.10, 1,336 objects): the body
// answered DateCreated (0xDC08) with "2" for every object, so the newest-first walk never saw a date, described the
// whole card at ~0.25 s per property and lost the session before a single file. Fake camera over loopback TCP only.
import Foundation
import Testing
@testable import DialInCamera

private let day = "2026-10-09"

@Suite("Wi-Fi listing on a large card", .serialized)
struct WifiListingTests {
    private func placeholderDates() -> FakeFujiWifiCamera.Behavior {
        var b = FakeFujiWifiCamera.Behavior()
        b.dateCreatedOverride = "2"
        return b
    }

    private func counts(_ r: FakeFujiWifiCamera.Record) -> (names: Int, dates: Int) {
        (r.commands.filter { $0.op == 0x9803 && $0.params.last == 0xDC07 }.count,
         r.commands.filter { $0.op == 0x9803 && $0.params.last == 0xDC08 }.count)
    }

    @Test("DateCreated placeholder: dates come from each file's EXIF and the walk stops 8 files past --since")
    func placeholderDateStopsEarly() async throws {
        let run = try await WifiRun(behavior: placeholderDates(), olderCount: 60, todayCount: 3)
        defer { run.cleanup() }
        let summary = try await run.importAll()
        #expect(summary.saved.count == 4)                 // 3 JPEGs + the RAF from `day`
        #expect(summary.plan.tooOld <= PTPCardSource.olderRunStop)
        try run.expectFilesIdentical(summary)
        let (names, dates) = counts(run.fake.record)
        #expect(names <= 4 + PTPCardSource.olderRunStop, "described \(names) of \(run.fake.frames.count) objects")
        #expect(dates == 1, "an unusable DateCreated is asked once, not per object")
        let m = try await run.library.manifest(for: day)
        #expect(m.files.allSatisfy { $0.captured?.hasPrefix(day) == true })
    }

    @Test("--last N describes only the newest N objects and needs no dates")
    func lastN() async throws {
        let run = try await WifiRun(behavior: placeholderDates(), olderCount: 60, todayCount: 3)
        defer { run.cleanup() }
        let summary = try await PhotoImporter.run(source: run.cam, library: run.library,
                                                  options: ImportOptions(since: nil, thumbnails: false, includeUndated: true, last: 2))
        #expect(summary.saved.map(\.originalName).sorted() == ["DSCF0062.RAF", "DSCF0063.JPG"])
        #expect(counts(run.fake.record).names == 2)
        try run.expectFilesIdentical(summary)
    }

    @Test("Files with no readable date at all end the date walk after 8 in a row instead of describing the whole card")
    func undatedRunStops() async throws {
        var frames: [FakeFujiWifiCamera.Frame] = []
        for n in 1...40 {
            let jpeg = SyntheticJPEG.make(dateTimeOriginal: "unknown", payloadBytes: 2_000 + n, seed: UInt8(n))
            frames.append(.init(handle: UInt32(n), name: String(format: "DSCF%04d.JPG", n), data: jpeg, date: "2"))
        }
        let fake = FakeFujiWifiCamera(frames: frames, behavior: placeholderDates())
        let port = try await fake.start()
        defer { fake.stop() }
        var cfg = WifiRun.config
        cfg.transport.port = port
        let cam = FujiWifiCamera(config: cfg)
        let root = try TempDir.make("wifi-undated")
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = try await PhotoImporter.run(source: cam, library: ImportLibrary(root: root),
                                                  options: ImportOptions(since: day, thumbnails: false))
        await cam.close()
        #expect(summary.saved.isEmpty && summary.plan.undated == PTPCardSource.undatedRunStop)
        #expect(counts(fake.record).names == PTPCardSource.undatedRunStop)
    }

    @Test("Keepalive: one D212 read only when idle, and a real request during it waits instead of failing")
    func keepalive() async throws {
        let fake = FakeFujiWifiCamera(frames: FakeFujiWifiCamera.sampleCard(day: day))
        let port = try await fake.start()
        defer { fake.stop() }
        let t = FujiPTPIPTransport(config: .init(host: "127.0.0.1", port: port, connectTimeout: .seconds(3), readTimeout: .seconds(3)))
        try await t.open(timeout: .seconds(3))
        #expect(await t.keepAliveIfIdle(.seconds(60)) == false, "not idle long enough: nothing sent")
        #expect(await t.keepAliveIfIdle(.zero))
        let polls = fake.record.commands.filter { $0.op == PTP.Op.getDevicePropValue && $0.params == [UInt32(FujiWifiProp.events)] }
        #expect(polls.count == 1)
        for _ in 0..<20 {
            async let ping = t.keepAliveIfIdle(.zero)
            async let real = t.transact(PTP.Op.getDevicePropValue, params: [0xD621], dataOut: nil, timeout: .seconds(3))
            let (_, r) = try await (ping, real)
            #expect(r.isOK)
        }
        await t.close()
        #expect(!fake.record.commands.contains { $0.op == PTP.Op.deleteObject })
    }

    @Test("--last on a source that can't cap its listing keeps the newest N by capture time")
    func lastGenericSource() async throws {
        let card = try TempDir.make("folder-last")
        defer { try? FileManager.default.removeItem(at: card) }
        for (i, stamp) in ["2026:10:09 09:00:00", "2026:10:09 10:00:00", "2026:10:09 11:00:00"].enumerated() {
            try SyntheticJPEG.make(dateTimeOriginal: stamp, payloadBytes: 1_000 + i, seed: UInt8(i))
                .write(to: card.appendingPathComponent(String(format: "DSCF%04d.JPG", i + 1)))
        }
        let root = try TempDir.make("folder-last-out")
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = try await PhotoImporter.run(source: FolderSource(root: card), library: ImportLibrary(root: root),
                                                  options: ImportOptions(since: nil, thumbnails: false, includeUndated: true, last: 1))
        #expect(summary.saved.map(\.originalName) == ["DSCF0003.JPG"])
    }
}
