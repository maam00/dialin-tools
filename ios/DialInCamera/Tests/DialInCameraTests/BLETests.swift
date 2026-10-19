// BLE adverts, handshake, chunk reassembly and checksum. Fixtures are lifted from the reference repos, cited per test
// (repository-relative paths): Th0rgal/fuji-bridge Tests/BluetoothTests.swift and RecipeBackupTests.swift
// (MIT, Copyright (c) 2026 Thomas Marchand), petabyt/libfuji lib/bluetooth.c, gkoh/furble FujifilmSecure.h — the same
// fixtures our Python port uses in ble/tests/test_gatt.py.
@preconcurrency import CoreBluetooth
import Foundation
import Synchronization
import Testing
@testable import DialInCamera

/// A secure X100VI's GATT side for the flows: scripted notifications (FIFO, consumed once), chunks pulled by reads.
actor FakeGATT: GATTClient {
    var present: Set<String> = Set([
        FujiBLE.secureStatus, FujiBLE.clientName, FujiBLE.backupRequest, FujiBLE.backupState, FujiBLE.filePartialData,
        FujiBLE.fileTransactionState, FujiBLE.filePartialSize, FujiBLE.fileTransferIndex, FujiBLE.fileInformation,
        FujiBLE.fileTransferResult, FujiBLE.deviceName, FujiBLE.firmwareRevision,
    ] + FujiBLE.subscriptions.prefix(9))
    var status = Data([0x07, 0x96, 0x00, 0x00])
    var pendingPairing = 0
    var backupStates: [Data] = [Data([1, 0])]
    var chunks: [Data] = []
    var information = Data()
    var stale: [String: [Data]] = [:]
    var linkUp = true
    private var queued: [String: [Data]] = [:]
    private var readIndex = 0
    private(set) var steps: [String] = []
    private(set) var writes: [(String, Data)] = []

    func configure(_ body: @Sendable (isolated FakeGATT) -> Void) { body(self) }

    func has(_ c: String) async -> Bool { present.contains(c) }

    func read(_ c: String) async throws -> Data {
        if c == FujiBLE.secureStatus && pendingPairing > 0 {
            pendingPairing -= 1
            throw NSError(domain: CBATTErrorDomain, code: CBATTError.Code.insufficientEncryption.rawValue)
        }
        steps.append("read \(c.prefix(8))")
        switch c {
        case FujiBLE.secureStatus: return status
        case FujiBLE.fileInformation: return information
        case FujiBLE.filePartialData:
            defer { readIndex += 1 }
            return chunks[readIndex]
        case FujiBLE.deviceName: return Data("X100VI-1D7B8".utf8) + Data(count: 4)
        case FujiBLE.firmwareRevision: return Data("1.32".utf8)
        case FujiBLE.backupState: return Data([0, 0])
        default: return Data()
        }
    }

    func write(_ c: String, _ value: Data) async throws {
        steps.append("write \(c.prefix(8))")
        writes.append((c, value))
        if c == FujiBLE.backupRequest {
            queued[FujiBLE.backupState] = backupStates
        }
        if c == FujiBLE.fileTransferIndex {
            // One "transferring" notify per chunk, then "file finished" (fuji-bridge RecipeBackupTests.swift:17-23).
            queued[FujiBLE.fileTransactionState] = chunks.indices.map { Data([$0 == 0 ? 1 : 2, 0, UInt8($0 & 0xFF), 0]) } + [Data([3, 0, 0, 0])]
        }
    }

    func subscribe(_ c: String) async -> Bool {
        steps.append("subscribe \(c.prefix(8))")
        return present.contains(c)
    }

    func nextValue(_ c: String, timeout: Duration) async -> Data? {
        if var q = queued[c], !q.isEmpty {
            let v = q.removeFirst()
            queued[c] = q
            return v
        }
        return nil // "timed out" at once
    }

    func drain(_ c: String) async -> [Data] { stale.removeValue(forKey: c) ?? [] }

    var isLinkUp: Bool { linkUp }

    var lastWrite: (String, Data)? { writes.last }
}

private func chunk(_ seq: UInt16, _ payload: [UInt8]) -> Data { FileChunk.build(seq: seq, payload: Data(payload)) }

