// In-camera RAW re-rendering: hand the X100VI one of its own RAFs, change only the RAW-conversion profile (D185), and
// get back a JPEG made by the camera's own processor. Never touches C1–C7.
//
// Wire sequence ported from FilmKit (https://github.com/eggricesoy/filmkit, MIT, Copyright (c) 2026 eggricesoy),
// src/ptp/session.ts:484-700 (`sendRaf`, `getProfile`, `setProfile`, `triggerConversion`, `waitForResult`), which runs
// on an X100VI; it agrees with libfuji lib/fuji_usb.c:330-400 (MIT):
//
//   900C SendObjectInfo [0,0,0]  ObjectInfo{format 0xF802, size = RAF bytes, "FUP_FILE.dat"}
//   900D SendObject2    []       the whole RAF
//   1015 GetDevicePropValue D185 → base profile (cached)
//   ── per look ──
//   1016 SetDevicePropValue D185 = patched profile (same length)
//   1016 SetDevicePropValue D183 = u16 0 or 1 (0 = preview conversion, 1 = full conversion; no other value is
//        known to be used)
//   1007 GetObjectHandles [0xFFFFFFFF,0,0] until a new handle appears (30 s cap)
//   1009 GetObject (or 100A GetThumb for a fast preview), then 100B DeleteObject
//
// Differences from FilmKit, on purpose: we wait for a handle that wasn't there before the trigger (FilmKit takes the
// first handle, which would return a stale object or the RAF itself if the camera listed it); a timeout is reported as
// a wedge with power-cycle instructions (rawji __main__.py:419-424 observes that retrying makes it worse).
import Foundation

public enum RawConvError: Error, CustomStringConvertible, Equatable, Sendable {
    case notRAF(String)
    case wrongModel(raf: String, camera: String)
    case badProfile(String)
    case noRafLoaded
    case profileSizeChanged(expected: Int, got: Int)
    case invalidSettings(String)
    case refused(String, code: UInt16, hint: String)
    /// The camera stopped answering mid-render. It needs a power cycle.
    case wedged(String)

    public var description: String {
        switch self {
        case .notRAF(let why): "Not a Fujifilm RAF: \(why)"
        case .wrongModel(let raf, let cam):
            "This RAF was shot on a \(raf), but the camera is a \(cam). The camera only converts its own model's RAFs."
        case .badProfile(let why): "The camera's RAW-conversion profile (D185) looks wrong: \(why)"
        case .noRafLoaded: "No RAF is loaded in the camera yet (loadRaf first)."
        case .profileSizeChanged(let e, let g): "Patched profile is \(g) bytes; the camera's is \(e). Refusing to send it."
        case .invalidSettings(let why): "Invalid render settings: \(why)"
        case .refused(let what, let code, let hint):
            "The camera refused \(what) (\(PTP.Response.name(code)))." + (hint.isEmpty ? "" : " \(hint)")
        case .wedged(let what):
            "The camera stopped answering while \(what). It has probably wedged: switch it OFF, wait 3 seconds, switch it ON "
                + "(it stays in USB RAW CONV./BACKUP RESTORE), then run again. Retrying without the power cycle makes it worse."
        }
    }

    public var isWedge: Bool { if case .wedged = self { true } else { false } }
}

/// What the camera handed back.
public enum RenderedImageKind: String, Codable, Sendable {
    case jpeg, heif, tiff, unknown

    public init(sniffing d: Data) {
        let b = [UInt8](d.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { self = .jpeg; return }
        if b.count >= 12, b[4...7] == [0x66, 0x74, 0x79, 0x70] { self = .heif; return }   // "ftyp"
        if b.count >= 4, b[0...3] == [0x49, 0x49, 0x2A, 0x00] || b[0...3] == [0x4D, 0x4D, 0x00, 0x2A] { self = .tiff; return }
        self = .unknown
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heif: "heif"
        case .tiff: "tif"
        case .unknown: "bin"
        }
    }
}

