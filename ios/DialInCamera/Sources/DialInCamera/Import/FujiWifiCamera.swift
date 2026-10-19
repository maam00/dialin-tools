// The X100VI's photos over its own Wi-Fi: PTP/IP session, "press OK" wait, gallery mode, card listing, and a
// reconnect that resumes a file where the socket died. A `PhotoSource`, so `PhotoImporter` drives it like USB.
//
// Sequence (fuji-bridge FujiBridge/Session.swift `wifiHandshake` + `gallery` + `IO.reopen`, MIT, Copyright (c) 2026
// Thomas Marchand, run against an X100VI fw 1.32; libfuji lib/fuji.c `fuji_setup` + its gallery setup, MIT,
// Copyright (c) 2026 Daniel Cook):
//  1. init / settle / OpenSession: `FujiPTPIPTransport.open`.
//  2. Poll GetDevicePropValue(D212) until DF00 ≠ 0. DF00 = 0 means the rear screen is asking for OK.
//  3. Read DF22, DF25, DF21, DF24 (version props).
//  4. DF01 = 20 (gallery). Newer bodies may show an accept dialog first; libfuji waits up to 255 s for this answer.
//  5. Gallery: DF28 read+echo, D226 = 0, D227 = 0, 0x9054(0x10000001), 0x9055(0x10000001), 0x9050, D22B,
//     0x9053(0, 30000), D620, D621 (import handles; the X100VI lists them newest first).
//  6. Handles = D621, else GetObjectHandles (a count does not establish contiguous handle IDs).
// Reconnect: up to 4 tries, 0/1/2/4 s apart, re-joining the camera network first when the app can (fuji-bridge).
import Foundation

