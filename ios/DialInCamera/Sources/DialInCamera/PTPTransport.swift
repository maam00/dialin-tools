// The seam between the Fuji logic and the wire. `ImageCaptureTransport` is the real one (iOS + macOS);
// tests use a fake camera.
import Foundation
import Synchronization

/// What came back from one PTP transaction.
public struct PTPResult: Sendable, Equatable {
    /// Response code (0x2001 = OK).
    public var code: UInt16
    /// Response parameters.
    public var params: [UInt32]
    /// Data-in phase (empty when the camera sent none).
    public var data: Data
    /// True when the transport got no response container and assumed OK (ImageCaptureCore can do this;
    /// read-back verification is the safety net).
    public var responseMissing: Bool

    public init(code: UInt16, params: [UInt32] = [], data: Data = Data(), responseMissing: Bool = false) {
        self.code = code
        self.params = params
        self.data = data
        self.responseMissing = responseMissing
    }

    public var isOK: Bool { code == PTP.Response.ok }
}

/// One PTP conversation with one camera.
///
/// `open` finds the camera and leaves a PTP session open (ImageCaptureCore opens the session itself, so callers
/// never send OpenSession/CloseSession through `transact`). Transactions are strictly one at a time.
public protocol PTPTransport: AnyObject, Sendable {
    /// Wait up to `timeout` for a Fujifilm camera, then open a session on it.
    func open(timeout: Duration) async throws
    /// Close the session (best effort).
    func close() async
    /// One transaction: command (+ optional data-out phase), then data-in (if any) and the response.
    func transact(_ operation: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult
}

extension PTPTransport {
    /// Command with an optional data phase from the camera (GetDevicePropValue, GetObject, …).
    public func command(_ operation: UInt16, _ params: [UInt32] = [], timeout: Duration? = nil) async throws -> PTPResult {
        try await transact(operation, params: params, dataOut: nil, timeout: timeout)
    }

    /// Command followed by a data phase from us (SetDevicePropValue, SendObject, …).
    public func command(_ operation: UInt16, _ params: [UInt32] = [], sending data: Data, timeout: Duration? = nil) async throws -> PTPResult {
        try await transact(operation, params: params, dataOut: data, timeout: timeout)
    }
}

/// Everything that can go wrong talking to the camera, in words the app can show.
public enum CameraError: Error, Equatable, CustomStringConvertible, Sendable {
    /// No Fujifilm camera appeared on USB.
    case noCamera
    /// Camera found, but it isn't in USB RAW CONV./BACKUP RESTORE mode (no slot editing over USB).
    case needsUSBMode(String)
    /// The user (iOS) declined camera control.
    case notAuthorized
    /// The camera went away or the session dropped.
    case disconnected(String)
    /// No answer within the timeout.
    case timeout(String)
    /// The camera answered a required step with an error code.
    case refused(String, code: UInt16)
    /// Bad input (slot out of range, too many looks, bad backup file …).
    case invalid(String)
    /// A transport-level failure.
    case transport(String)

    public var description: String {
        switch self {
        case .noCamera:
            "No Fujifilm camera on USB. Turn it on, set CONNECTION MODE to USB RAW CONV./BACKUP RESTORE, and plug it in with a data cable."
        case .needsUSBMode(let detail):
            "The camera isn't in USB RAW CONV./BACKUP RESTORE mode, so its custom slots can't be edited. MENU › NETWORK/USB SETTING › CONNECTION MODE › USB RAW CONV./BACKUP RESTORE. (\(detail))"
        case .notAuthorized:
            "This app isn't allowed to control the camera. Allow it when asked, or in Settings."
        case .disconnected(let why): "The camera disconnected (\(why))."
        case .timeout(let what): "The camera didn't answer (\(what))."
        case .refused(let what, let code): "The camera refused \(what) (\(PTP.Response.name(code)))."
        case .invalid(let what): what
        case .transport(let what): what
        }
    }

    /// Short reason for `CameraLinkState.failed`.
    public var reason: String { description }
}

/// Resumes a continuation at most once (completion vs timeout races).
final class OnceFlag: Sendable {
    private let done = Mutex(false)
    func claim() -> Bool { done.withLock { d in if d { return false }; d = true; return true } }
}
