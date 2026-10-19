import Foundation
import Synchronization
@testable import DialInCamera

/// Ordered log shared by the fake camera and test callbacks.
final class EventLog: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ e: String) { entries.withLock { $0.append(e) } }
    var all: [String] { entries.withLock { $0 } }
}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw CameraError.invalid("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
    }

    struct Vector: Decodable {
        struct Write: Decodable {
            let id: String
            let hex: String
            var propID: UInt16 { UInt16(id.dropFirst(2), radix: 16)! }
        }

        let recipe: Recipe
        let slot: Int
        let writes: [Write]

        var propWrites: [PropWrite] { writes.map { PropWrite(propID: $0.propID, bytes: Data(hexString: $0.hex)!) } }
    }

    static func vectors() throws -> [Vector] {
        try JSONDecoder().decode([Vector].self, from: data("slot-write-vectors.json"))
    }

    struct TSExpectations: Decodable {
        struct Summary: Decodable {
            struct Block: Decodable {
                let id: Int
                let hex: String
            }

            let recipe: Recipe
            let block: [Block]
            let summary: String
        }

        let slotNames: [[String]]
        let summaries: [Summary]
    }

    static func tsExpectations() throws -> TSExpectations {
        try JSONDecoder().decode(TSExpectations.self, from: data("ts-expectations.json"))
    }

    /// The base the TS vector exporter passes (scripts/export-vectors.ts): D18E, D18F, D191, D1A3, D1A4 = 07 00.
    static let vectorBase: [RawProp] = [0xD18E, 0xD18F, 0xD191, 0xD1A3, 0xD1A4].map { RawProp(id: $0, bytes: Data([7, 0])) }
}

