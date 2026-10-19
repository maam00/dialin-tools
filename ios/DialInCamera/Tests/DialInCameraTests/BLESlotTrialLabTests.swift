// The supervised one-slot Bluetooth lab trial (`dialin-cam ble-trial-*`): offline review, binding the live write to
// that review, and the comparison used for the USB read-back. Fake camera only; the production gate stays false.
import Foundation
import Synchronization
import Testing
@testable import DialInCamera

@Suite("Bluetooth one-slot lab trial")
struct BLESlotTrialLabTests {
    private let homeNatural = Recipe(name: "Home natural", filmSim: .proNegStd, grain: .off, colorChrome: .weak,
                                     whiteBalance: .auto, wbShiftR: 1, wbShiftB: -1, dynamicRange: .dr200, highlight: -1,
                                     shadow: -0.5, color: 1, sharpness: -1, noiseReduction: -4)

    private func paired() async throws -> FakeFujiBLECamera {
        let camera = FakeFujiBLECamera(scenario: .ok, reportedModel: "FF230003", compressedSettings: true)
        _ = try await camera.adoptRegisteredKey(timeout: .milliseconds(10))
        return camera
    }

    /// A same-layout change outside every slot, with the fake's checksum model kept consistent.
    private func touching(_ data: Data, at offset: Int) throws -> Data {
        var out = data
        out[offset] ^= 1
        let sum = try FujiSettingsFile.expectedChecksum(original: try FujiSettingsFile(data), patchedBytes: [UInt8](out))
        out[FujiSettingsFile.checksumOffset] = UInt8(sum & 0xFF)
        out[FujiSettingsFile.checksumOffset + 1] = UInt8(sum >> 8)
        return out
    }

    @Test("Offline review: only C7's look bytes and the checksum low half change; it reproduces and round-trips as JSON")
    func review() throws {
        let baseline = FakeFujiBLECamera.sampleSettings()
        let (file, review) = try BLESlotTrialLab.prepare(baseline: baseline, placement: .init(slot: 7, recipe: homeNatural))
        try RestoreGuard.check(file, against: baseline, slots: [7])
        let region = try FujiSettingsFile(baseline).slotRegion(7)
        #expect(!review.changes.isEmpty && review.changes.allSatisfy { region.contains($0.offset) })
        #expect(review.slotRegion == [region.lowerBound, region.upperBound] && !review.wirelessWritesValidated)
        let c = try BLESlotTrialLab.compare(baseline, file)
        #expect(c.onlyExpected(slot: 7, crossTransport: false) && c.checksumHigh.isEmpty && c.header.isEmpty)
        #expect(!c.onlyExpected(slot: 6, crossTransport: false))
        let decoded = try JSONDecoder().decode(BLESlotTrialLab.Review.self, from: JSONEncoder().encode(review))
        #expect(decoded == review)
        try BLESlotTrialLab.revalidate(review: decoded, baseline: baseline, prepared: file)
        var tampered = file
        tampered[review.changes[0].offset] ^= 1
        #expect(throws: BLESlotTrialLab.Refusal.self) { try BLESlotTrialLab.revalidate(review: review, baseline: baseline, prepared: tampered) }
    }

