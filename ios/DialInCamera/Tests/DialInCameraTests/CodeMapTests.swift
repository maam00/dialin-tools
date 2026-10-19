// dialin-cam map-codes against the pretend camera (RehearsalSlotCamera): the plan, the sweep, a wrong X-T5 guess, a
// failed control, a refused value, an unplug mid-sweep, and the restore proved byte for byte. Runs on oct9Codes (what
// 10/9 proved), so it still holds after more codes are merged.
import Foundation
import Synchronization
import Testing
@testable import DialInCamera

/// Keeps what map-codes saves in memory, in order.
final class CodeMapStore: Sendable {
    let files = Mutex<[(String, Data)]>([])
    var labels: [String] { files.withLock { $0.map(\.0) } }
    var savers: CodeMap.Savers {
        CodeMap.Savers(
            slots: { b in
                let d = try b.jsonData()
                self.files.withLock { $0.append(("slots", d)) }
                return "mem/slots.json"
            },
            settings: { d, label in
                self.files.withLock { $0.append(("settings-\(label)", d)) }
                return "mem/settings-\(label).dat"
            })
    }
}

@Suite("map-codes (pretend camera)")
struct CodeMapTests {
    func connected(_ fake: RehearsalSlotCamera) async throws -> FujiCamera {
        let cam = FujiCamera(transport: fake, timing: .immediate)
        try await cam.connect()
        return cam
    }

    func sweep(_ fake: RehearsalSlotCamera, slot: Int = 7, only: Set<CodeMap.Field>? = nil) async throws -> (CodeMap.Report, CodeMapStore) {
        let store = CodeMapStore()
        let cam = try await connected(fake)
        let report = try await CodeMap.run(cam, slot: slot, probes: try CodeMap.probes(codes: oct9Codes, only: only), codes: oct9Codes,
                                           rehearsal: true, save: store.savers)
        await cam.disconnect()
        return (report, store)
    }

