// Container pack/unpack and dataset parsing (FilmKit vendor/container.ts + binary.ts semantics).
import Foundation
import Testing
@testable import DialInCamera

@Suite("PTP containers and datasets")
struct PTPTests {
    @Test("Command container: 12-byte header + u32 params, little-endian")
    func packCommand() {
        let c = PTPContainer.command(PTP.Op.setDevicePropValue, transactionID: 5, params: [UInt32(FujiProp.slot)])
        #expect(c.pack().hexString == "10000000" + "0100" + "1610" + "05000000" + "8cd10000")
        // The 12-byte form ImageCaptureCore takes for a no-param command (fuji-bridge Packets.command).
        #expect(PTPContainer.command(PTP.Op.getDeviceInfo, transactionID: 1).pack().hexString == "0c000000" + "0100" + "0110" + "01000000")
    }

    @Test("Data container carries the payload after the header")
    func packData() {
        let d = PTPContainer.data(PTP.Op.setDevicePropValue, transactionID: 9, payload: Data([0x0B, 0x00])).pack()
        #expect(d.hexString == "0e000000" + "0200" + "1610" + "09000000" + "0b00")
    }

    @Test("At most 5 params are packed")
    func paramCap() {
        let c = PTPContainer.command(0x1234, transactionID: 1, params: [1, 2, 3, 4, 5, 6, 7])
        #expect(c.pack().count == 12 + 5 * 4)
    }

    @Test("Response unpack reads code, transaction and up to 5 params")
    func unpackResponse() throws {
        let raw = Data(hexString: "14000000" + "0300" + "0120" + "07000000" + "aa000000" + "bb000000")!
        let r = try PTPContainer.unpack(raw)
        #expect(r.type == PTP.ContainerType.response)
        #expect(r.code == PTP.Response.ok)
        #expect(r.transactionID == 7)
        #expect(r.params == [0xAA, 0xBB])
        #expect(r.payload.isEmpty)
    }

    @Test("Data unpack keeps everything after the header as payload")
    func unpackData() throws {
        let raw = Data(hexString: "10000000" + "0200" + "1510" + "03000000" + "9001ffff")!
        let r = try PTPContainer.unpack(raw)
        #expect(r.type == PTP.ContainerType.data)
        #expect(r.payload == Data([0x90, 0x01, 0xFF, 0xFF]))
        #expect(r.params.isEmpty)
    }

    @Test("Pack → unpack round trip; short input throws; length field")
    func roundTripAndErrors() throws {
        let c = PTPContainer.command(PTP.Op.getDevicePropValue, transactionID: 0xDEADBEEF, params: [0xD192])
        #expect(try PTPContainer.unpack(c.pack()) == c)
        #expect(throws: PTPError.containerTooShort(11)) { try PTPContainer.unpack(Data(count: 11)) }
        #expect(PTPContainer.length(of: c.pack()) == 16)
        #expect(PTPContainer.length(of: Data([1, 2])) == nil)
    }

    @Test("PTP string: count byte incl. NUL, UTF-16LE, NUL terminator (matches the golden name bytes)")
    func strings() {
        #expect(PTPPack.string("Warm Gold").hexString == "0a5700610072006d00200047006f006c0064000000")
        #expect(PTPPack.string("") == Data([0]))
        #expect(parsePTPString(PTPPack.string("Golden faces")) == "Golden faces")
        #expect(parsePTPString(Data()) == "")
    }

    @Test("u16/i16 packing wraps like DataView")
    func packing() {
        #expect(PTPPack.i16(-5).hexString == "fbff")
        #expect(PTPPack.u16(0x8007).hexString == "0780")
        #expect(PTPPack.u16(65536 + 3).hexString == "0300")
        #expect(PTPPack.u32(33404).hexString == "7c820000")
    }

    @Test("GetDeviceInfo dataset round trip (model, firmware, serial, props)")
    func deviceInfo() throws {
        var info = PTPDeviceInfo()
        info.standardVersion = 100
        info.vendorExtensionID = 0x0E
        info.vendorExtensionDescription = "fujifilm.co.jp: 1.0;"
        info.operations = [0x1001, 0x1015, 0x1016]
        info.properties = [0xD18C, 0xD18D, 0xD192]
        info.manufacturer = "FUJIFILM"
        info.model = "X100VI"
        info.deviceVersion = "1.32"
        info.serialNumber = "59S12345"
        let parsed = try PTPDeviceInfo(parsing: info.encoded())
        #expect(parsed == info)
        // camera.ts stops after the model; a dataset that ends there still parses.
        var short = info
        short.deviceVersion = ""
        short.serialNumber = ""
        let truncated = info.encoded().prefix(info.encoded().count - PTPPack.string("1.32").count - PTPPack.string("59S12345").count)
        #expect(try PTPDeviceInfo(parsing: truncated) == short)
        #expect(throws: PTPError.self) { try PTPDeviceInfo(parsing: Data([1, 2, 3])) }
    }

    @Test("Property values decode like camera.ts decode(): int16, int32, u8, string, hex")
    func propDecode() {
        #expect(RawProp(id: 0xD19B, bytes: Data([0xFB, 0xFF])).value == .int(-5))
        #expect(RawProp(id: 0xD199, bytes: Data([0x07, 0x80])).intValue == -32761) // WB is masked & 0xFFFF later
        #expect(RawProp(id: 1, bytes: Data([0x10, 0, 0, 0])).value == .int(16))
        #expect(RawProp(id: 1, bytes: Data([3])).value == .int(3))
        #expect(RawProp(id: FujiProp.name, bytes: PTPPack.string("Moody B&W")).value == .string("Moody B&W"))
        #expect(RawProp(id: 1, bytes: Data([1, 2, 3])).value == .hex("010203"))
    }

    @Test("Response names")
    func names() {
        #expect(PTP.Response.name(0x2001) == "OK")
        #expect(PTP.Response.name(0x201C) == "InvalidDevicePropValue")
        #expect(PTP.Response.name(0x2BAD) == "0x2BAD")
    }
}
