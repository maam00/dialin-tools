// Just enough EXIF to date and identify a Fujifilm file: Make, Model, DateTimeOriginal (+ offset), and the
// embedded thumbnail. Works on a truncated head (the first 64 KB of a JPEG), on a whole JPEG, and on a RAF
// (whose header points at an embedded JPEG). Pure Swift, bounds-checked, no ImageIO, so it runs anywhere.
//
// Layouts: JPEG markers and the "Exif\0\0" APP1 (EXIF 2.32 §4.5.4 / §4.6), TIFF IFDs (TIFF 6.0 §2). The JPEG walk is
// the same shape as fuji-bridge's `Exif.orientation` (FujiBridge/Bytes.swift, MIT, Copyright (c) 2026 Thomas
// Marchand). RAF header: "FUJIFILMCCD-RAW " magic, embedded JPEG offset/length as big-endian u32 at 84/88 (the layout
// dcraw, LibRaw and exiftool document for Fujifilm RAF).
import Foundation

public struct ExifInfo: Sendable, Equatable {
    public var make: String?
    public var model: String?
    /// EXIF DateTimeOriginal (0x9003), "YYYY:MM:DD HH:MM:SS".
    public var dateTimeOriginal: String?
    /// EXIF OffsetTimeOriginal (0x9011), "+HH:MM".
    public var offsetTimeOriginal: String?
    /// IFD0 DateTime (0x0132): last resort when DateTimeOriginal is missing.
    public var dateTime: String?
    /// IFD1 JPEG thumbnail (0x0201/0x0202), when the bytes are inside the data we were given.
    public var thumbnail: Data?

    public var captured: CaptureTime? {
        if let d = dateTimeOriginal, let t = CaptureTime.parseEXIF(d, offset: offsetTimeOriginal) { return t }
        if let d = dateTime { return CaptureTime.parseEXIF(d) }
        return nil
    }

    /// EXIF Make contains FUJIFILM.
    public var isFujifilm: Bool { make?.uppercased().contains("FUJIFILM") == true }
    /// Make FUJIFILM, Model X100VI.
    public var isX100VI: Bool {
        isFujifilm && model?.uppercased().replacingOccurrences(of: " ", with: "") == "X100VI"
    }
}

public enum ExifReader {
    /// Reads EXIF from a JPEG (or its first bytes), a RAF (or its first bytes, if they reach the embedded JPEG's
    /// EXIF), or a bare TIFF. Nil when there is no EXIF in what was given.
    public static func read(_ data: Data) -> ExifInfo? {
        let b = [UInt8](data)
        if b.count >= 16, b[0..<15].elementsEqual(Array("FUJIFILMCCD-RAW".utf8)) {
            guard let range = rafEmbeddedJPEG(b), range.lowerBound < b.count else { return nil }
            return jpeg(Array(b[range.lowerBound..<min(range.upperBound, b.count)]))
        }
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 { return jpeg(b) }
        if b.count >= 8, (b[0] == 0x49 && b[1] == 0x49) || (b[0] == 0x4D && b[1] == 0x4D) { return tiff(b, base: 0, end: b.count) }
        return nil
    }

    /// Where a RAF keeps its embedded full-size JPEG preview (which carries the EXIF): BE u32 offset @84, length @88.
    public static func rafEmbeddedJPEG(_ data: Data) -> Range<Int>? { rafEmbeddedJPEG([UInt8](data)) }

    static func rafEmbeddedJPEG(_ b: [UInt8]) -> Range<Int>? {
        guard b.count >= 92, b[0..<15].elementsEqual(Array("FUJIFILMCCD-RAW".utf8)) else { return nil }
        let off = Int(be32(b, 84)), len = Int(be32(b, 88))
        guard off > 0, len > 0 else { return nil }
        return off..<(off + len)
    }

