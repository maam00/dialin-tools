import Foundation

/// Read-only evidence beside Recipe. A Recipe is a rendering subset, never a complete native-bank backup.
/// Raw bytes are retained even when their semantics or their settings-file location are unverified.
public struct NativeSlotSnapshot: Codable, Equatable, Sendable {
    public enum Key: String, Codable, CaseIterable, Sendable {
        case monoWarmCool = "mono_warm_cool", monoMagentaGreen = "mono_magenta_green"
        case dRangePriority = "dr_priority", smoothSkin = "smooth_skin", whiteBalance = "white_balance"
        case dynamicRange = "dynamic_range", imageSize = "image_size", aspectRatio = "aspect_ratio"
        case imageQuality = "image_quality", colorSpace = "color_space", heif, rawRecording = "raw_recording"
    }

    public struct Observation: Codable, Equatable, Sendable {
        public enum Source: String, Codable, Sendable { case settingsFile, slotProperties }
        public enum Evidence: String, Codable, Sendable { case correlated, inferred, readback, unknown }
        public let key: Key
        public let source: Source
        public let evidence: Evidence
        /// Semantic value only when readback/correlation supports that value. Unknown never becomes zero.
        public let value: Double?
        public let label: String?
        public let raw: Data?
        public let absoluteOffset: Int?
        public let propertyID: UInt16?
        public let note: String
    }

    public let slot: Int
    public let name: String
    public let recipe: Recipe?
    /// Includes the complete WB/Kelvin preamble and all unrecognized bytes. Private evidence, not a write target.
    public let fileRegion: Data?
    public let fileRegionOffset: Int?
    /// Exact entries, including unknown codes, malformed hex and duplicates in an existing snapshot.
    public let properties: [SlotSnapshot.Prop]
    public let observations: [Observation]
    public let layout: String?
    public var isFullyRepresentedByRecipe: Bool { false }

    /// This deliberately requires actual property evidence for both axes, not two assumed zero blob bytes.
    public var hasReadbackNeutralMonochromeTint: Bool {
        [Key.monoWarmCool, Key.monoMagentaGreen].allSatisfy { key in
            let reads = observations.filter { $0.key == key && $0.source == .slotProperties }
            return reads.count == 1 && reads[0].evidence == .readback && reads[0].value == 0
        }
    }