public actor FujiWifiCamera: PhotoSource {
    public struct Config: Sendable {
        public var transport: FujiPTPIPTransport.Config
        /// DF01. 20 = gallery (what fuji-bridge uses after the Bluetooth wake). If refused, 2 (view all) is tried.
        public var clientState: Int
        /// How long to wait for OK on the camera.
        public var accessTimeout: Duration
        /// How long the DF01 write may take (the camera may show an accept dialog).
        public var clientStateTimeout: Duration
        public var pollInterval: Duration
        public var reconnectPauses: [Duration]
        /// Originals (default) or the camera's resized copies; switch later with `setPhotoSize(_:)`.
        public var photoSize: PhotoSize = .original

        public init(transport: FujiPTPIPTransport.Config = .init(), clientState: Int = FujiWifiProp.clientStateGallery,
                    accessTimeout: Duration = .seconds(120), clientStateTimeout: Duration = .seconds(90),
                    pollInterval: Duration = .milliseconds(400),
                    reconnectPauses: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(4)]) {
            self.transport = transport
            self.clientState = clientState
            self.accessTimeout = accessTimeout
            self.clientStateTimeout = clientStateTimeout
            self.pollInterval = pollInterval
            self.reconnectPauses = reconnectPauses
        }
    }

    /// What the camera said during setup.
    public struct Gallery: Sendable, Equatable {
        public var cameraName: String?
        /// DF00 when access was granted (2 full access, 6 remote access, 1 multi-transfer).
        public var cameraState: UInt32
        /// D222 from the change list, when present.
        public var objectCount: Int?
        public var versions: [UInt16: UInt32]
        /// DF01 value the camera accepted (nil: it refused every one we tried).
        public var clientState: Int?
        /// Card handles, ascending.
        public var handles: [UInt32]
        /// D242 (6–11, five steps) when answered.
        public var battery: UInt32?
    }

    public nonisolated let route = ImportRoute.wifi
    public let config: Config
    private let log: @Sendable (String) -> Void
    private let prompt: @Sendable (String) -> Void
    private let rejoin: (@Sendable () async -> Bool)?
    private let transport: FujiPTPIPTransport
    /// What every command goes through: the read-only import guard (open/close stay on `transport`).
    private let guarded: ReadOnlyPTP
    private var card: PTPCardSource?
    private var generation: UInt64 = 0
    public private(set) var gallery: Gallery?

    /// - Parameters:
    ///   - prompt: things the photographer has to do on the camera ("press OK").
    ///   - rejoin: before a reconnect, put this device back on the camera's network; true when it is.
    public init(config: Config = Config(), log: @escaping @Sendable (String) -> Void = { _ in },
                prompt: @escaping @Sendable (String) -> Void = { _ in }, rejoin: (@Sendable () async -> Bool)? = nil) {
        self.config = config
        self.log = log
        self.prompt = prompt
        self.rejoin = rejoin
        transport = FujiPTPIPTransport(config: config.transport, log: log)
        guarded = ReadOnlyPTP(transport)
    }

    /// Operations the read-only guard refused this session (empty unless something asked for a write).
    public var refusedOperations: [String] { guarded.blocked }

    public func setTrace(_ t: (@Sendable (String) -> Void)?) async { await transport.setTrace(t) }

    /// Opens the session and puts the camera in gallery mode. Called by `list` if needed.
    @discardableResult
    public func connect() async throws -> Gallery {
        try Task.checkCancellation()
        if let gallery, await transport.isOpen { return gallery }
        let expected = generation
        do {
            try await transport.open(timeout: config.transport.connectTimeout)
            let g = try await FujiWifiHandshake.run(guarded, config: config, cameraName: await transport.cameraName, full: true,
                                                    log: log, prompt: prompt)
            try checkCurrent(expected)
            if let card {
                await card.sessionReopened()
                await card.setHandles(g.handles)
            } else {
                let c = PTPCardSource(transport: guarded, layout: .fujiWifi, route: .wifi, handles: g.handles, log: log)
                await c.setPhotoSize(pendingPhotoSize ?? config.photoSize)
                card = c
            }
            try checkCurrent(expected)
            gallery = g
            return g
        } catch {
            gallery = nil
            await transport.close()
            throw error
        }
    }

    private var pendingPhotoSize: PhotoSize?

    /// One read-only camera-state query when the open session has been idle for `idle` (see
    /// `FujiPTPIPTransport.keepAliveIfIdle`). No-op while a request is on the wire or no session is open.
    @discardableResult
    public func keepAlive(idle: Duration = .seconds(3)) async -> Bool {
        guard gallery != nil else { return false }
        return await transport.keepAliveIfIdle(idle)
    }

    /// Originals or resized copies from the next file on (e.g. resized for browsing, then one original on demand).
    public func setPhotoSize(_ size: PhotoSize) async {
        pendingPhotoSize = size
        await card?.setPhotoSize(size)
    }

    // MARK: PhotoSource

    public func list(hint: ListHint) async throws -> [ImportItem] {
        try await connect()
        return try await withReconnect("listing") { try await $0.list(hint: hint) }
    }

    public func thumbnail(for item: ImportItem) async throws -> Data? {
        try await withReconnect("thumbnail \(item.name)") { try await $0.thumbnail(for: item) }
    }

    public func read(_ item: ImportItem, offset: Int, length: Int) async throws -> Data? {
        try await withReconnect("reading \(item.name)") { try await $0.read(item, offset: offset, length: length) }
    }

    public func download(_ item: ImportItem, to destination: URL, progress: @escaping @Sendable (Int, Int?) -> Void) async throws -> Int {
        // A retry resumes from the .part on disk (512-byte aligned).
        try await withReconnect("\(item.name)") { try await $0.download(item, to: destination, progress: progress) }
    }

    public func close() async {
        generation &+= 1
        gallery = nil
        await card?.close()
        await transport.close()
        log("Wi-Fi session closed")
    }

    // MARK: Reconnect

    private func withReconnect<T: Sendable>(_ what: String, _ body: @Sendable (PTPCardSource) async throws -> T) async throws -> T {
        var attempt = 0
        let expected = generation
        while true {
            try checkCurrent(expected)
            guard let card else { throw ImportError.link("not connected") }
            do {
                let result = try await body(card)
                try checkCurrent(expected)
                return result
            } catch let e as ImportError where e.isLinkFailure && attempt < config.reconnectPauses.count {
                try checkCurrent(expected)
                let pause = config.reconnectPauses[attempt]
                attempt += 1
                log("lost the camera during \(what) (\(e)); reconnecting, attempt \(attempt) of \(config.reconnectPauses.count)")
                await transport.close()
                gallery = nil
                if let rejoin {
                    log(await rejoin() ? "on the camera's network" : "not on the camera's network, and re-joining didn't work")
                    try checkCurrent(expected)
                }
                if pause > .zero { try await Task.sleep(for: pause) }
                do {
                    _ = try await connect()
                    try checkCurrent(expected)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    log("reconnect failed: \(error)")
                }
            }
        }
    }

    private func checkCurrent(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
    }
}