/// A Fujifilm body in USB RAW CONV./BACKUP RESTORE mode, answering plain PTP the way camera.ts expects:
/// per-slot storage behind the D18C cursor, OK for every write unless told otherwise.
actor FakePTPCamera: PTPTransport {
    struct Command: Sendable {
        let op: UInt16
        let params: [UInt32]
        let dataOut: Data?
        let at: ContinuousClock.Instant
    }

    var model = "X100VI"
    var advertised: [UInt16] = [FujiProp.usbMode] + Array(0xD18C...0xD1A5).map { UInt16($0) }
    var slots: [Int: [UInt16: Data]] = [:]
    var global: [UInt16: Data] = [FujiProp.usbMode: PTPPack.u16(6)]
    var selected = 1
    private(set) var commands: [Command] = []
    private(set) var opened = false
    private(set) var closed = false

    /// Simulate low ISO: refuse DR above this (test-writer.ts `rejectDrAbove`).
    var rejectDRAbove = 0
    /// Answer 0x201C for these props.
    var rejectProps: Set<UInt16> = []
    /// Hardware-observed conditional refusal: D19F cannot be written while a monochrome simulation is selected.
    var rejectColorInMonochrome = false
    var rejectReadProps: Set<UInt16> = []
    /// Answer OK but don't store (a write that "didn't stick").
    var ignoreWrites: Set<UInt16> = []
    /// Throw on GetDeviceInfo (card-reader mode).
    var failDeviceInfo = false
    /// Throw a disconnect on the Nth SetDevicePropValue (1-based).
    var disconnectOnWrite: Int?
    var settingsFile = Data()
    /// GetDevicePropValue answers these bytes instead of what's stored (e.g. grain Off reading back as 7).
    var readBackOverride: [UInt16: Data] = [:]
    /// Selects and name read-backs are appended here as they happen.
    var eventLog: EventLog?
    /// After an accepted write to the key, also store these (e.g. a film-sim change resetting another live value).
    var writeSideEffects: [UInt16: [UInt16: Data]] = [:]

    init() {
        for slot in 1...7 {
            let recipe = Recipe(name: "C\(slot)", filmSim: .provia)
            var values: [UInt16: Data] = [FujiProp.name: PTPPack.string(recipe.slotName)]
            for p in SlotEncoder.presetProps(PresetValues(recipe: recipe)) where p.propID != FujiProp.liveImageSize {
                values[p.propID] = p.bytes
            }
            slots[slot] = values
        }
    }

    func configure(_ body: @Sendable (isolated FakePTPCamera) -> Void) { body(self) }

    /// Every SetDevicePropValue, in order.
    var writes: [PropWrite] {
        commands.filter { $0.op == PTP.Op.setDevicePropValue }.map { PropWrite(propID: UInt16($0.params[0]), bytes: $0.dataOut ?? Data()) }
    }

    var reads: [UInt16] { commands.filter { $0.op == PTP.Op.getDevicePropValue }.map { UInt16($0.params[0]) } }

    func open(timeout: Duration) async throws { opened = true }
    func close() async { closed = true }

    func transact(_ op: UInt16, params: [UInt32], dataOut: Data?, timeout: Duration?) async throws -> PTPResult {
        commands.append(Command(op: op, params: params, dataOut: dataOut, at: .now))
        switch op {
        case PTP.Op.getDeviceInfo:
            if failDeviceInfo { throw CameraError.transport("PTP 0x1001 failed: device is a mass-storage volume") }
            var info = PTPDeviceInfo()
            info.manufacturer = "FUJIFILM"
            info.model = model
            info.deviceVersion = "1.32"
            info.serialNumber = "12345678"
            info.operations = [0x1001, 0x1002, 0x1003, 0x1008, 0x1009, 0x100C, 0x100D, 0x1014, 0x1015, 0x1016]
            info.properties = advertised
            return PTPResult(code: PTP.Response.ok, data: info.encoded())
        case PTP.Op.getDevicePropValue:
            let id = UInt16(params[0])
            if rejectReadProps.contains(id) { return PTPResult(code: PTP.Response.devicePropNotSupported) }
            if id == FujiProp.name { eventLog?.append("readname \(selected)") }
            if let v = readBackOverride[id], value(id) != nil { return PTPResult(code: PTP.Response.ok, data: v) }
            if let v = value(id) { return PTPResult(code: PTP.Response.ok, data: v) }
            return PTPResult(code: PTP.Response.devicePropNotSupported)
        case PTP.Op.setDevicePropValue:
            let id = UInt16(params[0])
            let bytes = dataOut ?? Data()
            if let n = disconnectOnWrite, writes.count == n { throw CameraError.disconnected("camera unplugged") }
            if id == FujiProp.slot {
                selected = Int(LE.u16([UInt8](bytes), 0))
                eventLog?.append("select \(selected)")
                return PTPResult(code: PTP.Response.ok)
            }
            if rejectProps.contains(id) { return PTPResult(code: PTP.Response.invalidDevicePropValue) }
            if id == FujiProp.color, rejectColorInMonochrome,
               let sim = slots[selected]?[FujiProp.filmSimulation], sim.count >= 2,
               FujiFilmSim.monochromeCodes.contains(Int(LE.u16([UInt8](sim), 0))) {
                return PTPResult(code: PTP.Response.invalidDevicePropValue)
            }
            if (id == FujiProp.dynamicRange || id == LiveProps.dynamicRange.code) && rejectDRAbove != 0
                && Int(LE.u16([UInt8](bytes), 0)) > rejectDRAbove {
                return PTPResult(code: PTP.Response.invalidDevicePropValue)
            }
            if ignoreWrites.contains(id) { return PTPResult(code: PTP.Response.ok) }
            store(id, bytes)
            for (k, v) in writeSideEffects[id] ?? [:] { store(k, v) }
            return PTPResult(code: PTP.Response.ok)
        case PTP.Op.getObjectInfo:
            return params.first == 0 && !settingsFile.isEmpty
                ? PTPResult(code: PTP.Response.ok, data: FujiCamera.settingsObjectInfo(fileLength: settingsFile.count))
                : PTPResult(code: PTP.Response.invalidObjectHandle)
        case PTP.Op.getObject:
            return PTPResult(code: PTP.Response.ok, data: settingsFile)
        case PTP.Op.sendObjectInfo, PTP.Op.sendObject:
            return PTPResult(code: PTP.Response.ok)
        default:
            return PTPResult(code: PTP.Response.operationNotSupported)
        }
    }

    private func isSlotProp(_ id: UInt16) -> Bool { id == FujiProp.name || FujiProp.slotBlock.contains(id) }

    private func value(_ id: UInt16) -> Data? { isSlotProp(id) ? slots[selected]?[id] : global[id] }

    private func store(_ id: UInt16, _ bytes: Data) {
        if isSlotProp(id) { slots[selected, default: [:]][id] = bytes } else { global[id] = bytes }
    }

    /// Fill a slot as if the camera held this recipe.
    func seed(slot: Int, recipe: Recipe) {
        var s: [UInt16: Data] = [FujiProp.name: PTPPack.string(recipe.slotName)]
        for p in SlotEncoder.presetProps(PresetValues(recipe: recipe)) where p.propID != FujiProp.liveImageSize {
            s[p.propID] = p.bytes
        }
        slots[slot] = s
    }
}

extension Recipe {
    /// test-writer.ts `look({})`.
    static func testLook(
        name: String = "Test", filmSim: FilmSimulation = .classicChrome, whiteBalance: WhiteBalance = .kelvin, kelvin: Int = 5600
    ) -> Recipe {
        Recipe(
            name: name, filmSim: filmSim, grain: .weakSmall, colorChrome: .strong, colorChromeFxBlue: .weak,
            whiteBalance: whiteBalance, kelvin: kelvin, wbShiftR: 2, wbShiftB: -3, dynamicRange: .dr400, highlight: -1,
            shadow: 0.5, color: 2, sharpness: -2, noiseReduction: -4, clarity: 0, why: "")
    }
}
