// The "FUJIFILM's phone app already auto-transferred them" route: find today's X100VI photos in the Photos library (iPhone, or a Mac
// with iCloud Photos) and copy the original resource out with its EXIF intact. iOS + macOS, PhotoKit.
//
// How a photo is recognised: EXIF Make contains FUJIFILM and Model is X100VI, read from the first chunk of the asset's
// own file (PHAssetResourceManager streams it; we stop after 64 KB). Cheap prefilter first: the resource's original
// file name looks like a Fujifilm one (DSCF/_DSF + digits, or .RAF). `deepScan` checks every image of the day instead.
//
// Notes for the app:
// - Info.plist: NSPhotoLibraryUsageDescription. Reading needs .readWrite or .limited access (add-only can't read).
// - FUJIFILM's phone app with "RESIZE IMAGE FOR SMARTPHONE" ON saves ~3 MP copies: same EXIF capture time and camera, fewer bytes.
//   A Photos copy of a photo already imported from the camera (same name and capture second) is skipped; an original
//   imported after its Photos copy is kept too, as DSCF1234_2.JPG (`ImportManifest.entry(matching:)`).
// - Assets that live only in iCloud are downloaded (isNetworkAccessAllowed).
#if canImport(Photos)
import Foundation
@preconcurrency import Photos

public final class PhotoLibrarySource: PhotoSource, @unchecked Sendable {
    public let route = ImportRoute.photos
    /// Check the EXIF of every image of the day, not only Fujifilm-named files.
    public var deepScan: Bool
    public var model: String
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var resources: [String: PHAssetResource] = [:]

    public init(model: String = "X100VI", deepScan: Bool = false, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.model = model
        self.deepScan = deepScan
        self.log = log
    }

    /// Asks for library access if needed. True when this app can read the library.
    public static func authorize() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        return status == .authorized || status == .limited
    }

    /// "DSCF1234.JPG", "_DSF1234.RAF": the names Fujifilm bodies write (phone transfers keep them).
    public static func looksFujifilm(_ name: String) -> Bool {
        let u = name.uppercased()
        if u.hasSuffix(".RAF") { return true }
        for prefix in ["DSCF", "_DSF"] where u.hasPrefix(prefix) {
            return u.dropFirst(prefix.count).prefix(4).allSatisfy(\.isNumber)
        }
        return false
    }

    public func list(hint: ListHint) async throws -> [ImportItem] {
        guard await Self.authorize() else {
            throw ImportError.notAuthorized("No access to the Photos library. Allow it in System Settings / Settings › Privacy › Photos.")
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let since = hint.since, let start = Self.startOfDay(since) {
            options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        }
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var candidates: [(PHAsset, PHAssetResource)] = []
        assets.enumerateObjects { asset, _, _ in
            for r in PHAssetResource.assetResources(for: asset) where [.photo, .alternatePhoto, .fullSizePhoto].contains(r.type) {
                candidates.append((asset, r))
            }
        }
        log("Photos: \(assets.count) images in range, \(candidates.count) resources")
        var out: [ImportItem] = []
        for (asset, r) in candidates {
            guard deepScan || Self.looksFujifilm(r.originalFilename) else { continue }
            let head = await Self.head(of: r, bytes: 65_536)
            let exif = head.flatMap(ExifReader.read)
            let isRAF = r.originalFilename.uppercased().hasSuffix(".RAF")
            guard isRAF || exif.map({ $0.isFujifilm && ($0.model ?? "").replacingOccurrences(of: " ", with: "").uppercased() == model.uppercased() }) == true else { continue }
            let id = "photos:\(asset.localIdentifier):\(r.type.rawValue)"
            lock.withLock { resources[id] = r }
            let captured = exif?.captured ?? asset.creationDate.map { CaptureTime(date: $0) }
            out.append(ImportItem(id: id, name: r.originalFilename, size: nil, captured: captured, camera: exif?.model ?? model))
        }
        log("Photos: \(out.count) \(model) files")
        return out
    }

    public func thumbnail(for item: ImportItem) async throws -> Data? {
        guard let r = resource(item), let head = await Self.head(of: r, bytes: 65_536) else { return nil }
        return ExifReader.read(head)?.thumbnail
    }

    public func read(_ item: ImportItem, offset: Int, length: Int) async throws -> Data? {
        guard offset == 0, let r = resource(item) else { return nil }
        return await Self.head(of: r, bytes: length)
    }

    public func download(_ item: ImportItem, to destination: URL, progress: @escaping @Sendable (Int, Int?) -> Void) async throws -> Int {
        guard let r = resource(item) else { throw ImportError.invalid("\(item.name) isn't in this listing") }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: r, toFile: destination, options: opts)
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        progress(size, size)
        return size
    }

    public func close() async {}

    private func resource(_ item: ImportItem) -> PHAssetResource? { lock.withLock { resources[item.id] } }

    /// First `bytes` of a resource, then the request is cancelled.
    static func head(of r: PHAssetResource, bytes: Int) async -> Data? {
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        let mgr = PHAssetResourceManager.default()
        let acc = HeadAccumulator(limit: bytes)
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            var requestID: PHAssetResourceDataRequestID = 0
            requestID = mgr.requestData(for: r, options: opts, dataReceivedHandler: { chunk in
                if acc.add(chunk) {
                    mgr.cancelDataRequest(requestID)
                    if let d = acc.finish() { cont.resume(returning: d) }
                }
            }, completionHandler: { _ in
                if let d = acc.finish() { cont.resume(returning: d.isEmpty ? nil : d) }
            })
        }
    }

    static func startOfDay(_ day: String) -> Date? {
        let f = day.split(separator: "-").compactMap { Int($0) }
        guard f.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: f[0], month: f[1], day: f[2]))
    }
}

/// Collects chunks until `limit`, then hands the bytes out exactly once.
private final class HeadAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var done = false
    let limit: Int

    init(limit: Int) { self.limit = limit }

    /// True once enough has arrived.
    func add(_ chunk: Data) -> Bool {
        lock.withLock {
            data.append(chunk)
            return data.count >= limit
        }
    }

    /// The bytes, the first time only.
    func finish() -> Data? {
        lock.withLock {
            if done { return nil }
            done = true
            return data.prefix(limit)
        }
    }
}
#endif
