// Fujifilm's PTP/IP dialect on the camera's access point, as a `PTPTransport` (so the same card logic serves USB and
// Wi-Fi). iOS + macOS, Network.framework.
//
// Wire format (docs/FUJIFILM-PROTOCOL.md §5; libfuji lib/fuji.c:502-539 + lib/fujiptp.h:421-444, MIT, Copyright (c) 2026
// Daniel Cook; fuji-bridge FujiBridge/Bytes.swift `Packets` + Session.swift `wifiHandshake`, MIT, Copyright (c) 2026
// Thomas Marchand):
// - TCP 192.168.0.1:55740. First packet: Fuji's 82-byte init = u32 0x52, u32 1 (INIT_COMMAND_REQUEST),
//   u32 0x8f53e4f2 (version), 12 GUID bytes 5d48a5ad 0b7fb287 d0ded5d3, then OUR IPv4 address as a u32 LE at 24
//   (192.168.0.2 → 02 00 a8 c0, accepted by an X100VI fw 1.10; libfuji/fuji-bridge send zeros there, which fw 1.32
//   accepted), client name UTF-16LE from offset 28.
// - Reply: u32 length, u32 type: 2 = ACK (camera name UTF-16LE at offset 28), 5 = Init Fail (bodies often fail the
//   first init: send it again; a socket that never answers gets a fresh socket and a fresh init).
// - Wait 50 ms (an OpenSession inside that window gets silence), then OpenSession(1) with transaction id 1.
// - After that every packet is a USB PTP container: u32 len, u16 type (1 cmd, 2 data, 3 resp, 4 event), u16 code,
//   u32 tid, params | payload. SetDevicePropValue's command and data phase go out in one write (no Nagle stall).
// - Goodbye: 08 00 00 00 FF FF FF FF (libfuji fuji.c:52-54), after CloseSession.
// - Deadlines: 8 s connect, 10 s per answer, 30 s per transfer window; a missed deadline cancels the socket, because
//   a socket that missed one answer won't get the next one right (fuji-bridge TCPLink.swift).
import Foundation
@preconcurrency import Network

public enum FujiPTPIP {
    public static let defaultHost = "192.168.0.1"
    public static let commandPort: UInt16 = 55740
    public static let version: UInt32 = 0x8F53_E4F2
    public static let initLength = 82
    /// The init acknowledgement: 68 bytes carrying the fixed responder marker (docs/FUJIFILM-PROTOCOL.md §5.3).
    public static let initAckLength = 68
    public static let cameraGUID = Data([0x08, 0x70, 0xB0, 0x61, 0x0A, 0x8B, 0x45, 0x93,
                                         0xB2, 0xE7, 0x93, 0x57, 0xDD, 0x36, 0xE0, 0x50])
    public static let goodbye = Data([0x08, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])

    /// The 82-byte init. Send the same name here as was written to BLE 85b9163e (fuji-bridge DEVELOPMENT.md), and
    /// our own IPv4 address at 24 as a u32 LE: `localIPv4` is the dotted quad read as one big-endian number
    /// (192.168.0.2 = 0xC0A80002, sent as 02 00 a8 c0). 0 = the zeros libfuji and fuji-bridge send.
    public static func initPacket(clientName: String, localIPv4: UInt32 = 0) -> Data {
        var d = Data(count: initLength)
        func put32(_ v: UInt32, _ o: Int) { for k in 0..<4 { d[o + k] = UInt8(v >> (8 * UInt32(k)) & 0xFF) } }
        put32(0x52, 0)
        put32(1, 4)
        put32(version, 8)
        put32(0x5D48_A5AD, 12)
        put32(0x0B7F_B287, 16)
        put32(0xD0DE_D5D3, 20)
        put32(localIPv4, 24)
        var o = 28
        for unit in clientName.utf16 {
            if o + 4 > initLength { break }              // keep a UTF-16 NUL at the end (fuji-bridge `initCommand`)
            d[o] = UInt8(unit & 0xFF)
            d[o + 1] = UInt8(unit >> 8)
            o += 2
        }
        return d
    }

