// The camera's card over PTP, through any `PTPTransport`: USB via ImageCaptureCore (standard ObjectInfo) or the
// camera's Wi-Fi via `FujiPTPIPTransport` (Fujifilm's ObjectInfo variant and object-property fast path).
//
// Ported from fuji-bridge FujiBridge/Session.swift `Importer.copy` + `IO` and FujiBridge/Bytes.swift (MIT, Copyright (c)
// 2026 Thomas Marchand), which imports from an X100VI (fw 1.32) over USB and Wi-Fi:
// - GetPartialObject (0x101B) in 1 MB windows, re-aligned to 512-byte offsets (the body is ~40× slower unaligned),
//   an empty window or the same short window twice = end of file (an X100VI keeps announcing the original's length).
// - Wi-Fi: name/size/date via MTP GetObjectPropValue (0x9803) of ObjectFileName 0xDC07 / ObjectSize 0xDC04 /
//   DateCreated 0xDC08 (~10 ms each) instead of GetObjectInfo (500–700 ms each on an X100VI); a body that doesn't
//   answer gets libfuji's D227 = 1 so ObjectInfo reports the real size (libfuji lib/fujiptp.h:57-63).
// - Wi-Fi ObjectInfo: compressed_size is the unaligned u32 at offset 13, filename a PTP string at 52
//   (libfuji lib/fujiptp.h:457-483 `PtpFujiObjectInfo`, lib/data.c:70-84). USB ObjectInfo is standard (size at 8).
// - D226 = 2 (originals) for the whole import, back to 0 at the end. `photoSize = .resized` asks for the
//   camera's own smartphone-size copies instead (D22E = resize rate, then D226 = 1; docs/FUJIFILM-PROTOCOL.md §5.4):
//   the browse copies the iPhone app pulls first, with originals fetched on demand.
import Foundation

/// Which copy of a photo the camera serves over Wi-Fi.
public enum PhotoSize: String, Sendable, Equatable {
    /// The file as recorded (D226 = 2).
    case original
    /// The camera's resized copy for smartphones (D22E = 1 "S", D226 = 1). The camera keeps announcing the original's
    /// size while it serves the smaller file; the importer records that (`listedSize`).
    case resized
}

