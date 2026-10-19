// LiveProps: the live (C0) property catalog, codecs, capability check, and the live-look planner. No hardware.
import Foundation
import Testing
@testable import DialInCamera

@Suite("Live props catalog")
struct LivePropsCatalogTests {
    @Test("Codes are unique and the 23-code look block mirrors D18E...D1A4")
    func lookBlockMirrorsSlots() {
        let codes = LiveProps.all.map(\.code)
        #expect(Set(codes).count == codes.count, "no duplicate codes")
        #expect(LiveProps.lookBlock.count == 23)
        let slotCodes = Set(LiveProps.lookBlock.compactMap(\.slotCode))
        #expect(slotCodes == Set(FujiProp.slotBlock), "every slot-block code has exactly one live twin")
    }

    @Test("Slot → live pairs match docs/FUJIFILM-PROTOCOL.md §2.9")
    func slotToLivePairs() {
        let expected: [UInt16: UInt16] = [
            0xD18E: 0xD1A5, 0xD18F: 0xD018, 0xD190: 0xD007, 0xD191: 0xD02E, 0xD192: 0xD001, 0xD193: 0xD104,
            0xD194: 0xD031, 0xD195: 0xD023, 0xD196: 0xD029, 0xD197: 0xD030, 0xD198: 0xD189, 0xD199: 0x5005,
            0xD19A: 0xD00B, 0xD19B: 0xD00C, 0xD19C: 0xD017, 0xD19D: 0xD320, 0xD19E: 0xD321, 0xD19F: 0xD008,
            0xD1A0: 0x5015, 0xD1A1: 0xD01C, 0xD1A2: 0xD032, 0xD1A3: 0xD34D, 0xD1A4: 0xD00A,
        ]
        #expect(LiveProps.liveCodeForSlotCode == expected)
    }

    @Test("PTP datatypes match the catalogued types")
    func datatypes() {
        #expect(LiveProps.filmSimulation.type == .uint16)
        #expect(LiveProps.highlight.type == .int16)
        #expect(LiveProps.monoWarmCool.type == .int16)
        #expect(LiveProps.wbShiftR.type == .int16)
        #expect(LiveProps.sensitivity.type == .int32)
        #expect(LiveProps.shutterSpeed.type == .uint32)
        #expect(LiveProps.exposureBias.type == .int16)
        #expect(LiveProps.focusArea.type == .string)
        #expect(LivePTPType.uint32.byteCount == 4 && LivePTPType.string.byteCount == nil)
    }

    @Test("Mode-6 reach only on the look block and the connection-mode readout")
    func reach() {
        let mode6 = Set(LiveProps.all.filter { $0.reach == .mode6 }.map(\.code))
        #expect(mode6 == Set(LiveProps.lookBlock.map(\.code)).union([LiveProps.usbMode.code]))
        #expect(LiveProps.shutterSpeed.reach == .tether && LiveProps.driveMode.reach == .tether)
    }

    @Test("Probe starts with identity and never includes the release prop")
    func probeOrder() {
        #expect(LiveProps.probeReadOrder.first == LiveProps.usbMode.code)
        #expect(!LiveProps.probeReadOrder.contains(LiveProps.release.code))
        #expect(Set(LiveProps.probeReadOrder).isSuperset(of: LiveProps.lookBlock.map(\.code)))
        #expect(LiveProps.prop(0xD001)?.name == "film simulation")
        #expect(LiveProps.label(0xBEEF) == "0xbeef")
    }
}

@Suite("Live props codecs")
struct LivePropsCodecTests {
    @Test("Encode/decode round-trips and honours sign")
    func roundTrip() throws {
        #expect(try LiveCodec.encode(-10, as: .int16) == Data([0xF6, 0xFF]))
        #expect(try LiveCodec.decode(Data([0xF6, 0xFF]), as: .int16) == -10)
        #expect(try LiveCodec.decode(Data([0xF6, 0xFF]), as: .uint16) == 0xFFF6)
        #expect(try LiveCodec.encode(3906, as: .uint32) == Data([0x42, 0x0F, 0, 0]))
        #expect(try LiveCodec.decode(Data([0xFF, 0xFF, 0xFF, 0xFF]), as: .int32) == -1)
        #expect(throws: LiveCodecError.self) { try LiveCodec.encode(70000, as: .uint16) }
        #expect(throws: LiveCodecError.self) { try LiveCodec.encode(-1, as: .uint16) }
        #expect(throws: LiveCodecError.badSize(expected: 2, got: 4)) { try LiveCodec.decode(Data([0, 0, 0, 0]), as: .uint16) }
        #expect(throws: LiveCodecError.notNumeric) { try LiveCodec.encode(1, as: .string) }
    }

