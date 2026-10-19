// PTP over USB through ImageCaptureCore, on iPhone/iPad (USB-C) and on the Mac.
//
// Pattern from Th0rgal/fuji-bridge FujiBridge/USBLink.swift (MIT, Copyright (c) 2026 Thomas Marchand), built and
// run against an X100VI: ICDeviceBrowser → (iOS) requestControlAuthorization → requestOpenSession → wait for the
// content catalog → requestSendPTPCommand with a 12-byte command container; the response code is at bytes 6–7 of
// the response container ImageCaptureCore hands back.
//
// On macOS this goes through ptpcamerad, so unlike libusb it doesn't fight the system for the device: do NOT
// `killall ptpcamerad` before using it.
import Foundation
@preconcurrency import ImageCaptureCore

@MainActor
public final class ImageCaptureTransport: PTPTransport {
    /// How long to let ImageCaptureCore finish listing the camera before sending commands. In USB RAW CONV. mode
    /// the card is hidden, so this should be quick; fuji-bridge waited up to 60 s in card mode (1771 files ≈ 32 s).
    public var catalogTimeout: Duration
    /// Default per-command timeout.
    public var commandTimeout: Duration
    /// Every step and PTP transaction, for debugging (`dialin-cam --verbose`).
    public var trace: (@Sendable (String) -> Void)?

    public private(set) var cameraName: String?
    public private(set) var usbProductID: Int?
    public var hasCamera: Bool { camera != nil }

    private let browser = ICDeviceBrowser()
    private var proxy: ICCDelegateProxy?
    private var camera: ICCameraDevice?
    private var sessionOpen = false
    private var catalogReady = false
    private var started = false
    private let deviceSignal = MainSignal()
    private let readySignal = MainSignal()
    private var transactionID: UInt32 = 0

    public init(catalogTimeout: Duration = .seconds(15), commandTimeout: Duration = .seconds(10)) {
        self.catalogTimeout = catalogTimeout
        self.commandTimeout = commandTimeout
    }

    /// Start listening for cameras (also done by `open`). Call early so the UI can show "camera found".
    public func startBrowsing() {
        guard !started else { return }
        started = true
        let proxy = ICCDelegateProxy(owner: self)
        self.proxy = proxy
        browser.delegate = proxy
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
        emit("browsing for USB cameras (vendor 0x04CB)")
    }

    // MARK: PTPTransport

