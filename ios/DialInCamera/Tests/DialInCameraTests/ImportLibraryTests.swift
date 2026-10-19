// Library layout, manifest dedupe, --since filtering, capture-date parsing (PTP + EXIF + RAF), and the engine's
// date fallbacks. No camera, no network.
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DialInCamera

@Suite("Import library, dates and EXIF")
struct ImportLibraryTests {
    // MARK: Dates

    @Test("PTP DateTime strings (ISO 15740 §5.3.5): plain, tenths, Z, ±hhmm; junk is nil")
    func ptpDates() {
        #expect(CaptureTime.parsePTP("20260924T195324")?.iso == "2026-09-24T19:53:24")          // X100VI over USB (fuji-bridge)
        #expect(CaptureTime.parsePTP("20150524T011710")?.iso == "2015-05-24T01:17:10")          // libfuji Wi-Fi sample
        #expect(CaptureTime.parsePTP("20261009T143012.0")?.iso == "2026-10-09T14:30:12")
        #expect(CaptureTime.parsePTP("20261009T143012Z")?.iso == "2026-10-09T14:30:12+00:00")
        #expect(CaptureTime.parsePTP("20261009T143012+0200")?.utcOffset == 7200)
        #expect(CaptureTime.parsePTP("20261009T143012-0530")?.utcOffset == -19_800)
        #expect(CaptureTime.parsePTP("20261009T143012\u{0}")?.dayKey == "2026-10-09")
        #expect(CaptureTime.parsePTP("") == nil)
        #expect(CaptureTime.parsePTP("2026-10-09 14:30") == nil)
        #expect(CaptureTime.parsePTP("20261339T143012") == nil)                                 // month 13
    }

    @Test("EXIF DateTimeOriginal with OffsetTimeOriginal; manifest ISO round trip")
    func exifDates() {
        let t = CaptureTime.parseEXIF("2026:10:09 23:59:58", offset: "-04:00")
        #expect(t?.iso == "2026-10-09T23:59:58-04:00")
        #expect(t?.dayKey == "2026-10-09")                     // the camera's wall-clock day, not UTC's
        #expect(CaptureTime.parseEXIF("2026:10:09 23:59:58")?.utcOffset == nil)
        #expect(CaptureTime.parseEXIF("    :  :     :  :  ") == nil)
        #expect(CaptureTime.parseISO("2026-10-09T23:59:58-04:00") == t)
        #expect(CaptureTime.parseISO("2026-10-09T23:59:58")?.iso == "2026-10-09T23:59:58")
    }

    @Test("Day keys: YYYY-MM-DD, today/yesterday, rejects junk")
    func days() {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        #expect(ImportDay.today(noon, timeZone: utc) == "2026-10-09")
        #expect(ImportDay.parse("2026-10-01") == "2026-10-01")
        #expect(ImportDay.parse("2026-1-5") == "2026-01-05")
        #expect(ImportDay.parse("10/01/2026") == nil)
        #expect(ImportDay.parse("2026-13-01") == nil)
        #expect(ImportDay.parse("today", now: noon) == ImportDay.today(noon))
    }

    // MARK: EXIF

    @Test("EXIF from a JPEG: Make, Model, DateTimeOriginal, OffsetTimeOriginal, IFD1 thumbnail")
    func exifJPEG() throws {
        let jpeg = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 14:30:12", offset: "-04:00")
        let e = try #require(ExifReader.read(jpeg))
        #expect(e.make == "FUJIFILM")
        #expect(e.model == "X100VI")
        #expect(e.isX100VI)
        #expect(e.captured?.iso == "2026-10-09T14:30:12-04:00")
        #expect(e.thumbnail == Data([0xFF, 0xD8, 0xFF, 0xD9]))
        // The first 300 bytes are enough (the importer probes 64 KB heads over USB/Wi-Fi).
        #expect(ExifReader.read(jpeg.prefix(300))?.captured?.iso == "2026-10-09T14:30:12-04:00")
        // Not a JPEG / no EXIF.
        #expect(ExifReader.read(Data([0xFF, 0xD8, 0xFF, 0xDA, 0, 2])) == nil)
        #expect(ExifReader.read(Data("hello".utf8)) == nil)
        #expect(ExifReader.read(jpeg.prefix(10)) == nil)
    }

