// Photo import: the shared vocabulary for every route (USB card reader, camera Wi-Fi, Photos library, a folder).
// Platform-neutral (Foundation only) so the iPhone app and `dialin-cam` use the same engine.
import Foundation

/// How a file reached the Mac or phone. Written into manifest.json.
public enum ImportRoute: String, Codable, Sendable, CaseIterable {
    /// ImageCaptureCore over the USB cable, camera in CONNECTION MODE › USB CARD READER.
    case usb
    /// Fujifilm PTP/IP on the camera's own access point (192.168.0.1:55740).
    case wifi
    /// Already in the Photos library (the phone app's auto-transfer), found with PhotoKit.
    case photos
    /// A folder on disk: the SD card in a reader, or what Image Capture.app copied.
    case folder
}

/// What a file is, from its extension. Fujifilm names: DSCF1234.JPG / .RAF / .HIF / .MOV.
public enum ImportFileKind: String, Sendable, Codable {
    case jpeg, raw, heif, movie, other

    public init(filename: String) {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "raf": self = .raw
        case "hif", "heif", "heic": self = .heif
        case "mov", "mp4": self = .movie
        default: self = .other
        }
    }
}

/// A capture time as the camera wrote it: wall-clock fields in the camera's own time zone, plus the UTC offset when
/// the file says (EXIF OffsetTimeOriginal, or a "+hhmm" suffix on a PTP date). Folders and `--since` use the wall-clock
/// date, so a photo taken at 23:50 lands on that day whatever the Mac's time zone is.
public struct CaptureTime: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var year: Int, month: Int, day: Int
    public var hour: Int, minute: Int, second: Int
    /// Seconds east of UTC, when the source states it.
    public var utcOffset: Int?

    public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, utcOffset: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.utcOffset = utcOffset
    }

    /// Wall-clock fields of `date` in `timeZone` (ImageCaptureCore and PhotoKit hand us `Date`s).
    public init(date: Date, timeZone: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1, hour: c.hour ?? 0, minute: c.minute ?? 0,
                  second: c.second ?? 0, utcOffset: timeZone.secondsFromGMT(for: date))
    }

    /// "2026-10-09": the folder name and what `--since` compares against.
    public var dayKey: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// "2026-10-09T14:30:12", plus "+02:00" when the offset is known. What manifest.json stores.
    public var iso: String {
        let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second)
        guard let off = utcOffset else { return base }
        let sign = off < 0 ? "-" : "+"
        let a = abs(off)
        return base + String(format: "%@%02d:%02d", sign, a / 3600, (a % 3600) / 60)
    }

    public var description: String { iso }

    /// Sortable wall-clock value (offset ignored: everything on one card shares the camera's clock).
    var sortKey: Int { ((((year * 100 + month) * 100 + day) * 100 + hour) * 100 + minute) * 100 + second }

    public static func < (a: CaptureTime, b: CaptureTime) -> Bool { a.sortKey < b.sortKey }
    public static func == (a: CaptureTime, b: CaptureTime) -> Bool { a.sortKey == b.sortKey }
    public func hash(into h: inout Hasher) { h.combine(sortKey) }

    var isPlausible: Bool {
        (1990...2100).contains(year) && (1...12).contains(month) && (1...31).contains(day)
            && (0...23).contains(hour) && (0...59).contains(minute) && (0...60).contains(second)
    }

    /// PTP DateTime string (ISO 15740 §5.3.5): "YYYYMMDDThhmmss[.s][Z|±hhmm]". An X100VI over USB sends
    /// "20260924T195324" (fuji-bridge Bytes.swift `ObjectInfo.captureDate`); libfuji's Wi-Fi ObjectInfo sample carries
    /// "20150524T011710" (libfuji lib/data.c:77-82).
    public static func parsePTP(_ raw: String) -> CaptureTime? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        let chars = Array(s)
        guard chars.count >= 15, chars[8] == "T" else { return nil }
        func num(_ r: Range<Int>) -> Int? { Int(String(chars[r])) }
        guard let y = num(0..<4), let mo = num(4..<6), let d = num(6..<8),
              let h = num(9..<11), let mi = num(11..<13), let se = num(13..<15) else { return nil }
        var rest = Array(chars[15...])
        if rest.first == "." { rest = Array(rest.drop(while: { $0 == "." || $0.isNumber })) }
        var offset: Int?
        if rest.first == "Z" {
            offset = 0
        } else if let sign = rest.first, sign == "+" || sign == "-" {
            let digits = rest.dropFirst().filter(\.isNumber)
            if digits.count >= 4, let hh = Int(String(digits.prefix(2))), let mm = Int(String(digits.dropFirst(2).prefix(2))) {
                offset = (hh * 3600 + mm * 60) * (sign == "-" ? -1 : 1)
            }
        }
        let t = CaptureTime(year: y, month: mo, day: d, hour: h, minute: mi, second: se, utcOffset: offset)
        return t.isPlausible ? t : nil
    }

    /// EXIF DateTimeOriginal "YYYY:MM:DD HH:MM:SS" (EXIF 2.32 tag 0x9003), with OffsetTimeOriginal "+HH:MM" (0x9011).
    public static func parseEXIF(_ raw: String, offset: String? = nil) -> CaptureTime? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" }).map(String.init)
        guard parts.count >= 6, let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
              let h = Int(parts[3]), let mi = Int(parts[4]), let se = Int(parts[5].prefix(2)) else { return nil }
        var off: Int?
        if let o = offset?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))),
           let sign = o.first, sign == "+" || sign == "-" {
            let f = o.dropFirst().split(separator: ":")
            if f.count == 2, let hh = Int(f[0]), let mm = Int(f[1]) { off = (hh * 3600 + mm * 60) * (sign == "-" ? -1 : 1) }
        }
        let t = CaptureTime(year: y, month: mo, day: d, hour: h, minute: mi, second: se, utcOffset: off)
        return t.isPlausible ? t : nil
    }

    /// Parses what `iso` writes (manifest round trip).
    public static func parseISO(_ s: String) -> CaptureTime? {
        guard s.count >= 19 else { return nil }
        let base = String(s.prefix(19))
        let tail = String(s.dropFirst(19))
        return parseEXIF(base, offset: tail.isEmpty ? nil : tail)
    }
}

