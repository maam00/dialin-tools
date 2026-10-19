// A pretend X100VI on TCP (loopback), speaking the Wi-Fi import protocol byte for byte as the references document it.
// Used by the tests and by `dialin-cam import-wifi --rehearse` (the whole CLI path, no camera, no network change).
//
// Packet layouts and behaviour, with sources:
// - Init: 82-byte request; the acknowledgement is 68 bytes, responder marker at 12, camera name at 28;
//   Init Fail = u32 12, u32 5, u32 reason (docs/FUJIFILM-PROTOCOL.md §5.3; vcam emulates the same).
// - After init: USB PTP containers, u32 len, u16 type, u16 code, u32 tid (libgphoto2 fujiptpip.c:20-36).
// - D212 = u16 n, n × (u16 code, u32 value), D222 deliberately first so a client reading "DF00 at offset 4" breaks
//   (VirtualBody.propValue). DF00 = 0 for the first `okAfterPolls` polls ("press OK"), then 2 (full access).
// - D621 = u32 n, n × u32 handles, newest first like the X100VI (fuji-bridge Session.swift afterHandshake).
// - Version props DF22/DF24 = 0x2000C, DF25 = 5, DF21 = 0x2000A (fakecam.py `prop`).
// - GetObjectPropValue 0x9803: DC04 → u64 size, DC07 → PTP string name, DC08 → PTP string date (VirtualBody).
// - GetObjectInfo: Fujifilm layout, size at 13 (102400 until D227 = 1 when `lieAboutSize`), name PTP string at 52,
//   then date / empty / "Orientation:1" (libfuji lib/data.c:77-82).
// - GetPartialObject 0x101B (handle, offset, length) → that slice; GetThumb 0x100A → a small JPEG.
// - Goodbye 08 00 00 00 FF FF FF FF closes the socket (libfuji fuji.c:52-54).
import Foundation
@preconcurrency import Network

public final class FakeFujiWifiCamera: @unchecked Sendable {
    public struct Frame: Sendable {
        public var handle: UInt32
        public var name: String
        public var data: Data
        /// PTP date string, "20261009T143012".
        public var date: String
        /// The camera's resized copy (served while D226 = 1). nil: the original is served either way.
        public var resized: Data?

        public init(handle: UInt32, name: String, data: Data, date: String, resized: Data? = nil) {
            self.handle = handle
            self.name = name
            self.data = data
            self.date = date
            self.resized = resized
        }
    }

    public struct Behavior: Sendable {
        /// First init on the first socket gets Init Fail (bodies "often FAIL the first init").
        public var initFailFirst = false
        /// First socket accepts the init and never answers it (fuji-bridge, X100VI just woken over Bluetooth).
        public var silentFirstInit = false
        /// D212 polls answered with DF00 = 0 before access is granted.
        public var okAfterPolls = 0
        /// Answer MTP object properties (DC04/DC07/DC08). Off: 0x2005, so clients fall back to GetObjectInfo.
        public var answersObjectProps = true
        /// Answer D621 with the handle list. Off: an empty list, requiring GetObjectHandles fallback.
        public var listsHandles = true
        /// ObjectInfo reports 102400 bytes until D227 = 1 (libfuji fujiptp.h:57-63).
        public var lieAboutSize = false
        /// DF01 values to refuse (0x201C).
        public var refuseClientStates: Set<Int> = []
        /// Drop the socket once, after this many bytes of GetPartialObject data (a Wi-Fi stall mid-file).
        public var dropAfterPartialBytes: Int?
        /// GetThumb returns no data unless GetObjectInfo for that handle came first (libfuji fuji.c:640-646).
        public var thumbNeedsInfo = false
        /// SetDevicePropValue on these props answers 0x200A (DevicePropNotSupported).
        public var refuseProps: Set<UInt16> = []
        /// Accept a TCP command and remain silent, for cancellation/deadline testing.
        public var silentOperations: Set<UInt16> = []
        /// Respond with a different TID for these operations, simulating stale/corrupt socket framing.
        public var mismatchedTransactionOperations: Set<UInt16> = []
        /// A camera setting/firmware bug keeps sending a smaller JPEG despite D226 = 2.
        public var ignoresOriginalRequest = false
        /// Wrong responder identity must be refused before OpenSession.
        public var wrongInitGUID = false
        /// Number of transient raw PTP 0x2019 busy answers before a property's write is accepted.
        public var busyPropWrites: [UInt16: Int] = [:]
        /// DC08 answers this string instead of the frame's date. A real X100VI (fw 1.10, 2026-10-15) answered "2" for
        /// every object, so listing must read dates from each file's EXIF instead.
        public var dateCreatedOverride: String?

