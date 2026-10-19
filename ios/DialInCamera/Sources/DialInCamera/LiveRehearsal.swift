// A pretend X100VI in USB RAW CONV./BACKUP RESTORE for `dialin-cam props / look-live / look-restore --rehearse` and the
// tests: the whole live-look path with nothing leaving the Mac.
//
// What it models (docs/FUJIFILM-PROTOCOL.md §2.9): GetDeviceInfo lists D16E, the slot block and
// the 23 live look codes (what an X-H2 lists in mode 6; the X100VI's real list is what `props --read` reports). Live
// values start at `MockCameraLink.defaultLiveState`. Writes obey the camera's gates with 0x201C: Kelvin only while WB is
// Kelvin; DR/highlight/shadow only while D-Range Priority is Off; mono toning only on B&W sims; colour-only codes only
// on colour sims. Grain Off written as 1 reads back 6, like the X100VI. Anything else answers 0x200A.
import Foundation

public actor FakeLiveCamera: PTPTransport {
    public private(set) var values: [UInt16: Data]
    /// "set D001 0b00 → OK" / "get D001" lines, in order.
    public private(set) var log: [String] = []
    public let advertised: [UInt16]

    public init(values: [UInt16: Data] = MockCameraLink.defaultLiveState) {
        var v = values
        v[LiveProps.usbMode.code] = PTPPack.u16(6)
        self.values = v
        advertised = [LiveProps.usbMode.code] + Array(0xD18C...0xD1A5).map { UInt16($0) }
            + LiveProps.lookBlock.map(\.code).filter { !(0xD18C...0xD1A5).contains($0) }
    }

    public func open(timeout: Duration) async throws {}
    public func close() async {}

    public func transact(_ operation: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult {
        switch operation {
        case PTP.Op.getDeviceInfo:
            var info = PTPDeviceInfo()
            info.manufacturer = "FUJIFILM"
            info.model = "X100VI"
            info.deviceVersion = "rehearsal"
            info.operations = [0x1001, 0x1002, 0x1003, 0x1008, 0x1009, 0x100C, 0x100D, 0x1014, 0x1015, 0x1016, 0x900C, 0x900D]
            info.properties = advertised
            return PTPResult(code: PTP.Response.ok, data: info.encoded())
        case PTP.Op.getDevicePropValue:
            let id = UInt16(params.first ?? 0)
            log.append("get \(LiveHex.code(id))")
            guard let v = values[id] else { return PTPResult(code: PTP.Response.devicePropNotSupported) }
            return PTPResult(code: PTP.Response.ok, data: v)
        case PTP.Op.setDevicePropValue:
            let id = UInt16(params.first ?? 0)
            let bytes = dataOut ?? Data()
            let code = gate(id, bytes)
            log.append("set \(LiveHex.code(id)) \(bytes.hexString) → \(PTP.Response.name(code))")
            if code == PTP.Response.ok {
                values[id] = id == LiveProps.grain.code && bytes == PTPPack.u16(1) ? PTPPack.u16(6) : bytes
            }
            return PTPResult(code: code)
        default:
            return PTPResult(code: PTP.Response.operationNotSupported)
        }
    }

    private func u16(_ code: UInt16) -> Int? { values[code].flatMap { try? LiveCodec.decode($0, as: .uint16) } }

    /// The response the camera would give.
    func gate(_ id: UInt16, _ bytes: Data) -> UInt16 {
        guard LiveLook.writableCodes.contains(id), values[id] != nil else { return PTP.Response.devicePropNotSupported }
        guard bytes.count == 2 else { return PTP.Response.invalidDevicePropValue }
        let mono = u16(LiveProps.filmSimulation.code).flatMap { LiveFilmSim(rawValue: UInt16($0)) }?.isMonochrome ?? false
        let ok = PTP.Response.ok, refused = PTP.Response.invalidDevicePropValue
        switch id {
        case LiveProps.colorTemperature.code:
            return u16(LiveProps.whiteBalance.code) == Int(LiveWB.kelvin.rawValue) ? ok : refused
        case LiveProps.dynamicRange.code, LiveProps.highlight.code, LiveProps.shadow.code:
            return u16(LiveProps.dRangePriority.code) == 0 ? ok : refused
        case LiveProps.monoWarmCool.code, LiveProps.monoMagentaGreen.code:
            return mono ? ok : refused
        case LiveProps.color.code, LiveProps.colorChrome.code, LiveProps.colorChromeFxBlue.code, LiveProps.wbShiftR.code, LiveProps.wbShiftB.code:
            return mono ? refused : ok
        case LiveProps.grain.code:
            return (try? LiveCodec.decode(bytes, as: .uint16)).map { (1...5).contains($0) } == true ? ok : refused
        default:
            return ok
        }
    }
}
