// The import engine, shared by every route: list → keep today's (or `since`) wanted files → drop what's already in
// the library → thumbnails first → full files newest first → verify → move into the day folder → manifest.json.
import Foundation

/// Something that can list photos and hand them over: the camera over USB (ImageCaptureCore), the camera's Wi-Fi
/// (PTP/IP), the Photos library, or a folder. Calls come one at a time from the importer.
public protocol PhotoSource: AnyObject, Sendable {
    var route: ImportRoute { get }
    /// Connect if needed and describe the files (no file bytes yet).
    func list(hint: ListHint) async throws -> [ImportItem]
    /// A small JPEG preview, or nil if this source has none.
    func thumbnail(for item: ImportItem) async throws -> Data?
    /// `length` bytes from `offset` (EXIF probing), or nil if unsupported.
    func read(_ item: ImportItem, offset: Int, length: Int) async throws -> Data?
    /// Write the whole file to `destination` (resuming a `destination.part` where the source can). Returns bytes.
    func download(_ item: ImportItem, to destination: URL, progress: @escaping @Sendable (Int, Int?) -> Void) async throws -> Int
    /// Let go of the camera (best effort).
    func close() async
}

public enum PhotoImporter {
    /// Runs one import. Per-file failures are reported and skipped; a lost camera ends the run with `interrupted`
    /// (running the same command again resumes: finished files are in the manifest, partial ones in .incoming).
    public static func run(source: any PhotoSource, library: ImportLibrary, options: ImportOptions = ImportOptions(),
                           events: @escaping @Sendable (ImportEvent) -> Void = { _ in }) async throws -> ImportSummary {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        let route = source.route
        events(.note(options.since.map { "looking for photos from \($0) on" } ?? "looking for photos from every date"))
        var items = try await source.list(hint: ListHint(since: options.since, last: options.last))
        if let last = options.last, items.count > last {
            // Sources that can't cap their own listing: keep the newest `last` (capture time, then name).
            items = Array(items.sorted { a, b in
                switch (a.captured, b.captured) {
                case let (x?, y?) where x != y: x > y
                default: a.name > b.name
                }
            }.prefix(max(0, last)))
        }
        events(.listed(total: items.count))

        // Kinds first (cheap), then dates.
        var otherKinds = 0
        items = items.filter { item in
            if options.wants(item.kind) { return true }
            otherKinds += 1
            return false
        }
        // A RAF without a date inherits its JPEG's (same stem, shot together).
        let jpegTimes = Dictionary(items.compactMap { i in i.kind != .raw ? i.captured.map { (i.stem, $0) } : nil },
                                   uniquingKeysWith: { a, _ in a })
        for k in items.indices where items[k].captured == nil {
            if let t = jpegTimes[items[k].stem] { items[k].captured = t }
        }
        // Still undated: probe the file's own EXIF (JPEG head, or RAF header → embedded JPEG). Only a date filter
        // needs it before downloading; otherwise each file is dated from its own EXIF once it's here (see commit below).
        for k in items.indices where items[k].captured == nil && options.since != nil {
            try Task.checkCancellation()
            if let t = try? await probeDate(items[k], source: source) { items[k].captured = t }
        }

        var tooOld = 0, undated = 0
        let inRange = items.filter { item in
            guard options.wants(day: item.captured?.dayKey) else {
                if item.captured == nil { undated += 1 } else { tooOld += 1 }
                return false
            }
            return true
        }.sorted { a, b in
            switch (a.captured, b.captured) {
            case let (x?, y?) where x != y: x > y
            default: a.name > b.name
            }
        }

        var todo: [(item: ImportItem, day: String, fileName: String)] = []
        var already = 0
        for item in inRange {
            let day = item.dayKey
            if options.reimport {
                todo.append((item, day, item.name))
                continue
            }
            switch try await library.status(of: item, day: day, route: route) {
            case .new(let fileName): todo.append((item, day, fileName))
            case .already: already += 1
            case .adopted: already += 1; events(.skipped(item, "already in the folder (recorded in manifest.json)"))
            }
        }
        if let limit = options.limit, todo.count > limit { todo = Array(todo.prefix(limit)) }

        let plan = ImportPlanSummary(listed: items.count + otherKinds, inRange: inRange.count, already: already, toFetch: todo.count,
                                     tooOld: tooOld, undated: undated, otherKinds: otherKinds)
        events(.planned(plan))
        var summary = ImportSummary(route: route, plan: plan)
        var folders = Set<URL>()
        if options.dryRun || todo.isEmpty {
            summary.seconds = seconds(since: started)
            return summary
        }

        // 1. Thumbnails: a quick look at everything new before the slow part.
        if options.thumbnails || options.thumbsOnly {
            for entry in todo {
                if Task.isCancelled {
                    summary.interrupted = true
                    summary.interruption = "cancelled"
                    break
                }
                do {
                    guard let data = try await source.thumbnail(for: entry.item), !data.isEmpty else { continue }
                    let url = try await library.saveThumbnail(data, for: entry.item, day: entry.day)
                    summary.thumbnails += 1
                    folders.insert(library.folder(for: entry.day))
                    events(.thumbnail(entry.item, url))
                } catch is CancellationError {
                    summary.interrupted = true
                    summary.interruption = "cancelled"
                    break
                } catch let e as ImportError where e.isLinkFailure {
                    summary.interrupted = true
                    summary.interruption = e.description
                    break
                } catch {
                    events(.failed(entry.item, "thumbnail: \(error)"))
                }
            }
        }
        if options.thumbsOnly || summary.interrupted {
            summary.folders = folders.sorted { $0.path < $1.path }
            summary.seconds = seconds(since: started)
            return summary
        }

        // 2. Full files, newest first: a run cut short has already brought the photos just taken.
        for (index, entry) in todo.enumerated() {
            if Task.isCancelled {
                summary.interrupted = true
                summary.interruption = "cancelled"
                break
            }
            let item = entry.item
            events(.downloading(item, index: index + 1, of: todo.count))
            let t0 = ContinuousClock.now
            do {
                let staged = try await library.stagingURL(for: item)
                let bytes = try await source.download(item, to: staged) { got, total in events(.progress(item, bytes: got, total: total)) }
                try Task.checkCancellation()
                if item.kind == .jpeg && !JPEGCheck.isComplete(staged) {
                    try? FileManager.default.removeItem(at: staged)
                    throw ImportError.incomplete("\(item.name) arrived but doesn't end like a JPEG; not kept")
                }
                if let want = item.size, bytes < want {
                    // A whole JPEG that is smaller than announced is a resized copy: an X100VI keeps announcing the
                    // original's length while it resizes (fuji-bridge docs/DEVELOPMENT.md). Keep it, say so.
                    guard item.kind == .jpeg else {
                        try? FileManager.default.removeItem(at: staged)
                        throw ImportError.incomplete("\(item.name): got \(bytes) of \(want) bytes")
                    }
                    events(.note("\(item.name): the camera sent a smaller copy (\(bytes / 1024) KB of \(want / 1024) KB). For originals, turn Bluetooth/SMARTPHONE SETTING › RESIZE IMAGE FOR SMARTPHONE OFF."))
                }
                // The file's own EXIF is the best date. If it disagrees with the listing about the day, trust EXIF.
                let exif = headEXIF(staged)
                let captured = exif?.captured ?? item.captured
                var day = entry.day
                var fileName = entry.fileName
                if let c = captured, c.dayKey != day {
                    day = c.dayKey
                    if case .new(let n) = try await library.status(of: item, day: day, route: route) { fileName = n } else {
                        try? FileManager.default.removeItem(at: staged)
                        events(.skipped(item, "already imported under \(day)"))
                        continue
                    }
                }
                var stamped = item
                stamped.camera = exif?.model ?? item.camera
                try Task.checkCancellation()
                let (url, record) = try await library.commit(staged: staged, item: stamped, fileName: fileName, day: day,
                                                             captured: captured, route: route, camera: stamped.camera)
                folders.insert(library.folder(for: day))
                summary.saved.append(record)
                summary.bytes += bytes
                events(.saved(item, url, bytes: bytes, seconds: seconds(since: t0)))
            } catch is CancellationError {
                summary.interrupted = true
                summary.interruption = "cancelled"
                break
            } catch let e as ImportError where e.isLinkFailure {
                events(.failed(item, e.description))
                summary.failures.append((item.name, e.description))
                summary.interrupted = true
                summary.interruption = e.description
                break
            } catch {
                events(.failed(item, "\(error)"))
                summary.failures.append((item.name, "\(error)"))
            }
        }
        summary.folders = folders.sorted { $0.path < $1.path }
        summary.seconds = seconds(since: started)
        return summary
    }

    /// EXIF date from the first 64 KB (JPEG) or via the RAF header's pointer to its embedded JPEG.
    static func probeDate(_ item: ImportItem, source: any PhotoSource) async throws -> CaptureTime? {
        switch item.kind {
        case .jpeg:
            guard let head = try await source.read(item, offset: 0, length: 65_536) else { return nil }
            return ExifReader.read(head)?.captured
        case .raw:
            guard let header = try await source.read(item, offset: 0, length: 512),
                  let range = ExifReader.rafEmbeddedJPEG(header),
                  let head = try await source.read(item, offset: range.lowerBound, length: min(65_536, range.count)) else { return nil }
            return ExifReader.read(head)?.captured
        default:
            return nil
        }
    }

    /// EXIF of a file on disk (first 64 KB; RAFs follow the header pointer).
    static func headEXIF(_ url: URL) -> ExifInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 65_536) else { return nil }
        if let range = ExifReader.rafEmbeddedJPEG(head) {
            try? h.seek(toOffset: UInt64(range.lowerBound))
            guard let jpeg = try? h.read(upToCount: min(65_536, range.count)) else { return nil }
            return ExifReader.read(jpeg)
        }
        return ExifReader.read(head)
    }

    static func seconds(since t: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