        public init() {}
    }

    public struct Command: Sendable, Equatable { public var op: UInt16; public var tid: UInt32; public var params: [UInt32] }
    public struct PropSet: Sendable, Equatable { public var prop: UInt16; public var value: Data }
    public struct Partial: Sendable, Equatable { public var handle: UInt32; public var offset: Int; public var length: Int }

    public struct Record: Sendable {
        public var connections = 0
        public var initPackets: [Data] = []
        public var commands: [Command] = []
        public var sets: [PropSet] = []
        public var openSessionTids: [UInt32] = []
        public var closeSessions = 0
        public var goodbyes = 0
        public var partials: [Partial] = []
        public var drops = 0
    }

    public let cameraName: String
    public private(set) var frames: [Frame]
    public let behavior: Behavior
    private let queue = DispatchQueue(label: "co.dialin.fakecam")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _record = Record()
    private var polls = 0
    private var failedOnce = false
    private var silencedOnce = false
    private var droppedOnce = false
    private var partialBytes = 0
    private var remainingBusyPropWrites: [UInt16: Int] = [:]
    private var conns: [ObjectIdentifier: Conn] = [:]

    public var record: Record { lock.withLock { _record } }

    public init(frames: [Frame], behavior: Behavior = Behavior(), cameraName: String = "X100VI") {
        self.frames = frames
        self.behavior = behavior
        self.cameraName = cameraName
    }

