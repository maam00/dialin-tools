// Wi-Fi import of the camera's resized copies (D22E = resize rate, then D226 = 1) for the iPhone's browse
// view, and one original on demand over the same session (D226 = 2). Against the in-process fake X100VI over loopback.
import Foundation
import Testing
@testable import DialInCamera

private let day = "2026-10-09"

@Suite("Wi-Fi import: resized copies, originals on demand", .serialized)
struct ImportResizedTests {
    /// The sample card, each JPEG with a much smaller "resized" copy (same EXIF date).
    static func frames() -> [FakeFujiWifiCamera.Frame] {
        FakeFujiWifiCamera.sampleCard(day: day, todayCount: 3, olderCount: 1, jpegBytes: 60_000).map { f in
            var f = f
            guard f.name.hasSuffix(".JPG") else { return f }
            let d = f.date   // "20261009T090000"
            let exif = "\(d.prefix(4)):\(d.dropFirst(4).prefix(2)):\(d.dropFirst(6).prefix(2)) "
                + "\(d.dropFirst(9).prefix(2)):\(d.dropFirst(11).prefix(2)):\(d.dropFirst(13).prefix(2))"
            f.resized = SyntheticJPEG.make(dateTimeOriginal: exif, payloadBytes: 4_000, seed: 9)
            return f
        }
    }

    static func camera(port: UInt16, size: PhotoSize) -> FujiWifiCamera {
        var cfg = FujiWifiCamera.Config(transport: .init(host: "127.0.0.1", port: port, connectTimeout: .seconds(3), readTimeout: .seconds(3)),
                                        accessTimeout: .seconds(10), pollInterval: .milliseconds(20), reconnectPauses: [.zero])
        cfg.photoSize = size
        return FujiWifiCamera(config: cfg)
    }

    @Test("photoSize .resized: D22E = 1 then D226 = 1; the smaller copies land, the manifest keeps the original's size")
    func resized() async throws {
        let fake = FakeFujiWifiCamera(frames: Self.frames())
        let port = try await fake.start()
        defer { fake.stop() }
        let root = try TempDir.make("resized")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ImportLibrary(root: root)
        let cam = Self.camera(port: port, size: .resized)
        let summary = try await PhotoImporter.run(source: cam, library: library,
                                                  options: ImportOptions(since: day, thumbnails: false, includeRAW: false))
        #expect(summary.saved.count == 3)
        for e in summary.saved {
            let frame = try #require(fake.frames.first { $0.name == e.originalName })
            let got = try Data(contentsOf: library.folder(for: day).appendingPathComponent(e.file))
            #expect(got == frame.resized, "\(e.file) should be the resized copy")
            #expect(e.listedSize == frame.data.count)
        }
        // Order: the resize rate, then "resized" (never 2 in this run).
        let r = fake.record
        let sets = r.sets.filter { $0.prop == 0xD22E || $0.prop == 0xD226 }.map { "\(String(format: "%04X", $0.prop))=\($0.value.first ?? 99)" }
        #expect(sets.prefix(3) == ["D226=0", "D22E=1", "D226=1"])
        #expect(!sets.contains("D226=2"))
        await cam.close()
    }

    @Test("setPhotoSize(.original) mid-session: D226 = 2 before the next file, and the original arrives byte for byte")
    func originalOnDemand() async throws {
        let fake = FakeFujiWifiCamera(frames: Self.frames())
        let port = try await fake.start()
        defer { fake.stop() }
        let root = try TempDir.make("original")
        defer { try? FileManager.default.removeItem(at: root) }
        let cam = Self.camera(port: port, size: .resized)
        let items = try await cam.list(hint: ListHint(since: day)).filter { $0.kind == .jpeg && $0.dayKey == day }
        let item = try #require(items.first)
        let small = root.appendingPathComponent("small.jpg"), full = root.appendingPathComponent("full.jpg")
        _ = try await cam.download(item, to: small, progress: { _, _ in })
        await cam.setPhotoSize(.original)
        _ = try await cam.download(item, to: full, progress: { _, _ in })
        let frame = try #require(fake.frames.first { $0.name == item.name })
        #expect(try Data(contentsOf: small) == frame.resized)
        #expect(try Data(contentsOf: full) == frame.data)
        let d226 = fake.record.sets.filter { $0.prop == 0xD226 }.compactMap { $0.value.first }
        #expect(d226.suffix(2) == [1, 2])
        await cam.close()
    }
}