    @Test("Film sim numbering matches the slot table and Recipe codes")
    func filmSims() {
        for sim in FilmSimulation.allCases {
            let live = LiveFilmSim(rawValue: UInt16(sim.code))
            #expect(live != nil, "\(sim) has a live code")
            #expect(live?.isMonochrome == sim.isMonochrome, "\(sim) mono flag agrees")
        }
        #expect(LiveFilmSim.realaAce.rawValue == 0x14)
        #expect(LiveFilmSim.auto.rawValue == 0x8000)
        #expect(LiveFilmSim(bytes: Data([0x0B, 0x00])) == .classicChrome)
        #expect(LiveFilmSim.classicNeg.bytes == Data([0x11, 0x00]))
    }

    @Test("WB, DR, D-Range Priority and effects use the catalogued values")
    func enums() {
        #expect(LiveWB.kelvin.rawValue == UInt16(FujiWB.colorTemp))
        #expect(LiveWB.auto.rawValue == UInt16(FujiWB.auto))
        #expect(LiveWB.autoAmbiencePriority.rawValue == UInt16(FujiWB.ambiencePriority))
        #expect(LiveWB.autoWhitePriority.rawValue == 0x8020)
        #expect(LiveDR.auto.rawValue == 0xFFFF && LiveDR.dr400.rawValue == 400 && LiveDR.dr400.minimumISO == 500)
        #expect(LiveDRangePriority.auto.rawValue == 0x8000 && LiveDRangePriority.off.rawValue == 0)
        #expect(LiveEffect.strong.bytes == Data([3, 0]) && LiveEffect.off.label == "Off")
        #expect(LiveFocusMode.afc.rawValue == 0x8002 && LiveAFMode.zone.rawValue == 0x8002)
        #expect(LiveFaceDetection.off.rawValue == 2 && LiveEyeAF.auto.rawValue == 2)
        #expect(LivePriority.pc.rawValue == 2 && LiveForceMode.shoot.rawValue == 1)
        #expect(LiveAEMode.aperturePriority.label == "A")
    }

    @Test("Grain: Off is written as 1, read-backs 6/7 decode as Off")
    func grain() {
        #expect(LiveGrain(wire: 6) == .off(large: false))
        #expect(LiveGrain(wire: 7) == .off(large: true))
        #expect(LiveGrain(wire: 7)?.wire == 1, "never send 7")
        #expect(LiveGrain(wire: 6)?.bytes == Data([1, 0]))
        #expect(LiveGrain(wire: 4) == .weakLarge && LiveGrain(wire: 4)?.isOff == false)
        #expect(LiveGrain(wire: 0) == nil && LiveGrain(wire: 8) == nil)
    }

    @Test("Tone dials are x10 with each setting's range and step")
    func tones() throws {
        #expect(try LiveTone.encode(-1, LiveTone.highlight) == PTPPack.i16(-10))
        #expect(try LiveTone.encode(0.5, LiveTone.shadow) == PTPPack.i16(5))
        #expect(try LiveTone.encode(-18, LiveTone.mono) == PTPPack.i16(-180))
        #expect(throws: LiveCodecError.self) { try LiveTone.encode(1.25, LiveTone.highlight) }
        #expect(throws: LiveCodecError.self) { try LiveTone.encode(5, LiveTone.color) }
        #expect(throws: LiveCodecError.self) { try LiveTone.encode(0.5, LiveTone.clarity) }
        #expect(LiveTone.decode(PTPPack.i16(-15)) == -1.5)
        #expect(LiveTone.nrEncode == FujiNR.encode, "NR table identical to the slot's")
        #expect(try LiveTone.encodeNR(-4) == Data([0x00, 0x80]))
        #expect(LiveTone.decodeNR(0x6000) == 3)
    }

