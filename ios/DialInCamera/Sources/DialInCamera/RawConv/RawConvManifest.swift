// The files around a re-render: variants.json in (what to try, from tools/colorlab/propose.py or by hand) and
// renders.json out (what the camera made, with every setting, patch and timing), which tools/colorlab/compare.py reads.
import Foundation

/// One candidate look to render.
public struct RenderVariant: Codable, Sendable, Equatable {
    /// File-safe id: "tune-warmer", "acros-r". Becomes `<photo>__<name>.jpg`.
    public var name: String
    /// Shown on the comparison sheet: "Harbor color, a touch warmer".
    public var label: String?
    /// tune | neighbor | bw | color | rescue | unchanged | recipe | custom
    public var kind: String?
    /// One line, in camera units: "+⅓ lifts her face; the sky holds".
    public var why: String?
    /// What the render should show if it worked ("less clipping on the subject"); compare.py checks it.
    public var expected: String?
    public var settings: RenderSettings

    public init(name: String, label: String? = nil, kind: String? = nil, why: String? = nil, expected: String? = nil,
                settings: RenderSettings) {
        self.name = name
        self.label = label
        self.kind = kind
        self.why = why
        self.expected = expected
        self.settings = settings
    }

    public static let unchanged = RenderVariant(
        name: "unchanged", label: "As shot (camera re-render, profile unchanged)", kind: "unchanged",
        why: "fidelity check against the camera JPEG", settings: .unchanged)

    /// "Harbor Color!" → "harbor-color".
    public static func slug(_ s: String) -> String {
        let mapped = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "variant" : String(collapsed.prefix(48))
    }
}

/// variants.json: `{"photo": …, "raf": …, "variants": [...]}` or a bare array of variants.
public struct VariantsFile: Sendable {
    public var photo: String?
    public var raf: String?
    public var variants: [RenderVariant]

    public static func decode(_ data: Data) throws -> VariantsFile {
        if let arr = try? JSONDecoder().decode([RenderVariant].self, from: data) {
            return VariantsFile(photo: nil, raf: nil, variants: arr)
        }
        struct Wrapper: Decodable {
            var photo: String?
            var raf: String?
            var variants: [RenderVariant]
        }
        let w = try JSONDecoder().decode(Wrapper.self, from: data)
        return VariantsFile(photo: w.photo, raf: w.raf, variants: w.variants)
    }
}

/// renders.json.
public struct RenderManifest: Codable, Sendable {
    public static let schemaID = "dialin.rawconv.renders/1"

    public struct Source: Codable, Sendable {
        public var name: String
        public var raf: String
        public var rafBytes: Int
        /// The camera's own JPEG for this frame (the master), when found.
        public var photo: String?

        enum CodingKeys: String, CodingKey { case name, raf, rafBytes = "raf_bytes", photo }

        public init(name: String, raf: String, rafBytes: Int, photo: String?) {
            self.name = name
            self.raf = raf
            self.rafBytes = rafBytes
            self.photo = photo
        }
    }

    public struct Profile: Codable, Sendable {
        public var length: Int
        public var count: Int
        public var paramsOffset: Int
        public var iop: String
        public var file: String?
        public var hex: String
        public var params: [Int32]
        public var labels: [String]
        public var exposureIndex: D185Layout.ExposureIndexGuess
        public var layout: D185Layout
        public var asShot: D185AsShot

        enum CodingKeys: String, CodingKey {
            case length, count, paramsOffset = "params_offset", iop, file, hex, params, labels
            case exposureIndex = "exposure_index", layout, asShot = "as_shot"
        }
    }

    public struct Record: Codable, Sendable {
        public var name: String
        public var label: String?
        public var kind: String?
        public var why: String?
        public var expected: String?
        public var pass: Int
        public var file: String?
        public var bytes: Int?
        public var imageKind: RenderedImageKind?
        public var width: Int?
        public var height: Int?
        public var sha256: String?
        public var thumbnail: Bool
        public var startValue: Int
        public var settings: RenderSettings
        public var summary: String
        public var changes: [D185Patch.Change]
        public var notes: [String]
        public var steps: [FujiRawConverter.Step]
        public var totalMs: Double?
        public var error: String?

