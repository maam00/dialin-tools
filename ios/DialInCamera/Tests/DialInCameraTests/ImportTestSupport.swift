// Shared fakes for the import tests: a temp library, a USB card behind a fake PTPTransport (standard ObjectInfo, as an
// X100VI answers over USB through ImageCaptureCore per fuji-bridge docs/DEVELOPMENT.md "Measured on the body"), and a
// scripted PhotoSource.
import Foundation
import Synchronization
@testable import DialInCamera

enum TempDir {
    static func make(_ label: String = "import") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dialin-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// An X100VI in USB CARD READER mode behind ImageCaptureCore, at the PTP level: GetObjectHandles lists a DCIM folder
/// association and the files; ObjectInfo is ISO 15740 (size at 8, PTP strings from 52); GetPartialObject serves slices,
/// optionally shorter than asked once (to exercise the 512-byte realignment).
final class FakeUSBCard: PTPTransport, @unchecked Sendable {
    struct File {
        var handle: UInt32
        var name: String
        var data: Data
        var date: String
        var folder = false
    }

    let files: [File]
    private let lock = NSLock()
    private var _log: [(op: UInt16, params: [UInt32])] = []
    /// Next GetPartialObject answers only this many bytes.
    var shortOnce: Int?

    init(files: [File]) { self.files = files }

    var log: [(op: UInt16, params: [UInt32])] { lock.withLock { _log } }

    func open(timeout: Duration) async throws {}
    func close() async {}

    func transact(_ op: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult {
        lock.withLock { _log.append((op, params)) }
        let p0 = params.first ?? 0
        switch op {
        case PTP.Op.getObjectHandles:
            return PTPResult(code: PTP.Response.ok, data: FujiArray.encode(files.map(\.handle)))
        case PTP.Op.getObjectInfo:
            guard let f = files.first(where: { $0.handle == p0 }) else { return PTPResult(code: PTP.Response.invalidObjectHandle) }
            return PTPResult(code: PTP.Response.ok, data: PTPObjectInfo.encode(layout: .standard, format: f.folder ? 0x3001 : 0x3801,
                                                                             size: f.folder ? 0 : f.data.count, filename: f.name, captureDate: f.date))
        case PTP.Op.getThumb:
            return PTPResult(code: PTP.Response.ok, data: SyntheticJPEG.make(dateTimeOriginal: "2000:01:01 00:00:00", payloadBytes: 200))
        case PTP.Op.getPartialObject:
            guard let f = files.first(where: { $0.handle == p0 }), params.count >= 3 else { return PTPResult(code: PTP.Response.invalidObjectHandle) }
            let off = Int(params[1])
            var len = Int(params[2])
            lock.withLock {
                if let s = shortOnce { len = min(len, s); shortOnce = nil }
            }
            let slice = off < f.data.count ? f.data.subdata(in: off..<min(off + len, f.data.count)) : Data()
            return PTPResult(code: PTP.Response.ok, data: slice)
        default:
            return PTPResult(code: PTP.Response.operationNotSupported)
        }
    }
}

/// A source whose listing the test writes, files served from memory.
final class ScriptedSource: PhotoSource, @unchecked Sendable {
    let route: ImportRoute
    var items: [ImportItem]
    var bodies: [String: Data]
    private let lock = NSLock()
    private var _reads: [(String, Int, Int)] = []

    init(route: ImportRoute = .folder, items: [ImportItem], bodies: [String: Data]) {
        self.route = route
        self.items = items
        self.bodies = bodies
    }

    var reads: [(String, Int, Int)] { lock.withLock { _reads } }

    func list(hint: ListHint) async throws -> [ImportItem] { items }
    func thumbnail(for item: ImportItem) async throws -> Data? { nil }
    func read(_ item: ImportItem, offset: Int, length: Int) async throws -> Data? {
        lock.withLock { _reads.append((item.id, offset, length)) }
        guard let d = bodies[item.id], offset < d.count else { return nil }
        return d.subdata(in: offset..<min(offset + length, d.count))
    }
    func download(_ item: ImportItem, to destination: URL, progress: @escaping @Sendable (Int, Int?) -> Void) async throws -> Int {
        guard let d = bodies[item.id] else { throw ImportError.invalid("no body") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: destination)
        return d.count
    }
    func close() async {}
}

/// Collects importer events.
final class EventBox: Sendable {
    private let all = Mutex<[ImportEvent]>([])
    func add(_ e: ImportEvent) { all.withLock { $0.append(e) } }
    var events: [ImportEvent] { all.withLock { $0 } }
}

func exifDate(_ day: String, _ time: String = "12:00:00") -> String { day.replacingOccurrences(of: "-", with: ":") + " " + time }
func ptpDate(_ day: String, _ time: String = "120000") -> String { day.replacingOccurrences(of: "-", with: "") + "T" + time }