@Suite("BLE")
struct BLETests {
    // MARK: Adverts (fuji-bridge Tests/BluetoothTests.swift:79-103)

    @Test("The advert from a bonded X100VI (fw 1.32) is a body waiting for its phone")
    func bondedAdvert() {
        // fuji-bridge's capture from an X100VI, firmware 1.32, paired with FUJIFILM's app on an iPhone.
        let manufacturer = Data([0xD8, 0x04, 0x01, 0x31, 0x44, 0x37, 0x42, 0x38, 0x00])
        let advert = FujiAdvert.parse(manufacturer: manufacturer, services: [FujiBLE.reconnectAdvert])
        #expect(advert?.kind == .reconnect)
        #expect(advert?.tag == "1D7B8")
        #expect(advert?.token == nil)
        #expect(FujiAdvert.parse(manufacturer: Data([0x4C, 0x00, 0x02]), services: []) == nil, "Apple, not Fujifilm")
    }

    @Test("Same body with service 123d8f06 is bonded; with a9d2b304 it is in pairing mode (CBUUID casing ignored)")
    func secondAdvertAndPairing() {
        let manufacturer = Data([0xD8, 0x04, 0x01, 0x31, 0x44, 0x37, 0x42, 0x38])
        #expect(FujiAdvert.parse(manufacturer: manufacturer, services: [FujiBLE.securePairService.uppercased()])?.kind == .reconnect)
        let pairing = FujiAdvert.parse(manufacturer: manufacturer, services: ["A9D2B304-E8D6-4902-8336-352B772D7597"])
        #expect(pairing?.kind == .securePairing)
        #expect(pairing?.tag == "1D7B8")
    }

    @Test("A basic pairing advert carries the token")
    func basicToken() {
        let advert = FujiAdvert.parse(manufacturer: Data([0xD8, 0x04, 0x02, 0xDE, 0xAD, 0xBE, 0xEF]), services: [])
        #expect(advert?.kind == .basicPairing)
        #expect(advert?.token == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(advert?.tag == "deadbeef")
    }

    // MARK: Handshake

    @Test("Pair mode waits for a basic registration key while retaining secure reconnect support")
    func pairingEligibility() {
        #expect(!FujiAdvert(kind: .basic, tag: "").allowsPairingAttempt)
        #expect(!FujiAdvert(kind: .basicStandby, tag: "", token: Data([1, 2, 3, 4])).allowsPairingAttempt)
        #expect(!FujiAdvert(kind: .basicPairing, tag: "").allowsPairingAttempt)
        #expect(!FujiAdvert(kind: .basicPairing, tag: "", token: Data([1, 2, 3])).allowsPairingAttempt)
        #expect(FujiAdvert(kind: .basicPairing, tag: "", token: Data([1, 2, 3, 4])).allowsPairingAttempt)
        #expect(FujiAdvert(kind: .securePairing, tag: "").allowsPairingAttempt)
        #expect(FujiAdvert(kind: .reconnect, tag: "").allowsPairingAttempt)
        #expect(!FujiAdvert(kind: .other, tag: "").allowsPairingAttempt)
    }

    @Test("Secure status ack sets byte 3 to 0x20 (furble FujifilmSecure.h:73: 07960000 → 07960020)")
    func ack() throws {
        #expect(try FujiBLE.ackSecureStatus(Data([0x07, 0x96, 0x00, 0x00])) == Data([0x07, 0x96, 0x00, 0x20]))
        #expect(throws: FujiBLEError.self) { try FujiBLE.ackSecureStatus(Data([0x07, 0x96, 0x00])) }
    }