/// Fujifilm RAF header facts we check before uploading (magic, model). Read from the first 64 bytes.
public enum RAFHeader {
    public static let magic = Data("FUJIFILMCCD-RAW".utf8)

    /// Camera model at 0x1C (32 bytes, NUL-padded), e.g. "X100VI". Nil if this isn't a RAF.
    public static func model(_ d: Data) -> String? {
        guard d.count >= 0x3C, d.prefix(magic.count) == magic else { return nil }
        let raw = [UInt8](d[d.startIndex + 0x1C ..< d.startIndex + 0x3C]).prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
    }

    /// The RAF's embedded JPEG (offset/length big-endian u32 at 0x54/0x58). Used by the rehearsal fake only.
    public static func embeddedJPEG(_ d: Data) -> Data? {
        guard d.count >= 0x5C, d.prefix(magic.count) == magic else { return nil }
        let b = [UInt8](d[d.startIndex + 0x54 ..< d.startIndex + 0x5C])
        let off = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        let len = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
        guard off > 0, len > 0, off + len <= d.count else { return nil }
        let jpg = d[d.startIndex + off ..< d.startIndex + off + len]
        return jpg.prefix(2) == Data([0xFF, 0xD8]) ? Data(jpg) : nil
    }
}

/// Pixel size from a JPEG's SOF marker (no decoding).
public enum JPEGSize {
    public static func of(_ d: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](d)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let m = b[i + 1]
            if m == 0xFF { i += 1; continue }
            if m == 0xD8 || m == 0x01 || (0xD0...0xD7).contains(m) { i += 2; continue }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (0xC0...0xCF).contains(m) && m != 0xC4 && m != 0xC8 && m != 0xCC {
                let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                return (w, h)
            }
            if m == 0xDA { return nil }
            i += 2 + len
        }
        return nil
    }
}

