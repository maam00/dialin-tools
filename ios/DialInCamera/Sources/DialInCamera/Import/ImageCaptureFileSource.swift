// USB import, camera in CONNECTION MODE › USB CARD READER: ImageCaptureCore's own file catalog and download (the path
// Photos and Image Capture.app use). macOS and iPhone/iPad with USB-C.
//
// The X100VI in card-reader mode is a PTP camera whose catalog is the SD card; ImageCaptureCore lists it first
// (~32 s for 1771 files on an X100VI, fuji-bridge docs/DEVELOPMENT.md "USB import"), then serves each file.
// Alternative on the same cable: `PTPCardSource` over `ImageCaptureTransport` (raw GetObjectHandles/GetPartialObject,
// what fuji-bridge measured at ~22 MB/s on the Mac with an X100VI); `dialin-cam import-usb --ptp`.
//
// iOS: an app must call requestContentsAuthorization (iOS 14+) before reading a camera's files; the system asks the
// user once. Compiled for iOS, not yet run on a phone.
#if canImport(ImageCaptureCore)
import Foundation
@preconcurrency import ImageCaptureCore

@MainActor
public final class ImageCaptureFileSource: PhotoSource {
    public nonisolated let route = ImportRoute.usb
    /// How long to wait for the camera to show up.
    public var deviceTimeout: Duration
    /// How long to let ImageCaptureCore finish listing the card (go ahead with what's listed after that).
    public var catalogTimeout: Duration
    public var trace: (@Sendable (String) -> Void)?
    public private(set) var cameraName: String?
    /// False when `catalogTimeout` ran out first: the listing may be missing files (ImageCaptureCore's order isn't
    /// promised, so today's could be among them). `PTPCardSource` over `ImageCaptureTransport` asks the camera directly.
    public var catalogComplete: Bool { catalogReady }

    private let browser = ICDeviceBrowser()
    private var proxy: FileSourceProxy?
    private var camera: ICCameraDevice?
    private var files: [String: ICCameraFile] = [:]
    private var started = false
    private var sessionOpen = false
    private var catalogReady = false
    private let deviceSignal = MainSignal()
    private let readySignal = MainSignal()
    private var others: [String] = []

    public init(deviceTimeout: Duration = .seconds(60), catalogTimeout: Duration = .seconds(120)) {
        self.deviceTimeout = deviceTimeout
        self.catalogTimeout = catalogTimeout
    }