/// Day keys ("YYYY-MM-DD") for folders and `--since`.
public enum ImportDay {
    /// Today on this device's calendar.
    public static func today(_ now: Date = Date(), timeZone: TimeZone = .current) -> String {
        CaptureTime(date: now, timeZone: timeZone).dayKey
    }

    /// Validates "YYYY-MM-DD" (also accepts "today" and "yesterday").
    public static func parse(_ s: String, now: Date = Date()) -> String? {
        switch s.lowercased() {
        case "today": return today(now)
        case "yesterday": return today(now.addingTimeInterval(-86_400))
        default: break
        }
        let f = s.split(separator: "-")
        guard f.count == 3, f[0].count == 4, let y = Int(f[0]), let m = Int(f[1]), let d = Int(f[2]),
              (1990...2100).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Folder for files whose capture date nobody could tell.
    public static let undated = "undated"
}

/// One file a source can deliver, described from metadata only (nothing downloaded yet).
public struct ImportItem: Sendable, Hashable, Identifiable {
    /// Source-specific key ("ptp:1802", "icc:…", a PhotoKit local identifier, a path).
    public var id: String
    /// The camera's file name, "DSCF1802.JPG". Kept as-is in the library.
    public var name: String
    /// Bytes, when the source knows before downloading.
    public var size: Int?
    /// Capture time from the listing (PTP date, ImageCaptureCore, PhotoKit, EXIF probe).
    public var captured: CaptureTime?
    /// "X100VI" when the source says.
    public var camera: String?

    public init(id: String, name: String, size: Int? = nil, captured: CaptureTime? = nil, camera: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.captured = captured
        self.camera = camera
    }

    public var kind: ImportFileKind { ImportFileKind(filename: name) }
    /// "DSCF1802" for pairing a RAF with its JPEG.
    public var stem: String { ((name as NSString).deletingPathExtension).uppercased() }
    public var dayKey: String { captured?.dayKey ?? ImportDay.undated }
}

/// What the importer should take.
public struct ImportOptions: Sendable {
    /// Oldest day to import ("YYYY-MM-DD"); nil = every day on the card. Default: today.
    public var since: String?
    /// Fetch the camera's small preview for each new photo first (fast look before the full files).
    public var thumbnails: Bool
    /// Stop after the thumbnails.
    public var thumbsOnly: Bool
    public var includeRAW: Bool
    public var includeHEIF: Bool
    public var includeMovies: Bool
    /// Take files nobody could date (only when `since` is nil).
    public var includeUndated: Bool
    /// List and plan only.
    public var dryRun: Bool
    /// Import again even if manifest.json says it's already here.
    public var reimport: Bool
    /// Stop after this many new files (newest first). Nil = no cap.
    public var limit: Int?
    /// Look only at the newest `last` files on the card (RAF and JPEG count separately). Nil = walk by date.
    public var last: Int?

