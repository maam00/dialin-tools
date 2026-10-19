import Foundation
import Testing
@testable import DialInCamera

@Suite("Compressed Bluetooth settings backups")
struct BLEBackupPayloadTests {
    func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "ble-settings-synthetic", withExtension: "zlib", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test("Decode a synthetic zlib backup with the size reported by the physical camera")
    func decode() throws {
        let wire = try fixture()
        let payload = try BLEBackupPayload.decode(wire, reportedSize: 70524)
        #expect(payload.compressed && payload.data.count == 70524)
        #expect(try FujiSettingsFile(payload.data).name(slot: 7) == "TEST C7")
        #expect(SettingsFileHeader(payload.data).serial == "TEST")
        #expect(byteSum16(wire) != byteSum16(payload.data))
        #expect(try BLEBackupPayload.decode(payload.data, reportedSize: 70524).compressed == false)
    }

    @Test("Truncation, checksum corruption, trailing streams and wrong sizes fail")
    func rejectDamaged() throws {
        let wire = try fixture()
        var corrupt = wire
        corrupt[corrupt.count - 1] ^= 1
        for bad in [Data(wire.dropLast()), corrupt, wire + Data([0]), wire + wire] {
            #expect(throws: FujiBLEError.self) { try BLEBackupPayload.decode(bad, reportedSize: 70524) }
        }
        for size in [0, 70523, 70525, BLEBackupPayload.maximumSize + 1] {
            #expect(throws: FujiBLEError.self) { try BLEBackupPayload.decode(wire, reportedSize: size) }
        }
        #expect(throws: FujiBLEError.self) { try BLEBackupPayload.decode(Data(count: 100), reportedSize: 70524) }
    }

    @Test("Full BLE flow verifies the compressed sum, exposes decoded settings and preserves exact wire bytes")
    func flow() async throws {
        let wire = try fixture()
        let sum = byteSum16(wire)
        let gatt = FakeGATT()
        let frames = stride(from: 0, to: wire.count, by: 120).enumerated().map { index, offset in
            let last = offset + 120 >= wire.count
            let bytes = Data(wire[offset..<min(offset + 120, wire.count)])
            return FileChunk.build(seq: last ? 0xFFFF : UInt16(index), payload: last ? bytes + PTPPack.u16(sum) : bytes)
        }
        await gatt.configure {
            $0.chunks = frames
            $0.information = FileInformation.build(name: "backup.dat", size: 70524)
        }
        let result = try await FujiBLEFlows.backupSettings(gatt)
        #expect(result.checksumOK == true && result.computedSum == sum)
        #expect(result.wireData == wire && result.compressed)
        #expect(result.data.count == 70524 && result.header.magicOK && result.header.lengthConsistent)
        #expect(await gatt.lastWrite?.1 == Data([3, 0]))
    }

    @Test("Patched settings keep the fresh backup's zlib header and round-trip; unchanged settings preserve exact wire bytes")
    func encode() async throws {
        let camera = FakeFujiBLECamera(compressedSettings: true)
        _ = try await camera.adoptRegisteredKey(timeout: .milliseconds(10))
        try await camera.connect(pairing: false, timeout: .seconds(1))
        let fresh = try await FujiBLEFlows.backupSettings(camera)
        #expect(try BLEBackupPayload.encode(fresh.data, matching: fresh) == fresh.wireData)
        let file = try FujiSettingsFile(fresh.data)
        let patched = try file.applyingLooks([.init(slot: 7, recipe: Recipe(name: "Compressed", filmSim: .classicChrome, noiseReduction: -4))]).file.data
        let wire = try BLEBackupPayload.encode(patched, matching: fresh)
        #expect(wire.prefix(2) == fresh.wireData.prefix(2) && wire != patched)
        #expect(try BLEBackupPayload.decode(wire, reportedSize: patched.count).data == patched)
        var wrongIdentity = patched
        wrongIdentity[0x34] ^= 1
        #expect(throws: FujiBLEError.self) { try BLEBackupPayload.encode(wrongIdentity, matching: fresh) }
        var damagedMetadata = fresh
        damagedMetadata.expectedSum = 0
        #expect(throws: FujiBLEError.self) { try BLEBackupPayload.encode(patched, matching: damagedMetadata) }
        camera.disconnect()
    }

    @Test("Compression variants preserve supported window/flags and refuse unfamiliar formats")
    func compressionFormat() throws {
        let data = FakeFujiBLECamera.sampleSettings()
        for flag: UInt8 in [0x01, 0x5E, 0x9C, 0xDA] {
            let header = Data([0x78, flag])
            let wire = try BLEBackupPayload.compress(data, matchingHeader: header)
            #expect(wire.prefix(2) == header)
            #expect(try BLEBackupPayload.decode(wire, reportedSize: data.count).data == data)
        }
        for header in [Data([0x68, 0x81]), Data([0x78, 0x20]), Data([0x78])] {
            #expect(throws: FujiBLEError.self) { try BLEBackupPayload.compress(data, matchingHeader: header) }
        }
    }
}