    /// Walks JPEG markers up to SOS looking for the EXIF APP1.
    static func jpeg(_ b: [UInt8]) -> ExifInfo? {
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }                       // fill byte
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            if marker == 0xDA || marker == 0xD9 { return nil }           // image data / end: no EXIF before it
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2 else { return nil }
            let segEnd = min(i + 2 + length, b.count)
            if marker == 0xE1, i + 10 <= b.count, b[(i + 4)..<(i + 10)].elementsEqual([0x45, 0x78, 0x69, 0x66, 0, 0]) {
                return tiff(b, base: i + 10, end: segEnd)
            }
            i += 2 + length
        }
        return nil
    }

    /// TIFF header + IFD0 (+ Exif IFD, + IFD1 for the thumbnail). Offsets are relative to `base`.
    static func tiff(_ b: [UInt8], base: Int, end: Int) -> ExifInfo? {
        guard base + 8 <= end, end <= b.count else { return nil }
        let little: Bool
        switch (b[base], b[base + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= end else { return nil }
            return little ? Int(b[at]) | Int(b[at + 1]) << 8 : Int(b[at]) << 8 | Int(b[at + 1])
        }
        func u32(_ at: Int) -> Int? {
            guard let lo = u16(little ? at : at + 2), let hi = u16(little ? at + 2 : at) else { return nil }
            return lo | hi << 16
        }
        guard u16(base + 2) == 42, let ifd0 = u32(base + 4) else { return nil }

        struct Entry { var tag: Int; var type: Int; var count: Int; var valueAt: Int }
        func entries(_ ifdOffset: Int) -> (list: [Entry], next: Int?) {
            let at = base + ifdOffset
            guard ifdOffset > 0, let n = u16(at), n < 1000 else { return ([], nil) }
            var list: [Entry] = []
            for k in 0..<n {
                let e = at + 2 + k * 12
                guard let tag = u16(e), let type = u16(e + 2), let count = u32(e + 4) else { break }
                list.append(Entry(tag: tag, type: type, count: count, valueAt: e + 8))
            }
            return (list, u32(at + 2 + n * 12))
        }
        func string(_ e: Entry) -> String? {
            guard e.type == 2, e.count > 0, e.count < 4096 else { return nil }
            let start: Int
            if e.count <= 4 { start = e.valueAt } else { guard let off = u32(e.valueAt) else { return nil }; start = base + off }
            guard start >= 0, start + e.count <= end else { return nil }
            let bytes = b[start..<(start + e.count)].prefix { $0 != 0 }
            let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
        func long(_ e: Entry) -> Int? {
            if e.type == 4 || e.type == 13 { return u32(e.valueAt) }
            if e.type == 3 { return u16(e.valueAt) }
            return nil
        }

        var info = ExifInfo()
        let (ifd0Entries, ifd1) = entries(ifd0)
        var exifIFD: Int?
        for e in ifd0Entries {
            switch e.tag {
            case 0x010F: info.make = string(e)
            case 0x0110: info.model = string(e)
            case 0x0132: info.dateTime = string(e)
            case 0x8769: exifIFD = long(e)
            default: break
            }
        }
        if let exifIFD {
            var digitized: String?
            for e in entries(exifIFD).list {
                switch e.tag {
                case 0x9003: info.dateTimeOriginal = string(e)
                case 0x9004: digitized = string(e)
                case 0x9011: info.offsetTimeOriginal = string(e)
                default: break
                }
            }
            if info.dateTimeOriginal == nil { info.dateTimeOriginal = digitized }
        }
        if let ifd1, ifd1 > 0 {
            var thumbOffset: Int?, thumbLength: Int?
            for e in entries(ifd1).list {
                if e.tag == 0x0201 { thumbOffset = long(e) }
                if e.tag == 0x0202 { thumbLength = long(e) }
            }
            if let o = thumbOffset, let l = thumbLength, l > 0, base + o + l <= end {
                info.thumbnail = Data(b[(base + o)..<(base + o + l)])
            }
        }
        let empty = info.make == nil && info.model == nil && info.dateTimeOriginal == nil && info.dateTime == nil
        return empty ? nil : info
    }

    static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
}

/// Builds a small JPEG with real EXIF (Make, Model, DateTimeOriginal, OffsetTimeOriginal, an IFD1 thumbnail).
/// Not a decodable picture, but every marker is well-formed: SOI, APP1 "Exif", a stub SOS, EOI. The fake camera
/// serves these and the tests parse them; the byte layout follows EXIF 2.32 §4.6 (big-endian "MM" TIFF here, the
/// byte order Fujifilm bodies write).
public enum SyntheticJPEG {
    public static func make(make: String = "FUJIFILM", model: String = "X100VI", dateTimeOriginal: String,
                            offset: String? = nil, payloadBytes: Int = 4096, seed: UInt8 = 0) -> Data {
        // --- TIFF (big-endian) ---
        var t = [UInt8]()
        func p16(_ v: Int) { t += [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func p32(_ v: Int) { t += [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let thumb: [UInt8] = [0xFF, 0xD8, 0xFF, 0xD9]
        func ascii(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
        let makeB = ascii(make), modelB = ascii(model), dtoB = ascii(dateTimeOriginal), offB = offset.map(ascii)
        // Offsets: header 8, IFD0 (3 entries) at 8, then Exif IFD, then IFD1, then data.
        let ifd0At = 8
        let ifd0Size = 2 + 3 * 12 + 4
        let exifAt = ifd0At + ifd0Size
        let exifCount = offB == nil ? 1 : 2
        let exifSize = 2 + exifCount * 12 + 4
        let ifd1At = exifAt + exifSize
        let ifd1Size = 2 + 2 * 12 + 4
        var dataAt = ifd1At + ifd1Size
        let makeAt = dataAt; dataAt += makeB.count
        let modelAt = dataAt; dataAt += modelB.count
        let dtoAt = dataAt; dataAt += dtoB.count
        let offAt = dataAt; dataAt += offB?.count ?? 0
        let thumbAt = dataAt
        t += [0x4D, 0x4D]; p16(42); p32(ifd0At)
        p16(3)
        p16(0x010F); p16(2); p32(makeB.count); p32(makeAt)
        p16(0x0110); p16(2); p32(modelB.count); p32(modelAt)
        p16(0x8769); p16(4); p32(1); p32(exifAt)
        p32(ifd1At)
        p16(exifCount)
        p16(0x9003); p16(2); p32(dtoB.count); p32(dtoAt)
        if let offB { p16(0x9011); p16(2); p32(offB.count); p32(offAt) }
        p32(0)
        p16(2)
        p16(0x0201); p16(4); p32(1); p32(thumbAt)
        p16(0x0202); p16(4); p32(1); p32(thumb.count)
        p32(0)
        t += makeB + modelB + dtoB + (offB ?? []) + thumb
        // --- JPEG ---
        var j: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1]
        let app1Len = 2 + 6 + t.count
        j += [UInt8(app1Len >> 8), UInt8(app1Len & 0xFF)]
        j += [0x45, 0x78, 0x69, 0x66, 0, 0] + t
        j += [0xFF, 0xDA, 0x00, 0x02]                          // stub SOS header
        var x = UInt32(seed) &+ 0x9E37_79B9
        for _ in 0..<max(0, payloadBytes) {                    // scan data: no 0xFF, so no false markers
            x = x &* 1_664_525 &+ 1_013_904_223
            j.append(UInt8(truncatingIfNeeded: x >> 24) & 0xFE)
        }
        j += [0xFF, 0xD9]
        return Data(j)
    }

    /// A minimal RAF: header with the embedded-JPEG pointer at 84/88, then `jpeg`, then filler "CFA" bytes.
    public static func raf(embedding jpeg: Data, model: String = "X100VI", cfaBytes: Int = 2048) -> Data {
        var h = [UInt8](repeating: 0, count: 160)
        let magic = Array("FUJIFILMCCD-RAW 0201FF383501".utf8)
        h.replaceSubrange(0..<magic.count, with: magic)
        let name = Array(model.utf8.prefix(31))
        h.replaceSubrange(28..<(28 + name.count), with: name)
        func put(_ v: Int, _ at: Int) { h[at] = UInt8(v >> 24 & 0xFF); h[at + 1] = UInt8(v >> 16 & 0xFF); h[at + 2] = UInt8(v >> 8 & 0xFF); h[at + 3] = UInt8(v & 0xFF) }
        put(h.count, 84)
        put(jpeg.count, 88)
        return Data(h) + jpeg + Data(repeating: 0x5A, count: cfaBytes)
    }
}