    @Test("Secure registration: read status, write the ack, write the name, then subscribe in libfuji's order")
    func secureRegistration() async throws {
        let gatt = FakeGATT()
        let reg = try await FujiBLEFlows.register(gatt, clientName: "Dial In", pause: .milliseconds(1))
        let steps = await gatt.steps
        let nonSub = steps.filter { !$0.hasPrefix("subscribe") }
        #expect(nonSub == ["read f557d96b", "write f557d96b", "write 85b9163e"])
        #expect(steps.lastIndex { !$0.hasPrefix("subscribe") }! < steps.firstIndex { $0.hasPrefix("subscribe") }!)
        #expect(reg.mode == "secure")
        #expect(reg.statusWritten == Data([0x07, 0x96, 0x00, 0x20]))
        #expect(reg.subscribed.count + reg.missing.count == FujiBLE.subscriptions.count)
        #expect(Array(reg.subscribed.prefix(3)) == Array(FujiBLE.subscriptions.prefix(3)))
        let writes = await gatt.writes
        // The client name goes out UTF-8 + NUL (docs/FUJIFILM-PROTOCOL.md §3.4).
        #expect(writes.first { $0.0 == FujiBLE.clientName }?.1 == Data("Dial In".utf8) + Data([0]))
        #expect(!reg.pairingPromptSeen)
    }

