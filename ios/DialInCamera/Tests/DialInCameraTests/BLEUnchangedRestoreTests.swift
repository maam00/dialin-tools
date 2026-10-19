import Foundation
import Synchronization
import Testing
@testable import DialInCamera

private actor BackupThenRestoreGATT: GATTClient {
    let backup: FakeGATT
    let restore: RestoreCameraGATT
    var restoring = false
    init(backup: FakeGATT, restore: RestoreCameraGATT) { self.backup = backup; self.restore = restore }
    var current: any GATTClient { restoring ? restore : backup }
    var isLinkUp: Bool { true }
    func has(_ c: String) async -> Bool { await current.has(c) }
    func read(_ c: String) async throws -> Data { try await current.read(c) }
    func subscribe(_ c: String) async -> Bool {
        if c == FujiBLE.restoreState { return await restore.subscribe(c) }
        return await current.subscribe(c)
    }
    func drain(_ c: String) async -> [Data] { await current.drain(c) }
    func nextValue(_ c: String, timeout: Duration) async -> Data? { await current.nextValue(c, timeout: timeout) }
    func write(_ c: String, _ value: Data) async throws {
        if c == FujiBLE.restoreRequest { restoring = true }
        try await current.write(c, value)
    }
}

@Suite("Unchanged BLE lab restore")
struct BLEUnchangedRestoreTests {
    private func camera(badSum: Bool = false) async throws -> (BackupThenRestoreGATT, Data) {
        let wire = try BLEBackupPayloadTests().fixture()
        let sum = byteSum16(wire) ^ (badSum ? 1 : 0)
        let frames = stride(from: 0, to: wire.count, by: 120).enumerated().map { index, offset in
            let last = offset + 120 >= wire.count
            let bytes = Data(wire[offset..<min(offset + 120, wire.count)])
            return FileChunk.build(seq: last ? 0xFFFF : UInt16(index), payload: last ? bytes + PTPPack.u16(sum) : bytes)
        }
        let backup = FakeGATT()
        await backup.configure {
            $0.chunks = frames
            $0.information = FileInformation.build(name: "backup.dat", size: 70524)
            $0.present.formUnion([FujiBLE.restoreRequest, FujiBLE.restoreState])
        }
        return (BackupThenRestoreGATT(backup: backup, restore: RestoreCameraGATT(settings: wire)), wire)
    }

    @Test("Preserves compressed bytes and declares their wire length after saving a fresh backup")
    func unchanged() async throws {
        let (camera, wire) = try await camera()
        let saved = Mutex<Fi>(.init())
        let result = try await FujiBLEFlows.restoreFreshBackupUnchanged(camera, experimental: true, betweenTransfers: .zero,
            onSafetyBackup: { backup in saved.withLock { $0.data = backup.data; $0.wire = backup.wireData } })
        #expect(saved.withLock { $0.wire == wire && $0.data.count == 70524 })
        #expect(result.framesSent == (wire.count + 119) / 120)
        #expect(result.verifiedIdentical == nil)
        #expect(await camera.restore.settings == wire)
        #expect(await camera.restore.applied == 1)
        #expect(await camera.restore.problems.isEmpty)
        let writes = await camera.restore.writes
        let info = try #require(writes.first { $0.0 == FujiBLE.fileInformation }?.1)
        #expect(try FileInformation.parse(info).size == wire.count)
        #expect(!BLESlotWriter.wirelessWritesValidated)
    }

    private struct Fi { var data = Data(); var wire = Data() }

    @Test("Default gate, damaged backup and failed durable save prevent every restore request")
    func refusal() async throws {
        let (disabled, _) = try await camera()
        await #expect(throws: FujiBLEError.self) {
            _ = try await FujiBLEFlows.restoreFreshBackupUnchanged(disabled, onSafetyBackup: { _ in })
        }
        #expect(await disabled.backup.writes.isEmpty)
        let (damaged, _) = try await camera(badSum: true)
        await #expect(throws: FujiBLEError.self) {
            _ = try await FujiBLEFlows.restoreFreshBackupUnchanged(damaged, experimental: true, betweenTransfers: .zero,
                onSafetyBackup: { _ in Issue.record("Bad checksum reached the save callback") })
        }
        #expect(await damaged.restore.writes.isEmpty)
        let (unsaved, _) = try await camera()
        await #expect(throws: CocoaError.self) {
            _ = try await FujiBLEFlows.restoreFreshBackupUnchanged(unsaved, experimental: true, betweenTransfers: .zero,
                onSafetyBackup: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        }
        #expect(await unsaved.restore.writes.isEmpty)
    }
}