    @Test("Offline review refuses inferred codes, a look already in the slot, and a recipe file that names another slot")
    func refusals() throws {
        let baseline = FakeFujiBLECamera.sampleSettings()
        var inferred = homeNatural
        inferred.filmSim = .eterna
        #expect(throws: BLESlotTrialLab.Refusal.self) {
            try BLESlotTrialLab.prepare(baseline: baseline, placement: .init(slot: 7, recipe: inferred))
        }
        let once = try BLESlotTrialLab.prepare(baseline: baseline, placement: .init(slot: 7, recipe: homeNatural)).file
        #expect(throws: BLESlotTrialLab.Refusal.self) {
            try BLESlotTrialLab.prepare(baseline: once, placement: .init(slot: 7, recipe: homeNatural))
        }
        let artifact = try JSONSerialization.data(withJSONObject: [
            "placements": [["slot": 6, "recipe": try JSONSerialization.jsonObject(with: JSONEncoder().encode(homeNatural))]]])
        #expect(throws: BLESlotTrialLab.Refusal.self) { try BLESlotTrialLab.placement(fromJSON: artifact, slot: 7) }
        let book = try JSONSerialization.data(withJSONObject: [
            "recipes": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(homeNatural))]])
        #expect(try BLESlotTrialLab.placement(fromJSON: book, slot: 7) == .init(slot: 7, recipe: homeNatural))
    }

    @Test("Live run bound to the review: verified write, counters before C1 tolerated, gate unchanged")
    func boundWrite() async throws {
        let camera = try await paired()
        let reviewed = camera.settings
        let (_, review) = try BLESlotTrialLab.prepare(baseline: reviewed, placement: .init(slot: 7, recipe: homeNatural))
        camera.settings = try touching(reviewed, at: FujiSettingsFile.frameCounterBlock.lowerBound)  // a photo was taken since
        let fresh = Mutex<Data?>(nil)
        let outcome = try await BLESlotWriter.writeExperimental(
            [.init(slot: 7, recipe: homeNatural)], to: camera, expectedIdentity: BackupIdentity(reviewed), experimental: true,
            protectedSlots: Set(1...6), timing: .immediate,
            onSafetyBackup: { b0 in
                let outside = try BLESlotTrialLab.requireReviewedSlots(fresh: b0.data, reviewedBaseline: reviewed)
                #expect(Set(outside).subtracting(RestoreGuard.checksumBytes) == [FujiSettingsFile.frameCounterBlock.lowerBound])
                fresh.withLock { $0 = b0.data }
            },
            onPrepared: { sent in
                try BLESlotTrialLab.requireMatchesReview(prepared: sent, fresh: try #require(fresh.withLock { $0 }), review: review)
            })
        #expect(outcome.result == .verified)
        let c = try BLESlotTrialLab.compare(try #require(fresh.withLock { $0 }), camera.settings)
        #expect(c.onlyExpected(slot: 7, crossTransport: false))
        #expect(!BLESlotWriter.wirelessWritesValidated)
    }

    @Test("Live run stops before any restore request when C1–C7 changed since the review")
    func staleReview() async throws {
        let camera = try await paired()
        let reviewed = camera.settings
        let c3 = try FujiSettingsFile(reviewed).slotRegion(3).lowerBound + 0x80 + 0x79   // C3 sharpness, edited on the camera
        camera.settings = try touching(reviewed, at: c3)
        await #expect(throws: BLESlotWriter.WriteError.self) {
            _ = try await BLESlotWriter.writeExperimental(
                [.init(slot: 7, recipe: homeNatural)], to: camera, expectedIdentity: BackupIdentity(reviewed), experimental: true,
                protectedSlots: Set(1...6), timing: .immediate,
                onSafetyBackup: { b0 in try BLESlotTrialLab.requireReviewedSlots(fresh: b0.data, reviewedBaseline: reviewed) })
        }
        #expect(camera.record.restoreRequests == 0 && camera.record.applied == 0)
    }

    @Test("A file that differs from the reviewed change set is refused; comparison flags unexplained global bytes")
    func mismatchAndGlobal() throws {
        let baseline = FakeFujiBLECamera.sampleSettings()
        let (file, review) = try BLESlotTrialLab.prepare(baseline: baseline, placement: .init(slot: 7, recipe: homeNatural))
        var other = homeNatural
        other.sharpness = 0
        let different = try BLESlotTrialLab.prepare(baseline: baseline, placement: .init(slot: 7, recipe: other)).file
        #expect(throws: BLESlotTrialLab.Refusal.self) {
            try BLESlotTrialLab.requireMatchesReview(prepared: different, fresh: baseline, review: review)
        }
        try BLESlotTrialLab.requireMatchesReview(prepared: file, fresh: baseline, review: review)
        let global = try touching(file, at: 0xEC)          // the 10/13 unexplained global field
        let c = try BLESlotTrialLab.compare(baseline, global)
        #expect(c.other == [0xEC] && !c.onlyExpected(slot: 7, crossTransport: false))
        var header = file
        header[0x47] ^= 1
        #expect(try BLESlotTrialLab.compare(baseline, header).onlyExpected(slot: 7, crossTransport: true))
        #expect(!(try BLESlotTrialLab.compare(baseline, header).onlyExpected(slot: 7, crossTransport: false)))
    }
}
