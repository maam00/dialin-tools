// Where imported photos land and how we remember them.
//
//   ~/Pictures/Dial In/2026-10-09/DSCF1802.JPG     original name, original bytes (EXIF untouched)
//   ~/Pictures/Dial In/2026-10-09/manifest.json    file, capture time, size, route, for every import
//   ~/Pictures/Dial In/2026-10-09/.thumbs/…        the camera's 160×120 previews (hidden: not photos)
//   ~/Pictures/Dial In/.incoming/…                 downloads in progress (resumable .part files)
//
// On iOS the root is the app's Documents/Dial In. Platform-neutral.
import Foundation

/// One day folder's record of what was imported. Written as `manifest.json` next to the photos.
public struct ImportManifest: Codable, Sendable, Equatable {
    public var version: Int
    public var day: String
    public var files: [Entry]

    public struct Entry: Codable, Sendable, Equatable {
        /// Name in the folder (the camera's name, unless a different file already had it).
        public var file: String
        /// The camera's file name.
        public var originalName: String
        /// Capture time, "2026-10-09T14:30:12" (+offset when known).
        public var captured: String?
        /// Bytes.
        public var size: Int
        /// usb | wifi | photos | folder
        public var route: String
        /// When we copied it (UTC, ISO 8601).
        public var importedAt: String
        /// "X100VI" when known.
        public var camera: String?
        /// The size the camera announced, when the file that arrived is smaller (a resized copy).
        public var listedSize: Int?

        public init(file: String, originalName: String, captured: String?, size: Int, route: String, importedAt: String, camera: String?,
                    listedSize: Int? = nil) {
            self.file = file
            self.originalName = originalName
            self.captured = captured
            self.size = size
            self.route = route
            self.importedAt = importedAt
            self.camera = camera
            self.listedSize = listedSize
        }
    }

    public init(day: String, files: [Entry] = []) {
        version = 1
        self.day = day
        self.files = files
    }

    /// Already imported: same camera file name and the same size. When the source can't tell the size before
    /// downloading (Photos library), the same capture second counts instead. So an original from the camera is never
    /// blocked by a smaller phone-transfer copy, but a Photos-library copy of a photo already imported from the camera is skipped.
    public func entry(matching item: ImportItem) -> Entry? {
        files.first { e in
            guard e.originalName.caseInsensitiveCompare(item.name) == .orderedSame else { return false }
            if let size = item.size { return size == e.size || size == e.listedSize }
            guard let t = item.captured else { return true }
            return e.captured.flatMap(CaptureTime.parseISO) == t
        }
    }
}