    public func open(timeout: Duration) async throws {
        startBrowsing()
        if camera == nil {
            emit("waiting up to \(timeout) for a Fujifilm camera")
            _ = await deviceSignal.wait(timeout: timeout)
        }
        guard let camera else { throw CameraError.noCamera }
        #if os(iOS)
        // iPhone and iPad ask the user once before an app may send commands to a camera.
        if browser.controlAuthorizationStatus != .authorized {
            emit("requesting camera control authorization")
            let status = await withCheckedContinuation { (cont: CheckedContinuation<ICAuthorizationStatus, Never>) in
                browser.requestControlAuthorization { @Sendable status in cont.resume(returning: status) }
            }
            guard status == .authorized else { throw CameraError.notAuthorized }
        }
        #endif
        if !sessionOpen {
            let started = ContinuousClock.now
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let once = OnceFlag()
                camera.requestOpenSession(options: [:]) { @Sendable error in
                    guard once.claim() else { return }
                    if let error {
                        cont.resume(throwing: CameraError.transport("Couldn't open a USB session: \(error.localizedDescription)"))
                    } else {
                        cont.resume()
                    }
                }
                Task {
                    try? await Task.sleep(for: .seconds(20))
                    if once.claim() { cont.resume(throwing: CameraError.timeout("opening the USB session")) }
                }
            }
            sessionOpen = true
            emit("session open on \(camera.name ?? "camera") in \(ContinuousClock.now - started)")
        }
        if !catalogReady {
            let ready = await readySignal.wait(timeout: catalogTimeout)
            emit(ready ? "catalog ready" : "catalog still loading after \(catalogTimeout); going ahead")
        }
    }

    public func close() async {
        guard let camera, sessionOpen else { return }
        sessionOpen = false
        catalogReady = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            camera.requestCloseSession(options: [:]) { @Sendable _ in
                if once.claim() { cont.resume() }
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                if once.claim() { cont.resume() }
            }
        }
        emit("session closed")
    }

    public func transact(_ operation: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult {
        guard let camera else { throw CameraError.disconnected("camera unplugged") }
        guard sessionOpen else { throw CameraError.disconnected("no open session") }
        transactionID &+= 1
        let command = PTPContainer.command(operation, transactionID: transactionID, params: params).pack()
        let limit = timeout ?? commandTimeout
        let opName = String(format: "0x%04X", operation)
        let (data, response): (Data, Data) = try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            camera.requestSendPTPCommand(command, outData: dataOut) { @Sendable (data: Data, response: Data, error: (any Error)?) in
                guard once.claim() else { return }
                if let error {
                    cont.resume(throwing: CameraError.transport("PTP \(opName) failed: \(error.localizedDescription)"))
                } else {
                    cont.resume(returning: (data, response))
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.claim() { cont.resume(throwing: CameraError.timeout("PTP \(opName) after \(limit)")) }
            }
        }
        let r = [UInt8](response)
        let result: PTPResult
        if r.count >= 8 {
            var rp: [UInt32] = []
            var off = PTPContainer.headerSize
            while off + 4 <= r.count && rp.count < 5 {
                rp.append(LE.u32(r, off))
                off += 4
            }
            result = PTPResult(code: LE.u16(r, 6), params: rp, data: data)
        } else {
            result = PTPResult(code: PTP.Response.ok, data: data, responseMissing: true)
        }
        if let trace {
            let p = params.map { String(format: "%X", $0) }.joined(separator: ",")
            trace("PTP \(opName)(\(p))" + (dataOut.map { " out \($0.count)B \($0.prefix(24).hexString)" } ?? "")
                + " → \(PTP.Response.name(result.code))" + (data.isEmpty ? "" : " in \(data.count)B \(data.prefix(24).hexString)"))
        }
        return result
    }

    // MARK: Delegate events (hopped to the main actor by the proxy)

    fileprivate func deviceAdded(_ device: ICDevice) {
        guard camera == nil, let found = device as? ICCameraDevice else { return }
        guard Int(found.usbVendorID) == PTP.fujifilmVendorID else {
            emit("ignoring non-Fujifilm camera \(found.name ?? "?") (vendor 0x\(String(found.usbVendorID, radix: 16)))")
            return
        }
        camera = found
        cameraName = found.name
        usbProductID = Int(found.usbProductID)
        found.delegate = proxy
        emit("found \(found.name ?? "Fujifilm") (PID 0x\(String(found.usbProductID, radix: 16)), transport \(found.transportType ?? "?"))")
        deviceSignal.fireAll()
    }

    fileprivate func deviceRemoved(_ device: ICDevice) {
        guard let camera, device == camera else { return }
        emit("camera removed")
        self.camera = nil
        cameraName = nil
        usbProductID = nil
        sessionOpen = false
        catalogReady = false
        readySignal.fireAll()
    }

    fileprivate func sessionClosed(_ device: ICDevice, _ error: (any Error)?) {
        guard let camera, device == camera else { return }
        sessionOpen = false
        catalogReady = false
        emit("session closed by ImageCaptureCore" + (error.map { " (\($0.localizedDescription))" } ?? ""))
    }

    fileprivate func catalogComplete(_ device: ICDevice) {
        guard let camera, device == camera else { return }
        catalogReady = true
        readySignal.fireAll()
    }

    private func emit(_ line: String) { trace?("usb: " + line) }
}

/// ImageCaptureCore delegate callbacks, forwarded to the transport on the main actor. A separate NSObject so the
/// transport can stay a plain @MainActor class, and so a callback on an unexpected thread can't trip Swift 6's
/// isolation checks.
private final class ICCDelegateProxy: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, @unchecked Sendable {
    weak var owner: ImageCaptureTransport?

    init(owner: ImageCaptureTransport) { self.owner = owner }

    private func hop(_ device: ICDevice, _ body: @escaping @MainActor (ImageCaptureTransport, ICDevice) -> Void) {
        let box = UncheckedBox(device)
        let owner = owner
        Task { @MainActor in
            guard let owner else { return }
            body(owner, box.value)
        }
    }

    // ICDeviceBrowserDelegate
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        hop(device) { $0.deviceAdded($1) }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        hop(device) { $0.deviceRemoved($1) }
    }

    // ICDeviceDelegate
    func didRemove(_ device: ICDevice) { hop(device) { $0.deviceRemoved($1) } }
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        let message = error.map { UncheckedBox($0 as any Error) }
        hop(device) { owner, dev in owner.sessionClosed(dev, message?.value) }
    }

    // ICCameraDeviceDelegate
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

/// Carries a non-Sendable ImageCaptureCore object across the hop to the main actor (it is only used there).
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// One-shot waiters on the main actor: `wait` returns true when fired, false on timeout.
@MainActor
final class MainSignal {
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func wait(timeout: Duration) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            waiters[id] = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(id, false)
            }
        }
    }

    func fireAll() {
        let all = waiters
        waiters.removeAll()
        for c in all.values { c.resume(returning: true) }
    }

    private func resume(_ id: UUID, _ value: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: value)
    }
}