    /// Starts listening on 127.0.0.1 and returns the port.
    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, any Error>) in
            let once = OnceFlag()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e):
                    if once.claim() { cont.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let all = lock.withLock { conns.values.map(\.connection) }
        all.forEach { $0.cancel() }
    }

    // MARK: Connections

    private final class Conn: @unchecked Sendable {   // only touched on `queue`
        let connection: NWConnection
        var buffer = Data()
        var gotInit = false
        var pendingSet: (prop: UInt16, tid: UInt32)?
        var infoSeen = Set<UInt32>()
        init(_ c: NWConnection) { connection = c }
    }

    private func accept(_ c: NWConnection) {
        let conn = Conn(c)
        lock.withLock {
            conns[ObjectIdentifier(conn)] = conn
            _record.connections += 1
        }
        c.start(queue: queue)
        receive(conn)
    }

    private func receive(_ conn: Conn) {
        conn.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { conn.buffer.append(data) }
            while self.handleNext(conn) {}
            if done || error != nil {
                conn.connection.cancel()
                _ = self.lock.withLock { self.conns.removeValue(forKey: ObjectIdentifier(conn)) }
                return
            }
            if conn.connection.state == .cancelled { return }
            self.receive(conn)
        }
    }

    /// Handles one complete packet from the buffer; false when more bytes are needed.
    private func handleNext(_ conn: Conn) -> Bool {
        let b = [UInt8](conn.buffer)
        guard b.count >= 4 else { return false }
        let length = Int(LE.u32(b, 0))
        guard length >= 8 else { conn.connection.cancel(); return false }
        guard b.count >= length else { return false }
        let packet = Data(b[0..<length])
        conn.buffer = Data(b[length...])
        handle(packet, conn)
        return conn.connection.state != .cancelled
    }

    private func handle(_ p: Data, _ conn: Conn) {
        let b = [UInt8](p)
        if p == FujiPTPIP.goodbye {
            lock.withLock { _record.goodbyes += 1 }
            conn.connection.cancel()
            return
        }
        if !conn.gotInit {
            guard b.count == FujiPTPIP.initLength, LE.u32(b, 4) == 1 else { conn.connection.cancel(); return }
            lock.withLock { _record.initPackets.append(p) }
            let (silence, fail): (Bool, Bool) = lock.withLock {
                if behavior.silentFirstInit && !silencedOnce { silencedOnce = true; return (true, false) }
                if behavior.initFailFirst && !failedOnce { failedOnce = true; return (false, true) }
                return (false, false)
            }
            if silence { return }
            if fail {
                var d = Data()
                d.appendLE32(12); d.appendLE32(5); d.appendLE32(UInt32(PTP.Response.deviceBusy))
                send(d, conn)
                return
            }
            conn.gotInit = true
            var ack = Data(count: 68)
            ack[0] = 0x44; ack[4] = 2
            ack.replaceSubrange(12..<28, with: behavior.wrongInitGUID ? Data(count: 16) : FujiPTPIP.cameraGUID)
            var o = 28
            for u in cameraName.utf16.prefix(19) { ack[o] = UInt8(u & 0xFF); ack[o + 1] = UInt8(u >> 8); o += 2 }
            send(ack, conn)
            return
        }
        guard b.count >= 12 else { return }
        let type = LE.u16(b, 4), code = LE.u16(b, 6), tid = LE.u32(b, 8)
        if type == PTP.ContainerType.data, let pending = conn.pendingSet, pending.tid == tid {
            conn.pendingSet = nil
            let value = Data(b[12...])
            lock.withLock { _record.sets.append(PropSet(prop: pending.prop, value: value)) }
            let busy = lock.withLock {
                let remaining = remainingBusyPropWrites[pending.prop] ?? behavior.busyPropWrites[pending.prop] ?? 0
                remainingBusyPropWrites[pending.prop] = max(0, remaining - 1)
                return remaining > 0
            }
            if busy {
                respond(code, tid, PTP.Response.deviceBusy, conn)
            } else if pending.prop == FujiWifiProp.clientState, b.count >= 14, behavior.refuseClientStates.contains(Int(LE.u16(b, 12))) {
                respond(code, tid, PTP.Response.invalidDevicePropValue, conn)
            } else if behavior.refuseProps.contains(pending.prop) {
                respond(code, tid, PTP.Response.devicePropNotSupported, conn)
            } else {
                if pending.prop == FujiWifiProp.realSizeInfo, b.count >= 14 { lock.withLock { realSize = LE.u16(b, 12) } }
                if pending.prop == FujiWifiProp.forceCompression, b.count >= 14 { lock.withLock { compression = LE.u16(b, 12) } }
                respond(code, tid, PTP.Response.ok, conn)
            }
            return
        }
        guard type == PTP.ContainerType.command else { return }
        var params: [UInt32] = []
        var o = 12
        while o + 4 <= b.count { params.append(LE.u32(b, o)); o += 4 }
        lock.withLock { _record.commands.append(Command(op: code, tid: tid, params: params)) }
        if behavior.silentOperations.contains(code) { return }
        let p0 = params.first ?? 0
        switch code {
        case PTP.Op.openSession:
            lock.withLock { _record.openSessionTids.append(tid) }
            respond(code, tid, PTP.Response.ok, conn)
        case PTP.Op.closeSession:
            lock.withLock { _record.closeSessions += 1 }
            respond(code, tid, PTP.Response.ok, conn)
        case PTP.Op.setDevicePropValue:
            conn.pendingSet = (UInt16(truncatingIfNeeded: p0), tid)
        case PTP.Op.getDevicePropValue:
            dataAndOK(code, tid, prop(UInt16(truncatingIfNeeded: p0)), conn)
        case PTP.Op.getObjectPropValue:
            guard behavior.answersObjectProps else { respond(code, tid, PTP.Response.operationNotSupported, conn); return }
            guard let f = frame(p0), params.count > 1 else { respond(code, tid, PTP.Response.invalidObjectHandle, conn); return }
            switch UInt16(truncatingIfNeeded: params[1]) {
            case FujiWifiProp.objectSize:
                var d = Data(); d.appendLE32(UInt32(f.data.count)); d.appendLE32(0)
                dataAndOK(code, tid, d, conn)
            case FujiWifiProp.objectFileName: dataAndOK(code, tid, PTPPack.string(f.name), conn)
            case FujiWifiProp.dateCreated: dataAndOK(code, tid, PTPPack.string(behavior.dateCreatedOverride ?? f.date), conn)
            default: respond(code, tid, PTP.Response.parameterNotSupported, conn)
            }
        case PTP.Op.getObjectInfo:
            guard let f = frame(p0) else { respond(code, tid, PTP.Response.invalidObjectHandle, conn); return }
            conn.infoSeen.insert(p0)
            let honest = !behavior.lieAboutSize || lock.withLock { realSize == 1 }
            dataAndOK(code, tid, PTPObjectInfo.encode(layout: .fujiWifi, size: honest ? f.data.count : 102_400, filename: f.name, captureDate: f.date), conn)
        case PTP.Op.getObjectHandles:
            dataAndOK(code, tid, FujiArray.encode(frames.map(\.handle)), conn)
        case PTP.Op.getThumb:
            guard frame(p0) != nil else { respond(code, tid, PTP.Response.invalidObjectHandle, conn); return }
            if behavior.thumbNeedsInfo && !conn.infoSeen.contains(p0) { respond(code, tid, PTP.Response.ok, conn); return }
            dataAndOK(code, tid, Self.thumbJPEG, conn)
        case PTP.Op.getPartialObject:
            guard let f = frame(p0), params.count >= 3 else { respond(code, tid, PTP.Response.invalidObjectHandle, conn); return }
            let off = Int(params[1]), len = Int(params[2])
            lock.withLock { _record.partials.append(Partial(handle: p0, offset: off, length: len)) }
            // D226 = 1: the resized copy (the real body keeps announcing the original's size meanwhile).
            let body = lock.withLock { compression == 1 || (compression == 2 && behavior.ignoresOriginalRequest) } ? (f.resized ?? f.data) : f.data
            let slice = off < body.count ? body.subdata(in: off..<min(off + len, body.count)) : Data()
            let drop: Bool = lock.withLock {
                partialBytes += slice.count
                if let limit = behavior.dropAfterPartialBytes, !droppedOnce, partialBytes > limit {
                    droppedOnce = true
                    _record.drops += 1
                    return true
                }
                return false
            }
            let replyTID = responseID(code, tid)
            let container = PTPContainer.data(code, transactionID: replyTID, payload: slice).pack()
            if drop {
                // Half a window, then silence and a dead socket.
                conn.connection.send(content: container.prefix(container.count / 2), completion: .contentProcessed { _ in conn.connection.cancel() })
                return
            }
            send(container + Self.response(code, replyTID, PTP.Response.ok), conn)
        default:
            respond(code, tid, PTP.Response.ok, conn)
        }
    }

    private var realSize: UInt16 = 0
    /// Last D226 written (0 none, 1 resized, 2 originals).
    private var compression: UInt16 = 0

    private func prop(_ id: UInt16) -> Data {
        switch id {
        case FujiWifiProp.events:
            let state: UInt32 = lock.withLock {
                polls += 1
                return polls > behavior.okAfterPolls ? 2 : 0
            }
            return FujiEvents.encode([(FujiWifiProp.objectCount, UInt32(frames.count)), (FujiWifiProp.cameraState, state)])
        case FujiWifiProp.importHandles:
            return FujiArray.encode(behavior.listsHandles ? frames.map(\.handle).sorted(by: >) : [])
        case FujiWifiProp.importCount: return PTPPack.u32(UInt32(frames.count))
        case FujiWifiProp.getObjectVersion, FujiWifiProp.remoteVersion: return PTPPack.u32(0x0002_000C)
        case FujiWifiProp.remoteGetObjectVersion: return PTPPack.u32(5)
        case FujiWifiProp.imageGetVersion: return PTPPack.u32(0x0002_000A)
        case FujiWifiProp.remotePhotoViewExVersion: return PTPPack.u32(3)
        case FujiWifiProp.batteryMulti: return PTPPack.u16(10)
        default: return PTPPack.u32(0)
        }
    }

    private func frame(_ handle: UInt32) -> Frame? { frames.first { $0.handle == handle } }

    private func dataAndOK(_ code: UInt16, _ tid: UInt32, _ payload: Data, _ conn: Conn) {
        let replyTID = responseID(code, tid)
        send(PTPContainer.data(code, transactionID: replyTID, payload: payload).pack() + Self.response(code, replyTID, PTP.Response.ok), conn)
    }

    private func respond(_ code: UInt16, _ tid: UInt32, _ rc: UInt16, _ conn: Conn) {
        send(Self.response(code, responseID(code, tid), rc), conn)
    }

    private func responseID(_ code: UInt16, _ tid: UInt32) -> UInt32 {
        behavior.mismatchedTransactionOperations.contains(code) ? tid &+ 1 : tid
    }

    private static func response(_ code: UInt16, _ tid: UInt32, _ rc: UInt16) -> Data {
        var d = Data()
        d.appendLE32(12); d.appendLE16(PTP.ContainerType.response); d.appendLE16(rc); d.appendLE32(tid)
        return d
    }

    private func send(_ d: Data, _ conn: Conn) {
        conn.connection.send(content: d, completion: .idempotent)
    }

    /// A ~400-byte JPEG standing in for the body's 160×120 thumbnail.
    static let thumbJPEG = SyntheticJPEG.make(dateTimeOriginal: "2000:01:01 00:00:00", payloadBytes: 256)

    // MARK: Sample card

    /// A card with `todayCount` JPEGs (the second also shot as RAF) dated `day`, after `olderCount` JPEGs from the day
    /// before. Handles follow shooting order, names DSCF0001… like the body.
    public static func sampleCard(day: String = ImportDay.today(), todayCount: Int = 3, olderCount: Int = 2,
                                  jpegBytes: Int = 300_000) -> [Frame] {
        let f = day.split(separator: "-").compactMap { Int($0) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: f[0], month: f[1], day: f[2], hour: 9)) ?? Date()
        var frames: [Frame] = []
        var handle: UInt32 = 1
        func add(_ name: String, _ at: Date, raw: Bool = false, seed: Int) {
            let t = CaptureTime(date: at, timeZone: cal.timeZone)
            let exifDate = String(format: "%04d:%02d:%02d %02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.minute, t.second)
            let ptpDate = String(format: "%04d%02d%02dT%02d%02d%02d", t.year, t.month, t.day, t.hour, t.minute, t.second)
            let jpeg = SyntheticJPEG.make(dateTimeOriginal: exifDate, payloadBytes: jpegBytes + seed * 1_337, seed: UInt8(seed & 0xFF))
            frames.append(Frame(handle: handle, name: name + ".JPG", data: jpeg, date: ptpDate))
            handle += 1
            if raw {
                frames.append(Frame(handle: handle, name: name + ".RAF", data: SyntheticJPEG.raf(embedding: jpeg, cfaBytes: jpegBytes), date: ptpDate))
                handle += 1
            }
        }
        var n = 1
        for k in 0..<olderCount {
            add(String(format: "DSCF%04d", n), base.addingTimeInterval(-86_400 + Double(k) * 600), seed: n)
            n += 1
        }
        for k in 0..<todayCount {
            add(String(format: "DSCF%04d", n), base.addingTimeInterval(Double(k) * 3_600), raw: k == 1, seed: n)
            n += 1
        }
        return frames
    }
}