    /// "192.168.0.2" → 0xC0A80002. Nil for anything but four 0…255 parts.
    public static func ipv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let b = UInt8(p) else { return nil }
            v = v << 8 | UInt32(b)
        }
        return v
    }

    /// 0xC0A80002 → "192.168.0.2".
    public static func ipv4String(_ v: UInt32) -> String {
        [24, 16, 8, 0].map { String(v >> UInt32($0) & 0xFF) }.joined(separator: ".")
    }

    public enum InitReply: Equatable, Sendable {
        case ack(cameraName: String?)
        /// Type 5. `reason` is the u32 after the type when present (e.g. 0x2019 busy).
        case fail(reason: UInt32?)
        case unexpected(type: UInt32)
    }

    public static func parseInitReply(_ p: Data) -> InitReply {
        let b = [UInt8](p)
        guard b.count >= 8 else { return .unexpected(type: 0) }
        let type = LE.u32(b, 4)
        guard Int(LE.u32(b, 0)) == b.count else { return .unexpected(type: type) }
        switch type {
        case 2:
            guard b.count == initAckLength, p.subdata(in: 12..<28) == cameraGUID else {
                return .unexpected(type: type)
            }
            var units: [UInt16] = []
            var o = 28
            while o + 1 < b.count {
                let u = LE.u16(b, o)
                if u == 0 { break }
                units.append(u)
                o += 2
            }
            let name = String(decoding: units, as: UTF16.self)
            return .ack(cameraName: name.isEmpty ? nil : name)
        case 5:
            guard b.count == 12 else { return .unexpected(type: type) }
            return .fail(reason: LE.u32(b, 8))
        default:
            return .unexpected(type: type)
        }
    }
}