        enum CodingKeys: String, CodingKey {
            case name, label, kind, why, expected, pass, file, bytes, imageKind = "image_kind", width, height, sha256, thumbnail
            case startValue = "start_value", settings, summary, changes, notes, steps, totalMs = "total_ms", error
        }

        public init(variant v: RenderVariant, pass: Int, thumbnail: Bool, startValue: Int) {
            name = v.name
            label = v.label
            kind = v.kind
            why = v.why
            expected = v.expected
            self.pass = pass
            self.thumbnail = thumbnail
            self.startValue = startValue
            settings = v.settings
            summary = v.settings.summary
            changes = []
            notes = []
            steps = []
        }
    }

    public struct Timing: Codable, Sendable {
        public var uploadMs: Double?
        public var firstRenderMs: Double?
        /// Renders after the first (same RAF already in the camera).
        public var laterMeanMs: Double?
        public var laterMinMs: Double?
        public var laterMaxMs: Double?
        public var renders: Int
        /// True when every pass of the same variant returned byte-identical files.
        public var deterministic: Bool?

        enum CodingKeys: String, CodingKey {
            case uploadMs = "upload_ms", firstRenderMs = "first_render_ms", laterMeanMs = "later_mean_ms"
            case laterMinMs = "later_min_ms", laterMaxMs = "later_max_ms", renders, deterministic
        }

        public static func from(upload: [FujiRawConverter.Step], records: [Record]) -> Timing {
            let ok = records.filter { $0.error == nil && $0.totalMs != nil }
            let later = ok.dropFirst().compactMap(\.totalMs)
            var same: Bool?
            let byName = Dictionary(grouping: ok, by: { "\($0.name)#\($0.startValue)#\($0.thumbnail)" })
            for (_, rs) in byName where rs.count > 1 {
                let shas = Set(rs.compactMap(\.sha256))
                same = (same ?? true) && shas.count == 1
            }
            return Timing(
                uploadMs: upload.first { $0.name == "upload" }?.ms, firstRenderMs: ok.first?.totalMs,
                laterMeanMs: later.isEmpty ? nil : later.reduce(0, +) / Double(later.count), laterMinMs: later.min(),
                laterMaxMs: later.max(), renders: ok.count, deterministic: same)
        }
    }

    public var schema = Self.schemaID
    public var createdAt: String
    /// "X100VI in-camera RAW conversion", or a loud label for rehearsals / dry runs.
    public var renderedBy: String
    public var rehearsal: Bool
    public var dryRun: Bool
    /// Always false here; tools/colorlab/preview.py writes true for its approximations.
    public var preview: Bool
    public var source: Source
    public var camera: FujiRawConverter.CameraInfo?
    public var profile: Profile?
    public var upload: [FujiRawConverter.Step]
    public var variants: [Record]
    public var timing: Timing?
    /// Set when the run stopped early (e.g. the camera wedged).
    public var aborted: String?

    enum CodingKeys: String, CodingKey {
        case schema, createdAt = "created_at", renderedBy = "rendered_by", rehearsal, dryRun = "dry_run", preview
        case source, camera, profile, upload, variants, timing, aborted
    }

    public init(createdAt: String, renderedBy: String, rehearsal: Bool, dryRun: Bool, source: Source) {
        self.createdAt = createdAt
        self.renderedBy = renderedBy
        self.rehearsal = rehearsal
        self.dryRun = dryRun
        self.preview = false
        self.source = source
        self.upload = []
        self.variants = []
    }

    public static func profileSection(_ p: D185Profile, layout: D185Layout, file: String?) -> Profile {
        let ev = layout.exposureIndex(for: p)
        return Profile(
            length: p.bytes.count, count: p.count, paramsOffset: p.paramsOffset, iop: p.iopCode, file: file,
            hex: p.bytes.hexString, params: p.params, labels: (0..<p.count).map { layout.label($0, exposureIndex: ev.index) },
            exposureIndex: ev, layout: layout, asShot: D185AsShot(p, layout: layout, exposureIndex: ev.index))
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}
