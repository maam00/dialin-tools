// USB card-reader import at the PTP level (`PTPCardSource` over a fake transport standing in for ImageCaptureTransport):
// standard ObjectInfo, folders skipped, GetThumb, GetPartialObject windows with the 512-byte realignment. The
// ImageCaptureCore high-level route (`ImageCaptureFileSource`) needs the real camera; see IMPORT.md.
import Foundation
import Testing
@testable import DialInCamera

@Suite("USB import (PTP)")
struct ImportUSBTests {
    private func card() -> (FakeUSBCard, [String: Data]) {
        let today = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 15:00:00", payloadBytes: 2_300_000, seed: 1)
        let raw = SyntheticJPEG.raf(embedding: today, cfaBytes: 1_000_000)
        let old = SyntheticJPEG.make(dateTimeOriginal: "2026:09:30 15:00:00", payloadBytes: 1_000, seed: 2)
        let files: [FakeUSBCard.File] = [
            .init(handle: 0x10, name: "100_FUJI", data: Data(), date: "", folder: true),
            .init(handle: 0x21, name: "DSCF0007.JPG", data: old, date: ptpDate("2026-09-30", "150000")),
            .init(handle: 0x22, name: "DSCF0008.JPG", data: today, date: ptpDate("2026-10-09", "150000")),
            .init(handle: 0x23, name: "DSCF0008.RAF", data: raw, date: ptpDate("2026-10-09", "150000")),
        ]
        return (FakeUSBCard(files: files), ["DSCF0008.JPG": today, "DSCF0008.RAF": raw, "DSCF0007.JPG": old])
    }

    @Test("Standard ObjectInfo: size at offset 8, name and date as PTP strings from 52; folders are associations")
    func objectInfo() throws {
        let d = PTPObjectInfo.encode(layout: .standard, size: 25_000_000, filename: "DSCF0008.JPG", captureDate: "20261009T150000")
        #expect(d.subdata(in: 8..<12).hexString == "40787d01")        // 25,000,000 LE
        let i = try #require(PTPObjectInfo(d, layout: .standard))
        #expect(i.size == 25_000_000 && i.filename == "DSCF0008.JPG" && i.captureDate == "20261009T150000")
        #expect(!i.isFolder)
        #expect(PTPObjectInfo(PTPObjectInfo.encode(layout: .standard, format: 0x3001, size: 0, filename: "100_FUJI", captureDate: nil), layout: .standard)?.isFolder == true)
        // Fujifilm Wi-Fi variant: size at 13.
        let w = PTPObjectInfo.encode(layout: .fujiWifi, size: 123_456, filename: "A.JPG", captureDate: nil)
        #expect(PTPObjectInfo(w, layout: .fujiWifi)?.size == 123_456)
    }

    @Test("Card-reader import: GetObjectHandles, folder skipped, today's JPEG + RAF, 1 MB windows, byte-identical")
    func importToday() async throws {
        let (fake, bodies) = card()
        let root = try TempDir.make("usb")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = PTPCardSource(transport: fake, layout: .standard, route: .usb)
        let library = ImportLibrary(root: root)
        let s = try await PhotoImporter.run(source: source, library: library, options: ImportOptions(since: "2026-10-09"))
        #expect(s.saved.map(\.file).sorted() == ["DSCF0008.JPG", "DSCF0008.RAF"])
        #expect(s.plan.tooOld == 1)
        #expect(s.thumbnails == 2)
        for e in s.saved {
            #expect(try Data(contentsOf: library.folder(for: "2026-10-09").appendingPathComponent(e.file)) == bodies[e.file])
            #expect(e.route == "usb")
        }
        let log = fake.log
        #expect(log.first?.op == PTP.Op.getObjectHandles)
        #expect(log.first?.params == [0xFFFF_FFFF, 0, 0])
        let windows = log.filter { $0.op == PTP.Op.getPartialObject }
        #expect(windows.allSatisfy { $0.params[2] <= 1 << 20 && $0.params[1] % 512 == 0 })
        // No Wi-Fi-only props over USB (they answer 0x200A there, fuji-bridge docs/DEVELOPMENT.md).
        #expect(!log.contains { $0.op == PTP.Op.setDevicePropValue })
        // Nothing for the old photo but its ObjectInfo.
        #expect(!log.contains { $0.params.first == 0x21 && $0.op != PTP.Op.getObjectInfo })
    }

    @Test("A short window mid-file: the tail past the last 512-byte boundary is dropped and asked again")
    func realign() async throws {
        let (fake, bodies) = card()
        fake.shortOnce = 300_001
        let root = try TempDir.make("usb")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ImportLibrary(root: root)
        let s = try await PhotoImporter.run(source: PTPCardSource(transport: fake, layout: .standard, route: .usb), library: library,
                                            options: ImportOptions(since: "2026-10-09", thumbnails: false, limit: 1))
        let saved = try #require(s.saved.first)
        #expect(try Data(contentsOf: library.folder(for: "2026-10-09").appendingPathComponent(saved.file)) == bodies[saved.file])
        let offsets = fake.log.filter { $0.op == PTP.Op.getPartialObject }.map { Int($0.params[1]) }
        #expect(offsets.prefix(2) == [0, 299_520])          // 300,001 → back to 585 × 512
    }

    @Test("--all takes every date; --no-raw leaves RAFs; resumes a .part left by an earlier run")
    func optionsAndResume() async throws {
        let (fake, bodies) = card()
        let root = try TempDir.make("usb")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ImportLibrary(root: root)
        // An earlier run died 1.2 MB into DSCF0008.JPG.
        let jpgItem = ImportItem(id: "ptp:34", name: "DSCF0008.JPG", size: bodies["DSCF0008.JPG"]!.count)
        let staged = try await library.stagingURL(for: jpgItem)
        try bodies["DSCF0008.JPG"]!.prefix(1_200_000).write(to: staged.appendingPathExtension("part"))
        let s = try await PhotoImporter.run(source: PTPCardSource(transport: fake, layout: .standard, route: .usb), library: library,
                                            options: ImportOptions(since: nil, thumbnails: false, includeRAW: false))
        #expect(s.saved.map(\.file).sorted() == ["DSCF0007.JPG", "DSCF0008.JPG"])
        #expect(try Data(contentsOf: library.folder(for: "2026-10-09").appendingPathComponent("DSCF0008.JPG")) == bodies["DSCF0008.JPG"])
        let first = fake.log.first { $0.op == PTP.Op.getPartialObject && $0.params[0] == 0x22 }
        #expect(first?.params[1] == 1_199_616)                // resumed at 2343 × 512, not at 0
    }
}
