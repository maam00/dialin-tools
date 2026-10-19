// A folder on disk as a source: the SD card in a reader (/Volumes/…/DCIM), or files Image Capture.app / AirDrop already
// copied somewhere. Same library, manifest and dedupe as the camera routes. Platform-neutral.
import Foundation

public final class FolderSource: PhotoSource, @unchecked Sendable {
    public let route = ImportRoute.folder
    public let root: URL
    private let lock = NSLock()
    private var paths: [String: URL] = [:]

    public init(root: URL) { self.root = root }

    public func list(hint: ListHint) async throws -> [ImportItem] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.invalid("\(root.path) isn't a folder")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [ImportItem] = []
        while let url = walker.nextObject() as? URL {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true, ImportFileKind(filename: url.lastPathComponent) != .other else { continue }
            let id = "file:" + url.path
            lock.withLock { paths[id] = url }
            var captured: CaptureTime?
            var model: String?
            if let h = try? FileHandle(forReadingFrom: url) {
                let head = (try? h.read(upToCount: 65_536)) ?? Data()
                var exif = ExifReader.read(head)
                if exif == nil, let range = ExifReader.rafEmbeddedJPEG(head) {
                    try? h.seek(toOffset: UInt64(range.lowerBound))
                    exif = (try? h.read(upToCount: min(65_536, range.count))).flatMap(ExifReader.read)
                }
                try? h.close()
                captured = exif?.captured
                model = exif?.model
            }
            // Cameras stamp the file time with the capture time (local wall clock); good enough for HEIF/MOV.
            if captured == nil, let m = v?.contentModificationDate { captured = CaptureTime(date: m) }
            out.append(ImportItem(id: id, name: url.lastPathComponent, size: v?.fileSize, captured: captured, camera: model))
        }
        return out
    }

    public func thumbnail(for item: ImportItem) async throws -> Data? {
        guard let url = url(item), let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        return (try? h.read(upToCount: 65_536)).flatMap(ExifReader.read)?.thumbnail
    }

    public func read(_ item: ImportItem, offset: Int, length: Int) async throws -> Data? {
        guard let url = url(item), let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        return try h.read(upToCount: length)
    }

    public func download(_ item: ImportItem, to destination: URL, progress: @escaping @Sendable (Int, Int?) -> Void) async throws -> Int {
        guard let url = url(item) else { throw ImportError.invalid("\(item.name) isn't in this listing") }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: url, to: destination)
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        progress(size, item.size)
        return size
    }

    public func close() async {}

    private func url(_ item: ImportItem) -> URL? { lock.withLock { paths[item.id] } }
}