    @Test("EXIF written by ImageIO (a real encoder, little-endian or not) parses the same way")
    func exifFromImageIO() throws {
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X100VI"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:09 08:07:06",
                                             kCGImagePropertyExifOffsetTimeOriginal: "+02:00"],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let e = try #require(ExifReader.read(out as Data))
        #expect(e.isX100VI)
        #expect(e.dateTimeOriginal == "2026:10:09 08:07:06")
        #expect(e.captured?.dayKey == "2026-10-09")
        #expect(e.offsetTimeOriginal == nil || e.offsetTimeOriginal == "+02:00")
    }

    @Test("RAF: header points at the embedded JPEG (BE u32 @84/@88); its EXIF dates the RAF")
    func exifRAF() throws {
        let jpeg = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 10:00:00")
        let raf = SyntheticJPEG.raf(embedding: jpeg)
        #expect(raf.prefix(16) == Data("FUJIFILMCCD-RAW ".utf8))
        #expect(ExifReader.rafEmbeddedJPEG(raf) == 160..<(160 + jpeg.count))
        #expect(ExifReader.read(raf)?.captured?.iso == "2026-10-09T10:00:00")
        #expect(ExifReader.read(raf)?.model == "X100VI")
    }

    // MARK: Options

    @Test("--since keeps that day and later; undated only with --all; kinds")
    func sinceFilter() {
        let o = ImportOptions(since: "2026-10-09")
        #expect(o.wants(day: "2026-10-09"))
        #expect(o.wants(day: "2026-10-10"))
        #expect(!o.wants(day: "2026-10-08"))
        #expect(!o.wants(day: nil))
        let all = ImportOptions(since: nil, includeUndated: true)
        #expect(all.wants(day: "1999-01-01"))
        #expect(all.wants(day: nil))
        #expect(!ImportOptions(since: nil).wants(day: nil))
        #expect(o.wants(.jpeg) && o.wants(.raw) && o.wants(.heif))
        #expect(!o.wants(.movie) && !o.wants(.other))
        #expect(!ImportOptions(includeRAW: false).wants(.raw))
        #expect(ImportFileKind(filename: "DSCF0001.RAF") == .raw)
        #expect(ImportFileKind(filename: "dscf0001.jpg") == .jpeg)
        #expect(ImportFileKind(filename: "DSCF0001.HIF") == .heif)
        #expect(ImportFileKind(filename: "DSCF0001.MOV") == .movie)
    }

    // MARK: Library + engine

    @Test("Import lands originals in <root>/<day>/ with manifest.json; a second run fetches nothing")
    func manifestAndDedupe() async throws {
        let root = try TempDir.make("lib")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ImportLibrary(root: root)
        let src = sample()
        let first = try await PhotoImporter.run(source: src, library: library, options: ImportOptions(since: "2026-10-09"))
        #expect(first.saved.map(\.file).sorted() == ["DSCF0002.JPG", "DSCF0003.JPG", "DSCF0003.RAF"])
        #expect(first.plan.tooOld == 1)
        let dir = library.folder(for: "2026-10-09")
        #expect(try Data(contentsOf: dir.appendingPathComponent("DSCF0003.RAF")) == src.bodies["c-raf"])
        let m = try await library.manifest(for: "2026-10-09")
        #expect(m.version == 1 && m.day == "2026-10-09")
        #expect(m.files.count == 3)
        #expect(m.files.allSatisfy { $0.route == "folder" && $0.camera == "X100VI" })
        #expect(m.files.first { $0.file == "DSCF0002.JPG" }?.captured == "2026-10-09T09:15:00")
        // The JSON on disk has the documented keys.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: library.manifestURL(for: "2026-10-09"))) as? [String: Any]
        let entry = try #require((json?["files"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys).isSuperset(of: ["file", "captured", "size", "route"]))

        let second = try await PhotoImporter.run(source: src, library: library, options: ImportOptions(since: "2026-10-09"))
        #expect(second.saved.isEmpty)
        #expect(second.plan.already == 3)
        #expect(second.plan.toFetch == 0)
        #expect(try await library.manifest(for: "2026-10-09").files.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".incoming").path).isEmpty)
    }

    @Test("--since an earlier day brings the older file into its own day folder")
    func sinceEarlier() async throws {
        let root = try TempDir.make("lib")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ImportLibrary(root: root)
        let s = try await PhotoImporter.run(source: sample(), library: library, options: ImportOptions(since: "2026-10-08"))
        #expect(s.saved.count == 4)
        #expect(FileManager.default.fileExists(atPath: library.folder(for: "2026-10-08").appendingPathComponent("DSCF0001.JPG").path))
        #expect(s.folders.map(\.lastPathComponent) == ["2026-10-08", "2026-10-09"])
    }

    @Test("Already on disk but not in the manifest (interrupted run): adopted, not fetched again")
    func adopt() async throws {
        let root = try TempDir.make("lib")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ImportLibrary(root: root)
        let src = sample()
        let dir = library.folder(for: "2026-10-09")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try src.bodies["b"]!.write(to: dir.appendingPathComponent("DSCF0002.JPG"))
        let s = try await PhotoImporter.run(source: src, library: library, options: ImportOptions(since: "2026-10-09"))
        #expect(s.saved.map(\.file).sorted() == ["DSCF0003.JPG", "DSCF0003.RAF"])
        #expect(s.plan.already == 1)
        #expect(try await library.manifest(for: "2026-10-09").files.count == 3)
    }

    @Test("Same name, different photo (counter rolled over): kept as DSCF0002_2.JPG, nothing overwritten")
    func collision() async throws {
        let root = try TempDir.make("lib")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ImportLibrary(root: root)
        _ = try await PhotoImporter.run(source: sample(), library: library, options: ImportOptions(since: "2026-10-09"))
        let other = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 20:00:00", payloadBytes: 9_999, seed: 9)
        let src = ScriptedSource(items: [ImportItem(id: "z", name: "DSCF0002.JPG", size: other.count, captured: CaptureTime.parsePTP("20261009T200000"))],
                                 bodies: ["z": other])
        let s = try await PhotoImporter.run(source: src, library: library, options: ImportOptions(since: "2026-10-09"))
        #expect(s.saved.map(\.file) == ["DSCF0002_2.JPG"])
        #expect(s.saved.first?.originalName == "DSCF0002.JPG")
        #expect(try Data(contentsOf: library.folder(for: "2026-10-09").appendingPathComponent("DSCF0002_2.JPG")) == other)
    }

    @Test("Dedupe rule: same name + size; a size-less listing (Photos) matches on capture second")
    func matchRule() {
        let m = ImportManifest(day: "2026-10-09", files: [
            ImportManifest.Entry(file: "DSCF0002.JPG", originalName: "DSCF0002.JPG", captured: "2026-10-09T09:15:00", size: 1000,
                                 route: "usb", importedAt: "x", camera: "X100VI"),
        ])
        let t = CaptureTime.parsePTP("20261009T091500")
        #expect(m.entry(matching: ImportItem(id: "1", name: "dscf0002.jpg", size: 1000)) != nil)
        #expect(m.entry(matching: ImportItem(id: "1", name: "DSCF0002.JPG", size: 999, captured: t)) == nil)   // an original isn't blocked by a smaller copy
        #expect(m.entry(matching: ImportItem(id: "1", name: "DSCF0002.JPG", size: nil, captured: t)) != nil)   // Photos copy of it is skipped
        #expect(m.entry(matching: ImportItem(id: "1", name: "DSCF0002.JPG", size: nil, captured: CaptureTime.parsePTP("20261009T091501"))) == nil)
        #expect(m.entry(matching: ImportItem(id: "1", name: "DSCF0009.JPG", size: 1000)) == nil)
    }

    @Test("Undated listing: RAF inherits its JPEG's time; a JPEG is dated from its own EXIF head")
    func dateFallbacks() async throws {
        let root = try TempDir.make("lib")
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 18:00:00")
        let raf = SyntheticJPEG.raf(embedding: jpeg)
        let lone = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 19:00:00", seed: 4)
        let src = ScriptedSource(items: [
            ImportItem(id: "j", name: "DSCF0010.JPG", size: jpeg.count, captured: CaptureTime.parsePTP("20261009T180000")),
            ImportItem(id: "r", name: "DSCF0010.RAF", size: raf.count, captured: nil),
            ImportItem(id: "l", name: "DSCF0011.JPG", size: lone.count, captured: nil),
        ], bodies: ["j": jpeg, "r": raf, "l": lone])
        let library = ImportLibrary(root: root)
        let s = try await PhotoImporter.run(source: src, library: library, options: ImportOptions(since: "2026-10-09"))
        #expect(s.saved.count == 3)
        #expect(s.saved.first { $0.file == "DSCF0010.RAF" }?.captured == "2026-10-09T18:00:00")
        #expect(s.saved.first { $0.file == "DSCF0011.JPG" }?.captured == "2026-10-09T19:00:00")
        #expect(src.reads.contains { $0.0 == "l" && $0.1 == 0 })      // probed the head of the undated JPEG
        #expect(!src.reads.contains { $0.0 == "r" })                  // the RAF needed no probe
    }

    @Test("The file's EXIF beats the listing: a photo listed on the wrong day lands in its EXIF day")
    func exifWins() async throws {
        let root = try TempDir.make("lib")
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = SyntheticJPEG.make(dateTimeOriginal: "2026:10:10 00:30:00")
        let src = ScriptedSource(items: [ImportItem(id: "j", name: "DSCF0020.JPG", size: jpeg.count, captured: CaptureTime.parsePTP("20261009T233000"))],
                                 bodies: ["j": jpeg])
        let library = ImportLibrary(root: root)
        let s = try await PhotoImporter.run(source: src, library: library, options: ImportOptions(since: "2026-10-09"))
        #expect(s.saved.first?.captured == "2026-10-10T00:30:00")
        #expect(FileManager.default.fileExists(atPath: library.folder(for: "2026-10-10").appendingPathComponent("DSCF0020.JPG").path))
    }

    @Test("A JPEG that doesn't end in FF D9 is not kept")
    func brokenJPEG() async throws {
        let root = try TempDir.make("lib")
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 12:00:00").dropLast(2)
        let src = ScriptedSource(items: [ImportItem(id: "j", name: "DSCF0030.JPG", size: jpeg.count, captured: CaptureTime.parsePTP("20261009T120000"))],
                                 bodies: ["j": Data(jpeg)])
        let library = ImportLibrary(root: root)
        let s = try await PhotoImporter.run(source: src, library: library, options: ImportOptions(since: "2026-10-09"))
        #expect(s.saved.isEmpty)
        #expect(s.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: library.folder(for: "2026-10-09").appendingPathComponent("DSCF0030.JPG").path))
    }

    @Test("A whole JPEG smaller than announced (camera resizing) is kept with a note; the next run still dedupes it")
    func resizedCopy() async throws {
        let root = try TempDir.make("lib")
        defer { try? FileManager.default.removeItem(at: root) }
        let small = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 12:00:00", payloadBytes: 3_000)
        let item = ImportItem(id: "j", name: "DSCF0040.JPG", size: 9_500_000, captured: CaptureTime.parsePTP("20261009T120000"))
        let src = ScriptedSource(route: .wifi, items: [item], bodies: ["j": small])
        let library = ImportLibrary(root: root)
        let box = EventBox()
        let s = try await PhotoImporter.run(source: src, library: library, options: ImportOptions(since: "2026-10-09"), events: box.add)
        #expect(s.saved.first?.size == small.count)
        #expect(s.saved.first?.listedSize == 9_500_000)
        #expect(box.events.contains { if case .note(let n) = $0 { n.contains("RESIZE IMAGE FOR SMARTPHONE") } else { false } })
        let again = try await PhotoImporter.run(source: src, library: library, options: ImportOptions(since: "2026-10-09"))
        #expect(again.plan.already == 1 && again.saved.isEmpty)
        // A RAF that comes up short is still an error.
        let raf = ScriptedSource(items: [ImportItem(id: "r", name: "DSCF0041.RAF", size: 9_000_000, captured: item.captured)], bodies: ["r": Data(count: 100)])
        let r = try await PhotoImporter.run(source: raf, library: library, options: ImportOptions(since: "2026-10-09"))
        #expect(r.saved.isEmpty && r.failures.count == 1)
    }

    @Test("Dry run plans and writes nothing; --limit caps newest-first")
    func dryRunAndLimit() async throws {
        let root = try TempDir.make("lib")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ImportLibrary(root: root)
        let dry = try await PhotoImporter.run(source: sample(), library: library, options: ImportOptions(since: "2026-10-09", dryRun: true))
        #expect(dry.plan.toFetch == 3)
        #expect(dry.saved.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.folder(for: "2026-10-09").path))
        let one = try await PhotoImporter.run(source: sample(), library: library, options: ImportOptions(since: "2026-10-09", limit: 1))
        #expect(one.saved.map(\.file) == ["DSCF0003.RAF"])   // newest capture first; RAF before JPG at the same second
    }

    @Test("Partial file resumes on a 512-byte boundary and renames when finished")
    func partialFile() throws {
        let dir = try TempDir.make("part")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("x.bin")
        do {
            let p = try PartialFile(destination: dest, expected: 5000)
            try p.append(Data(repeating: 1, count: 1300))
            p.close()
        }
        let again = try PartialFile(destination: dest, expected: 5000)
        #expect(again.resumedAt == 1024)
        try again.append(Data(repeating: 2, count: 3976))
        try again.finish()
        let d = try Data(contentsOf: dest)
        #expect(d.count == 5000)
        #expect(d.prefix(1024).allSatisfy { $0 == 1 } && d.suffix(3976).allSatisfy { $0 == 2 })
        #expect(!FileManager.default.fileExists(atPath: dest.path + ".part"))
    }

    #if canImport(Photos)
    @Test("Photos route prefilter: Fujifilm-style names")
    func fujiNames() {
        #expect(PhotoLibrarySource.looksFujifilm("DSCF0001.JPG"))
        #expect(PhotoLibrarySource.looksFujifilm("_DSF1234.HIF"))
        #expect(PhotoLibrarySource.looksFujifilm("anything.RAF"))
        #expect(!PhotoLibrarySource.looksFujifilm("IMG_1234.HEIC"))
        #expect(!PhotoLibrarySource.looksFujifilm("DSCFabcd.JPG"))
    }
    #endif

    @Test("Folder source: walks a DCIM tree, dates from EXIF (RAF via its header), skips other files")
    func folderSource() async throws {
        let card = try TempDir.make("card")
        let root = try TempDir.make("lib")
        defer {
            try? FileManager.default.removeItem(at: card)
            try? FileManager.default.removeItem(at: root)
        }
        let dcim = card.appendingPathComponent("DCIM/100_FUJI", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        let a = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 07:00:00")
        try a.write(to: dcim.appendingPathComponent("DSCF0100.JPG"))
        try SyntheticJPEG.raf(embedding: a).write(to: dcim.appendingPathComponent("DSCF0100.RAF"))
        try SyntheticJPEG.make(dateTimeOriginal: "2026:10:01 07:00:00", seed: 2).write(to: dcim.appendingPathComponent("DSCF0050.JPG"))
        try Data("x".utf8).write(to: card.appendingPathComponent("DCIM/100_FUJI/info.txt"))
        let s = try await PhotoImporter.run(source: FolderSource(root: card), library: ImportLibrary(root: root),
                                            options: ImportOptions(since: "2026-10-09"))
        #expect(s.saved.map(\.file).sorted() == ["DSCF0100.JPG", "DSCF0100.RAF"])
        #expect(s.plan.tooOld == 1)
        #expect(s.saved.allSatisfy { $0.route == "folder" })
    }

    /// Card: DSCF0001 (yesterday), DSCF0002 (today 09:15), DSCF0003 JPG+RAF (today 13:40).
    private func sample() -> ScriptedSource {
        let a = SyntheticJPEG.make(dateTimeOriginal: "2026:10:08 17:00:00", seed: 1)
        let b = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 09:15:00", seed: 2)
        let c = SyntheticJPEG.make(dateTimeOriginal: "2026:10:09 13:40:00", seed: 3)
        let craw = SyntheticJPEG.raf(embedding: c)
        return ScriptedSource(items: [
            ImportItem(id: "a", name: "DSCF0001.JPG", size: a.count, captured: CaptureTime.parsePTP("20261008T170000")),
            ImportItem(id: "b", name: "DSCF0002.JPG", size: b.count, captured: CaptureTime.parsePTP("20261009T091500")),
            ImportItem(id: "c", name: "DSCF0003.JPG", size: c.count, captured: CaptureTime.parsePTP("20261009T134000")),
            ImportItem(id: "c-raf", name: "DSCF0003.RAF", size: craw.count, captured: CaptureTime.parsePTP("20261009T134000")),
            ImportItem(id: "m", name: "DSCF0004.MOV", size: 10, captured: CaptureTime.parsePTP("20261009T140000")),
        ], bodies: ["a": a, "b": b, "c": c, "c-raf": craw, "m": Data(count: 10)])
    }
}