public actor FujiPTPIPTransport: PTPTransport {
    public struct Config: Sendable {
        public var host: String
        public var port: UInt16
        /// Shown on the camera; use the same name that was registered over Bluetooth.
        public var clientName: String
        public var connectTimeout: Duration
        public var readTimeout: Duration
        public var initAttempts: Int
        public var settle: Duration
        /// Our IPv4 for the init packet's bytes 24–27. nil (default) = the address the TCP socket is bound to, falling back to this device's address in the camera's /24; "0.0.0.0" = zeros (libfuji/fuji-bridge).
        public var localIP: String?

        public init(host: String = FujiPTPIP.defaultHost, port: UInt16 = FujiPTPIP.commandPort, clientName: String = "Dial In",
                    connectTimeout: Duration = .seconds(8), readTimeout: Duration = .seconds(10), initAttempts: Int = 6,
                    settle: Duration = .milliseconds(50), localIP: String? = nil) {
            self.host = host
            self.port = port
            self.clientName = clientName
            self.connectTimeout = connectTimeout
            self.readTimeout = readTimeout
            self.initAttempts = initAttempts
            self.settle = settle
            self.localIP = localIP
        }
    }

    public let config: Config
    public private(set) var cameraName: String?
    public private(set) var isOpen = false
    /// The IPv4 the last init packet carried at 24–27 (0xC0A80002 = 192.168.0.2; 0 = zeros).
    public private(set) var localIPv4Sent: UInt32 = 0
    private var link: TCPLink?
    private var tid: UInt32 = 0
    private var broken = false
    /// Actors are reentrant across awaits. Reserve the single command socket across the entire exchange.
    private var wireBusy = false
    /// A keepalive holds the wire: a real request waits for it instead of failing as an overlap.
    private var keepaliveOnWire = false
    /// When the last exchange finished (or the session opened).
    private var lastExchange = ContinuousClock.now
    private var generation: UInt64 = 0
    private let log: @Sendable (String) -> Void
    /// Every container in and out, for `--verbose`.
    public var trace: (@Sendable (String) -> Void)?

    public init(config: Config = Config(), log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.config = config
        self.log = log
    }

    public func setTrace(_ t: (@Sendable (String) -> Void)?) { trace = t }

    // MARK: PTPTransport

    /// TCP connect, Fuji init (retried), settle, OpenSession(1) at tid 1. `timeout` caps the connect.
    public func open(timeout: Duration) async throws {
        try Task.checkCancellation()
        if isOpen && !broken { return }
        guard !wireBusy else { throw ImportError.link("another camera connection operation is still finishing") }
        wireBusy = true
        defer { wireBusy = false }
        let openedGeneration = generation
        if broken { closeLink() }
        cameraName = nil
        var acked = false
        var lastFailure = "no answer to the init"
        for attempt in 1...max(1, config.initAttempts) {
            try checkCurrent(openedGeneration)
            let l: TCPLink
            if let existing = link {
                l = existing
            } else {
                l = TCPLink(host: config.host, port: config.port, log: log)
                link = l
                broken = false
                do {
                    try await l.open(timeout: min(timeout, config.connectTimeout), wifiOnly: config.host == FujiPTPIP.defaultHost)
                    try checkCurrent(openedGeneration)
                } catch {
                    l.close()
                    link = nil
                    try checkCurrent(openedGeneration)
                    if error is CancellationError { throw error }
                    if l.localNetworkDenied { throw ImportError.localNetworkDenied }
                    throw ImportError.noCamera(
                        "Couldn't reach the camera at \(config.host):\(config.port) (\(error)). Is this device on the camera's Wi-Fi (FUJIFILM-…)?")
                }
            }
            localIPv4Sent = localIPv4(for: l)
            let packet = FujiPTPIP.initPacket(clientName: config.clientName, localIPv4: localIPv4Sent)
            trace?("OUT init \"\(config.clientName)\" from \(FujiPTPIP.ipv4String(localIPv4Sent)) \(packet.hexString)")
            do {
                try await l.write(packet, timeout: config.readTimeout)
                let reply = try await readPacket(l, timeout: config.readTimeout)
                try checkCurrent(openedGeneration)
                trace?("IN  init reply \(reply.prefix(40).hexString)")
                switch FujiPTPIP.parseInitReply(reply) {
                case .ack(let name):
                    cameraName = name
                    acked = true
                case .fail(let reason):
                    lastFailure = "Init Fail" + (reason.map { " (\(PTP.Response.name(UInt16(truncatingIfNeeded: $0))))" } ?? "")
                    guard reason == UInt32(PTP.Response.deviceBusy) else {
                        l.close()
                        link = nil
                        throw ImportError.refused("Wi-Fi connection", code: UInt16(truncatingIfNeeded: reason ?? 0))
                    }
                    log("camera answered \(lastFailure) (attempt \(attempt)); sending the init again")
                    try await Task.sleep(for: .milliseconds(500))
                case .unexpected(let type):
                    lastFailure = "unexpected init reply type \(type)"
                    log(lastFailure)
                    l.close()
                    link = nil
                }
            } catch {
                // A body just woken over Bluetooth can accept the socket and never answer it (fuji-bridge, X100VI 27 Sept):
                // a fresh socket and a fresh init.
                lastFailure = "\(error)"
                log("no answer to the init (attempt \(attempt)): \(error); opening a new socket")
                l.close()
                link = nil
                try checkCurrent(openedGeneration)
                if error is CancellationError { throw error }
                if let e = error as? ImportError, case .refused = e { throw error }
            }
            if acked { break }
        }
        try checkCurrent(openedGeneration)
        guard acked, let l = link else {
            link?.close()
            link = nil
            throw ImportError.link("the camera didn't accept the connection (\(lastFailure)). If a phone is connected to it, close the Fujifilm app there.")
        }
        do {
            try await Task.sleep(for: config.settle)
            try checkCurrent(openedGeneration)
        } catch {
            closeLink()
            throw error
        }
        // Fuji starts OpenSession at transaction id 1 (libfuji fuji.c:369-372), reset on every new socket.
        tid = 1
        let open = PTPContainer.command(PTP.Op.openSession, transactionID: 1, params: [1]).pack()
        do {
            try await l.write(open, timeout: config.readTimeout)
            let r = try await readResponse(l, transactionID: 1, timeout: config.readTimeout)
            try checkCurrent(openedGeneration)
            guard r.code == PTP.Response.ok || r.code == PTP.Response.sessionAlreadyOpen else {
                throw ImportError.refused("OpenSession", code: r.code)
            }
        } catch is CancellationError {
            closeLink()
            throw CancellationError()
        } catch let e as ImportError {
            closeLink()
            throw e
        } catch {
            closeLink()
            throw ImportError.link("OpenSession: \(error)")
        }
        isOpen = true
        lastExchange = ContinuousClock.now
        log("PTP/IP session open with \(cameraName ?? "the camera") at \(config.host):\(config.port)")
    }

    /// CloseSession and goodbye (libfuji's intentional disconnect), then drop the socket. Skips the niceties on a dead socket.
    public func close() async {
        generation &+= 1
        // A graceful CloseSession must never compete with an in-flight read or handshake. Cancelling that socket
        // also releases its pending callback; the old generation cannot reopen it after this returns.
        if wireBusy { closeLink(); return }
        guard let l = link else { isOpen = false; return }
        wireBusy = true
        defer { wireBusy = false }
        if isOpen && !broken {
            tid &+= 1
            let closingID = tid
            let cmd = PTPContainer.command(PTP.Op.closeSession, transactionID: tid).pack()
            if (try? await l.write(cmd, timeout: .seconds(2))) != nil {
                _ = try? await readResponse(l, transactionID: closingID, timeout: .seconds(2))
            }
            try? await l.write(FujiPTPIP.goodbye, timeout: .seconds(1))
        }
        closeLink()
    }

    /// Keep an idle session warm: one read-only camera-state query (GetDevicePropValue D212, the same poll the
    /// handshake uses) when nothing has crossed the wire for `idle`. Never overlaps a request; a real request that
    /// arrives meanwhile waits for it. Returns false when skipped or failed (a failure marks the link broken, as any
    /// other exchange would, so the importer's next request reconnects).
    @discardableResult
    public func keepAliveIfIdle(_ idle: Duration) async -> Bool {
        guard isOpen, !broken, link != nil, !wireBusy, ContinuousClock.now - lastExchange >= idle else { return false }
        keepaliveOnWire = true
        defer { keepaliveOnWire = false }
        let r = try? await transact(PTP.Op.getDevicePropValue, params: [UInt32(FujiWifiProp.events)], dataOut: nil,
                                    timeout: .seconds(5))
        return r?.isOK == true
    }

    public func transact(_ operation: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult {
        try Task.checkCancellation()
        if wireBusy && keepaliveOnWire {
            // A keepalive holds the socket: wait (bounded) for it rather than failing this real request.
            let deadline = ContinuousClock.now + .seconds(6)
            while wireBusy && keepaliveOnWire && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        guard !wireBusy else { throw ImportError.link("another camera request is still finishing") }
        guard let l = link, isOpen, !broken else { throw ImportError.link("no open Wi-Fi session") }
        wireBusy = true
        defer {
            wireBusy = false
            lastExchange = ContinuousClock.now
        }
        tid &+= 1
        let transactionID = tid
        let wait = timeout ?? config.readTimeout
        var out = PTPContainer.command(operation, transactionID: tid, params: params).pack()
        if let dataOut { out.append(PTPContainer.data(operation, transactionID: tid, payload: dataOut).pack()) }
        trace?(String(format: "OUT 0x%04X tid %u (%@)", operation, tid, params.map { String(format: "%X", $0) }.joined(separator: ",")) + (dataOut.map { " data \($0.prefix(16).hexString)" } ?? ""))
        do {
            try await l.write(out, timeout: wait)
            var data = Data()
            while true {
                let p = try await readPacket(l, timeout: wait)
                try Task.checkCancellation()
                let b = [UInt8](p)
                guard b.count >= 12 else { throw ImportError.link("short container (\(b.count) bytes)") }
                switch LE.u16(b, 4) {
                case PTP.ContainerType.data:
                    guard LE.u32(b, 8) == transactionID, LE.u16(b, 6) == operation else {
                        throw ImportError.link("a photo response belonged to a different camera request")
                    }
                    data.append(p.subdata(in: 12..<p.count))
                case PTP.ContainerType.response:
                    let c = try PTPContainer.unpack(p)
                    guard c.transactionID == transactionID else {
                        throw ImportError.link("a camera response belonged to a different request")
                    }
                    trace?(String(format: "IN  0x%04X %@", operation, PTP.Response.name(c.code)) + (data.isEmpty ? "" : " data \(data.count)B \(data.prefix(16).hexString)"))
                    return PTPResult(code: c.code, params: c.params, data: data)
                case PTP.ContainerType.event:
                    trace?("IN  event \(p.prefix(24).hexString) (ignored)")
                default:
                    throw ImportError.link("unexpected container type \(LE.u16(b, 4))")
                }
            }
        } catch is CancellationError {
            broken = true
            isOpen = false
            l.close()
            throw CancellationError()
        } catch let e as ImportError {
            broken = true
            isOpen = false
            l.close()
            throw e
        } catch let e as TCPLink.Failure {
            broken = true
            isOpen = false
            l.close()
            switch e {
            case .timeout(let what): throw ImportError.timeout(what)
            default: throw ImportError.link(e.description)
            }
        } catch {
            broken = true
            isOpen = false
            l.close()
            throw ImportError.link("\(error)")
        }
    }

    // MARK: Packets

    /// Bytes 24–27 of the init: a fixed `localIP`, else the socket's own local address, else our address next to the
    /// camera, else 0.
    private func localIPv4(for l: TCPLink) -> UInt32 {
        if let fixed = config.localIP { return FujiPTPIP.ipv4(fixed) ?? 0 }
        if let bound = l.localIPv4 { return bound }
        if let near = CameraNetwork.addresses(near: config.host).sorted().first, let v = FujiPTPIP.ipv4(near) { return v }
        return 0
    }

    private func closeLink() {
        link?.close()
        link = nil
        isOpen = false
        broken = false
    }

    private func checkCurrent(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
    }

    private func readPacket(_ l: TCPLink, timeout: Duration) async throws -> Data {
        let head = try await l.read(count: 4, timeout: timeout)
        let length = Int(LE.u32([UInt8](head), 0))
        // Windows are ≤ 8 MB (fuji-bridge's speed test); anything bigger is a framing error.
        guard length >= 8, length <= 0x0090_0000 else { throw ImportError.link("bad packet length \(length)") }
        return head + (try await l.read(count: length - 4, timeout: timeout))
    }

    private func readResponse(_ l: TCPLink, transactionID: UInt32, timeout: Duration) async throws -> PTPContainer {
        while true {
            let p = try await readPacket(l, timeout: timeout)
            let c = try PTPContainer.unpack(p)
            if c.type == PTP.ContainerType.event { continue }
            guard c.type == PTP.ContainerType.response, c.transactionID == transactionID else {
                throw ImportError.link("unexpected response while opening or closing the camera session")
            }
            return c
        }
    }
}

/// TCP with a deadline on every wait. Ported from fuji-bridge FujiBridge/TCPLink.swift (MIT, Copyright (c) 2026 Thomas
/// Marchand): TCP_NODELAY, keepalive, no cellular, and Wi-Fi only for 192.168.0.1 (a Mac on Ethernet to a home router at
/// that address would otherwise reach the router, not the camera).
final class TCPLink: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case timeout(String)
        case closed
        case failed(String)

        var description: String {
            switch self {
            case .timeout(let s): "no answer for too long (\(s))"
            case .closed: "connection closed by the camera"
            case .failed(let s): s
            }
        }
    }

    let host: String
    let port: UInt16
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "co.dialin.camera.tcp")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var buffer = Data()
    private var _localNetworkDenied = false

    var localNetworkDenied: Bool { lock.withLock { _localNetworkDenied } }

    /// The IPv4 address this socket is bound to (0xC0A80002 = 192.168.0.2), once connected.
    var localIPv4: UInt32? {
        guard let c = lock.withLock({ connection }), case .hostPort(let host, _)? = c.currentPath?.localEndpoint,
              case .ipv4(let addr) = host else { return nil }
        let b = [UInt8](addr.rawValue)
        guard b.count == 4 else { return nil }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    init(host: String, port: UInt16, log: @escaping @Sendable (String) -> Void) {
        self.host = host
        self.port = port
        self.log = log
    }

    func open(timeout: Duration, wifiOnly: Bool) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw Failure.failed("bad port \(port)") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(durationSeconds(timeout).rounded(.up)))
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.prohibitedInterfaceTypes = [.cellular]
        if wifiOnly { params.requiredInterfaceType = .wifi }
        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        lock.withLock {
            connection = c
            buffer.removeAll()
        }
        let what = "connecting to \(host):\(port)"
        let _: Void = try await deadline(timeout, what: what, connection: c) { finish in
            c.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .waiting(let error):
                    if c.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        self?.lock.withLock { self?._localNetworkDenied = true }
                        self?.log("waiting: Local Network access denied (or the macOS prompt is still open)")
                    } else {
                        self?.log("waiting: \(error.debugDescription). Is this device on the camera's Wi-Fi?")
                    }
                case .failed(let error):
                    finish(.failure(Failure.failed(error.debugDescription)))
                case .cancelled:
                    finish(.failure(Failure.closed))
                default:
                    break
                }
            }
            c.start(queue: self.queue)
        }
    }

    func close() {
        let c: NWConnection? = lock.withLock {
            let c = connection
            connection = nil
            buffer.removeAll()
            return c
        }
        c?.cancel()
    }

    func write(_ data: Data, timeout: Duration) async throws {
        guard let c = lock.withLock({ connection }) else { throw Failure.closed }
        let _: Void = try await deadline(timeout, what: "sending \(data.count) bytes", connection: c) { finish in
            c.send(content: data, completion: .contentProcessed { error in
                if let error { finish(.failure(Failure.failed(error.debugDescription))) } else { finish(.success(())) }
            })
        }
    }

    func read(count: Int, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        while lock.withLock({ buffer.count }) < count {
            try Task.checkCancellation()
            guard let c = lock.withLock({ connection }) else { throw Failure.closed }
            let want = max(count - lock.withLock({ buffer.count }), 64 * 1024)
            let chunk: Data = try await deadline(timeout, what: "waiting for the camera to answer", connection: c) { finish in
                c.receive(minimumIncompleteLength: 1, maximumLength: min(want, 2 * 1024 * 1024)) { data, _, isComplete, error in
                    if let error {
                        finish(.failure(Failure.failed(error.debugDescription)))
                    } else if let data, !data.isEmpty {
                        finish(.success(data))
                    } else if isComplete {
                        finish(.failure(Failure.closed))
                    } else {
                        finish(.success(Data()))
                    }
                }
            }
            lock.withLock { buffer.append(chunk) }
        }
        return lock.withLock {
            let out = buffer.prefix(count)
            buffer = Data(buffer.dropFirst(count))
            return Data(out)
        }
    }

    /// One Network.framework callback with a deadline; on timeout the connection is cancelled.
    private func deadline<T: Sendable>(_ timeout: Duration, what: String, connection: NWConnection,
                                       _ body: (@escaping @Sendable (Result<T, any Error>) -> Void) -> Void) async throws -> T {
        try Task.checkCancellation()
        let waiter = WirelessCallbackWait<T>()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
                guard waiter.install(cont) else { return }
                queue.asyncAfter(deadline: .now() + durationSeconds(timeout)) {
                    if waiter.finish(.failure(Failure.timeout(what))) { connection.cancel() }
                }
                body { _ = waiter.finish($0) }
            }
        } onCancel: {
            if waiter.finish(.failure(CancellationError())) { connection.cancel() }
        }
        try Task.checkCancellation()
        return result
    }
}

/// Bridges callback APIs without losing cancellation before their continuation is installed. Both the timer and
/// the OS callback may arrive after cancellation; exactly one result resumes the caller.
final class WirelessCallbackWait<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var completed = false
    private var cancelled = false
    /// Only retained when cancellation wins before install. A received photo window must not stay alive until
    /// its timeout callback fires; retaining every completed window would grow memory during a fast import.
    private var completion: Result<T, any Error>?

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(_ c: CheckedContinuation<T, any Error>) -> Bool {
        let prior: Result<T, any Error>? = lock.withLock {
            if let completion {
                self.completion = nil
                return completion
            }
            continuation = c
            return nil
        }
        if let prior { c.resume(with: prior); return false }
        return true
    }

    @discardableResult
    func finish(_ result: Result<T, any Error>) -> Bool {
        let claimed: (Bool, CheckedContinuation<T, any Error>?) = lock.withLock {
            guard !completed else { return (false, nil) }
            completed = true
            if case .failure(let error) = result { cancelled = error is CancellationError }
            let c = continuation
            continuation = nil
            if c == nil { completion = result }
            return (true, c)
        }
        claimed.1?.resume(with: result)
        return claimed.0
    }
}

func durationSeconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
