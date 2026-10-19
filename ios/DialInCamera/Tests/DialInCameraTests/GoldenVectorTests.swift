// The Swift writer must reproduce the TS writer byte-for-byte.
// Fixtures/slot-write-vectors.json comes from scripts/export-vectors.ts (FujiCamera.writeSlot recorded);
// Fixtures/ts-expectations.json from lib/fuji/recipe.ts + vendor/preset-translate.ts run under tsx.
import Foundation
import Testing
@testable import DialInCamera

@Suite("Golden vectors (TS ↔ Swift)")
struct GoldenVectorTests {
    @Test("SlotEncoder.plan reproduces every TS write, in order, byte-for-byte")
    func encoderMatchesVectors() throws {
        let vectors = try Fixture.vectors()
        #expect(vectors.count == 4)
        for v in vectors {
            let plan = SlotEncoder.plan(slot: v.slot, name: v.recipe.name, values: PresetValues(recipe: v.recipe), base: Fixture.vectorBase)
            #expect(plan == v.propWrites, "\(v.recipe.name): \(plan) vs \(v.propWrites)")
        }
    }

    @Test("FujiCamera.writeSlot sends exactly the TS SetDevicePropValue sequence over PTP")
    func cameraWriteMatchesVectors() async throws {
        for v in try Fixture.vectors() {
            let fake = FakePTPCamera()
            let cam = FujiCamera(transport: fake, timing: .immediate)
            try await cam.connect()
            let report = try await cam.writeSlot(v.slot, recipe: v.recipe, base: Fixture.vectorBase, verify: false)
            let writes = await fake.writes
            #expect(writes == v.propWrites, "\(v.recipe.name)")
            #expect(report.isClean)
            // Every write is a SetDevicePropValue whose single param is the property code.
            let cmds = await fake.commands.filter { $0.op == PTP.Op.setDevicePropValue }
            #expect(cmds.allSatisfy { $0.params.count == 1 })
        }
    }

    @Test("The vector recipes use the camera-safe name unchanged")
    func vectorNamesAreSlotSafe() throws {
        for v in try Fixture.vectors() { #expect(v.recipe.slotName == v.recipe.name) }
    }

    @Test("FilmKit's full encoded block (D18E–D1A5, no base) matches translateUIToPresetProps")
    func presetBlockMatchesTS() throws {
        for s in try Fixture.tsExpectations().summaries {
            let block = SlotEncoder.presetProps(PresetValues(recipe: s.recipe))
            let expected = s.block.map { PropWrite(propID: UInt16($0.id), bytes: Data(hexString: $0.hex)!) }
            #expect(block == expected, "\(s.recipe.name)")
        }
    }

    @Test("Decoding the block back gives the same `show` line as presetValuesToText(translatePresetToUI(...))")
    func summaryMatchesTS() throws {
        for s in try Fixture.tsExpectations().summaries {
            let props = SlotEncoder.presetProps(PresetValues(recipe: s.recipe)).map { RawProp(id: $0.propID, bytes: $0.bytes) }
            #expect(PresetValues(props: props).summary == s.summary)
        }
    }

    @Test("slotName matches recipe.ts slotName")
    func slotNamesMatchTS() throws {
        for pair in try Fixture.tsExpectations().slotNames {
            #expect(Recipe.slotName(pair[0]) == pair[1], "\(pair[0])")
        }
    }

    @Test("Encode → decode round-trips every field of the test-encoding.ts recipes")
    func encodingRoundTrip() throws {
        for s in try Fixture.tsExpectations().summaries {
            let values = PresetValues(recipe: s.recipe)
            let props = SlotEncoder.presetProps(values).map { RawProp(id: $0.propID, bytes: $0.bytes) }
            let back = PresetValues(props: props)
            #expect(back.filmSimulation == values.filmSimulation)
            #expect(back.dynamicRange == values.dynamicRange)
            #expect(back.grainEffect == values.grainEffect)
            #expect(back.colorChrome == values.colorChrome)
            #expect(back.colorChromeFxBlue == values.colorChromeFxBlue)
            #expect(back.whiteBalance == values.whiteBalance)
            #expect(back.wbShiftR == values.wbShiftR)
            #expect(back.wbShiftB == values.wbShiftB)
            #expect(back.highlightTone == values.highlightTone)
            #expect(back.shadowTone == values.shadowTone)
            #expect(back.color == values.color)
            #expect(back.sharpness == values.sharpness)
            #expect(back.noiseReduction == values.noiseReduction)
            #expect(back.clarity == values.clarity)
            if values.whiteBalance == FujiWB.colorTemp { #expect(back.wbColorTemp == values.wbColorTemp) }
            // And back to a Recipe (what "what's in the camera" shows in the app).
            let recipe = try #require(Recipe(name: s.recipe.slotName, values: back))
            var expected = s.recipe
            expected.name = s.recipe.slotName
            if expected.whiteBalance == .kelvin && expected.kelvin == 0 { expected.kelvin = 5500 } // recipe.ts default
            if expected.filmSim.isMonochrome { expected.color = 0 }
            #expect(recipe == expected)
        }
    }
}