    public init(since: String? = ImportDay.today(), thumbnails: Bool = true, thumbsOnly: Bool = false, includeRAW: Bool = true,
                includeHEIF: Bool = true, includeMovies: Bool = false, includeUndated: Bool = false, dryRun: Bool = false,
                reimport: Bool = false, limit: Int? = nil, last: Int? = nil) {
        self.since = since
        self.thumbnails = thumbnails
        self.thumbsOnly = thumbsOnly
        self.includeRAW = includeRAW
        self.includeHEIF = includeHEIF
        self.includeMovies = includeMovies
        self.includeUndated = includeUndated
        self.dryRun = dryRun
        self.reimport = reimport
        self.limit = limit
        self.last = last
    }

    public func wants(_ kind: ImportFileKind) -> Bool {
        switch kind {
        case .jpeg: true
        case .raw: includeRAW
        case .heif: includeHEIF
        case .movie: includeMovies
        case .other: false
        }
    }

    /// True when a file from `day` is in range. Undated files only pass with no `since` and `includeUndated`.
    public func wants(day: String?) -> Bool {
        guard let day, day != ImportDay.undated else { return since == nil && includeUndated }
        guard let since else { return true }
        return day >= since
    }
}

/// Hints a source may use to keep the listing short (the camera's Wi-Fi is slow to describe a file).
public struct ListHint: Sendable {
    /// Oldest wanted day. A source that walks newest-first may stop once it is well past it.
    public var since: String?
    /// Only the newest `last` objects on the card (explicit choice; no date needed). Nil = no cap.
    public var last: Int?
    public init(since: String? = nil, last: Int? = nil) {
        self.since = since
        self.last = last
    }
}

/// What happens during an import, for a progress UI or the CLI.
public enum ImportEvent: Sendable {
    case note(String)
    case listed(total: Int)
    case planned(ImportPlanSummary)
    case thumbnail(ImportItem, URL)
    case downloading(ImportItem, index: Int, of: Int)
    case progress(ImportItem, bytes: Int, total: Int?)
    case saved(ImportItem, URL, bytes: Int, seconds: Double)
    case skipped(ImportItem, String)
    case failed(ImportItem, String)
}

public struct ImportPlanSummary: Sendable, Equatable {
    /// Files on the card (all kinds).
    public var listed: Int
    /// Wanted kinds in the date range.
    public var inRange: Int
    /// Already in the library (manifest or same file on disk).
    public var already: Int
    /// New files to fetch.
    public var toFetch: Int
    /// Older than `since`.
    public var tooOld: Int
    /// No capture date anywhere.
    public var undated: Int
    /// Skipped kinds (movies, other files, RAW/HEIF when excluded).
    public var otherKinds: Int
}

public struct ImportSummary: Sendable {
    public var route: ImportRoute
    public var plan: ImportPlanSummary
    public var saved: [ImportManifest.Entry] = []
    public var thumbnails = 0
    public var failures: [(name: String, reason: String)] = []
    public var bytes = 0
    public var seconds = 0.0
    /// Day folders touched.
    public var folders: [URL] = []
    /// True when the run stopped early (link lost, cancelled); re-running resumes.
    public var interrupted = false
    public var interruption: String?
}

/// Errors from the import paths, in words to show the photographer.
public enum ImportError: Error, Equatable, CustomStringConvertible, Sendable {
    case noCamera(String)
    case link(String)
    case timeout(String)
    case refused(String, code: UInt16)
    case pressOKTimedOut
    case localNetworkDenied
    case wifiJoin(String)
    case invalid(String)
    case incomplete(String)
    case notAuthorized(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .noCamera(let s): s
        case .link(let s): "Lost the camera: \(s)"
        case .timeout(let s): "The camera didn't answer (\(s))."
        case .refused(let what, let code): "The camera refused \(what) (\(PTP.Response.name(code)))."
        case .pressOKTimedOut: "The camera kept waiting for OK. Press MENU/OK on the camera when it asks to allow the connection, then run the command again."
        case .localNetworkDenied:
            #if os(iOS)
            "This iPhone blocked access to the camera. Open Settings › Apps › Dial In and turn on Local Network, then try connecting again."
            #else
            "macOS blocked the connection to the camera (Local Network privacy). System Settings › Privacy & Security › Local Network › turn on your terminal app (Terminal / iTerm / Ghostty), then run the command again."
            #endif
        case .wifiJoin(let s): s
        case .invalid(let s): s
        case .incomplete(let s): s
        case .notAuthorized(let s): s
        case .unsupported(let s): s
        }
    }

    /// Worth reconnecting for (a dead socket or a missed answer), as opposed to a refusal.
    public var isLinkFailure: Bool {
        switch self {
        case .link, .timeout: true
        default: false
        }
    }
}
