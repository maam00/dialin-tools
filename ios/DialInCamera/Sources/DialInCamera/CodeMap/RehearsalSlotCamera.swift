// A pretend X100VI in USB RAW CONV./BACKUP RESTORE for `dialin-cam map-codes --rehearse` and the tests: C1–C7 as PTP
// slot props behind the D18C cursor, plus the settings file (handle 0) that follows every slot write the way the camera
// stores it. `truth` decides the bytes for the values map-codes measures; by default it is the X-T5-derived guess
// (LookSlotMap), so a rehearsal reports every guess as right. Tests pass a different truth to show a wrong guess.
//
// Modeled: grain Off written as 1 reads back 6; saturation refused under a B&W sim (0x201C); a sim or WB the
// truth doesn't know refused; the per-WB-mode shift table (a shift lands in the entry of the slot's WB at that moment).
// Nothing leaves the process.
import Foundation

public actor RehearsalSlotCamera: PTPTransport {
    public struct Truth: Sendable, Equatable {
        public struct WB: Sendable, Equatable {
            public var code: Int
            public var entry: Int
            public init(code: Int, entry: Int) {
                self.code = code
                self.entry = entry
            }
        }

        /// PTP film-sim code → byte at slot + 0x64.
        public var filmSims: [Int: Int]
        /// PTP WB code → byte at slot − 0x0F and its WB-shift entry.
        public var whiteBalances: [Int: WB]
        /// Color −4…+4 → byte at slot + 0x77.
        public var colors: [Int: Int]
        /// High ISO NR −4…+4 → byte at slot + 0x2B.
        public var noiseReductions: [Int: Int]

        public init(filmSims: [Int: Int], whiteBalances: [Int: WB], colors: [Int: Int], noiseReductions: [Int: Int]) {
            self.filmSims = filmSims
            self.whiteBalances = whiteBalances
            self.colors = colors
            self.noiseReductions = noiseReductions
        }

        /// The X-T5-derived guesses (with the confirmed codes, which agree with them).
        public static let guesses = Truth(
            filmSims: Dictionary(uniqueKeysWithValues: LookSlotMap.filmSimGuesses.compactMap { k, v in Int(k).map { ($0, v) } }),
            whiteBalances: Dictionary(uniqueKeysWithValues: LookSlotMap.wbGuesses.compactMap { k, v in
                Int(k).flatMap { p in LookSlotMap.wbIndexGuesses[p].map { (p, WB(code: v, entry: $0)) } }
            }),
            colors: Dictionary(uniqueKeysWithValues: LookSlotMap.colorGuesses.compactMap { k, v in Double(k).map { (Int($0), v) } }),
            noiseReductions: Dictionary(uniqueKeysWithValues: (-4...4).map { ($0, $0 + 4) }))
    }

    public let truth: Truth
    /// The settings file as the camera holds it now (checksum fixed when it's downloaded).
    public private(set) var file: [UInt8]
    public private(set) var slots: [Int: [UInt16: Data]] = [:]
    public private(set) var selected = 1
    /// "set D192 0300 → OK", "get settings", … in order.
    public private(set) var log: [String] = []
    /// PTP film-sim codes the camera refuses (0x201C), to rehearse a skipped probe.
    public var refusedFilmSims: Set<Int> = []
    /// Throw a disconnect on the Nth slot write (1-based), to rehearse an unplug mid-sweep.
    public var unplugOnWrite: Int?
    private var slotWrites = 0

    public init(truth: Truth = .guesses) {
        self.truth = truth
        file = []
        var b = [UInt8](FakeFujiBLECamera.sampleSettings())
        let looks = FakeFujiBLECamera.sampleLooks
        let anchors = (try? FujiSettingsFile(bytes: b).anchors) ?? (0..<7).map { 0xF800 + $0 * 0x400 }
        for (i, look) in looks.enumerated() {
            let a = anchors[i]
            // A real table: every entry a shift (−2…+2), the look's own WB entry holding its shift.
            for e in 0..<CodeMap.entries {
                b[a - 0x0D + 4 * e] = UInt8(9 - ((i + e) % 5 - 2))
                b[a - 0x0B + 4 * e] = UInt8(9 - ((i * 3 + e) % 5 - 2))
            }
            var props: [UInt16: Data] = [FujiProp.name: PTPPack.string(look.slotName)]
            for p in SlotEncoder.presetProps(PresetValues(recipe: look)) where p.propID != FujiProp.liveImageSize { props[p.propID] = p.bytes }
            let wbPTP = LookSlotMap.wbCodes[look.whiteBalance] ?? 2
            if let e = truth.whiteBalances[wbPTP]?.entry, !look.filmSim.isMonochrome {
                b[a - 0x0D + 4 * e] = UInt8(9 - look.wbShiftR)
                b[a - 0x0B + 4 * e] = UInt8(9 - look.wbShiftB)
            }
            if look.filmSim.isMonochrome {
                // B&W looks keep colour values they don't use, in the file and in the PTP props.
                b[a + 0x77] = UInt8(truth.colors[1] ?? 6)
                b[a + 0x7F] = 1
                b[a + 0x80] = 0
                props[FujiProp.color] = PTPPack.i16(10)
                props[FujiProp.colorChrome] = PTPPack.u16(2)
                props[FujiProp.colorChromeFxBlue] = PTPPack.u16(1)
                props[FujiProp.wbShiftR] = PTPPack.i16(0)
                props[FujiProp.wbShiftB] = PTPPack.i16(0)
                // The current WB bank and property readback describe the same saved shifts.
                if let e = truth.whiteBalances[wbPTP]?.entry {
                    b[a - 0x0D + 4 * e] = 9
                    b[a - 0x0B + 4 * e] = 9
                }
            }
            slots[i + 1] = props
        }
        file = FakeFujiBLECamera.restamp(b, from: nil, k: 0xE5AE)
    }

    public func configure(_ body: @Sendable (isolated RehearsalSlotCamera) -> Void) { body(self) }

    /// The settings file the camera would send now.
    public var settingsFile: Data { Data(FakeFujiBLECamera.restamp(file, from: nil, k: 0xE5AE)) }

    public func open(timeout: Duration) async throws {}
    public func close() async {}

    public func transact(_ operation: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult {
        switch operation {
        case PTP.Op.getDeviceInfo:
            var info = PTPDeviceInfo()
            info.manufacturer = "FUJIFILM"
            info.model = "X100VI"
            info.deviceVersion = "1.10"
            info.serialNumber = "REHEARSAL"
            info.operations = [0x1001, 0x1002, 0x1003, 0x1008, 0x1009, 0x100C, 0x100D, 0x1014, 0x1015, 0x1016]
            info.properties = [FujiProp.usbMode] + Array(0xD18C...0xD1A5).map { UInt16($0) }
            return PTPResult(code: PTP.Response.ok, data: info.encoded())
        case PTP.Op.getObjectInfo:
            return params.first == 0
                ? PTPResult(code: PTP.Response.ok, data: FujiCamera.settingsObjectInfo(fileLength: file.count))
                : PTPResult(code: PTP.Response.invalidObjectHandle)
        case PTP.Op.getObject:
            log.append("get settings")
            return PTPResult(code: PTP.Response.ok, data: settingsFile)
        case PTP.Op.getDevicePropValue:
            let id = UInt16(params.first ?? 0)
            if id == FujiProp.usbMode { return PTPResult(code: PTP.Response.ok, data: PTPPack.u16(6)) }
            guard let v = slots[selected]?[id] else { return PTPResult(code: PTP.Response.devicePropNotSupported) }
            return PTPResult(code: PTP.Response.ok, data: v)
        case PTP.Op.setDevicePropValue:
            let id = UInt16(params.first ?? 0)
            let bytes = dataOut ?? Data()
            if id == FujiProp.slot {
                selected = Int(LE.u16([UInt8](bytes), 0))
                log.append("select C\(selected)")
                return PTPResult(code: PTP.Response.ok)
            }
            slotWrites += 1
            if let n = unplugOnWrite, slotWrites >= n { throw CameraError.disconnected("camera unplugged (rehearsal)") }
            let code = apply(id, bytes)
            log.append("set \(LiveHex.code(id)) \(bytes.hexString) → \(PTP.Response.name(code))")
            if code == PTP.Response.ok {
                slots[selected, default: [:]][id] = id == FujiProp.grain && bytes == PTPPack.u16(1) ? PTPPack.u16(6) : bytes
            }
            return PTPResult(code: code)
        default:
            return PTPResult(code: PTP.Response.operationNotSupported)
        }
    }

    private func u16(_ d: Data) -> Int { d.count >= 2 ? Int(LE.u16([UInt8](d), 0)) : 0 }
    private func i16(_ d: Data) -> Int { Int(Int16(bitPattern: UInt16(truncatingIfNeeded: u16(d)))) }

    /// A slot prop write as the camera stores it in the settings file. Returns the PTP response.
    private func apply(_ id: UInt16, _ bytes: Data) -> UInt16 {
        guard (1...7).contains(selected), let a = try? FujiSettingsFile(bytes: file).anchors[selected - 1] else {
            return PTP.Response.invalidDevicePropValue
        }
        let ok = PTP.Response.ok, refused = PTP.Response.invalidDevicePropValue
        let v = u16(bytes), s = i16(bytes)
        let sim = slots[selected]?[FujiProp.filmSimulation].map(u16) ?? 1
        let mono = FujiFilmSim.monochromeCodes.contains(sim)
        func put(_ rel: Int, _ raw: Int) -> UInt16 {
            guard (0...255).contains(raw) else { return refused }
            file[a + rel] = UInt8(raw)
            return ok
        }
        switch id {
        case FujiProp.name:
            var field = Array(parsePTPString(bytes).utf8.prefix(FujiSettingsFile.nameMaxLength))
            field += [UInt8](repeating: 0, count: FujiSettingsFile.nameFieldLength - field.count)
            file.replaceSubrange(a + FujiSettingsFile.nameRel..<a + FujiSettingsFile.nameRel + FujiSettingsFile.nameFieldLength, with: field)
            return ok
        case FujiProp.filmSimulation:
            guard let raw = truth.filmSims[v], !refusedFilmSims.contains(v) else { return refused }
            return put(0x64, raw)
        case FujiProp.dRangePriority:
            return put(0x76, [0: 4, 1: 3, 2: 2, 0x8000: 0][v] ?? 4)
        case FujiProp.dynamicRange:
            guard let raw = [100: 1, 200: 2, 400: 3][v] else { return refused }
            return put(0x74, raw)
        case FujiProp.grain:
            switch v {
            case 1: return put(0x81, 2)
            case 2: _ = put(0x82, 0); return put(0x81, 1)
            case 3: _ = put(0x82, 0); return put(0x81, 0)
            case 4: _ = put(0x82, 1); return put(0x81, 1)
            case 5: _ = put(0x82, 1); return put(0x81, 0)
            default: return refused
            }
        case FujiProp.colorChrome, FujiProp.colorChromeFxBlue:
            // X100VI 1.10 USB hardware, 2026-10-13: these accept raw writes under Acros.
            guard (1...3).contains(v) else { return refused }
            return put(id == FujiProp.colorChrome ? 0x7F : 0x80, v - 1)
        case FujiProp.smoothSkin:
            return put(0x83, max(0, v - 1))
        case FujiProp.whiteBalance:
            guard let wb = truth.whiteBalances[v] else { return refused }
            return put(-0x0F, wb.code)
        case FujiProp.colorTemperature:
            file[a - 0x74] = UInt8(v & 0xFF)
            file[a - 0x73] = UInt8(v >> 8)
            return ok
        case FujiProp.wbShiftR, FujiProp.wbShiftB:
            let wbPTP = slots[selected]?[FujiProp.whiteBalance].map(u16) ?? 2
            guard (-9...9).contains(s), let e = truth.whiteBalances[wbPTP]?.entry else { return refused }
            return put((id == FujiProp.wbShiftR ? -0x0D : -0x0B) + 4 * e, 9 - s)
        case FujiProp.highlight, FujiProp.shadow:
            return put(id == FujiProp.highlight ? 0x7B : 0x7D, (s + 20) / 5)
        case FujiProp.color:
            guard !mono, let raw = truth.colors[s / 10] else { return refused }
            return put(0x77, raw)
        case FujiProp.sharpness:
            return put(0x79, 4 - s / 10)
        case FujiProp.highISONR:
            guard let n = FujiNR.decode[v], let raw = truth.noiseReductions[n] else { return refused }
            return put(0x2B, raw)
        case FujiProp.clarity:
            return put(0x2E, s / 10 + 6)
        default:
            return ok
        }
    }
}