    @Test("Registration waits while the user confirms the pairing code (fuji-bridge BluetoothTests.swift:126-139)")
    func pairingWait() async throws {
        let gatt = FakeGATT()
        await gatt.configure { $0.pendingPairing = 3 }
        let prompts = PromptCounter()
        let reg = try await FujiBLEFlows.register(gatt, clientName: "Dial In", pause: .milliseconds(1), onPrompt: { prompts.bump() })
        #expect(reg.pairingPromptSeen)
        #expect(prompts.count == 1)

        let stuck = FakeGATT()
        await stuck.configure { $0.pendingPairing = 50 }
        await #expect(throws: FujiBLEError.notPaired) {
            _ = try await FujiBLEFlows.register(stuck, clientName: "x", pairingAttempts: 2, pause: .milliseconds(1))
        }
    }

    @Test("Basic firmware sends the advert token instead of the status (fuji-bridge BluetoothTests.swift:141-147)")
    func basicRegistration() async throws {
        let gatt = FakeGATT()
        await gatt.configure { g in
            g.present.remove(FujiBLE.secureStatus)
            g.present.insert(FujiBLE.pairingToken)
        }
        let reg = try await FujiBLEFlows.register(gatt, clientName: "Dial In", token: Data([1, 2, 3, 4]))
        #expect(reg.mode == "basic")
        let writes = await gatt.writes.map(\.0)
        #expect(Array(writes.prefix(2)) == [FujiBLE.pairingToken, FujiBLE.clientName])
    }

    // MARK: Framing (libfuji captures, fuji-bridge fixtures)

    @Test("A basic body without a valid key cannot claim registration or start a backup")
    func basicRegistrationRequiresKey() async throws {
        for token in [nil, Data(), Data([1, 2, 3]), Data([1, 2, 3, 4, 5])] as [Data?] {
            let gatt = FakeGATT()
            await gatt.configure { g in
                g.present.remove(FujiBLE.secureStatus)
                g.present.insert(FujiBLE.pairingToken)
            }
            await #expect(throws: FujiBLEError.pairingKeyMissing) {
                _ = try await FujiBLEFlows.register(gatt, clientName: "Dial In", token: token)
            }
            #expect(await gatt.writes.isEmpty)
        }
        #expect(!FujiBLEFlows.isPairingPending(FujiBLEError.pairingKeyMissing), "No encrypted-read retry can obtain a missing basic key")
    }

    @Test("An unknown registration profile is refused before identifying the client")
    func unknownRegistrationIsNotSuccess() async throws {
        let gatt = FakeGATT()
        await gatt.configure { g in
            g.present.remove(FujiBLE.secureStatus)
            g.present.remove(FujiBLE.pairingToken)
        }
        await #expect(throws: FujiBLEError.self) {
            _ = try await FujiBLEFlows.register(gatt, clientName: "Dial In")
        }
        #expect(await gatt.writes.isEmpty)
    }

    @Test("FILE_INFORMATION from libfuji's capture: backup.dat, 33,404 bytes (bluetooth.c:32-34)")
    func fileInformation() throws {
        let raw = Data("backup.dat".utf8) + Data(count: 0x28 - 10) + Data([0x7C, 0x82, 0x00, 0x00])
        #expect(raw.count == 44)
        let info = try FileInformation.parse(raw)
        #expect(info.name == "backup.dat")
        #expect(info.size == 33_404)
        #expect(FileInformation.build(name: "backup.dat", size: 33_404) == raw)
    }

    @Test("Transaction state: libfuji's idle 05 00 ff ff (bluetooth.c:43); fuji-bridge [state, 0, index, 0]")
    func transactionState() throws {
        let st = try TransactionState.parse(Data([0x05, 0x00, 0xFF, 0xFF]))
        #expect(st.state == 5)
        #expect(st.aux == Data([0xFF, 0xFF]))
        #expect(try TransactionState.parse(Data([2, 0, 7, 0])).state == 2)
    }

    @Test("Chunk layout: u16 seq, u32 len, payload (fuji-bridge RecipeBackupTests.swift:37-40)")
    func chunkLayout() throws {
        let c = chunk(0, [UInt8](repeating: 7, count: 120))
        #expect([UInt8](c.prefix(6)) == [0, 0, 120, 0, 0, 0])
        let parsed = try FileChunk.parse(c)
        #expect(parsed.seq == 0 && parsed.length == 120 && !parsed.isLast)
    }

    @Test("Reassembly and checksum (fuji-bridge RecipeBackupTests.swift:44-61)")
    func reassembly() throws {
        let first = [UInt8](repeating: 7, count: 120)
        let last: [UInt8] = [1, 2, 3, 4]
        let sum = (first + last).reduce(0) { $0 + Int($1) } & 0xFFFF
        var asm = BackupAssembler()
        try asm.add(chunk(0, first))
        try asm.add(chunk(0xFFFF, last + [UInt8(sum & 0xFF), UInt8(sum >> 8)]))
        #expect([UInt8](asm.data) == first + last)
        #expect(asm.checksumOK == true)
        #expect(asm.seqReport.contains("ended with 0xFFFF"))
        #expect(byteSum16(asm.data) == sum)
    }

    @Test("A damaged backup fails the sum (fuji-bridge RecipeBackupTests.swift:64-66)")
    func damaged() throws {
        var asm = BackupAssembler()
        try asm.add(chunk(0xFFFF, [9, 9, 0x00, 0x00]))
        #expect(asm.checksumOK == false)
    }

    @Test("Short or lying chunks are rejected; gaps and a missing terminator are reported")
    func badChunks() throws {
        #expect(throws: FujiBLEError.self) { try FileChunk.parse(Data([0, 0, 5])) }
        #expect(throws: FujiBLEError.self) { try FileChunk.parse(FileChunk.build(seq: 1, payload: Data(count: 50)).prefix(9)) }
        var asm = BackupAssembler()
        for seq: UInt16 in [0, 1, 3] { try asm.add(chunk(seq, [0x78])) }
        #expect(asm.seqReport.contains("NOT consecutive"))
        #expect(asm.seqReport.contains("NO 0xFFFF"))
        #expect(asm.checksumOK == nil)
    }

    // MARK: Backup flow (fuji-bridge RecipeBackupTests.swift SettingsBackupTests)

    @Test("A backup is reassembled, checked, trimmed to FILE_INFORMATION's size, and finished with 03 00")
    func backupFlow() async throws {
        let gatt = FakeGATT()
        let first = [UInt8](repeating: 7, count: 120)
        let last: [UInt8] = [1, 2, 3, 4]
        let sum = (first + last).reduce(0) { $0 + Int($1) } & 0xFFFF
        await gatt.configure { g in
            g.chunks = [chunk(0, first), chunk(0xFFFF, last + [UInt8(sum & 0xFF), UInt8(sum >> 8)])]
            g.information = FileInformation.build(name: "backup.dat", size: 124)
            g.stale = [FujiBLE.fileTransactionState: [Data([5, 0, 0xFF, 0xFF])]]
        }
        let result = try await FujiBLEFlows.backupSettings(gatt)
        #expect(result.name == "backup.dat")
        #expect([UInt8](result.data) == first + last)
        #expect(result.checksumOK == true)
        #expect(result.chunks == 2)
        #expect(result.reportedSize == 124)
        let writes = await gatt.writes
        #expect(writes.first?.0 == FujiBLE.backupRequest && writes.first?.1 == Data([1, 0]))
        #expect(writes.contains { $0.0 == FujiBLE.filePartialSize && $0.1 == Data([120, 0, 0, 0]) })
        #expect(writes.contains { $0.0 == FujiBLE.fileTransferIndex && $0.1 == Data([0, 0, 0, 0]) })
        #expect(writes.last?.0 == FujiBLE.fileTransferResult && writes.last?.1 == Data([3, 0]))
    }

    @Test("A damaged backup is refused and the transfer is closed with 00 00")
    func backupDamaged() async throws {
        let gatt = FakeGATT()
        await gatt.configure { $0.chunks = [chunk(0xFFFF, [9, 9, 0x00, 0x00])] }
        await #expect(throws: FujiBLEError.checksum(expected: 0, got: 18)) { _ = try await FujiBLEFlows.backupSettings(gatt) }
        let last = await gatt.lastWrite
        #expect(last?.0 == FujiBLE.fileTransferResult && last?.1 == Data([0, 0]))
    }

    @Test("A busy camera (BACKUP_STATE 0) says so")
    func backupBusy() async throws {
        let gatt = FakeGATT()
        await gatt.configure { $0.backupStates = [Data([0, 0])] }
        await #expect(throws: FujiBLEError.busy) { _ = try await FujiBLEFlows.backupSettings(gatt, stateTimeout: .milliseconds(50)) }
    }

    @Test("Busy then ready (0 then 1) proceeds, as client.py waits for a 1")
    func backupBusyThenReady() async throws {
        let gatt = FakeGATT()
        let payload: [UInt8] = [1, 2, 3]
        await gatt.configure { g in
            g.backupStates = [Data([0, 0]), Data([1, 0])]
            g.chunks = [chunk(0xFFFF, payload + [6, 0])]
        }
        let result = try await FujiBLEFlows.backupSettings(gatt, stateTimeout: .seconds(1))
        #expect([UInt8](result.data) == payload)
    }

    @Test("A camera without the file service is unsupported, before anything is written")
    func backupUnsupported() async throws {
        let gatt = FakeGATT()
        await gatt.configure { $0.present.remove(FujiBLE.backupRequest) }
        await #expect(throws: FujiBLEError.self) { _ = try await FujiBLEFlows.backupSettings(gatt) }
        #expect(await gatt.writes.isEmpty)
    }

    @Test("Restore is a clear 'unsupported' error until the sniffing session")
    func restoreUnsupported() async {
        let link = FujiBluetoothLink()
        await #expect(throws: FujiBLEFlows.restoreUnsupported) { try await link.restoreSettings(Data()) }
    }

    @Test("Settings-file header sniff (helios FUJI_BLOB_FORMAT.md:48-66)")
    func header() {
        var d = Data("FUJIFILMX-BACKUP".utf8) + Data("0100".utf8)
        d += Data("X100VI".utf8) + Data(count: 0x34 - 0x14 - 6)
        d += Data("59S12345".utf8) + Data(count: 0x98 - 0x34 - 8)
        d += PTPPack.u32(0xA8) + Data(count: 4) + PTPPack.u32(100) + Data(count: 4)
        d += Data(count: 100)
        let h = SettingsFileHeader(d)
        #expect(h.magicOK && h.version == "0100" && h.model == "X100VI" && h.serial == "59S12345")
        #expect(h.payloadStart == 0xA8 && h.payloadLength == 100 && h.lengthConsistent)
        #expect(!SettingsFileHeader(Data(count: 200)).magicOK)
    }

    @Test("UUID normalisation: 16-bit SIG and CBUUID upper case map to our keys")
    func uuids() {
        #expect(FujiBLE.normalize("2A26") == FujiBLE.firmwareRevision)
        #expect(FujiBLE.normalize("F557D96B-8284-4667-8793-B971C1DECA2A") == FujiBLE.secureStatus)
    }
}

final class PromptCounter: Sendable {
    private let n = Mutex(0)
    func bump() { n.withLock { $0 += 1 } }
    var count: Int { n.withLock { $0 } }
}
