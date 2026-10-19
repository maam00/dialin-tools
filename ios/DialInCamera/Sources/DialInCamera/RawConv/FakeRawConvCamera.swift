// A pretend X100VI in USB RAW CONV./BACKUP RESTORE, answering the RAW-conversion sequence the way the references
// describe it (FilmKit session.ts:484-700; on an X-T5 in mode 6, D183/D185 refuse reads until
// a RAF is loaded). Used by the tests and by `dialin-cam rawconv --rehearse` (the whole CLI path, no camera).
//
// It checks what it is sent: the 900C ObjectInfo must say format 0xF802 / "FUP_FILE.dat" / the RAF's size, 900D must
// carry exactly that many bytes of a RAF for the same model, and D185 writes must keep the profile's length. Its
// "render" is canned bytes; it never processes anything, so nothing it returns is ever Fuji color.
import Foundation

public actor FakeRawConvCamera: PTPTransport {
    public struct Config: Sendable {
        public var model = "X100VI"
        public var firmware = "1.10"
        public var usbMode = 6
        /// List 900C/900D and D183/D185 in DeviceInfo.
        public var advertiseRawConv = true
        public var profile: Data = FakeRawConvCamera.sampleProfile()
        /// What a full render returns.
        public var renderBytes: Data = FakeRawConvCamera.tinyJPEG(width: 3888, height: 2592)
        public var thumbBytes: Data = FakeRawConvCamera.tinyJPEG(width: 640, height: 480)
        public var supportsThumb = true
        /// GetObjectHandles calls that return nothing before the render appears.
        public var pollsUntilReady = 2
        /// Never produce a render (a wedged camera).
        public var wedge = false
        /// Throw a transport timeout on this opcode.
        public var timeoutOn: UInt16?
        /// Also list the uploaded RAF as object 1 (a camera that does would break "take the first handle").
        public var listUploadedRAF = false
        /// Answer D185 writes with 0x201C when this returns true.
        public var rejectProfile: (@Sendable (Data) -> Bool)?
        /// Answer these opcodes with OperationNotSupported.
        public var refuseOps: Set<UInt16> = []

        public init() {}
    }

    public struct Command: Sendable {
        public let op: UInt16
        public let params: [UInt32]
        public let dataOut: Data?
    }

    public var config: Config
    public private(set) var commands: [Command] = []
    public private(set) var uploadedRAF: Data?
    /// The D185 bytes in effect at each D183 trigger.
    public private(set) var renderedProfiles: [Data] = []
    public private(set) var startValues: [Int] = []
    public private(set) var deletedHandles: [UInt32] = []
    public private(set) var opened = false
    public private(set) var closed = false

    private var expectedSize: Int?
    private var currentProfile = Data()
    private var pending: (handle: UInt32, polls: Int)?
    private var ready: Set<UInt32> = []
    private var nextHandle: UInt32 = 0x9000_0001
    private static let rafHandle: UInt32 = 1

    public init(config: Config = Config()) {
        self.config = config
    }

    public func configure(_ body: @Sendable (inout Config) -> Void) { body(&config) }

    public var ops: [UInt16] { commands.map(\.op) }

    public func open(timeout: Duration) async throws { opened = true }
    public func close() async { closed = true }

    public func transact(_ op: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult {
        commands.append(Command(op: op, params: params, dataOut: dataOut))
        if config.timeoutOn == op { throw CameraError.timeout(String(format: "PTP 0x%04X after %@", op, String(describing: timeout ?? .seconds(10)))) }
        if config.refuseOps.contains(op) { return PTPResult(code: PTP.Response.operationNotSupported) }
        switch op {
        case PTP.Op.getDeviceInfo:
            var info = PTPDeviceInfo()
            info.manufacturer = "FUJIFILM"
            info.model = config.model
            info.deviceVersion = config.firmware
            info.serialNumber = "00000000"
            info.operations = [0x1001, 0x1002, 0x1003, 0x1007, 0x1009, 0x100A, 0x100B, 0x1015, 0x1016]
                + (config.advertiseRawConv ? [FujiRawConverter.Op.sendObjectInfo, FujiRawConverter.Op.sendObject2] : [])
            info.properties = [FujiProp.usbMode, FujiProp.slot]
                + (config.advertiseRawConv ? [FujiRawConverter.Prop.startConversion, FujiRawConverter.Prop.profile] : [])
            return PTPResult(code: PTP.Response.ok, data: info.encoded())

        case PTP.Op.getDevicePropValue:
            switch UInt16(params.first ?? 0) {
            case FujiProp.usbMode: return PTPResult(code: PTP.Response.ok, data: PTPPack.u16(config.usbMode))
            case FujiProp.compatibilityCode: return PTPResult(code: PTP.Response.ok, data: PTPPack.string("\(config.model)_0110"))
            case FujiRawConverter.Prop.profile:
                guard uploadedRAF != nil else { return PTPResult(code: PTP.Response.generalError) }
                return PTPResult(code: PTP.Response.ok, data: currentProfile)
            default: return PTPResult(code: PTP.Response.devicePropNotSupported)
            }

        case PTP.Op.setDevicePropValue:
            let bytes = dataOut ?? Data()
            switch UInt16(params.first ?? 0) {
            case FujiRawConverter.Prop.profile:
                guard uploadedRAF != nil else { return PTPResult(code: PTP.Response.generalError) }
                guard bytes.count == config.profile.count, config.rejectProfile?(bytes) != true else {
                    return PTPResult(code: PTP.Response.invalidDevicePropValue)
                }
                currentProfile = bytes
                return PTPResult(code: PTP.Response.ok)
            case FujiRawConverter.Prop.startConversion:
                guard uploadedRAF != nil, bytes.count == 2 else { return PTPResult(code: PTP.Response.generalError) }
                renderedProfiles.append(currentProfile)
                startValues.append(Int(LE.u16([UInt8](bytes), 0)))
                if !config.wedge {
                    pending = (nextHandle, config.pollsUntilReady)
                    nextHandle += 1
                }
                return PTPResult(code: PTP.Response.ok)
            default:
                return PTPResult(code: PTP.Response.devicePropNotSupported)
            }

        case FujiRawConverter.Op.sendObjectInfo:
            let oi = [UInt8](dataOut ?? Data())
            guard params == [0, 0, 0], oi.count >= 52, LE.u16(oi, 4) == 0xF802,
                  parsePTPString(Data(oi[52...])) == "FUP_FILE.dat" else { return PTPResult(code: PTP.Response.invalidStorageID) }
            expectedSize = Int(LE.u32(oi, 8))
            return PTPResult(code: PTP.Response.ok)

        case FujiRawConverter.Op.sendObject2:
            let raf = dataOut ?? Data()
            guard let expectedSize else { return PTPResult(code: PTP.Response.generalError) }
            guard raf.count == expectedSize else { return PTPResult(code: PTP.Response.incompleteTransfer) }
            guard let m = RAFHeader.model(raf), m == config.model else { return PTPResult(code: PTP.Response.generalError) }
            uploadedRAF = raf
            currentProfile = config.profile
            self.expectedSize = nil
            return PTPResult(code: PTP.Response.ok)

        case FujiRawConverter.Op.getObjectHandles:
            var list: [UInt32] = []
            if config.listUploadedRAF, uploadedRAF != nil { list.append(Self.rafHandle) }
            if let p = pending {
                if p.polls <= 0 {
                    ready.insert(p.handle)
                    pending = nil
                } else {
                    pending = (p.handle, p.polls - 1)
                }
            }
            list += ready.sorted()
            var d = Data()
            d.appendLE32(UInt32(list.count))
            for h in list { d.appendLE32(h) }
            return PTPResult(code: PTP.Response.ok, data: d)

        case FujiRawConverter.Op.getObject:
            let h = params.first ?? 0
            if h == Self.rafHandle, config.listUploadedRAF, let raf = uploadedRAF { return PTPResult(code: PTP.Response.ok, data: raf) }
            guard ready.contains(h) else { return PTPResult(code: PTP.Response.invalidObjectHandle) }
            return PTPResult(code: PTP.Response.ok, data: config.renderBytes)

        case FujiRawConverter.Op.getThumb:
            guard config.supportsThumb else { return PTPResult(code: PTP.Response.operationNotSupported) }
            guard ready.contains(params.first ?? 0) else { return PTPResult(code: PTP.Response.invalidObjectHandle) }
            return PTPResult(code: PTP.Response.ok, data: config.thumbBytes)

        case FujiRawConverter.Op.deleteObject:
            let h = params.first ?? 0
            guard ready.remove(h) != nil else { return PTPResult(code: PTP.Response.invalidObjectHandle) }
            deletedHandles.append(h)
            return PTPResult(code: PTP.Response.ok)

        default:
            return PTPResult(code: PTP.Response.operationNotSupported)
        }
    }

    // MARK: Canned data

    /// A SYNTHETIC 625-byte profile shaped like FilmKit's description of the X100VI's (29 int32 parameters at
    /// `625 − 29·4`, d185.ts:91-95), holding _DSF1222's maker-note recipe (Reala Ace, DR400, grain Weak Small, CC Weak,
    /// CC FX Blue Weak, WB as shot, H −1, S 0, color +1, sharpness −1, NR −4, clarity 0) in FilmKit's encodings, with
    /// image quality 4 at index 4 and exposure 0 at index 5 (the libfuji reading). NOT a camera capture.
    public static func sampleProfile() -> Data {
        var p = [Int32](repeating: 0, count: 29)
        p[1] = 2          // [libfuji] shooting condition
        p[2] = 7          // [libfuji] file type
        p[3] = 7          // [libfuji] image size
        p[4] = 4          // FilmKit exposure / [libfuji] image quality
        p[5] = 0          // [libfuji] exposure bias
        p[6] = 400        // DR %
        p[8] = 0x14       // Reala Ace
        p[9] = 2          // grain Weak Small
        p[10] = 2         // CC Weak
        p[11] = 1         // FilmKit smooth skin Off / [libfuji] WB shoot condition on
        p[16] = -10       // highlight −1
        p[17] = 0
        p[18] = 10        // color +1
        p[19] = -10       // sharpness −1
        p[20] = 0x8000    // NR −4 (also FilmKit's "as shot" sentinel)
        p[21] = 1
        p[22] = 2
        p[25] = 2         // CC FX Blue Weak (1-indexed)
        return profile(iop: "FF179503", params: p, length: 625)
    }

    /// Build a profile: u16 count, u8 char count, UTF-16LE IOP + NUL, zeros, then the params at `length − n·4`.
    public static func profile(iop: String, params: [Int32], length: Int) -> Data {
        var d = Data()
        d.appendLE16(UInt16(params.count))
        let units = Array(iop.utf16)
        d.append(UInt8(units.count + 1))
        for u in units { d.appendLE16(u) }
        d.appendLE16(0)
        let off = length - params.count * 4
        precondition(d.count <= off, "header doesn't fit")
        d.append(Data(count: off - d.count))
        for v in params { d.appendLE32(UInt32(bitPattern: v)) }
        return d
    }

    /// Smallest bytes that sniff as a JPEG and carry a size (SOI, SOF0, EOI). Not decodable; tests only.
    public static func tinyJPEG(width: Int, height: Int) -> Data {
        var d = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08])
        d.append(contentsOf: [UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF)])
        d.append(contentsOf: [0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xD9])
        return d
    }

    /// A minimal RAF: the 16-byte magic, version, camera id, model at 0x1C, then filler.
    public static func tinyRAF(model: String = "X100VI", size: Int = 4096) -> Data {
        var d = Data("FUJIFILMCCD-RAW 0201FF179503".utf8)
        var m = Data(model.utf8)
        m.append(Data(count: 32 - m.count))
        d.append(m)
        d.append(Data(count: max(0, size - d.count)))
        return d
    }
}