public actor FujiRawConverter {
    public struct Timing: Sendable {
        /// Between GetObjectHandles polls (FilmKit 1 s, rawji 50 ms).
        public var pollInterval: Duration
        /// Longest wait for a render to appear (FilmKit and rawji: 30 s).
        public var renderTimeout: Duration
        /// The RAF upload (40–50 MB; ~2–4 s at the ~22 MB/s measured over ImageCaptureCore).
        public var uploadTimeout: Duration
        /// Downloading one rendered JPEG.
        public var downloadTimeout: Duration
        /// Everything else.
        public var commandTimeout: Duration

        public init(pollInterval: Duration = .milliseconds(100), renderTimeout: Duration = .seconds(30),
                    uploadTimeout: Duration = .seconds(180), downloadTimeout: Duration = .seconds(60),
                    commandTimeout: Duration = .seconds(10)) {
            self.pollInterval = pollInterval
            self.renderTimeout = renderTimeout
            self.uploadTimeout = uploadTimeout
            self.downloadTimeout = downloadTimeout
            self.commandTimeout = commandTimeout
        }

        public static let camera = Timing()
    }

    /// The value written to D183 (UINT16) to start a conversion.
    public enum StartValue: Int, Codable, Sendable, CaseIterable {
        /// Preview conversion. Renders at the shot's own size; FilmKit and libfuji use it.
        case zero = 0
        /// Full conversion. Honours the D185 image size (index 3): L 3:2 = 7728 px, M 3:2 = 5472, S 3:2 = 3888.
        case one = 1
    }

    public enum Op {
        public static let getObjectHandles: UInt16 = 0x1007
        public static let getObject: UInt16 = 0x1009
        public static let getThumb: UInt16 = 0x100A
        public static let deleteObject: UInt16 = 0x100B
        public static let sendObjectInfo: UInt16 = 0x900C
        public static let sendObject2: UInt16 = 0x900D
    }

    public enum Prop {
        public static let startConversion: UInt16 = 0xD183
        public static let profile: UInt16 = 0xD185
    }

    public struct CameraInfo: Codable, Sendable, Equatable {
        public var model: String
        public var firmware: String
        public var usbMode: Int?
        /// D186/D187 identity strings (`<Model>_<fw>`), when readable.
        public var identity: [String: String]
        /// RAW-conversion ops/props DeviceInfo didn't list (macOS forwards unlisted codes anyway; iOS refuses them).
        public var notAdvertised: [String]

        enum CodingKeys: String, CodingKey {
            case model, firmware, usbMode = "usb_mode", identity, notAdvertised = "not_advertised"
        }
    }

    /// One timed step.
    public struct Step: Codable, Sendable, Equatable {
        public var name: String
        public var ms: Double
        public var bytes: Int?
        /// For polls: how many GetObjectHandles calls.
        public var count: Int?

        public init(name: String, ms: Double, bytes: Int? = nil, count: Int? = nil) {
            self.name = name
            self.ms = ms
            self.bytes = bytes
            self.count = count
        }

        /// "upload 2.31s 36.1MB (15.6 MB/s)".
        public var line: String {
            var s = "\(name) " + (ms >= 1000 ? String(format: "%.2fs", ms / 1000) : String(format: "%.0fms", ms))
            if let bytes {
                s += String(format: " %.1fMB", Double(bytes) / 1_048_576)
                if ms > 50 { s += String(format: " (%.1f MB/s)", Double(bytes) / 1_048_576 / (ms / 1000)) }
            }
            if let count { s += " (\(count) polls)" }
            return s
        }
    }

    public struct LoadResult: Sendable {
        public var rafBytes: Int
        public var rafModel: String
        public var profile: D185Profile
        public var steps: [Step]
    }

    public struct RenderResult: Sendable {
        public var data: Data
        public var kind: RenderedImageKind
        public var handle: UInt32
        /// True when the bytes came from GetThumb (small preview, still rendered by the camera).
        public var thumbnail: Bool
        public var steps: [Step]
        public var totalMs: Double
        /// Handles that were already listed before the trigger (logged; never downloaded or deleted).
        public var staleHandles: [UInt32]
    }

    public let transport: any PTPTransport
    public let timing: Timing
    private let log: @Sendable (String) -> Void
    public private(set) var deviceInfo = PTPDeviceInfo()
    public private(set) var baseProfile: D185Profile?
    public private(set) var rafModel: String?

    public init(transport: any PTPTransport, timing: Timing = .camera, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transport = transport
        self.timing = timing
        self.log = log
    }

    // MARK: Session

    /// Open the session, read DeviceInfo and the USB mode. Throws `CameraError.needsUSBMode` unless the camera is in
    /// USB RAW CONV./BACKUP RESTORE (D16E = 6). Missing RAW-conversion codes in DeviceInfo are reported, not fatal.
    @discardableResult
    public func connect(timeout: Duration = .seconds(30)) async throws -> CameraInfo {
        try await transport.open(timeout: timeout)
        let info: PTPResult
        do {
            info = try await transport.command(PTP.Op.getDeviceInfo, timeout: timing.commandTimeout)
        } catch {
            throw CameraError.needsUSBMode("GetDeviceInfo failed: \(error)")
        }
        if info.isOK, let parsed = try? PTPDeviceInfo(parsing: info.data) { deviceInfo = parsed }
        let mode = try await readU16(FujiProp.usbMode)
        if let mode, mode != 6 {
            let label = [5: "USB TETHER SHOOTING", 8: "webcam"][mode] ?? "mode \(mode)"
            throw CameraError.needsUSBMode("the camera is in \(label); RAW conversion needs USB RAW CONV./BACKUP RESTORE")
        }
        var identity: [String: String] = [:]
        for id in [FujiProp.tetherCondition, FujiProp.compatibilityCode] {
            if let r = try? await transport.command(PTP.Op.getDevicePropValue, [UInt32(id)], timeout: timing.commandTimeout),
               r.isOK, !r.data.isEmpty {
                identity[String(format: "%04X", id)] = RawProp(id: id, bytes: r.data).stringValue ?? r.data.hexString
            }
        }
        var missing: [String] = []
        if !deviceInfo.operations.isEmpty {
            for op in [Op.sendObjectInfo, Op.sendObject2] where !deviceInfo.operations.contains(op) {
                missing.append(String(format: "op %04X", op))
            }
        }
        if !deviceInfo.properties.isEmpty {
            for p in [Prop.startConversion, Prop.profile] where !deviceInfo.properties.contains(p) {
                missing.append(String(format: "prop %04X", p))
            }
        }
        if !missing.isEmpty { log("DeviceInfo doesn't list \(missing.joined(separator: ", ")); trying anyway (macOS forwards unlisted codes)") }
        if mode == nil { log("couldn't read the USB mode (D16E); assuming RAW CONV.") }
        return CameraInfo(model: deviceInfo.model, firmware: deviceInfo.deviceVersion, usbMode: mode, identity: identity,
                          notAdvertised: missing)
    }

    public func disconnect() async {
        await transport.close()
    }

    // MARK: RAF upload

    /// The ObjectInfo FilmKit sends before the RAF (session.ts:489-511): 82 bytes.
    public static func rafObjectInfo(size: Int) -> Data {
        var d = Data()
        d.appendLE32(0)                                       // StorageID
        d.appendLE16(0xF802)                                  // ObjectFormat: must be 0xF802 for a RAF
        d.appendLE16(0)                                       // ProtectionStatus
        d.appendLE32(UInt32(truncatingIfNeeded: size))        // CompressedSize
        d.appendLE16(0)                                       // ThumbFormat
        for _ in 0..<7 { d.appendLE32(0) }                    // ThumbSize, ThumbW, ThumbH, ImageW, ImageH, BitDepth, Parent
        d.appendLE16(0)                                       // AssociationType
        d.appendLE32(0)                                       // AssociationDesc
        d.appendLE32(0)                                       // SequenceNumber
        d.append(PTPPack.string("FUP_FILE.dat"))              // Filename
        d.append(contentsOf: [0, 0, 0])                       // CaptureDate, ModificationDate, Keywords (empty)
        return d
    }

    public func loadRaf(url: URL) async throws -> LoadResult {
        let t = ContinuousClock.now
        let data = try Data(contentsOf: url)
        let readMs = Self.ms(since: t)
        var r = try await loadRaf(data: data)
        r.steps.insert(Step(name: "read file", ms: readMs, bytes: data.count), at: 0)
        return r
    }

    /// Upload a RAF (900C + 900D) and read the base profile. Call once per photo; then `render` as many looks as you like.
    public func loadRaf(data: Data) async throws -> LoadResult {
        guard let model = RAFHeader.model(data) else { throw RawConvError.notRAF("no FUJIFILMCCD-RAW header") }
        let cam = deviceInfo.model
        if !cam.isEmpty, !model.isEmpty, cam.uppercased() != model.uppercased() {
            throw RawConvError.wrongModel(raf: model, camera: cam)
        }
        baseProfile = nil
        rafModel = nil
        var steps: [Step] = []

        var t = ContinuousClock.now
        let r1 = try await checked("SendObjectInfo (900C)") {
            try await transport.command(Op.sendObjectInfo, [0, 0, 0], sending: Self.rafObjectInfo(size: data.count), timeout: timing.commandTimeout)
        }
        steps.append(Step(name: "object info", ms: Self.ms(since: t)))
        try requireOK(r1, "the RAF's object info (900C)", hint: "Is the camera in USB RAW CONV./BACKUP RESTORE?")

        t = ContinuousClock.now
        let r2 = try await checked("uploading the RAF (900D)") {
            try await transport.command(Op.sendObject2, [], sending: data, timeout: timing.uploadTimeout)
        }
        steps.append(Step(name: "upload", ms: Self.ms(since: t), bytes: data.count))
        try requireOK(r2, "the RAF upload (900D)", hint: r2.code == PTP.Response.generalError ? "0x2002 often means a RAF from another camera model." : "")

        t = ContinuousClock.now
        let profile = try await readProfile()
        steps.append(Step(name: "read profile", ms: Self.ms(since: t), bytes: profile.bytes.count))
        baseProfile = profile
        rafModel = model
        return LoadResult(rafBytes: data.count, rafModel: model, profile: profile, steps: steps)
    }

    /// The base profile for the loaded RAF (cached after `loadRaf`; `refresh` reads it again).
    public func getProfile(refresh: Bool = false) async throws -> D185Profile {
        if !refresh, let baseProfile { return baseProfile }
        guard rafModel != nil else { throw RawConvError.noRafLoaded }
        let p = try await readProfile()
        if baseProfile == nil { baseProfile = p }
        return p
    }

    private func readProfile() async throws -> D185Profile {
        let r = try await checked("reading the profile (D185)") {
            try await transport.command(PTP.Op.getDevicePropValue, [UInt32(Prop.profile)], timeout: timing.commandTimeout)
        }
        try requireOK(r, "to give its RAW-conversion profile (D185)", hint: "The camera only answers once a RAF is loaded.")
        guard !r.data.isEmpty else { throw RawConvError.badProfile("empty; is a RAF loaded?") }
        return try D185Profile(r.data)
    }

    // MARK: Render

    /// Patch the base profile with `settings` and render. Returns the image and what was changed.
    public func render(
        _ settings: RenderSettings, layout: D185Layout = .filmKit, start: StartValue = .zero, thumbnail: Bool = false
    ) async throws -> (RenderResult, D185Patch.Result) {
        guard let base = baseProfile else { throw RawConvError.noRafLoaded }
        let patch = try D185Patch.apply(settings, to: base, layout: layout)
        let result = try await render(profile: patch.profile, start: start, thumbnail: thumbnail)
        return (result, patch)
    }

    /// Render with exactly this profile (e.g. the base, unchanged, for the fidelity test).
    public func render(profile: D185Profile, start: StartValue = .zero, thumbnail: Bool = false) async throws -> RenderResult {
        guard let base = baseProfile else { throw RawConvError.noRafLoaded }
        guard profile.bytes.count == base.bytes.count else {
            throw RawConvError.profileSizeChanged(expected: base.bytes.count, got: profile.bytes.count)
        }
        let t0 = ContinuousClock.now
        var steps: [Step] = []

        var t = ContinuousClock.now
        let stale = try await handles("listing objects before the render")
        if !stale.isEmpty { log("objects already listed before the render (ignored): \(stale.map { String(format: "0x%08X", $0) })") }

        let r1 = try await checked("sending the profile (D185)") {
            try await transport.command(PTP.Op.setDevicePropValue, [UInt32(Prop.profile)], sending: profile.bytes, timeout: timing.commandTimeout)
        }
        steps.append(Step(name: "set profile", ms: Self.ms(since: t)))
        try requireOK(r1, "the RAW-conversion profile (D185)",
                      hint: r1.code == PTP.Response.invalidDevicePropValue ? "A value in the patch is one the camera won't take (see the changes in renders.json)." : "")

        t = ContinuousClock.now
        let r2 = try await checked("starting the conversion (D183)") {
            try await transport.command(PTP.Op.setDevicePropValue, [UInt32(Prop.startConversion)], sending: PTPPack.u16(start.rawValue), timeout: timing.commandTimeout)
        }
        steps.append(Step(name: "start", ms: Self.ms(since: t)))
        try requireOK(r2, "to start the conversion (D183 = \(start.rawValue))", hint: "")

        t = ContinuousClock.now
        var polls = 0
        var handle: UInt32?
        let deadline = ContinuousClock.now + timing.renderTimeout
        while handle == nil {
            polls += 1
            let now = try await handles("waiting for the render")
            handle = now.first { !stale.contains($0) }
            if handle != nil { break }
            if ContinuousClock.now >= deadline {
                throw RawConvError.wedged("waiting for the render (nothing after \(timing.renderTimeout), \(polls) polls)")
            }
            try await Task.sleep(for: timing.pollInterval)
        }
        guard let handle else { throw RawConvError.wedged("waiting for the render") }
        steps.append(Step(name: "wait", ms: Self.ms(since: t), count: polls))

        t = ContinuousClock.now
        var data = Data()
        var usedThumb = false
        if thumbnail {
            let th = try await checked("downloading the thumbnail (GetThumb)") {
                try await transport.command(Op.getThumb, [handle], timeout: timing.downloadTimeout)
            }
            if th.isOK, !th.data.isEmpty {
                data = th.data
                usedThumb = true
            } else {
                log("GetThumb refused (\(PTP.Response.name(th.code))); downloading the full render")
            }
        }
        if data.isEmpty {
            let obj = try await checked("downloading the render (GetObject)") {
                try await transport.command(Op.getObject, [handle], timeout: timing.downloadTimeout)
            }
            try requireOK(obj, "to hand over the render (GetObject)", hint: "")
            data = obj.data
        }
        steps.append(Step(name: usedThumb ? "thumb" : "download", ms: Self.ms(since: t), bytes: data.count))

        t = ContinuousClock.now
        if let del = try? await transport.command(Op.deleteObject, [handle], timeout: timing.commandTimeout), !del.isOK {
            log("DeleteObject(0x\(String(handle, radix: 16))) answered \(PTP.Response.name(del.code)) (not fatal)")
        }
        steps.append(Step(name: "delete", ms: Self.ms(since: t)))

        guard !data.isEmpty else { throw RawConvError.refused("to hand over the render", code: PTP.Response.generalError, hint: "It sent 0 bytes.") }
        return RenderResult(data: data, kind: RenderedImageKind(sniffing: data), handle: handle, thumbnail: usedThumb,
                            steps: steps, totalMs: Self.ms(since: t0), staleHandles: stale)
    }

    // MARK: Helpers

    /// GetObjectHandles(all storages, any format, any parent): u32 count + u32 handles.
    private func handles(_ what: String) async throws -> [UInt32] {
        let r = try await checked(what) {
            try await transport.command(Op.getObjectHandles, [0xFFFF_FFFF, 0, 0], timeout: timing.commandTimeout)
        }
        try requireOK(r, "to list objects (GetObjectHandles)", hint: "")
        let b = [UInt8](r.data)
        guard b.count >= 4 else { return [] }
        let n = Int(LE.u32(b, 0))
        return (0..<min(n, (b.count - 4) / 4)).map { LE.u32(b, 4 + $0 * 4) }
    }

    private func readU16(_ id: UInt16) async throws -> Int? {
        guard let r = try? await transport.command(PTP.Op.getDevicePropValue, [UInt32(id)], timeout: timing.commandTimeout),
              r.isOK, r.data.count >= 2 else { return nil }
        return Int(LE.u16([UInt8](r.data), 0))
    }

    private func requireOK(_ r: PTPResult, _ what: String, hint: String) throws {
        if r.responseMissing { log("warning: no PTP response container for \(what); assuming OK") }
        guard r.isOK else { throw RawConvError.refused(what, code: r.code, hint: hint) }
    }

    /// Runs one camera call; a transport timeout means the camera stopped answering, which is a wedge.
    private func checked(_ what: String, _ body: () async throws -> PTPResult) async throws -> PTPResult {
        do {
            return try await body()
        } catch let e as CameraError {
            if case .timeout = e { throw RawConvError.wedged(what) }
            throw e
        }
    }

    static func ms(since start: ContinuousClock.Instant) -> Double { ms(start, until: .now) }

    static func ms(_ a: ContinuousClock.Instant, until b: ContinuousClock.Instant) -> Double {
        let d = b - a
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