    /// Find the Fujifilm camera, open a session, wait for the catalog.
    public func connect() async throws {
        if !started {
            started = true
            let p = FileSourceProxy(owner: self)
            proxy = p
            browser.delegate = p
            let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
            browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
            browser.start()
            emit("browsing for USB cameras")
        }
        if camera == nil { _ = await deviceSignal.wait(timeout: deviceTimeout) }
        guard let camera else {
            let seen = others.isEmpty ? "" : " (saw only: \(others.joined(separator: ", ")))"
            throw ImportError.noCamera(
                "No Fujifilm camera on USB\(seen). Camera on, CONNECTION MODE › USB CARD READER, USB POWER SUPPLY/COMM SETTING › AUTO, and a data cable (not charge-only).")
        }
        #if os(iOS)
        if browser.contentsAuthorizationStatus != .authorized {
            let status = await withCheckedContinuation { (cont: CheckedContinuation<ICAuthorizationStatus, Never>) in
                browser.requestContentsAuthorization { @Sendable s in cont.resume(returning: s) }
            }
            guard status == .authorized else { throw ImportError.notAuthorized("Allow Dial In to read the camera's photos (Settings › Privacy).") }
        }
        #endif
        if !sessionOpen {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let once = OnceFlag()
                camera.requestOpenSession(options: [:]) { @Sendable error in
                    guard once.claim() else { return }
                    if let error { cont.resume(throwing: ImportError.link("couldn't open a USB session: \(error.localizedDescription)")) } else { cont.resume() }
                }
                Task {
                    try? await Task.sleep(for: .seconds(20))
                    if once.claim() { cont.resume(throwing: ImportError.timeout("opening the USB session")) }
                }
            }
            sessionOpen = true
            emit("session open on \(camera.name ?? "camera")")
        }
        if !catalogReady {
            let t0 = ContinuousClock.now
            let progress = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, let cam = self.camera, !self.catalogReady else { return }
                    self.emit("camera still listing its card: \(cam.contentCatalogPercentCompleted)% (\(cam.mediaFiles?.count ?? 0) files so far)")
                }
            }
            let ready = await readySignal.wait(timeout: catalogTimeout)
            progress.cancel()
            emit(ready ? "card listed in \(ContinuousClock.now - t0)" : "card still listing after \(catalogTimeout); going ahead with \(camera.mediaFiles?.count ?? 0) files")
        }
    }

    // MARK: PhotoSource

    public func list(hint: ListHint) async throws -> [ImportItem] {
        if camera == nil || !sessionOpen { try await connect() }
        guard let camera else { throw ImportError.noCamera("The camera went away.") }
        var out: [ImportItem] = []
        var seen = Set<ObjectIdentifier>()
        func add(_ f: ICCameraFile) {
            guard seen.insert(ObjectIdentifier(f)).inserted, let name = f.name, !name.isEmpty else { return }
            let id = "icc:\(f.ptpObjectHandle):\(name)"
            files[id] = f
            let date = f.exifCreationDate ?? f.creationDate ?? f.fileCreationDate
            out.append(ImportItem(id: id, name: name, size: f.fileSize > 0 ? Int(f.fileSize) : nil,
                                  captured: date.map { CaptureTime(date: $0) }, camera: cameraName))
        }
        for item in camera.mediaFiles ?? [] {
            guard let f = item as? ICCameraFile else { continue }
            add(f)
            // A RAF shot with a JPEG may hang off the JPEG instead of being listed on its own.
            if let raw = f.pairedRawImage { add(raw) }
        }
        emit("ImageCaptureCore lists \(out.count) files")
        return out
    }

    public func thumbnail(for item: ImportItem) async throws -> Data? {
        let f = try file(item)
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            // A missing preview never stops the import.
            f.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 320]) { @Sendable data, error in
                cont.resume(returning: error == nil ? data : nil)
            }
        }
    }

    public func read(_ item: ImportItem, offset: Int, length: Int) async throws -> Data? {
        let f = try file(item)
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            f.requestReadData(atOffset: off_t(offset), length: off_t(length)) { @Sendable data, error in
                cont.resume(returning: error == nil ? data : nil)
            }
        }
    }

    public func download(_ item: ImportItem, to destination: URL, progress: @escaping @Sendable (Int, Int?) -> Void) async throws -> Int {
        let f = try file(item)
        let dir = destination.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: dir,
            .saveAsFilename: destination.lastPathComponent,
            .overwrite: true,
            // Copy only: never let ImageCaptureCore remove the photo from the card after the download.
            .deleteAfterSuccessfulDownload: false,
        ]
        // Generous: 25 MB JPEGs / 50 MB RAFs at USB speeds take a second or two; a stuck request shouldn't hang forever.
        let limit = Duration.seconds(60 + (item.size ?? 0) / 1_000_000)
        let saved: String = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
            let once = OnceFlag()
            let box = UncheckedBox(options)
            _ = f.requestDownload(options: box.value) { @Sendable filename, error in
                guard once.claim() else { return }
                if let error {
                    // One file failing is reported and skipped; an unplugged camera shows up as a timeout or on the next file.
                    cont.resume(throwing: ImportError.incomplete("download of \(item.name) failed: \(error.localizedDescription)"))
                } else {
                    cont.resume(returning: filename ?? destination.lastPathComponent)
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.claim() { cont.resume(throwing: ImportError.timeout("downloading \(item.name) over USB")) }
            }
        }
        let landed = dir.appendingPathComponent(saved)
        if landed.standardizedFileURL != destination.standardizedFileURL {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: landed, to: destination)
        }
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        progress(size, item.size)
        return size
    }

    public func close() async {
        guard let camera, sessionOpen else { return }
        sessionOpen = false
        catalogReady = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            camera.requestCloseSession(options: [:]) { @Sendable _ in if once.claim() { cont.resume() } }
            Task {
                try? await Task.sleep(for: .seconds(5))
                if once.claim() { cont.resume() }
            }
        }
        emit("USB session closed")
    }

    // MARK: Internals

    private func file(_ item: ImportItem) throws -> ICCameraFile {
        guard let f = files[item.id] else { throw ImportError.invalid("\(item.name) isn't on this camera's list") }
        return f
    }

    fileprivate func deviceAdded(_ device: ICDevice) {
        guard camera == nil, let found = device as? ICCameraDevice else { return }
        let name = found.name ?? "camera"
        let fuji = Int(found.usbVendorID) == PTP.fujifilmVendorID
            || name.uppercased().contains("FUJIFILM") || name.uppercased().contains("X100")
        guard fuji else {
            // Never import from an iPhone or another camera that happens to be plugged in.
            others.append(name)
            emit("ignoring \(name) (vendor 0x\(String(found.usbVendorID, radix: 16)))")
            return
        }
        camera = found
        cameraName = found.name
        found.delegate = proxy
        emit("found \(name) (vendor 0x\(String(found.usbVendorID, radix: 16)) product 0x\(String(found.usbProductID, radix: 16)))")
        deviceSignal.fireAll()
    }

    fileprivate func deviceRemoved(_ device: ICDevice) {
        guard let camera, device == camera else { return }
        emit("camera unplugged")
        self.camera = nil
        sessionOpen = false
        catalogReady = false
        files = [:]
        readySignal.fireAll()
    }

    fileprivate func catalogComplete(_ device: ICDevice) {
        guard let camera, device == camera else { return }
        catalogReady = true
        readySignal.fireAll()
    }

    private func emit(_ s: String) { trace?("usb: " + s) }
}

private final class FileSourceProxy: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, @unchecked Sendable {
    weak var owner: ImageCaptureFileSource?

    init(owner: ImageCaptureFileSource) { self.owner = owner }

    private func hop(_ device: ICDevice, _ body: @escaping @MainActor (ImageCaptureFileSource, ICDevice) -> Void) {
        let box = UncheckedBox(device)
        let owner = owner
        Task { @MainActor in
            guard let owner else { return }
            body(owner, box.value)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) { hop(device) { $0.deviceAdded($1) } }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) { hop(device) { $0.deviceRemoved($1) } }
    func didRemove(_ device: ICDevice) { hop(device) { $0.deviceRemoved($1) } }
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) { hop(device) { $0.catalogComplete($1) } }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
#endif
