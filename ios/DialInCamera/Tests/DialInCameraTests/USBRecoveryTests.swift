import Foundation
import Testing
@testable import DialInCamera

@Suite("USB recovery from real monochrome round-trip failure")
struct USBRecoveryTests {
    func setup() async throws -> (FakePTPCamera, CameraLink, SlotBackup) {
        let fake = FakePTPCamera()
        await fake.configure { f in
            f.seed(slot: 7, recipe: Recipe(name: "Old mono", filmSim: .acrosYe, grain: .strongLarge,
                                         highlight: 2, shadow: 3, sharpness: 1, noiseReduction: -4))
            f.slots[7]?[FujiProp.color] = PTPPack.i16(30)
            f.slots[7]?[FujiProp.colorChrome] = PTPPack.u16(1)
            f.slots[7]?[FujiProp.colorChromeFxBlue] = PTPPack.u16(1)
            f.slots[7]?[FujiProp.wbShiftR] = PTPPack.i16(0)
            f.slots[7]?[FujiProp.wbShiftB] = PTPPack.i16(0)
            f.rejectColorInMonochrome = true
        }
        let link = CameraLink(transport: fake, timing: .immediate)
        let look = Recipe(name: "Park shade", filmSim: .proNegStd, colorChrome: .weak, colorChromeFxBlue: .weak,
                          wbShiftR: 1, wbShiftB: -1, highlight: -0.5, color: 1, sharpness: -1, noiseReduction: -4)
        let report = try await link.load(placements: [.init(slot: 7, recipe: look)], protectedSlots: Set(1...6), onBackup: { _ in })
        #expect(report.isClean)
        return (fake, link, report.backup)
    }

    @Test func hiddenValuesAndOriginalMonochromeReturn() async throws {
        let (fake, link, before) = try await setup()
        let untouched = await fake.slots.filter { $0.key != 7 }
        let result = try await link.restore(before, protectedSlots: Set(1...6), onBackup: { _ in })
        #expect(result.isClean)
        let actual = try await link.fujiCamera.readSlot(7)
        #expect(actual == before.slots[0])
        #expect(await fake.slots.filter { $0.key != 7 } == untouched)
        let writes = await fake.writes
        #expect(writes.contains(PropWrite(propID: FujiProp.filmSimulation, bytes: PTPPack.u16(FujiFilmSim.provia))))
        #expect(writes.last(where: { $0.propID == FujiProp.filmSimulation })?.bytes == PTPPack.u16(FujiFilmSim.acrosYe))
        #expect(!writes.contains { FujiProp.neverWritten.contains($0.propID) })
    }

    @Test func hiddenWriteThatDoesNotStickCannotClaimRecovery() async throws {
        let (fake, link, before) = try await setup()
        await fake.configure { $0.ignoreWrites = [FujiProp.color] }
        let result = try await link.restore(before, protectedSlots: Set(1...6), onBackup: { _ in })
        #expect(!result.isClean)
        #expect(result.slots[0].mismatched.contains { $0.contains("0xd19f") })
        #expect(try await link.fujiCamera.readProp(FujiProp.filmSimulation)?.bytes == PTPPack.u16(FujiFilmSim.acrosYe))
    }

    @Test func unavailableTemporaryColorModeLeavesRecoveryPartial() async throws {
        let (fake, link, before) = try await setup()
        // Ignore all film writes: the new color mode remains, so the original monochrome cannot be verified.
        await fake.configure { $0.ignoreWrites = [FujiProp.filmSimulation] }
        let result = try await link.restore(before, protectedSlots: Set(1...6), onBackup: { _ in })
        #expect(!result.isClean)
        #expect(result.slots[0].mismatched.contains { $0.contains("0xd192") })
    }

    @Test func differencesInFieldsWeNeverWriteAreReported() async throws {
        let (fake, link, before) = try await setup()
        await fake.configure { $0.slots[7]?[FujiProp.imageQuality] = PTPPack.u16(5) }
        let result = try await link.restore(before, protectedSlots: Set(1...6), onBackup: { _ in })
        #expect(!result.isClean)
        #expect(result.slots[0].mismatched.contains { $0.contains("0xd18f") })
        #expect(!(await fake.writes).contains { $0.propID == FujiProp.imageQuality })
    }

    @Test func missingWrittenValueReadbackIsNotConfirmed() async throws {
        let fake = FakePTPCamera()
        let camera = FujiCamera(transport: fake, timing: .immediate)
        try await camera.connect()
        let base = try await camera.readSlot(7).rawProps
        await fake.configure { $0.rejectReadProps = [FujiProp.sharpness] }
        let report = try await camera.writeSlot(7, recipe: .testLook(), base: base)
        #expect(!report.isClean)
        #expect(report.mismatched.contains { $0.contains("0xd1a0") && $0.contains("could not be read back") })
    }

    @Test func missingNameReadbackIsNotConfirmed() async throws {
        let fake = FakePTPCamera()
        let camera = FujiCamera(transport: fake, timing: .immediate)
        try await camera.connect()
        let base = try await camera.readSlot(7).rawProps
        await fake.configure { $0.rejectReadProps = [FujiProp.name] }
        let report = try await camera.writeSlot(7, recipe: .testLook(), base: base)
        #expect(!report.isClean)
        #expect(report.mismatched.contains("name could not be read back"))
    }
}