    @Test("Exposure: milli-EV thirds, µs shutter table, f x 100")
    func exposure() throws {
        #expect(try LiveExposure.exposureBias(thirds: 1) == PTPPack.i16(333))
        #expect(try LiveExposure.exposureBias(thirds: 2) == PTPPack.i16(667))
        #expect(try LiveExposure.exposureBias(thirds: -3) == PTPPack.i16(-1000))
        #expect(try LiveExposure.exposureBias(thirds: 15) == PTPPack.i16(5000))
        #expect(throws: LiveCodecError.self) { try LiveExposure.exposureBias(thirds: 16) }
        #expect(LiveExposure.thirds(milliEV: -667) == -2)
        #expect(LiveExposure.thirds(milliEV: 500) == nil)
        #expect(LiveExposure.shutter("1/250") == 3906)
        #expect(LiveExposure.shutter("1/8000") == 122)
        #expect(LiveExposure.shutter("30") == 32_000_000)
        #expect(try LiveExposure.aperture(2.0) == PTPPack.u16(200))
        #expect(try LiveExposure.aperture(5.6) == PTPPack.u16(560))
        #expect(throws: LiveCodecError.self) { try LiveExposure.aperture(0.5) }
    }

    @Test("ISO decodes Fuji's negative auto presets and libgphoto2's bit-31 form")
    func iso() {
        #expect(LiveISO(wire: 400) == .iso(400))
        #expect(LiveISO(wire: -1) == .autoPreset(1))
        #expect(LiveISO(wire: -10) == .auto)
        #expect(LiveISO(wire: Int(Int32(bitPattern: 0x8000_1900))) == .autoCeiling(6400))
        #expect(LiveISO.iso(400).bytes == Data([0x90, 0x01, 0x00, 0x00]))
        #expect(LiveISO.autoPreset(2).bytes == Data([0xFE, 0xFF, 0xFF, 0xFF]))
        #expect(LiveISO.autoCeiling(6400).bytes == nil, "we never write the bit-31 form")
    }

    @Test("Drive keeps the raw value; only S and movie are confident")
    func drive() {
        #expect(LiveDrive.single.bytes == Data([4, 0]) && LiveDrive.single.isConfident)
        #expect(LiveDrive(wire: 0x1000).label == "CL (per-model table)" && !LiveDrive(wire: 0x1000).isConfident)
        #expect(LiveDrive(wire: 0x0003).label.contains("generic table"))
    }

    @Test("describe() renders reads for logs")
    func describe() {
        #expect(LiveCodec.describe(Data([0x0B, 0]), for: LiveProps.filmSimulation) == "Classic Chrome (11)")
        #expect(LiveCodec.describe(PTPPack.i16(667), for: LiveProps.exposureBias) == "+0.7 EV (667)")
        #expect(LiveCodec.describe(PTPPack.u32(3906), for: LiveProps.shutterSpeed) == "1/250 s (3906)")
        #expect(LiveCodec.describe(PTPPack.u16(7), for: LiveProps.grain) == "Off (large) (7)")
        #expect(LiveCodec.describe(PTPPack.i16(-15), for: LiveProps.highlight) == "-1.5 (-15)")
        #expect(LiveCodec.describe(PTPPack.u16(6), for: LiveProps.usbMode) == "RAW CONV./BACKUP RESTORE (6)")
        #expect(LiveCodec.describe(Data([1, 2, 3]), for: LiveProps.filmSimulation) == "0x010203")
    }
}

