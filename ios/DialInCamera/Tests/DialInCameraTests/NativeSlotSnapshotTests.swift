import Foundation
import Testing
@testable import DialInCamera

@Suite("Read-only native bank fidelity")
struct NativeSlotSnapshotTests {
    func monoFile() throws -> FujiSettingsFile {
        let file = try FujiSettingsFile(bytes: syntheticSettings())
        let mono = Recipe(name: "Quiet mono", filmSim: .acrosYe, grain: .off, whiteBalance: .auto,
                          dynamicRange: .dr100, noiseReduction: -4)
        return try file.applyingLooks([.init(slot: 7, recipe: mono)]).file
    }

    @Test("A bank retains every byte of its WB preamble and unknown native state")
    func completeRegion() throws {
        let file = try monoFile(), before = file.data
        let snapshot = try file.nativeSnapshot(slot: 7)
        #expect(snapshot.fileRegion == Data(file.bytes[file.slotRegion(7)]))
        #expect(snapshot.fileRegionOffset == file.slotRegion(7).lowerBound)
        #expect(snapshot.fileRegionOffset == file.anchors[6] - 0x80)
        #expect(snapshot.recipe?.filmSim == .acrosYe)
        #expect(!snapshot.isFullyRepresentedByRecipe)
        #expect(file.data == before)
    }

    @Test("Inferred zero tint bytes cannot establish neutral monochrome output")
    func inferredTint() throws {
        let original = try monoFile()
        var bytes = original.bytes
        bytes[original.anchors[6] + 0x70] = 18
        bytes[original.anchors[6] + 0x72] = 18
        let file = try FujiSettingsFile(bytes: bytes)
        let snapshot = try file.nativeSnapshot(slot: 7)
        let tint = snapshot.observations.filter { $0.source == .settingsFile && ($0.key == .monoWarmCool || $0.key == .monoMagentaGreen) }
        #expect(tint.count == 2)
        #expect(tint.allSatisfy { $0.evidence == .inferred && $0.value == nil && $0.raw == Data([18]) })
        #expect(!snapshot.hasReadbackNeutralMonochromeTint)
        #expect(snapshot.reviewNotes.contains { $0.contains("not been established as neutral") })
    }

    @Test("Read-back native tint is signed, preserved and independent of Recipe")
    func tintReadback() throws {
        let file = try monoFile()
        let native = try file.nativeSnapshot(slot: 7, rawProperties: [
            RawProp(id: FujiProp.monoWarmCool, bytes: PTPPack.i16(-70)),
            RawProp(id: FujiProp.monoMagentaGreen, bytes: PTPPack.i16(30)),
        ])
        #expect(native.observations.first { $0.key == .monoWarmCool && $0.source == .slotProperties }?.value == -7)
        #expect(native.observations.first { $0.key == .monoMagentaGreen && $0.source == .slotProperties }?.value == 3)
        #expect(!native.hasReadbackNeutralMonochromeTint)
        #expect(native.recipe == file.recipe(slot: 7))
    }

    @Test("Both actual neutral-axis property values are needed; absence does not default to zero")
    func neutralEvidence() throws {
        let file = try monoFile()
        let one = [RawProp(id: FujiProp.monoWarmCool, bytes: PTPPack.i16(0))]
        #expect(!(try file.nativeSnapshot(slot: 7, rawProperties: one)).hasReadbackNeutralMonochromeTint)
        let both = one + [RawProp(id: FujiProp.monoMagentaGreen, bytes: PTPPack.i16(0))]
        #expect(try file.nativeSnapshot(slot: 7, rawProperties: both).hasReadbackNeutralMonochromeTint)
        let missing = try file.nativeSnapshot(slot: 7).observations.first { $0.key == .dRangePriority && $0.source == .slotProperties }
        #expect(missing?.value == nil && missing?.evidence == .unknown)
    }

    @Test("Malformed, duplicate and out-of-range properties stay raw rather than invented settings")
    func invalidProperties() throws {
        let file = try monoFile()
        let props = [RawProp(id: FujiProp.monoWarmCool, bytes: Data([0])),
                     RawProp(id: FujiProp.monoMagentaGreen, bytes: PTPPack.i16(190)),
                     RawProp(id: FujiProp.dRangePriority, bytes: PTPPack.u16(0)),
                     RawProp(id: FujiProp.dRangePriority, bytes: PTPPack.u16(2))]
        let snapshot = try file.nativeSnapshot(slot: 7, rawProperties: props)
        #expect(snapshot.properties.map(\.hex) == props.map { $0.bytes.hexString })
        let reads = snapshot.observations.filter { $0.source == .slotProperties && $0.raw != nil }
        #expect(reads.count == 4 && reads.allSatisfy { $0.value == nil && $0.evidence == .unknown })
    }

    @Test("Unknown WB and DR Auto remain native readback, not an invented Auto/DR100 recipe")
    func unrepresentedModes() throws {
        let snapshot = SlotSnapshot(slot: 3, name: "Custom faces", rawProps: [
            RawProp(id: FujiProp.whiteBalance, bytes: PTPPack.u16(0x8010)),
            RawProp(id: FujiProp.dynamicRange, bytes: PTPPack.u16(0)),
            RawProp(id: FujiProp.dRangePriority, bytes: PTPPack.u16(0x8000)),
        ])
        let native = try snapshot.nativeSnapshot()
        #expect(native.recipe == nil)
        #expect(native.observations.first { $0.key == .whiteBalance }?.value == Double(0x8010))
        #expect(native.observations.first { $0.key == .whiteBalance }?.label == nil)
        #expect(native.observations.first { $0.key == .dynamicRange }?.label == "Auto")
        #expect(native.observations.first { $0.key == .dRangePriority }?.label == "Auto")
    }

    @Test("Unknown/malformed property entries survive JSON evidence export exactly")
    func exportRoundtrip() throws {
        let original = SlotSnapshot(slot: 2, name: "Native bank", props: [
            .init(id: 0xD199, hex: "not-valid-hex"), .init(id: 0xEEEE, hex: "0102030405"),
        ])
        let native = try original.nativeSnapshot()
        let decoded = try JSONDecoder().decode(NativeSlotSnapshot.self, from: native.jsonData())
        #expect(decoded == native)
        #expect(decoded.properties == original.props)
        #expect(decoded.fileRegion == nil)
        #expect(decoded.observations.first { $0.key == .whiteBalance }?.value == nil)
    }

    @Test("A raw blob field outside observed format values remains inferred")
    func formatEvidence() throws {
        let file = try monoFile()
        let good = try file.nativeSnapshot(slot: 7)
        #expect(good.observations.first { $0.key == .imageQuality && $0.source == .settingsFile }?.label == "Fine+RAW")
        var bytes = file.bytes
        bytes[file.anchors[6] + 0x32] = 4
        let changed = try FujiSettingsFile(bytes: bytes).nativeSnapshot(slot: 7)
        let quality = changed.observations.first { $0.key == .imageQuality && $0.source == .settingsFile }
        #expect(quality?.value == nil && quality?.evidence == .inferred && quality?.raw == Data([4]))
        #expect(changed.fileRegion != good.fileRegion)
    }

    @Test("Snapshot validation rejects invalid slots without indexing the file")
    func invalidSlot() throws {
        let file = try monoFile()
        for slot in [0, 8, -1] {
            #expect(throws: SettingsFileError.self) { try file.nativeSnapshot(slot: slot) }
            #expect(throws: SettingsFileError.self) { try SlotSnapshot(slot: slot, name: "Bad", props: []).nativeSnapshot() }
        }
    }
}