/// Steps 2–6, over any PTP transport whose session is open (unit-tested against fake transports and the fake camera).
public enum FujiWifiHandshake {
    public static func run(_ transport: any PTPTransport, config: FujiWifiCamera.Config, cameraName: String?, full: Bool,
                           log: @Sendable (String) -> Void, prompt: @Sendable (String) -> Void) async throws -> FujiWifiCamera.Gallery {
        // Read-only, whoever calls this: the handshake only reads, plus the session switches ReadOnlyPTP allows.
        let t = ReadOnlyPTP.guarding(transport)
        // 2. Wait for OK.
        let started = ContinuousClock.now
        var events: [UInt16: UInt32] = [:]
        var asked = false
        var state: UInt32 = 0
        while true {
            try Task.checkCancellation()
            let r = try await t.transact(PTP.Op.getDevicePropValue, params: [UInt32(FujiWifiProp.events)], dataOut: nil, timeout: nil)
            let ev = r.isOK ? FujiEvents.parse(r.data) : [:]
            events.merge(ev) { _, new in new }
            state = ev[FujiWifiProp.cameraState] ?? 0
            if state != 0 { break }
            if !asked {
                asked = true
                prompt("Press MENU/OK on the camera to allow the connection (its screen asks).")
            }
            if ContinuousClock.now - started > config.accessTimeout { throw ImportError.pressOKTimedOut }
            try await Task.sleep(for: config.pollInterval)
        }
        log("camera state DF00 = \(state)\(asked ? " (OK pressed)" : "")")

        // 3. Versions.
        var versions: [UInt16: UInt32] = [:]
        for prop in [FujiWifiProp.getObjectVersion, FujiWifiProp.remoteGetObjectVersion, FujiWifiProp.imageGetVersion, FujiWifiProp.remoteVersion] {
            try Task.checkCancellation()
            let r = try await t.transact(PTP.Op.getDevicePropValue, params: [UInt32(prop)], dataOut: nil, timeout: nil)
            if r.isOK {
                versions[prop] = value(r.data)
            }
        }
        if !versions.isEmpty {
            log("versions " + versions.sorted { $0.key < $1.key }.map { String(format: "%04X=0x%X", $0.key, $0.value) }.joined(separator: " "))
        }

        // 4. Client state.
        var accepted: Int?
        var tries = [config.clientState]
        if config.clientState != FujiWifiProp.clientStateViewAll { tries.append(FujiWifiProp.clientStateViewAll) }
        for value in tries {
            if full { prompt("If the camera asks whether to allow \"\(config.transport.clientName)\", press MENU/OK.") }
            let r = try await FujiWifiCommand.setProperty(t, property: FujiWifiProp.clientState,
                                                          data: PTPPack.u16(value), timeout: config.clientStateTimeout)
            if r.isOK { accepted = value; break }
            log("camera refused DF01 = \(value) (\(PTP.Response.name(r.code)))")
        }
        guard accepted != nil else { throw ImportError.unsupported("The camera did not allow photo browsing. Close FUJIFILM's app on your phone and start the camera connection again.") }
        if let accepted { log("client state DF01 = \(accepted)\(accepted == FujiWifiProp.clientStateGallery ? " (gallery)" : "")") }

        // 5. Gallery (docs/FUJIFILM-PROTOCOL.md §5.4; harmless to skip any answer).
        if full && accepted == FujiWifiProp.clientStateGallery {
            func q(_ op: UInt16, _ p: [UInt32], _ out: Data? = nil) async throws -> PTPResult {
                if op == PTP.Op.setDevicePropValue, let property = p.first, let out {
                    return try await FujiWifiCommand.setProperty(t, property: UInt16(truncatingIfNeeded: property), data: out, timeout: nil)
                }
                return try await t.transact(op, params: p, dataOut: out, timeout: nil)
            }
            let v = try await q(PTP.Op.getDevicePropValue, [UInt32(FujiWifiProp.remotePhotoViewExVersion)])
            if v.isOK, !v.data.isEmpty {
                guard v.data.count == 4, value(v.data) <= 3 else {
                    throw ImportError.unsupported("This camera uses a photo transfer version Dial In does not support yet.")
                }
                _ = try await q(PTP.Op.setDevicePropValue, [UInt32(FujiWifiProp.remotePhotoViewExVersion)], v.data)
            }
            _ = try await q(PTP.Op.setDevicePropValue, [UInt32(FujiWifiProp.forceCompression)], PTPPack.u16(0))
            _ = try await q(PTP.Op.setDevicePropValue, [UInt32(FujiWifiProp.realSizeInfo)], PTPPack.u16(0))
            _ = try await q(PTP.Op.fujiGetExtensionObjectInfo, [0x1000_0001])
            _ = try await q(PTP.Op.fujiGetExtensionThumb, [0x1000_0001])
            _ = try await q(PTP.Op.fujiGetImageImportFolders, [])
            _ = try await q(PTP.Op.getDevicePropValue, [UInt32(FujiWifiProp.unknownD22B)])
            _ = try await q(PTP.Op.fujiGetImageImportDates, [0, 30000])
        }

        try Task.checkCancellation()

        // 6. Handles.
        _ = try await t.transact(PTP.Op.getDevicePropValue, params: [UInt32(FujiWifiProp.importCount)], dataOut: nil, timeout: nil)
        var handles: [UInt32] = []
        let r = try await t.transact(PTP.Op.getDevicePropValue, params: [UInt32(FujiWifiProp.importHandles)], dataOut: nil, timeout: nil)
        var hasHandleList = false
        if r.isOK {
            guard let decoded = FujiArray.decodeValidated(r.data) else {
                throw ImportError.invalid("The camera sent an incomplete photo list. Reconnect and try again.")
            }
            handles = decoded
            hasHandleList = true
        }
        var objectCount = events[FujiWifiProp.objectCount].map(Int.init)
        if handles.isEmpty {
            if objectCount == nil {
                let eventsReply = try await t.transact(PTP.Op.getDevicePropValue, params: [UInt32(FujiWifiProp.events)], dataOut: nil, timeout: nil)
                if eventsReply.isOK { objectCount = FujiEvents.parse(eventsReply.data)[FujiWifiProp.objectCount].map(Int.init) }
            }
            if !hasHandleList || (objectCount ?? 0) > 0 {
                // A count is not a list: handles can have gaps after in-camera deletes or use another namespace.
                let fallback = try await t.transact(PTP.Op.getObjectHandles, params: [0xFFFF_FFFF, 0, 0], dataOut: nil, timeout: nil)
                guard fallback.isOK, let decoded = FujiArray.decodeValidated(fallback.data) else {
                    throw ImportError.invalid("The camera could not provide a complete photo list. Start its image transfer mode and try again.")
                }
                handles = decoded
                log("no D621 list; using the camera's GetObjectHandles list")
            }
        } else if handles != handles.sorted() {
            log("camera lists handles \(handles.first ?? 0) … \(handles.last ?? 0) (newest first); sorting")
        }
        var battery: UInt32?
        if full {
            let batteryReply = try await t.transact(PTP.Op.getDevicePropValue, params: [UInt32(FujiWifiProp.batteryMulti)], dataOut: nil, timeout: nil)
            if batteryReply.isOK, !batteryReply.data.isEmpty { battery = value(batteryReply.data) }
        }
        return FujiWifiCamera.Gallery(cameraName: cameraName, cameraState: state, objectCount: objectCount, versions: versions,
                                      clientState: accepted, handles: handles.sorted(), battery: battery)
    }

    /// u8/u16/u32 property value, little-endian.
    static func value(_ d: Data) -> UInt32 {
        let b = [UInt8](d)
        switch b.count {
        case 0: return 0
        case 1: return UInt32(b[0])
        case 2, 3: return UInt32(LE.u16(b, 0))
        default: return LE.u32(b, 0)
        }
    }
}

/// The camera may still be switching modes after Bluetooth starts its AP. Retry the documented raw PTP busy
/// response for session property writes (0x2019). An app-level "busy" status is not a wire response.
enum FujiWifiCommand {
    static func setProperty(_ transport: any PTPTransport, property: UInt16, data: Data, timeout: Duration?) async throws -> PTPResult {
        for attempt in 0..<5 {
            try Task.checkCancellation()
            let result = try await transport.transact(PTP.Op.setDevicePropValue, params: [UInt32(property)], dataOut: data, timeout: timeout)
            if result.code != PTP.Response.deviceBusy || attempt == 4 { return result }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ImportError.link("the camera did not finish switching transfer modes")
    }
}