public actor ImportLibrary {
    public nonisolated let root: URL
    private let fm = FileManager.default

    /// `~/Pictures/Dial In` on the Mac; `Documents/Dial In` in an iOS app.
    public static var defaultRoot: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Dial In", isDirectory: true)
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Dial In", isDirectory: true)
        #endif
    }

    public init(root: URL = ImportLibrary.defaultRoot) {
        self.root = root
    }

    public nonisolated func folder(for day: String) -> URL { root.appendingPathComponent(day, isDirectory: true) }
    public nonisolated func manifestURL(for day: String) -> URL { folder(for: day).appendingPathComponent("manifest.json") }
    public nonisolated var incoming: URL { root.appendingPathComponent(".incoming", isDirectory: true) }

    public func manifest(for day: String) throws -> ImportManifest {
        let url = manifestURL(for: day)
        guard fm.fileExists(atPath: url.path) else { return ImportManifest(day: day) }
        do {
            return try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: url))
        } catch {
            throw ImportError.invalid("\(url.path) is not a readable manifest (\(error)). Move it aside and run again.")
        }
    }

    public enum Status: Sendable, Equatable {
        /// Not here yet. Save it under this name.
        case new(fileName: String)
        /// The manifest already has it.
        case already(ImportManifest.Entry)
        /// Same name and size on disk but missing from the manifest (an interrupted run): recorded, not fetched.
        case adopted(ImportManifest.Entry)
    }

    /// Decide what to do with `item` in `day`'s folder. Adopting writes the manifest.
    public func status(of item: ImportItem, day: String, route: ImportRoute) throws -> Status {
        var m = try manifest(for: day)
        if let e = m.entry(matching: item) { return .already(e) }
        let dir = folder(for: day)
        let target = dir.appendingPathComponent(item.name)
        if let size = fileSize(target) {
            if let want = item.size, want == size {
                let e = entry(file: item.name, item: item, size: size, route: route, captured: item.captured)
                m.files.append(e)
                try write(m)
                return .adopted(e)
            }
            return .new(fileName: freeName(for: item.name, in: dir, manifest: m))
        }
        if m.files.contains(where: { $0.file.caseInsensitiveCompare(item.name) == .orderedSame }) {
            return .new(fileName: freeName(for: item.name, in: dir, manifest: m))
        }
        return .new(fileName: item.name)
    }

    /// Hidden staging path for a download in progress (resumable; same item → same path).
    public func stagingURL(for item: ImportItem) throws -> URL {
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        let safeID = item.id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return incoming.appendingPathComponent("\(safeID)-\(item.size ?? 0)-\(item.name)")
    }

    /// The camera's preview, as `<day>/.thumbs/<name>.jpg`.
    public func saveThumbnail(_ data: Data, for item: ImportItem, day: String) throws -> URL {
        let dir = folder(for: day).appendingPathComponent(".thumbs", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(item.name + ".jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Move a finished download into `day` under `fileName`, then record it. Returns the final URL and entry.
    public func commit(staged: URL, item: ImportItem, fileName: String, day: String, captured: CaptureTime?,
                       route: ImportRoute, camera: String?) throws -> (URL, ImportManifest.Entry) {
        let dir = folder(for: day)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var m = try manifest(for: day)
        var name = fileName
        var dest = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) {
            name = freeName(for: item.name, in: dir, manifest: m)
            dest = dir.appendingPathComponent(name)
        }
        try fm.moveItem(at: staged, to: dest)
        let size = fileSize(dest) ?? 0
        var stamped = item
        stamped.camera = camera ?? item.camera
        var e = entry(file: name, item: stamped, size: size, route: route, captured: captured)
        if let listed = item.size, listed != size { e.listedSize = listed }
        m.files.removeAll { $0.file == name }
        m.files.append(e)
        try write(m)
        return (dest, e)
    }

    // MARK: Helpers

    private func entry(file: String, item: ImportItem, size: Int, route: ImportRoute, captured: CaptureTime?) -> ImportManifest.Entry {
        ImportManifest.Entry(file: file, originalName: item.name, captured: (captured ?? item.captured)?.iso, size: size,
                             route: route.rawValue, importedAt: Self.stamp(), camera: item.camera)
    }

    private func write(_ m: ImportManifest) throws {
        var m = m
        m.files.sort { ($0.captured ?? "", $0.file) < ($1.captured ?? "", $1.file) }
        try fm.createDirectory(at: folder(for: m.day), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(m).write(to: manifestURL(for: m.day), options: .atomic)
    }

    /// "DSCF1802_2.JPG", "_3"… the first name neither on disk nor in the manifest.
    private func freeName(for name: String, in dir: URL, manifest m: ImportManifest) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
            let taken = fm.fileExists(atPath: dir.appendingPathComponent(candidate).path)
                || m.files.contains { $0.file.caseInsensitiveCompare(candidate) == .orderedSame }
            if !taken { return candidate }
            n += 1
        }
    }

    private nonisolated func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    static func stamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// A download streamed to `<destination>.part` and renamed when complete. A run that dies keeps what it got and
/// the next run resumes on a 512-byte boundary. Ported from fuji-bridge FujiBridge/PartFile.swift (MIT, Copyright (c)
/// 2026 Thomas Marchand): "the body is ~40× slower from an unaligned offset" (measured on an X100VI over USB,
/// fuji-bridge docs/DEVELOPMENT.md "Measured on the body").
final class PartialFile {
    let destination: URL
    let partURL: URL
    private let handle: FileHandle
    private(set) var length: Int
    let resumedAt: Int

    init(destination: URL, expected total: Int?) throws {
        self.destination = destination
        partURL = destination.appendingPathExtension("part")
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        if !fm.fileExists(atPath: partURL.path) { fm.createFile(atPath: partURL.path, contents: nil) }
        handle = try FileHandle(forUpdating: partURL)
        let size = Int(try handle.seekToEnd())
        let keep = (total.map { size <= $0 } ?? true) ? size / 512 * 512 : 0
        try handle.truncate(atOffset: UInt64(keep))
        try handle.seek(toOffset: UInt64(keep))
        length = keep
        resumedAt = keep
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        length += data.count
    }

    func truncate(to offset: Int) throws {
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seek(toOffset: UInt64(offset))
        length = offset
    }

    func finish() throws {
        try handle.synchronize()
        try handle.close()
        try FileManager.default.moveItem(at: partURL, to: destination)
    }

    func close() { try? handle.close() }
}

/// Whole-JPEG check: starts FF D8, ends FF D9 (fuji-bridge keeps no JPEG that fails it; "a broken copy … looks like a
/// photo and is not one", fuji-bridge docs/DEVELOPMENT.md).
public enum JPEGCheck {
    public static func isComplete(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 2), head == Data([0xFF, 0xD8]),
              let end = try? h.seekToEnd(), end >= 4 else { return false }
        try? h.seek(toOffset: end - 2)
        return (try? h.read(upToCount: 2)) == Data([0xFF, 0xD9])
    }
}

/// A full-size JPEG must be complete and at least as large as the camera's advertised original.
/// Browse transfers deliberately accept smaller JPEGs; original downloads must not do that.
public enum OriginalJPEG {
    public static func isValid(_ url: URL, expectedSize: Int?) -> Bool {
        guard JPEGCheck.isComplete(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size >= (expectedSize ?? 4) else { return false }
        return true
    }

    /// Download to a private staging file, validate, then publish atomically. An interrupted copy never becomes
    /// an original. Existing valid originals are reused; an invalid old copy is retained under a quarantine name.
    public static func download(_ item: ImportItem, from camera: FujiWifiCamera, to destination: URL) async throws {
        if isValid(destination, expectedSize: item.size) { return }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".original-\(UUID().uuidString).jpg")
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: staging.appendingPathExtension("part"))
        }
        await camera.setPhotoSize(.original)
        do {
            _ = try await camera.download(item, to: staging, progress: { _, _ in })
            try Task.checkCancellation()
            guard isValid(staging, expectedSize: item.size) else {
                throw ImportError.invalid("The full-size photo did not arrive completely. Try downloading it again.")
            }
            if fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: destination, to: destination.appendingPathExtension("incomplete-\(UUID().uuidString)"))
            }
            try fm.moveItem(at: staging, to: destination)
            await camera.setPhotoSize(.resized)
        } catch {
            await camera.setPhotoSize(.resized)
            throw error
        }
    }
}