    public var reviewNotes: [String] {
        var notes = ["The recipe describes supported rendering fields. The exact native bank retains additional settings."]
        if recipe?.filmSim.isMonochrome == true && !hasReadbackNeutralMonochromeTint {
            notes.append("Monochrome tint has not been established as neutral. Loading this recipe does not clear either native tint axis.")
        }
        if recipe == nil { notes.append("This bank contains values the recipe schema cannot represent. Keep its native state; do not infer a replacement from its name.") }
        if observations.contains(where: { $0.evidence == .inferred }) {
            notes.append("Inferred file locations are retained as raw evidence only; they are not confirmed settings or permitted writes.")
        }
        return notes
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension FujiSettingsFile {
    /// Offline only. The caller must ensure supplemental properties are fresh reads from this exact body/bank;
    /// the function does not normalize camera identities or contact a camera to establish that provenance.
    public func nativeSnapshot(slot: Int, rawProperties: [RawProp] = []) throws -> NativeSlotSnapshot {
        guard (1...7).contains(slot) else { throw SettingsFileError.invalid("slot \(slot) is not 1…7") }
        let anchor = anchors[slot - 1], region = slotRegion(slot)
        var observations: [NativeSlotSnapshot.Observation] = []
        typealias Observation = NativeSlotSnapshot.Observation
        func file(_ key: NativeSlotSnapshot.Key, rel: Int, evidence: Observation.Evidence, value: Double? = nil,
                  label: String? = nil, note: String) {
            let offset = anchor + rel
            observations.append(Observation(key: key, source: .settingsFile, evidence: evidence, value: value,
                label: label, raw: Data([bytes[offset]]), absoluteOffset: offset, propertyID: nil, note: note))
        }
        // The existing map explicitly labels these X-T5-derived mono locations inferred, including raw 18.
        // Retain bytes; do not turn a plausible zero into neutral-tint proof.
        file(.monoWarmCool, rel: 0x72, evidence: .inferred, note: "Candidate +0x72 location from x100vi-fw110.json; arbitrary toning has not been correlated on this body.")
        file(.monoMagentaGreen, rel: 0x70, evidence: .inferred, note: "Candidate +0x70 location from x100vi-fw110.json; arbitrary toning has not been correlated on this body.")
        for (key, mapKey) in [(NativeSlotSnapshot.Key.dRangePriority, "dr_priority"), (.smoothSkin, "smooth_skin"),
                              (.whiteBalance, "white_balance"), (.dynamicRange, "dynamic_range")] {
            guard let field = LookSlotMap.field(mapKey) else { continue }
            let raw = Int(bytes[anchor + field.rel])
            let decoded = field.decode(raw: raw)?.double
            let supported: Bool
            switch field.encoding {
            case .enumeration(let known, _, let aliases): supported = known.values.contains(raw) || aliases[raw] != nil
            default: supported = field.located || decoded.map { field.observed.contains(String(Int($0))) } == true
            }
            file(key, rel: field.rel, evidence: supported && decoded != nil ? .correlated : .inferred,
                 value: supported ? decoded : nil,
                 label: key == .dRangePriority && supported && decoded == 0 ? "Off" : nil,
                 note: supported ? "Existing file-map correlation; this is not a claim of arbitrary-value write acceptance."
                    : "Raw byte preserved; this value/location has no established semantic mapping for this snapshot.")
        }
        for (key, mapKey) in [(NativeSlotSnapshot.Key.imageSize, "image_size"), (.aspectRatio, "aspect_ratio"),
                              (.imageQuality, "image_quality"), (.heif, "heif"), (.rawRecording, "raw_recording")] {
            guard let field = Self.slotField(mapKey) else { continue }
            let raw = Int(bytes[anchor + field.rel]), label = field.codes[raw]
            // The current evidence records one value for each of these fields, not their whole native range.
            let observed: [String: Int] = ["image_size": 0, "aspect_ratio": 1, "image_quality": 2]
            let correlated = field.status == .consistent && observed[mapKey] == raw && label != nil
            file(key, rel: field.rel, evidence: correlated ? .correlated : .inferred,
                 value: correlated ? Double(raw) : nil, label: correlated ? label : nil, note: field.evidence)
        }
        observations += nativePropertyObservations(rawProperties)
        return NativeSlotSnapshot(slot: slot, name: name(slot: slot), recipe: recipe(slot: slot),
            fileRegion: Data(bytes[region]), fileRegionOffset: region.lowerBound,
            properties: rawProperties.map { .init(id: Int($0.id), hex: $0.bytes.hexString) },
            observations: observations, layout: "X100VI-0100-70524")
    }
}

extension SlotSnapshot {
    /// Preserves the original property entries even when rawProps cannot parse them. No settings operation.
    public func nativeSnapshot() throws -> NativeSlotSnapshot {
        guard (1...7).contains(slot) else { throw SettingsFileError.invalid("slot \(slot) is not 1…7") }
        return NativeSlotSnapshot(slot: slot, name: name, recipe: recipe, fileRegion: nil, fileRegionOffset: nil,
            properties: props, observations: nativePropertyObservations(rawProps), layout: nil)
    }
}

private func nativePropertyObservations(_ properties: [RawProp]) -> [NativeSlotSnapshot.Observation] {
    typealias Key = NativeSlotSnapshot.Key
    typealias Observation = NativeSlotSnapshot.Observation
    let fields: [(Key, UInt16)] = [(.monoWarmCool, FujiProp.monoWarmCool), (.monoMagentaGreen, FujiProp.monoMagentaGreen),
        (.dRangePriority, FujiProp.dRangePriority), (.smoothSkin, FujiProp.smoothSkin), (.whiteBalance, FujiProp.whiteBalance),
        (.dynamicRange, FujiProp.dynamicRange), (.imageSize, FujiProp.imageSize), (.imageQuality, FujiProp.imageQuality),
        (.colorSpace, FujiProp.colorSpace)]
    return fields.flatMap { key, code -> [Observation] in
        let matches = properties.filter { $0.id == code }
        guard !matches.isEmpty else {
            return [Observation(key: key, source: .slotProperties, evidence: .unknown, value: nil, label: nil,
                raw: nil, absoluteOffset: nil, propertyID: code, note: "No property read was supplied; absent does not mean Off or zero.")]
        }
        return matches.map { property in
            let raw = [UInt8](property.bytes)
            // These native properties are two-byte integers, never decode a malformed payload heuristically.
            let wire = raw.count == 2 ? Int(LE.u16(raw, 0)) : nil
            var value = wire.map(Double.init)
            var label: String?
            if key == .monoWarmCool || key == .monoMagentaGreen {
                let signed = wire.map { Int(Int16(bitPattern: UInt16($0))) }
                value = signed.flatMap { (-180...180).contains($0) && $0 % 10 == 0 ? Double($0) / 10 : nil }
            } else if key == .dRangePriority {
                label = wire.flatMap { [0: "Off", 1: "Weak", 2: "Strong", 0x8000: "Auto"][$0] }
                if label == nil { value = nil }
            } else if key == .smoothSkin {
                label = wire.flatMap { [1: "Off", 2: "Weak", 3: "Strong"][$0] }
                if label == nil { value = nil }
            } else if key == .dynamicRange {
                label = wire.flatMap { [0: "Auto", 100: "DR100", 200: "DR200", 400: "DR400"][$0] }
                if label == nil { value = nil }
            } else if key == .whiteBalance {
                label = wire.flatMap { WhiteBalance(code: $0)?.rawValue }
                // An unknown WB code remains a real observed code, never gets replaced with Auto.
            }
            let coherent = matches.count == 1 && value != nil
            return Observation(key: key, source: .slotProperties, evidence: coherent ? .readback : .unknown,
                value: coherent ? value : nil, label: coherent ? label : nil, raw: property.bytes,
                absoluteOffset: nil, propertyID: code,
                note: matches.count > 1 ? "Conflicting/duplicate property entries retained; no single value chosen."
                    : coherent ? "Supplied slot-property readback, scoped by the caller; not settings-file write acceptance."
                    : "Malformed or unrecognized property value retained without a fabricated setting.")
        }
    }
}