public actor PTPCardSource: PhotoSource {
    public enum Layout: Sendable, Equatable {
        /// ISO 15740 ObjectInfo, GetObjectHandles: USB.
        case standard
        /// Fujifilm's Wi-Fi variant: handles from D621/D222, ObjectInfo size at 13, object-property fast path.
        case fujiWifi
    }

    public nonisolated let route: ImportRoute
    public let layout: Layout
    private let transport: any PTPTransport
    private let log: @Sendable (String) -> Void

    /// Bytes per GetPartialObject (fuji-bridge uses 1 MB; >1 MB gains ~5% over USB).
    public var window = 1 << 20
    public var commandTimeout: Duration = .seconds(10)
    /// Timeout for a window once files are moving (fuji-bridge docs/DEVELOPMENT.md).
    public var transferTimeout: Duration = .seconds(30)
    /// Wi-Fi only: originals (default) or the camera's resized copies. Change it with `setPhotoSize(_:)`.
    public private(set) var photoSize: PhotoSize = .original

    /// Card handles, ascending (shooting order). Wi-Fi: set from D621/D222 by the session. USB: GetObjectHandles.
    private var handles: [UInt32]?
    private var described: [UInt32: ImportItem] = [:]
    private var objectPropsWork: Bool?
    /// Whether DateCreated (0xDC08) carries a parseable date on this body; X100VI fw 1.10 answered "2". Asked once.
    private var dateCreatedUseful: Bool?
    /// D227 = 1 is needed on this body (no ObjectSize property), and whether it is set on the current connection.
    private var realSizeWanted = false
    private var realSizeApplied = false
    private var forceOriginalsSet = false

    /// Every command goes through `ReadOnlyPTP` (wrapped here if the caller didn't): an import can't delete, move,
    /// protect, format or send anything to the card, whatever this code asks for.
    public init(transport: any PTPTransport, layout: Layout, route: ImportRoute, handles: [UInt32]? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transport = ReadOnlyPTP.guarding(transport)
        self.layout = layout
        self.route = route
        self.handles = handles?.sorted()
        self.log = log
    }

    /// Replace the handle list (after a Wi-Fi reconnect re-reads D621).
    public func setHandles(_ h: [UInt32]) {
        handles = Array(Set(h)).sorted()
        described.removeAll()
    }

    /// Switch between originals and resized copies; takes effect with the next file command (D226 is re-sent).
    public func setPhotoSize(_ size: PhotoSize) {
        guard size != photoSize else { return }
        photoSize = size
        forceOriginalsSet = false
    }

    /// After a reconnect the camera forgets D226/D227: put them back before the next command.
    public func sessionReopened() {
        forceOriginalsSet = false
        realSizeApplied = false
        described.removeAll()
    }

    // MARK: PhotoSource

    public func list(hint: ListHint) async throws -> [ImportItem] {
        try await prepareWifi()
        let all: [UInt32]
        if let handles {
            all = handles
        } else {
            let r = try await call(PTP.Op.getObjectHandles, [0xFFFF_FFFF, 0, 0], "GetObjectHandles")
            all = FujiArray.decode(r.data).sorted()
            handles = all
        }
        log("card lists \(all.count) objects")
        var items: [ImportItem] = []
        // Newest first. Over Wi-Fi, describing is slow (an X100VI on 2026-10-15: ~0.25 s per property, so a
        // 1,336-object card took longer than the session lasted), and handles follow shooting order (fuji-bridge:
        // "handle 26 is DSCF0026"). So: `last` takes just the newest N; otherwise stop after a run of files older than
        // wanted. That body answers DateCreated with a placeholder, so an undated file's date comes from its own EXIF
        // (one small partial read), and a run of files whose date can't be read at all also ends the walk.
        var newestFirst = Array(all.reversed())
        if let last = hint.last {
            newestFirst = Array(newestFirst.prefix(max(0, last)))
            log("looking at the newest \(newestFirst.count) of them only (--last \(last))")
        }
        var olderRun = 0, undatedRun = 0, walked = 0
        for h in newestFirst {
            try Task.checkCancellation()
            guard var item = try await describe(h) else { continue }
            walked += 1
            // Only a date filter needs the date now. 2026-10-16, X100VI 1.10 over Wi-Fi: after a 64 KB EXIF read of
            // one file, the next request (a property read of another file) never got an answer and the session died.
            // Downloads read each file to its end; without --since the importer dates files from their own EXIF then.
            if layout == .fujiWifi, item.captured == nil, hint.since != nil {
                if let t = try await probeDateKeepingLinkErrors(item) {
                    item.captured = t
                    described[h] = item
                }
            }
            items.append(item)
            if layout == .fujiWifi && walked % 10 == 0 { log("listed \(walked) so far (newest \(items.first?.name ?? "?"))") }
            guard layout == .fujiWifi, hint.last == nil, let since = hint.since else { continue }
            if let day = item.captured?.dayKey {
                undatedRun = 0
                olderRun = day < since ? olderRun + 1 : 0
                if olderRun >= Self.olderRunStop {
                    log("stopped listing at \(item.name): \(Self.olderRunStop) in a row older than \(since)")
                    break
                }
            } else {
                undatedRun += 1
                if undatedRun >= Self.undatedRunStop {
                    log("stopped listing at \(item.name): \(Self.undatedRunStop) in a row without a readable date. "
                        + "To pick files without dates, run again with --last N (the newest N files on the card).")
                    break
                }
            }
        }
        return items
    }

    /// Files older than `since`, in a row, that end a newest-first walk (tolerates a few out-of-order handles).
    public static let olderRunStop = 8
    /// Files with no readable date, in a row, that end a newest-first date walk.
    public static let undatedRunStop = 8

    /// A file's EXIF date via a small partial read. A lost link still ends the listing (so the caller reconnects);
    /// anything else (no EXIF, a refused read) just leaves the file undated.
    private func probeDateKeepingLinkErrors(_ item: ImportItem) async throws -> CaptureTime? {
        guard item.kind == .jpeg || item.kind == .raw else { return nil }
        do {
            return try await PhotoImporter.probeDate(item, source: self)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as ImportError where e.isLinkFailure {
            throw e
        } catch {
            return nil
        }
    }

    public func thumbnail(for item: ImportItem) async throws -> Data? {
        try Task.checkCancellation()
        let h = try handle(of: item)
        try await objectInfoFirst(h)
        let r = try await call(PTP.Op.getThumb, [h], "GetThumb", allowFailure: true)
        return r.isOK && r.data.count > 100 ? r.data : nil
    }

    /// Over Wi-Fi, GetObjectInfo for a handle before any of its data, as libfuji does (lib/fuji.c `fuji_get_thumb`,
    /// `fuji_download_file_ex`; bodies with remote version above 0x20006 block GetThumb forever without it).
    /// 2026-10-16, X100VI 1.10 (DF24 0x2000B): a GetThumb without it never answered, and after a 64 KB
    /// GetPartialObject without it the next command never answered; both times the camera's network went down.
    private func objectInfoFirst(_ h: UInt32) async throws {
        guard layout == .fujiWifi else { return }
        _ = try await call(PTP.Op.getObjectInfo, [h], "GetObjectInfo", allowFailure: true)
    }

    public func read(_ item: ImportItem, offset: Int, length: Int) async throws -> Data? {
        let h = try handle(of: item)
        try await prepareWifi()
        try await objectInfoFirst(h)
        let r = try await call(PTP.Op.getPartialObject, try partialParams(h, offset: offset, length: length), "GetPartialObject", timeout: transferTimeout)
        guard r.data.count <= length else { throw ImportError.invalid("The camera sent more photo data than requested.") }
        return r.data
    }

    public func download(_ item: ImportItem, to destination: URL, progress: @escaping @Sendable (Int, Int?) -> Void) async throws -> Int {
        let h = try handle(of: item)
        try await prepareWifi()
        // A reconnect can expose another card or reuse a handle. Never append a different object's bytes onto a
        // previous partial file or label them as the original photo. The metadata cache is cleared on reopening.
        if layout == .fujiWifi {
            guard let current = try await describe(h), current.name == item.name,
                  current.size == item.size,
                  current.captured == nil || item.captured == nil || current.captured == item.captured else {
                throw ImportError.invalid("\(item.name) changed or is no longer on the camera. Refresh the photo list and try again.")
            }
        }
        try await objectInfoFirst(h)
        guard window > 0, window <= 8 * 1024 * 1024 else { throw ImportError.invalid("The photo transfer window is invalid.") }
        guard var total = item.size, total > 0 else { throw ImportError.invalid("\(item.name): the camera didn't say how big it is") }
        let part = try PartialFile(destination: destination, expected: total)
        var offset = part.length
        if offset > 0 { log("\(item.name): resuming at \(offset) of \(total) bytes") }
        var shortEnd: Int?
        // A size from GetObjectInfo without D227 = 1 may be Fuji's ~100 KB placeholder: keep asking past it until the
        // camera has nothing more (one extra round trip per file, only on such bodies).
        let sizeUntrusted = layout == .fujiWifi && objectPropsWork == false && !realSizeApplied
        do {
            while offset < total || (sizeUntrusted && shortEnd == nil && offset == total && total > 0) {
                try Task.checkCancellation()
                if offset >= total { total += window }
                let ask = min(window, total - offset)
                let r = try await call(PTP.Op.getPartialObject, try partialParams(h, offset: offset, length: ask), "GetPartialObject",
                                       allowFailure: true, timeout: transferTimeout)
                if !r.isOK && r.code != PTP.Response.sessionAlreadyOpen {
                    // Past the announced end (the untrusted-size probe), a refusal just means "no more".
                    if offset > 0 && offset >= item.size ?? .max { total = offset; break }
                    throw ImportError.refused("GetPartialObject for \(item.name)", code: r.code)
                }
                guard r.data.count <= ask else { throw ImportError.invalid("\(item.name): the camera sent an oversized photo chunk") }
                if r.data.isEmpty {
                    guard offset > 0 else { throw ImportError.incomplete("\(item.name): the camera sent no bytes") }
                    log("\(item.name): nothing past \(offset) although \(total) was announced; taking that as the end")
                    total = offset
                    break
                }
                try part.append(r.data)
                offset += r.data.count
                if r.data.count < ask && offset < total {
                    // Same short answer at the same place twice = the object really ends there (fuji-bridge saw a
                    // resized file asked for its last 257 bytes 1,510 times without this).
                    if shortEnd == offset {
                        total = offset
                        break
                    }
                    shortEnd = offset
                }
                let extra = offset < total ? offset % 512 : 0
                if extra > 0 {
                    offset -= extra
                    try part.truncate(to: offset)
                }
                progress(offset, total)
            }
            try Task.checkCancellation()
            if layout == .fujiWifi && photoSize == .original && !sizeUntrusted, let expected = item.size, offset < expected {
                throw ImportError.incomplete("\(item.name): the full-size photo was requested, but only \(offset) of \(expected) bytes arrived. Try again with image resizing turned off on the camera.")
            }
            try part.finish()
        } catch {
            part.close()
            if let e = error as? ImportError, case .incomplete = e { try? FileManager.default.removeItem(at: part.partURL) }
            throw error
        }
        return offset
    }

    public func close() async {
        if layout == .fujiWifi && forceOriginalsSet {
            _ = try? await setProp(FujiWifiProp.forceCompression, u16: 0)
            if realSizeApplied { _ = try? await setProp(FujiWifiProp.realSizeInfo, u16: 0) }
            realSizeApplied = false
            forceOriginalsSet = false
        }
    }

    // MARK: Describing

    private func describe(_ h: UInt32) async throws -> ImportItem? {
        if let known = described[h] { return known }
        var item: ImportItem?
        if layout == .fujiWifi && objectPropsWork != false {
            item = try await quickDescription(h)
            if item == nil {
                if objectPropsWork == nil { log("object properties unanswered; using GetObjectInfo (slower) from now on") }
                objectPropsWork = false
            } else {
                objectPropsWork = true
            }
        }
        if item == nil {
            if layout == .fujiWifi && !realSizeWanted {
                // Without D227 = 1 a Fuji body reports ~100 KB for every file (libfuji fujiptp.h:57-63).
                realSizeWanted = true
                try await prepareWifi()
            }
            let r = try await call(PTP.Op.getObjectInfo, [h], "GetObjectInfo", allowFailure: true)
            // fuji-bridge: skip a dead handle (0x2009) and keep going; same for any other refusal of one object.
            guard r.isOK else {
                if r.code != PTP.Response.invalidObjectHandle { log("GetObjectInfo refused for handle \(h) (\(PTP.Response.name(r.code))); skipping it") }
                return nil
            }
            guard let info = PTPObjectInfo(r.data, layout: layout) else { return nil }
            if info.isFolder { return nil }
            item = ImportItem(id: "ptp:\(h)", name: info.filename, size: info.size > 0 ? info.size : nil,
                              captured: info.captureDate.flatMap(CaptureTime.parsePTP))
        }
        if let item { described[h] = item }
        return item
    }

    /// fuji-bridge `IO.quickDescription`: ObjectSize, ObjectFileName, DateCreated by property. Nil if unanswered.
    private func quickDescription(_ h: UInt32) async throws -> ImportItem? {
        let s = try await call(PTP.Op.getObjectPropValue, [h, UInt32(FujiWifiProp.objectSize)], "ObjectSize", allowFailure: true)
        guard s.isOK, s.data.count >= 4 else { return nil }
        let b = [UInt8](s.data)
        let size = b.count >= 8 ? Int(LE.u32(b, 0)) | Int(LE.u32(b, 4)) << 32 : Int(LE.u32(b, 0))
        guard size > 0 else { return nil }
        let n = try await call(PTP.Op.getObjectPropValue, [h, UInt32(FujiWifiProp.objectFileName)], "ObjectFileName", allowFailure: true)
        guard n.isOK else { return nil }
        let name = (parsePTPString(n.data) as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        var date: CaptureTime?
        if dateCreatedUseful != false {
            let d = try await call(PTP.Op.getObjectPropValue, [h, UInt32(FujiWifiProp.dateCreated)], "DateCreated", allowFailure: true)
            if d.isOK {
                date = CaptureTime.parsePTP(parsePTPString(d.data))
                if dateCreatedUseful == nil {
                    dateCreatedUseful = date != nil
                    if date == nil { log("the camera's DateCreated isn't a date; reading each file's EXIF date instead") }
                }
            }
        }
        return ImportItem(id: "ptp:\(h)", name: name, size: size, captured: date)
    }

    // MARK: Wire

    /// Wi-Fi: D226 = 2 once (originals; fuji-bridge's ImageForceCompression) or D22E = 1 + D226 = 1 (resized copies), and
    /// D227 again after a reconnect.
    private func prepareWifi() async throws {
        try Task.checkCancellation()
        guard layout == .fujiWifi else { return }
        if !forceOriginalsSet {
            if photoSize == .resized {
                let rate = try await setProp(FujiWifiProp.resizeRate, u16: FujiWifiProp.resizeRateS)
                guard rate.isOK || rate.code == PTP.Response.devicePropNotSupported else {
                    throw ImportError.refused("smartphone photo size", code: rate.code)
                }
                if !rate.isOK { log("D22E unsupported; using the camera's default browse-copy size") }
                let r = try await setProp(FujiWifiProp.forceCompression, u16: 1)
                guard r.isOK else { throw ImportError.refused("resized photo transfer", code: r.code) }
            } else {
                let r = try await setProp(FujiWifiProp.forceCompression, u16: 2)
                guard r.isOK else { throw ImportError.refused("full-size photo transfer", code: r.code) }
            }
            forceOriginalsSet = true
        }
        if realSizeWanted && !realSizeApplied {
            realSizeApplied = try await setProp(FujiWifiProp.realSizeInfo, u16: 1).isOK
            if !realSizeApplied { log("D227 = 1 refused; sizes from GetObjectInfo may be wrong (the end-of-file check covers it)") }
        }
    }

    private func handle(of item: ImportItem) throws -> UInt32 {
        guard item.id.hasPrefix("ptp:"), let h = UInt32(item.id.dropFirst(4)) else {
            throw ImportError.invalid("\(item.name) didn't come from this camera")
        }
        return h
    }

    private func partialParams(_ handle: UInt32, offset: Int, length: Int) throws -> [UInt32] {
        guard offset >= 0, length > 0, length <= Int(UInt32.max) else {
            throw ImportError.invalid("The requested photo byte range is invalid.")
        }
        var params = [handle, UInt32(truncatingIfNeeded: offset), UInt32(length)]
        if UInt64(offset) > UInt64(UInt32.max) { params.append(UInt32(UInt64(offset) >> 32)) }
        return params
    }

    private func setProp(_ prop: UInt16, u16 value: Int) async throws -> PTPResult {
        try await FujiWifiCommand.setProperty(transport, property: prop, data: PTPPack.u16(value), timeout: commandTimeout)
    }

    private func call(_ op: UInt16, _ params: [UInt32], _ what: String, allowFailure: Bool = false, timeout: Duration? = nil) async throws -> PTPResult {
        try Task.checkCancellation()
        let r: PTPResult
        do {
            r = try await transport.transact(op, params: params, dataOut: nil, timeout: timeout ?? commandTimeout)
        } catch let e as ImportError {
            throw e
        } catch let e as CameraError {
            switch e {
            case .timeout(let s): throw ImportError.timeout(s)
            case .disconnected(let s), .transport(let s): throw ImportError.link(s)
            default: throw ImportError.link(e.description)
            }
        }
        if !allowFailure && !r.isOK && r.code != PTP.Response.sessionAlreadyOpen {
            throw ImportError.refused(what, code: r.code)
        }
        return r
    }
}

// MARK: - Codes and datasets

extension PTP.Op {
    public static let getThumb: UInt16 = 0x100A
    public static let deleteObject: UInt16 = 0x100B
    public static let getPartialObject: UInt16 = 0x101B
    /// MTP GetObjectPropValue (reads a file's size; fuji-bridge Bytes.swift).
    public static let getObjectPropValue: UInt16 = 0x9803
    // Fujifilm Wi-Fi gallery setup (libfuji lib/fujiptp.h:195-200 and its gallery setup in fuji.c).
    public static let fujiGetImageImportFolders: UInt16 = 0x9050
    public static let fujiGetImageImportDates: UInt16 = 0x9053
    public static let fujiGetExtensionObjectInfo: UInt16 = 0x9054
    public static let fujiGetExtensionThumb: UInt16 = 0x9055
}

/// Fujifilm Wi-Fi properties (libfuji lib/fujiptp.h:45-104; fuji-bridge Bytes.swift `Fuji`).
public enum FujiWifiProp {
    /// Change list: u16 n, n × (u16 code, u32 value). DF00 is not always first.
    public static let events: UInt16 = 0xD212
    public static let objectCount: UInt16 = 0xD222
    /// ImageForceCompression (fuji-bridge's name): 2 originals, 1 resized, 0 outside an import.
    public static let forceCompression: UInt16 = 0xD226
    /// Resize rate for D226 = 1: 0 XS, 1 S (written before D226 = 1).
    public static let resizeRate: UInt16 = 0xD22E
    public static let resizeRateS = 1
    /// 1 = ObjectInfo reports the real size (libfuji sets it; reading ObjectSize via 9803 also works).
    public static let realSizeInfo: UInt16 = 0xD227
    public static let unknownD22B: UInt16 = 0xD22B
    public static let batteryMulti: UInt16 = 0xD242
    public static let importCount: UInt16 = 0xD620
    /// Import handles: u32 count, count × u32 (X100VI lists them newest first).
    public static let importHandles: UInt16 = 0xD621
    /// 0 wait for OK · 1 multi-transfer · 2 full access · 3 PC AutoSave · 6 remote access.
    public static let cameraState: UInt16 = 0xDF00
    /// 1 view multiple · 2 view all · 5 remote · 11 remote image view · 20 phone-app gallery · 22 phone-app live view (libfuji).
    public static let clientState: UInt16 = 0xDF01
    public static let imageGetVersion: UInt16 = 0xDF21
    public static let getObjectVersion: UInt16 = 0xDF22
    public static let remoteVersion: UInt16 = 0xDF24
    public static let remoteGetObjectVersion: UInt16 = 0xDF25
    public static let remotePhotoViewExVersion: UInt16 = 0xDF28
    // MTP object property codes asked with GetObjectPropValue.
    public static let objectSize: UInt16 = 0xDC04
    public static let objectFileName: UInt16 = 0xDC07
    public static let dateCreated: UInt16 = 0xDC08

    /// Gallery client state (fuji-bridge sets it after a Bluetooth wake; libfuji fujiptp.h names it too).
    public static let clientStateGallery = 20
    /// "View all images and have normal PTP functionality" (libfuji FUJI_VIEW_ALL_IMGS), for older bodies.
    public static let clientStateViewAll = 2
}

/// D212 change list (libfuji `PtpFujiEvents`, fuji-bridge `FujiEvents`).
public enum FujiEvents {
    public static func parse(_ data: Data) -> [UInt16: UInt32] {
        let b = [UInt8](data)
        guard b.count >= 2 else { return [:] }
        let n = Int(LE.u16(b, 0))
        var out: [UInt16: UInt32] = [:]
        var o = 2
        for _ in 0..<n where o + 6 <= b.count {
            out[LE.u16(b, o)] = LE.u32(b, o + 2)
            o += 6
        }
        return out
    }

    public static func encode(_ items: [(UInt16, UInt32)]) -> Data {
        var d = Data()
        d.appendLE16(UInt16(items.count))
        for (code, value) in items { d.appendLE16(code); d.appendLE32(value) }
        return d
    }
}

/// u32 count, then count × u32 (PTP object handle arrays; Fujifilm's D621 the same way, libpict per fuji-bridge).
public enum FujiArray {
    public static func decode(_ data: Data) -> [UInt32] {
        decodeValidated(data) ?? []
    }

    /// Distinguish an empty card from a truncated or corrupt handle dataset before describing any object.
    public static func decodeValidated(_ data: Data) -> [UInt32]? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        let n = Int(LE.u32(b, 0))
        guard n <= 100_000, b.count == 4 + n * 4 else { return nil }
        return (0..<n).map { LE.u32(b, 4 + $0 * 4) }
    }

    public static func encode(_ values: [UInt32]) -> Data {
        var d = Data()
        d.appendLE32(UInt32(values.count))
        for v in values { d.appendLE32(v) }
        return d
    }
}

/// The parts of an ObjectInfo dataset the importer needs.
public struct PTPObjectInfo: Sendable, Equatable {
    public var format: UInt16
    public var size: Int
    public var filename: String
    /// PTP DateTime string, "20261009T143012".
    public var captureDate: String?
    /// Association (folder such as DCIM/100_FUJI): format 0x3001.
    public var isFolder: Bool { format == 0x3001 }

    /// Standard: ISO 15740 §5.5.2 (ObjectCompressedSize u32 @8). Fujifilm Wi-Fi: compressed_size u32 @13
    /// (libfuji `PtpFujiObjectInfo`). Both: Filename, CaptureDate, ModificationDate, Keywords as PTP strings from @52.
    public init?(_ data: Data, layout: PTPCardSource.Layout) {
        let b = [UInt8](data)
        guard b.count > 52 else { return nil }
        format = LE.u16(b, 4)
        size = Int(LE.u32(b, layout == .fujiWifi ? 13 : 8))
        var r = PTPReader(Data(b[52...]))
        guard let name = try? r.string(), !name.isEmpty else { return nil }
        filename = (name as NSString).lastPathComponent
        let date = try? r.string()
        captureDate = (date?.isEmpty ?? true) ? nil : date
    }

    /// Builds a dataset in `layout` (fake cameras and tests). The Fujifilm one mirrors libfuji's captured X-T sample
    /// (lib/data.c:77-82): filename, date "YYYYMMDDThhmmss", empty modification date, "Orientation:1".
    public static func encode(layout: PTPCardSource.Layout, format: UInt16 = 0x3801, size: Int, filename: String,
                              captureDate: String?, maxPartial: UInt32 = 0x0010_0000) -> Data {
        var head = [UInt8](repeating: 0, count: 52)
        func put32(_ v: UInt32, _ at: Int) { for k in 0..<4 { head[at + k] = UInt8(v >> (8 * UInt32(k)) & 0xFF) } }
        head[0] = 1; head[2] = 1                       // storage 0x00010001
        head[4] = UInt8(format & 0xFF); head[5] = UInt8(format >> 8)
        if layout == .fujiWifi {
            put32(maxPartial, 8)
            put32(UInt32(truncatingIfNeeded: size), 13)
        } else {
            put32(UInt32(truncatingIfNeeded: size), 8)
        }
        var d = Data(head)
        d.append(PTPPack.string(filename))
        d.append(PTPPack.string(captureDate ?? ""))
        d.append(PTPPack.string(""))
        d.append(PTPPack.string(layout == .fujiWifi ? "Orientation:1" : ""))
        return d
    }
}