@Suite("Live look planner")
struct LiveLookTests {
    @Test("A colour look becomes live writes in camera order with the slot's exact bytes")
    func colourLook() {
        let recipe = Recipe.testLook()
        let live = LiveLook.writes(for: recipe)
        let slot = SlotEncoder.writes(for: recipe)
        #expect(live.map(\.propID) == [
            0xD001, 0xD02E, 0xD007, 0xD023, 0xD029, 0xD030, 0xD189, 0x5005, 0xD017,
            0xD00B, 0xD00C, 0xD320, 0xD321, 0xD008, 0x5015, 0xD01C, 0xD032,
        ])
        #expect(live.map(\.bytes) == slot.map(\.bytes), "same payloads as the slot write")
        #expect(!live.contains { (0xD18C...0xD1A5).contains($0.propID) }, "no slot codes")
        #expect(live.first { $0.propID == 0xD02E }?.bytes == Data([0, 0]), "D-Range Priority forced Off")
        #expect(live.first { $0.propID == 0xD007 }?.bytes == PTPPack.u16(400))
    }

    @Test("A mono look adds toning after the film sim and drops colour-only codes")
    func monoLook() {
        var v = PresetValues(recipe: .testLook(filmSim: .acrosR, whiteBalance: .auto, kelvin: 0))
        v.monoWC = 3
        v.monoMG = -2
        let codes = LiveLook.writes(for: v).map(\.propID)
        #expect(Array(codes.prefix(3)) == [0xD001, 0xD104, 0xD031])
        #expect(LiveLook.writes(for: v).first { $0.propID == 0xD104 }?.bytes == PTPPack.i16(30))
        for colourOnly: UInt16 in [0xD008, 0xD00B, 0xD00C, 0xD029, 0xD030, 0xD017] {
            #expect(!codes.contains(colourOnly), "\(hex16(colourOnly)) skipped on mono")
        }
    }

    @Test("Restore under D-Range Priority leaves DR/tones alone, WB before Kelvin, grain 7 → 1")
    func restoreGates() {
        let snap: [UInt16: Data] = [
            0xD001: PTPPack.u16(11), 0xD02E: PTPPack.u16(0x8000), 0xD007: PTPPack.u16(0xFFFF), 0xD320: PTPPack.i16(10),
            0xD321: PTPPack.i16(0), 0x5005: PTPPack.u16(0x8007), 0xD017: PTPPack.u16(5200), 0xD023: PTPPack.u16(7),
            0xD029: PTPPack.u16(2), 0xD00B: PTPPack.i16(1), 0xD008: PTPPack.i16(0), 0x5015: PTPPack.i16(-10),
        ]
        let w = LiveLook.restoreWrites(from: snap)
        let codes = w.map(\.propID)
        #expect(codes.first == 0xD001)
        #expect(!codes.contains(0xD007) && !codes.contains(0xD320) && !codes.contains(0xD321), "camera-owned under DR-P")
        #expect(codes.contains(0xD02E))
        let wb = codes.firstIndex(of: 0x5005)!, kelvin = codes.firstIndex(of: 0xD017)!
        #expect(wb < kelvin, "Kelvin only accepted once WB is Kelvin")
        #expect(w.first { $0.propID == 0xD023 }?.bytes == Data([1, 0]))
        #expect(!codes.contains(0xD104), "colour sim: no mono toning")
    }

    @Test("Restore with D-Range Priority Off writes DR and tones before D02E")
    func restoreDROff() {
        let snap: [UInt16: Data] = [
            0xD001: PTPPack.u16(12), 0xD02E: PTPPack.u16(0), 0xD007: PTPPack.u16(200), 0xD320: PTPPack.i16(-5),
            0xD104: PTPPack.i16(20), 0x5005: PTPPack.u16(2), 0xD017: PTPPack.u16(6500), 0xD008: PTPPack.i16(10),
        ]
        let codes = LiveLook.restoreWrites(from: snap).map(\.propID)
        #expect(Array(codes.prefix(2)) == [0xD001, 0xD104], "mono toning right after an Acros sim")
        #expect(codes.firstIndex(of: 0xD007)! < codes.firstIndex(of: 0xD02E)!)
        #expect(!codes.contains(0xD017), "Kelvin not restored when WB isn't Kelvin")
        #expect(!codes.contains(0xD008), "colour skipped on a mono sim")
    }
}

@Suite("Live capabilities")
struct LiveCapabilitiesTests {
    @Test("A mode-6 style DeviceInfo can apply a look but can't capture or set exposure")
    func mode6Like() {
        var info = PTPDeviceInfo()
        info.properties = LiveProps.lookBlock.map(\.code) + [0xD16E, 0xD18C, 0xD18D]
        info.operations = [0x1001, 0x1002, 0x1003, 0x1014, 0x1015, 0x1016, 0x100C, 0x100D, 0x900C, 0x900D]
        let caps = LiveCapabilities(deviceInfo: info)
        #expect(caps.canApplyLookLive)
        #expect(caps.missingLook.isEmpty)
        #expect(!caps.canCapture && !caps.canLiveView && !caps.canSetExposure)
        #expect(caps.supported.contains(LiveProps.usbMode))
    }

    @Test("Missing Kelvin blocks live looks; listing InitiateCapture and 500F flips capture/exposure on")
    func gaps() {
        let props = Set(LiveCapabilities.coreLook.map(\.code)).subtracting([0xD017]).union([0x500F])
        let caps = LiveCapabilities(properties: props, operations: [0x100E, 0x101C])
        #expect(!caps.canApplyLookLive)
        #expect(caps.missingLook == [LiveProps.colorTemperature])
        #expect(caps.canCapture && caps.canLiveView && caps.canSetExposure)
    }
}