    @Test("The plan: a confirmed baseline first, every unconfirmed value once, a B&W control after the sims")
    func plan() throws {
        let p = try CodeMap.probes(codes: oct9Codes)
        #expect(p.count == 1 + 13 + 1 + 6 + 4 + 8)
        #expect(p[0].isControl && p[0].recipe.filmSim == .realaAce && p[0].expect == 18)
        #expect(p[0].recipe.whiteBalance == .auto && p[0].recipe.noiseReduction == -4 && p[0].recipe.color == 0)
        #expect(p.filter(\.isControl).map(\.value) == ["Reala Ace", "Acros+R"])
        #expect(p.filter { $0.field == .filmSim && !$0.isControl }.map(\.value).contains("Astia"))
        #expect(p.filter { $0.field == .whiteBalance }.map(\.value) == ["Auto Ambience", "Shade", "Fluorescent 1", "Fluorescent 2", "Fluorescent 3", "Incandescent"])
        #expect(p.filter { $0.field == .color }.map(\.value) == ["-4", "-3", "-2", "4"])
        #expect(p.filter { $0.field == .noiseReduction }.count == 8)
        // Each probe differs from the baseline in its one value only.
        for x in p.dropFirst() where x.field == .color { #expect(x.recipe.filmSim == .realaAce && x.recipe.whiteBalance == .auto) }
        #expect(try CodeMap.probes(codes: oct9Codes, only: [.filmSim]).count == 15)
        #expect(try CodeMap.parseFields("film_sim, wb") == [.filmSim, .whiteBalance])
        #expect(throws: CameraError.self) { try CodeMap.parseFields("film_sim,grain") }
        let dry = CodeMap.plan(slot: 7, probes: p)
        #expect(dry.first == "DRY RUN: no camera contacted, nothing written.")
        #expect(dry.contains { $0.contains("33 look(s) into C7") })
        // With every film sim confirmed, only the controls are left to run.
        var all = oct9Codes
        for (i, f) in FilmSimulation.allCases.enumerated() where all.filmSims[f.rawValue] == nil { all.filmSims[f.rawValue] = 100 + i }
        #expect(try CodeMap.probes(codes: all, only: [.filmSim]).allSatisfy(\.isControl))
    }

    @Test("A full sweep: backups first, every code read, guesses checked, C7 put back byte for byte")
    func sweep() async throws {
        let fake = RehearsalSlotCamera()
        let before = await fake.settingsFile
        let (r, store) = try await sweep(fake)
        #expect(r.aborted == nil)
        #expect(r.controls.allSatisfy(\.ok) && r.controls.count >= 5)
        #expect(r.codes.count == 31 && r.skipped.isEmpty)
        #expect(r.codes.allSatisfy { $0.agrees == true && $0.write == "clean" })
        let astia = try #require(r.codes.first { $0.value == "Astia" })
        #expect(astia.file == 2 && astia.ptp == 3 && astia.changed == ["film simulation (+0x64)"])
        let shade = try #require(r.codes.first { $0.value == "Shade" })
        #expect(shade.file == 4 && shade.shiftEntry == 8 && shade.inferredEntry == 8)
        #expect(r.codes.first { $0.field == "noise_reduction" && $0.value == "0" }?.file == 4)
        #expect(r.restore.ok && r.restore.verdict.hasPrefix("C7 restored: identical"), "\(r.restore.verdict)")
        let after = await fake.settingsFile
        #expect(after == before, "the whole settings file is as it was")
        // Both backups were saved before the first write.
        #expect(Array(store.labels.prefix(2)) == ["slots", "settings-before"])
        let log = await fake.log
        let firstSet = try #require(log.firstIndex { $0.hasPrefix("set ") })
        #expect(log.prefix(firstSet).contains("get settings"))
        #expect(r.backups.slots == "mem/slots.json" && r.backups.after == "mem/settings-after.dat")
        // The JSON `npm run codes -- merge` reads.
        let json = try #require(try JSONSerialization.jsonObject(with: r.jsonData()) as? [String: Any])
        #expect(json["kind"] as? String == "dialin.codemap/1" && json["settings_size"] as? Int == 70524 && json["rehearsal"] as? Bool == true)
        #expect(((json["codes"] as? [[String: Any]])?.first { $0["value"] as? String == "Shade" }?["shift_entry"]) as? Int == 8)
        #expect(try CodeMap.Report.decode(r.jsonData()) == r)
    }

    @Test("A colour slot (C1, Classic Chrome under Daylight) also goes back exactly")
    func colourSlot() async throws {
        let fake = RehearsalSlotCamera()
        let before = await fake.settingsFile
        let (r, _) = try await sweep(fake, slot: 1, only: [.whiteBalance, .color])
        let after = await fake.settingsFile
        #expect(r.codes.count == 10 && r.restore.ok)
        #expect(after == before)
    }

    @Test("Hidden monochrome memory differs even when visible properties match: recovery must fail")
    func hiddenRecoveryDifference() async throws {
        let transport = HiddenMemoryTransport()
        let cam = FujiCamera(transport: transport, timing: .immediate)
        try await cam.connect()
        let store = CodeMapStore()
        let report = try await CodeMap.run(cam, slot: 7,
            probes: try CodeMap.probes(codes: oct9Codes, only: [.filmSim]), codes: oct9Codes,
            rehearsal: true, save: store.savers)
        await cam.disconnect()
        #expect(report.aborted == nil)
        #expect(report.restore.ptp == "identical")
        #expect(!report.restore.ok)
        #expect(report.restore.verdict.contains("recovery incomplete"))
        #expect(report.restore.differences.contains { $0.contains("+0x6A") })
    }

    @Test("A wrong X-T5 guess is reported with the real byte and entry")
    func wrongGuess() async throws {
        var truth = RehearsalSlotCamera.Truth.guesses
        truth.filmSims[3] = 7                                    // Astia
        truth.whiteBalances[0x8006] = .init(code: 4, entry: 3)   // Shade's shift lives in entry 3
        let fake = RehearsalSlotCamera(truth: truth)
        let before = await fake.settingsFile
        let (r, _) = try await sweep(fake, only: [.filmSim, .whiteBalance])
        let astia = try #require(r.codes.first { $0.value == "Astia" })
        #expect(astia.file == 7 && astia.inferred == 2 && astia.agrees == false)
        let shade = try #require(r.codes.first { $0.value == "Shade" })
        #expect(shade.shiftEntry == 3 && shade.agrees == false)
        let after = await fake.settingsFile
        #expect(r.restore.ok && after == before)
    }

    @Test("A failed control stops the sweep before any code is recorded; the slot still goes back")
    func failedControl() async throws {
        var truth = RehearsalSlotCamera.Truth.guesses
        truth.filmSims[20] = 99    // Reala Ace isn't where the confirmed codes say
        let fake = RehearsalSlotCamera(truth: truth)
        let before = await fake.settingsFile
        let (r, _) = try await sweep(fake)
        #expect(r.aborted?.contains("control failed") == true)
        #expect(r.codes.isEmpty && r.controls.contains { !$0.ok })
        let after = await fake.settingsFile
        #expect(r.restore.ok && after == before)
    }

    @Test("A value the camera refuses is skipped; the rest still runs")
    func refused() async throws {
        let fake = RehearsalSlotCamera()
        await fake.configure { $0.refusedFilmSims = [10] }   // Sepia
        let (r, _) = try await sweep(fake, only: [.filmSim])
        #expect(r.skipped.map(\.value) == ["Sepia"] && r.skipped[0].why.hasPrefix("the camera refused it"))
        #expect(r.codes.count == 12 && r.aborted == nil && r.restore.ok)
    }

    @Test("Unplugged mid-sweep: the report says so and how to put the slot back")
    func unplugged() async throws {
        let fake = RehearsalSlotCamera()
        await fake.configure { $0.unplugOnWrite = 60 }
        let (r, _) = try await sweep(fake)
        #expect(r.aborted?.hasPrefix("stopped by an error") == true)
        #expect(!r.restore.ok && r.restore.verdict.contains("dialin-cam restore mem/slots.json --slot 7"))
        #expect(!r.codes.isEmpty, "what was measured before the unplug is kept")
    }

    @Test("Labels for the bytes a write changes")
    func labels() {
        #expect(CodeMap.label(rel: 0x64) == "film simulation (+0x64)")
        #expect(CodeMap.label(rel: -0x0F) == "white balance (-0xF)")
        #expect(CodeMap.label(rel: -0x0D + 4 * 8) == "WB shift R, entry 8 (+0x13)")
        #expect(CodeMap.label(rel: 0x1E5 + 3) == "name (+0x1E8)")
        #expect(CodeMap.label(rel: 0x2F) == "slot byte +0x2F")
    }
}

/// Reproduces the observed X100VI failure: its last Monochrome filter survives
/// switching back to Acros, without appearing in the current slot's PTP properties.
private actor HiddenMemoryTransport: PTPTransport {
    let camera = RehearsalSlotCamera()
    var settingsReads = 0

    func open(timeout: Duration) async throws { try await camera.open(timeout: timeout) }
    func close() async { await camera.close() }
    func transact(_ operation: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult {
        var result = try await camera.transact(operation, params: params, dataOut: dataOut, timeout: timeout)
        if operation == PTP.Op.getObject && result.isOK {
            settingsReads += 1
            if settingsReads > 1 {
                var bytes = [UInt8](result.data)
                bytes[0x1106A] = 12
                result.data = Data(FakeFujiBLECamera.restamp(bytes, from: nil, k: 0xE5AE))
            }
        }
        return result
    }
}
