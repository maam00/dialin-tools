// Live ("C0", current shooting state) camera-control properties for Fujifilm X-series bodies over USB PTP.
//
// Where the codes come from: interoperability study of how FUJIFILM's desktop tethering software talks to X-T5 and
// X-M5 bodies (property codes, PTP datatypes and value tables), cross-checked against libgphoto2 ptp.h names, libfuji,
// and the published X-H2 (fujifilm-ptp-recipes) and X-T5 (helios) bench results. The look subset and its slot pairs are
// in docs/FUJIFILM-PROTOCOL.md §2.9.
//
// Nothing in this file talks to a camera. It is a typed catalog plus pure encode/decode helpers and a planner that
// turns a Recipe into live writes (and a snapshot back into restore writes). The X100VI has no USB tether mode, so
// only props marked `.mode6` are expected to be reachable over USB on it; everything else is for Wi-Fi remote or
// other bodies until a GetDeviceInfo read proves otherwise.
import Foundation

// MARK: - Catalog types

/// PTP datatype codes (ISO 15740 §5.3).
public enum LivePTPType: UInt16, Sendable, Hashable {
    case int8 = 0x0001
    case uint8 = 0x0002
    case int16 = 0x0003
    case uint16 = 0x0004
    case int32 = 0x0005
    case uint32 = 0x0006
    case string = 0xFFFF

    /// Wire size in bytes; nil for strings (variable).
    public var byteCount: Int? {
        switch self {
        case .int8, .uint8: 1
        case .int16, .uint16: 2
        case .int32, .uint32: 4
        case .string: nil
        }
    }

    public var isSigned: Bool { self == .int8 || self == .int16 || self == .int32 }
}

public enum LiveAccess: String, Sendable, Hashable {
    /// Only ever read.
    case readOnly
    /// Written with SetDevicePropValue (the camera may still refuse in a given state or mode).
    case readWrite
}

/// What kind of setting it is.
public enum LiveGroup: String, Sendable, Hashable, CaseIterable {
    case look, exposure, focus, drive, capture, session, dials, slots
}

/// Whether we expect the X100VI to expose it over USB.
public enum LiveReach: String, Sendable, Hashable {
    /// Advertised (and, where writable, written) in USB RAW CONV./BACKUP RESTORE on an X-H2 and/or X-T5. The X100VI
    /// shares their capability row, so expect it there too. Still unverified on the X100VI itself.
    case mode6
    /// Only reached through the tether path (USB TETHER SHOOTING, which the X100VI doesn't have) or Wi-Fi remote.
    /// An X-T5 in mode 6 does not advertise these.
    case tether
    /// Not known either way; read GetDeviceInfo on the body to find out.
    case unknown
}

/// How sure we are of the code → meaning mapping.
public enum LiveEvidence: String, Sendable, Hashable {
    /// Interoperability study plus a hardware bench result (ILFforever X-H2 and/or helios X-T5 writes).
    case studiedAndBench
    /// Interoperability study (X-T5/X-M5); libgphoto2/libfuji agree or are silent; nobody has bench-tested it.
    case studied
    /// Our reading disagrees with another public reference; see the note.
    case conflict
    /// Our best guess; the meaning isn't established (unlabeled readout).
    case inferred
}

/// One live property.
public struct LiveProp: Sendable, Hashable, Identifiable, CustomStringConvertible {
    public let code: UInt16
    public let name: String
    public let type: LivePTPType
    public let access: LiveAccess
    public let group: LiveGroup
    public let reach: LiveReach
    public let evidence: LiveEvidence
    /// The C1–C7 slot-block code holding the same setting, if any.
    public let slotCode: UInt16?
    public let note: String

    public var id: UInt16 { code }
    public var description: String { "\(hex16(code)) \(name)" }

    public init(
        _ code: UInt16, _ name: String, _ type: LivePTPType, _ access: LiveAccess, _ group: LiveGroup,
        reach: LiveReach, evidence: LiveEvidence, slot: UInt16? = nil, note: String = ""
    ) {
        self.code = code
        self.name = name
        self.type = type
        self.access = access
        self.group = group
        self.reach = reach
        self.evidence = evidence
        self.slotCode = slot
        self.note = note
    }
}

// MARK: - The catalog

public enum LiveProps {
    // Look: the live mirror of the C1–C7 image-quality block (23 codes, all mode 6 on X-H2).
    public static let imageSize = LiveProp(0xD1A5, "image size (live)", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD18E, note: "Composite value. Never write as part of a look.")
    public static let imageQuality = LiveProp(0xD018, "image quality", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD18F, note: "1 RAW, 2 FINE, 3 NORMAL, 4 RAW+FINE, 5 RAW+NORMAL, 6 SUPERFINE, 7 RAW+SUPERFINE.")
    public static let dynamicRange = LiveProp(0xD007, "dynamic range", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD190, note: "100/200/400; 0xFFFF = Auto (and reads 0xFFFF while D-Range Priority owns it). Needs D02E = 0.")
    public static let dRangePriority = LiveProp(0xD02E, "D-Range Priority", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD191, note: "0 Off, 1 Weak, 2 Strong, 3 (third level), 0x8000 Auto.")
    public static let filmSimulation = LiveProp(0xD001, "film simulation", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD192)
    public static let monoWarmCool = LiveProp(0xD104, "mono warm/cool", .int16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD193, note: "Dial x10, -180...180. Mono sims only.")
    public static let monoMagentaGreen = LiveProp(0xD031, "mono magenta/green", .int16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD194, note: "Dial x10, -180...180. Mono sims only.")
    public static let grain = LiveProp(0xD023, "grain", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD195, note: "Write 1 for Off; reads back 6/7 (Off small/large). Writing back a 6/7 read is refused.")
    public static let colorChrome = LiveProp(0xD029, "color chrome", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD196, note: "1 Off, 2 Weak, 3 Strong.")
    public static let colorChromeFxBlue = LiveProp(0xD030, "color chrome FX blue", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD197)
    public static let smoothSkin = LiveProp(0xD189, "smooth skin", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD198)
    public static let whiteBalance = LiveProp(0x5005, "white balance", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD199, note: "PTP standard code. Write 5005, then D017 when the mode is Kelvin.")
    public static let wbShiftR = LiveProp(0xD00B, "WB shift red", .int16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD19A, note: "-9...9, 1:1.")
    public static let wbShiftB = LiveProp(0xD00C, "WB shift blue", .int16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD19B)
    public static let colorTemperature = LiveProp(0xD017, "color temperature", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD19C, note: "Kelvin. Only while 5005 = 0x8007.")
    public static let highlight = LiveProp(0xD320, "highlight tone", .int16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD19D, note: "Dial x10, -20...40 in 5s. Needs D02E = 0.")
    public static let shadow = LiveProp(0xD321, "shadow tone", .int16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD19E)
    public static let color = LiveProp(0xD008, "color", .int16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD19F, note: "Dial x10, -40...40. Colour sims only.")
    public static let sharpness = LiveProp(0x5015, "sharpness", .int16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD1A0, note: "PTP standard code. Dial x10.")
    public static let noiseReduction = LiveProp(0xD01C, "high ISO NR", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD1A1, note: "Non-linear table, same as the slot.")
    public static let clarity = LiveProp(0xD032, "clarity", .int16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD1A2, note: "Dial x10, -50...50. State-gated (drive/burst).")
    public static let lensModulationOptimiser = LiveProp(0xD34D, "lens modulation optimiser", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD1A3)
    public static let colorSpace = LiveProp(0xD00A, "color space", .uint16, .readWrite, .look, reach: .mode6, evidence: .studiedAndBench, slot: 0xD1A4, note: "1 sRGB, 2 AdobeRGB.")
    public static let filmSimulationTune = LiveProp(0xD002, "film simulation tune", .uint16, .readWrite, .look, reach: .unknown, evidence: .studied, note: "Per-sim tuning item selector; semantics not mapped.")

    // Exposure.
    public static let exposureProgram = LiveProp(0x500E, "exposure program", .uint16, .readWrite, .exposure, reach: .tether, evidence: .studied, note: "1 M, 3 A, 4 S, 6 P. On dial bodies it reflects the dials; D169/D16A are read with it.")
    public static let shutterSpeed = LiveProp(0x500D, "shutter speed", .uint32, .readWrite, .exposure, reach: .tether, evidence: .studied, note: "Microseconds on Fujifilm's power-of-two scale (1/250 = 3906). Bulb: 0xFFF0 on newer bodies; -1 in an alternate table.")
    public static let fNumber = LiveProp(0x5007, "aperture", .uint16, .readWrite, .exposure, reach: .tether, evidence: .studied, note: "f x 100 (f/2 = 200). Values below 0x5A are special states, not apertures.")
    public static let exposureBias = LiveProp(0x5010, "exposure compensation", .int16, .readWrite, .exposure, reach: .tether, evidence: .studied, note: "Milli-EV in thirds (333, 667, 1000...). Writes are kept within +/-3 EV.")
    public static let sensitivity = LiveProp(0x500F, "ISO", .int32, .readWrite, .exposure, reach: .tether, evidence: .conflict, note: "Our reading: plain ISO number, negative = auto preset (-1/-2/-3) or -10 auto. libgphoto2: 0x80000000 flag = auto. Read before trusting either.")
    public static let meteringMode = LiveProp(0x500B, "metering", .uint16, .readWrite, .exposure, reach: .tether, evidence: .studied, note: "1 average, 2 centre-weighted, 3 multi, 4 spot.")
    public static let programShift = LiveProp(0xD205, "program shift", .int16, .readWrite, .exposure, reach: .tether, evidence: .studied)
    public static let aeLock = LiveProp(0xD114, "AE lock", .uint16, .readWrite, .exposure, reach: .tether, evidence: .studied)
    public static let isoAuto1 = LiveProp(0xD115, "auto ISO setting 1", .uint16, .readWrite, .exposure, reach: .tether, evidence: .studied, note: "D115/D116/D117 are written together (default ISO, max ISO, min shutter + name). helios: absent on X-T5 mode 6.")
    public static let isoAuto2 = LiveProp(0xD116, "auto ISO setting 2", .uint16, .readWrite, .exposure, reach: .tether, evidence: .studied)
    public static let isoAuto3 = LiveProp(0xD117, "auto ISO setting 3", .uint32, .readWrite, .exposure, reach: .tether, evidence: .studied)
    public static let aeModeDetailA = LiveProp(0xD169, "AE mode detail A", .uint16, .readOnly, .exposure, reach: .unknown, evidence: .inferred, note: "Read alongside 500E; meaning not labelled.")
    public static let aeModeDetailB = LiveProp(0xD16A, "AE mode detail B", .uint16, .readOnly, .exposure, reach: .unknown, evidence: .inferred)

    // Physical dial readouts. Values are not decoded yet.
    public static let shutterDialStatus = LiveProp(0xD033, "shutter dial status", .uint16, .readOnly, .dials, reach: .unknown, evidence: .studied, note: "Shutter dial position.")
    public static let evDialStatus = LiveProp(0xD034, "exposure comp dial status", .uint16, .readOnly, .dials, reach: .unknown, evidence: .studied, note: "Exposure compensation dial position.")
    public static let isoDialStatus = LiveProp(0xD035, "ISO dial status", .uint16, .readOnly, .dials, reach: .unknown, evidence: .studied, note: "ISO dial position.")
    public static let apertureDialStatus = LiveProp(0xD036, "aperture ring status", .uint16, .readOnly, .dials, reach: .unknown, evidence: .studied, note: "Aperture ring position.")
    public static let dofScale = LiveProp(0xD028, "DOF scale", .uint16, .readWrite, .dials, reach: .tether, evidence: .conflict, note: "Our reading: DOF scale. libgphoto2 calls it CommandDialMode and the old Wi-Fi remote tools read it as F/SS authority. Don't use it as a dial-authority signal on X-Trans V.")

    // Focus.
    public static let focusMode = LiveProp(0x500A, "focus mode", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied, note: "1 MF, 0x8001 AF-S, 0x8002 AF-C. Physical switch on most bodies; X100VI sets it in the menu.")
    public static let afMode = LiveProp(0x501C, "AF mode", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied, note: "Angle 0 slot. 0x8001 single point, 0x8002 zone, 0x8003 wide/tracking, 0x8004 all, 0x0002 multi. D02A-D02D are the per-orientation copies.")
    public static let afModeAngle1 = LiveProp(0xD02A, "AF mode (orientation 1)", .uint16, .readWrite, .focus, reach: .tether, evidence: .conflict, note: "Our reading: AF mode for orientation index 1. libgphoto2/libfuji name D02A ExposureIndex (ISO). Treat as unknown until read.")
    public static let afModeAngle2 = LiveProp(0xD02B, "AF mode (orientation 2)", .uint16, .readWrite, .focus, reach: .tether, evidence: .conflict, note: "libgphoto2 names it MovieISO.")
    public static let focusArea = LiveProp(0xD395, "focus area", .string, .readWrite, .focus, reach: .tether, evidence: .studied, note: "Orientation 0. h/v/size packed into a string-typed value. Copies at D347, D372, D373, D374.")
    public static let faceDetection = LiveProp(0xD020, "face detection", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied, note: "1 On, 2 Off.")
    public static let eyeAF = LiveProp(0xD024, "eye AF", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied, note: "1 Off, 2 Auto, 3 right, 4 left.")
    public static let subjectDetection = LiveProp(0xD1BD, "subject detection", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied, note: "1 Off, 2 animal, 3 bird, 4 car, 5 bike, 6 airplane, 7 train, 0x8000 all.")
    public static let focusPoints = LiveProp(0xD025, "number of focus points", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied)
    public static let releasePriorityAFS = LiveProp(0xD10B, "release/focus priority AF-S", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied, note: "1 release, 2 focus. D10B applies to AF-S.")
    public static let releasePriorityAFC = LiveProp(0xD10A, "release/focus priority AF-C", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied)
    public static let preAF = LiveProp(0xD34B, "pre-AF", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied)
    public static let afIlluminator = LiveProp(0xD112, "AF illuminator", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied)
    public static let mfAssist = LiveProp(0xD026, "MF assist", .uint16, .readWrite, .focus, reach: .tether, evidence: .studied)
    public static let afStatus = LiveProp(0xD209, "AF status", .uint16, .readOnly, .focus, reach: .tether, evidence: .studied, note: "Polled after S1 (libgphoto2: 1 busy, 2 OK, 3 fail).")

    // Drive / shutter.
    public static let driveMode = LiveProp(0xD201, "drive mode", .uint16, .readWrite, .drive, reach: .tether, evidence: .conflict, note: "Three encodings in the wild; only S (4) is consistent. See LiveDrive.")
    public static let selfTimer = LiveProp(0x5012, "self-timer", .uint16, .readWrite, .drive, reach: .tether, evidence: .studied, note: "Milliseconds: 0 off, 2000, 10000.")
    public static let burstNumber = LiveProp(0x5018, "burst number", .uint16, .readWrite, .drive, reach: .tether, evidence: .studied)
    public static let imageStabilization = LiveProp(0xD351, "IS mode", .uint16, .readWrite, .drive, reach: .tether, evidence: .studied, note: "1 continuous, 2 shooting only, 3 off, 4 S1+shoot, 5/6 motion variants.")
    public static let silentMode = LiveProp(0xD355, "silent mode", .uint16, .readWrite, .drive, reach: .tether, evidence: .studied)
    public static let longExposureNR = LiveProp(0xD322, "long exposure NR", .uint16, .readWrite, .drive, reach: .tether, evidence: .studied)
    public static let flickerless = LiveProp(0xD234, "high-frequency flickerless", .uint16, .readWrite, .drive, reach: .tether, evidence: .studied)

    // Capture / media.
    public static let release = LiveProp(0xD208, "release (S1/S2)", .uint16, .readWrite, .capture, reach: .tether, evidence: .studied, note: "Write a LiveRelease code, then InitiateCapture 0x100E (0,0).")
    public static let mediaRecord = LiveProp(0xD20C, "media record", .uint16, .readWrite, .capture, reach: .tether, evidence: .studied, note: "1 RAW+JPEG, 2 RAW, 3 JPEG, 4 off (unverified).")
    public static let imageFormat = LiveProp(0xD1B2, "image format (JPEG/HEIF)", .uint16, .readWrite, .capture, reach: .tether, evidence: .studied)
    public static let digitalTeleconverter = LiveProp(0xD1B3, "crop zoom", .uint32, .readWrite, .capture, reach: .tether, evidence: .studied, note: "Crop zoom (digital teleconverter on fixed-lens bodies, unverified).")
    public static let liveViewImageQuality = LiveProp(0xD173, "live view quality", .uint16, .readWrite, .capture, reach: .tether, evidence: .studied, note: "1 fine, 2 normal, 3 basic.")
    public static let liveViewImageSize = LiveProp(0xD174, "live view size", .uint16, .readWrite, .capture, reach: .tether, evidence: .studied, note: "1 L(1280), 2 M(800), 3 S(640).")

    // Session.
    public static let usbMode = LiveProp(0xD16E, "PC connection mode", .uint16, .readOnly, .session, reach: .mode6, evidence: .studied, note: "Read right after OpenSession. Read as a bitmask: 1 tether, 2 RAW conversion, 4 backup/restore, 8 webcam, so 5 tether, 6 RAW CONV./BACKUP RESTORE, 8 webcam. The X100VI has no tether mode.")
    public static let priorityMode = LiveProp(0xD207, "priority mode", .uint16, .readWrite, .session, reach: .tether, evidence: .studied, note: "1 camera, 2 PC. Switch to PC before remote changes and back after.")
    public static let forceMode = LiveProp(0xD230, "force shoot/playback", .uint16, .readWrite, .session, reach: .tether, evidence: .studied, note: "1 shooting, 2 playback. Retry a refused call after forcing shooting mode.")
    public static let shootingMode = LiveProp(0xD037, "shooting mode (C0-C7)", .uint16, .readWrite, .session, reach: .unknown, evidence: .studied, note: "0x0001 C0 ... 0x0008 C7, 0x00F0 Auto. Mode-dial bodies; unknown on X100VI.")
    public static let changedProps = LiveProp(0xD212, "changed-properties list", .string, .readOnly, .session, reach: .unknown, evidence: .studied, note: "u16 count + (u16 code, u32 value) records. Polled; 0x200A over USB on X100VI 1.32 per fuji-bridge.")
    public static let cameraPropList = LiveProp(0xD235, "camera property list", .string, .readOnly, .session, reach: .tether, evidence: .studied, note: "Bulk dump (up to 1 MB) of current values.")
    public static let customSettingAutoUpdate = LiveProp(0xD307, "auto update custom setting", .uint16, .readWrite, .session, reach: .unknown, evidence: .studied, note: "The menu item that decides whether menu edits commit to the active C-slot.")

    // Slots (beyond the D18C...D1A4 block that FujiCodes.swift already covers).
    public static let customSelect = LiveProp(0xD34C, "custom setting select", .uint16, .readWrite, .slots, reach: .unknown, evidence: .inferred, note: "Custom-setting operation 1. libgphoto2 name CustomSetting. Likely recalls C1-C7 into the live state.")
    public static let customSave = LiveProp(0xD260, "custom setting save", .uint16, .readWrite, .slots, reach: .unknown, evidence: .inferred, note: "Custom-setting operation 2 (destination slot). Likely 'save current settings'.")
    public static let customReset = LiveProp(0xD261, "custom setting reset", .uint16, .readWrite, .slots, reach: .unknown, evidence: .inferred, note: "Custom-setting operation 3 (destination slot).")
    public static let customCopy = LiveProp(0xD262, "custom setting copy", .uint16, .readWrite, .slots, reach: .unknown, evidence: .inferred, note: "Custom-setting operation 4: value = source << 8 | destination.")

    /// Every catalogued prop, grouped roughly as above.
    public static let all: [LiveProp] = [
        imageSize, imageQuality, dynamicRange, dRangePriority, filmSimulation, monoWarmCool, monoMagentaGreen, grain,
        colorChrome, colorChromeFxBlue, smoothSkin, whiteBalance, wbShiftR, wbShiftB, colorTemperature, highlight,
        shadow, color, sharpness, noiseReduction, clarity, lensModulationOptimiser, colorSpace, filmSimulationTune,
        exposureProgram, shutterSpeed, fNumber, exposureBias, sensitivity, meteringMode, programShift, aeLock,
        isoAuto1, isoAuto2, isoAuto3, aeModeDetailA, aeModeDetailB,
        shutterDialStatus, evDialStatus, isoDialStatus, apertureDialStatus, dofScale,
        focusMode, afMode, afModeAngle1, afModeAngle2, focusArea, faceDetection, eyeAF, subjectDetection, focusPoints,
        releasePriorityAFS, releasePriorityAFC, preAF, afIlluminator, mfAssist, afStatus,
        driveMode, selfTimer, burstNumber, imageStabilization, silentMode, longExposureNR, flickerless,
        release, mediaRecord, imageFormat, digitalTeleconverter, liveViewImageQuality, liveViewImageSize,
        usbMode, priorityMode, forceMode, shootingMode, changedProps, cameraPropList, customSettingAutoUpdate,
        customSelect, customSave, customReset, customCopy,
    ]

    private static let index: [UInt16: LiveProp] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    public static func prop(_ code: UInt16) -> LiveProp? { index[code] }

    /// The 23 live image-quality codes (the C0 mirror of D18E...D1A4).
    public static var lookBlock: [LiveProp] { all.filter { $0.group == .look && $0.slotCode != nil } }

    /// Slot-block code → live code (D192 → D001, D199 → 5005, ...).
    public static let liveCodeForSlotCode: [UInt16: UInt16] = Dictionary(
        uniqueKeysWithValues: all.compactMap { p in p.slotCode.map { ($0, p.code) } }
    )

    /// Human label for logs.
    public static func label(_ code: UInt16) -> String { index[code]?.name ?? hex16(code) }

    /// Codes for the read-only probe, safest first: identity and mode, the look mirror, then everything else.
    public static let probeReadOrder: [UInt16] = {
        let first: [UInt16] = [usbMode.code, 0xD186, 0xD187, 0xD36A, 0xD36B]
        let rest = all.map(\.code).filter { !first.contains($0) && $0 != release.code }
        return first + rest
    }()
}

// MARK: - Capability check from GetDeviceInfo

/// What a camera says it supports, judged against the catalog. Pure: feed it a parsed GetDeviceInfo.
public struct LiveCapabilities: Sendable, Equatable {
    public let advertised: Set<UInt16>
    public let operations: Set<UInt16>

    public init(deviceInfo: PTPDeviceInfo) {
        advertised = Set(deviceInfo.properties)
        operations = Set(deviceInfo.operations)
    }

    public init(properties: Set<UInt16>, operations: Set<UInt16>) {
        self.advertised = properties
        self.operations = operations
    }

    public func has(_ p: LiveProp) -> Bool { advertised.contains(p.code) }

    /// Catalogued props the camera lists.
    public var supported: [LiveProp] { LiveProps.all.filter(has) }

    /// The core look codes Dial In would write live (no image size/quality, LMO, colour space).
    public static let coreLook: [LiveProp] = [
        LiveProps.filmSimulation, LiveProps.dRangePriority, LiveProps.dynamicRange, LiveProps.grain,
        LiveProps.colorChrome, LiveProps.colorChromeFxBlue, LiveProps.whiteBalance, LiveProps.colorTemperature,
        LiveProps.wbShiftR, LiveProps.wbShiftB, LiveProps.highlight, LiveProps.shadow, LiveProps.color,
        LiveProps.sharpness, LiveProps.noiseReduction,
    ]

    /// True when every core look code is advertised: a look can be applied without touching C1–C7.
    public var canApplyLookLive: Bool { Self.coreLook.allSatisfy(has) }

    /// Core look codes the camera doesn't list.
    public var missingLook: [LiveProp] { Self.coreLook.filter { !has($0) } }

    /// A body counts as a shooting (tether) camera only when it lists InitiateCapture.
    public var canCapture: Bool { operations.contains(0x100E) }
    /// InitiateOpenCapture (live view).
    public var canLiveView: Bool { operations.contains(0x101C) }
    /// Any exposure control advertised (ISO, shutter, aperture, EV).
    public var canSetExposure: Bool {
        [LiveProps.sensitivity, LiveProps.shutterSpeed, LiveProps.fNumber, LiveProps.exposureBias].contains(where: has)
    }
}

// MARK: - Codec

public enum LiveCodecError: Error, Equatable, CustomStringConvertible, Sendable {
    case outOfRange(String)
    case notOnStep(String)
    case badSize(expected: Int, got: Int)
    case notNumeric

    public var description: String {
        switch self {
        case .outOfRange(let s): "out of range: \(s)"
        case .notOnStep(let s): "not a valid step: \(s)"
        case .badSize(let e, let g): "expected \(e) bytes, got \(g)"
        case .notNumeric: "string property has no numeric value"
        }
    }
}

/// Little-endian encode/decode for a property's PTP datatype.
public enum LiveCodec {
    public static func encode(_ value: Int, as type: LivePTPType) throws -> Data {
        let range: ClosedRange<Int>
        switch type {
        case .int8: range = Int(Int8.min)...Int(Int8.max)
        case .uint8: range = 0...Int(UInt8.max)
        case .int16: range = Int(Int16.min)...Int(Int16.max)
        case .uint16: range = 0...Int(UInt16.max)
        case .int32: range = Int(Int32.min)...Int(Int32.max)
        case .uint32: range = 0...Int(UInt32.max)
        case .string: throw LiveCodecError.notNumeric
        }
        guard range.contains(value) else { throw LiveCodecError.outOfRange("\(value) for \(type)") }
        switch type.byteCount {
        case 1: return Data([UInt8(truncatingIfNeeded: value)])
        case 2: return PTPPack.u16(value)
        default: return PTPPack.u32(UInt32(truncatingIfNeeded: value))
        }
    }

    public static func encode(_ value: Int, for prop: LiveProp) throws -> Data { try encode(value, as: prop.type) }

    /// Exact-size decode honouring sign. Strings throw `.notNumeric`.
    public static func decode(_ data: Data, as type: LivePTPType) throws -> Int {
        guard let n = type.byteCount else { throw LiveCodecError.notNumeric }
        guard data.count == n else { throw LiveCodecError.badSize(expected: n, got: data.count) }
        let b = [UInt8](data)
        switch type {
        case .int8: return Int(Int8(bitPattern: b[0]))
        case .uint8: return Int(b[0])
        case .int16: return Int(Int16(bitPattern: LE.u16(b, 0)))
        case .uint16: return Int(LE.u16(b, 0))
        case .int32: return Int(Int32(bitPattern: LE.u32(b, 0)))
        case .uint32: return Int(LE.u32(b, 0))
        case .string: throw LiveCodecError.notNumeric
        }
    }

    public static func decode(_ data: Data, for prop: LiveProp) throws -> Int { try decode(data, as: prop.type) }

    /// Human rendering of a read value for logs and the probe ("Classic Chrome (11)", "+0.7 EV", "1/250 s").
    public static func describe(_ data: Data, for prop: LiveProp) -> String {
        if prop.type == .string { return parsePTPString(data).isEmpty ? "0x" + data.hexString : "\"\(parsePTPString(data))\"" }
        guard let v = try? decode(data, for: prop) else { return "0x" + data.hexString }
        func named(_ label: String?) -> String { label.map { "\($0) (\(v))" } ?? "\(v)" }
        switch prop.code {
        case LiveProps.filmSimulation.code: return named(LiveFilmSim(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.whiteBalance.code: return named(LiveWB(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.dynamicRange.code: return named(LiveDR(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.dRangePriority.code: return named(LiveDRangePriority(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.grain.code: return named(LiveGrain(wire: v)?.label)
        case LiveProps.colorChrome.code, LiveProps.colorChromeFxBlue.code, LiveProps.smoothSkin.code:
            return named(LiveEffect(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.noiseReduction.code: return named(LiveTone.decodeNR(v).map { String(format: "%+d", $0) })
        case LiveProps.highlight.code, LiveProps.shadow.code, LiveProps.color.code, LiveProps.sharpness.code,
             LiveProps.clarity.code, LiveProps.monoWarmCool.code, LiveProps.monoMagentaGreen.code:
            return named(LiveTone.dialString(v))
        case LiveProps.exposureBias.code: return named(LiveExposure.evString(milliEV: v))
        case LiveProps.shutterSpeed.code: return named(LiveExposure.shutterString(microseconds: v))
        case LiveProps.fNumber.code: return named(LiveExposure.apertureString(v))
        case LiveProps.sensitivity.code: return named(LiveISO(wire: v).label)
        case LiveProps.focusMode.code: return named(LiveFocusMode(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.afMode.code: return named(LiveAFMode(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.faceDetection.code: return named(LiveFaceDetection(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.eyeAF.code: return named(LiveEyeAF(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.imageStabilization.code: return named(LiveISMode(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.exposureProgram.code: return named(LiveAEMode(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.meteringMode.code: return named(LiveMetering(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.driveMode.code: return named(LiveDrive(wire: v).label)
        case LiveProps.priorityMode.code: return named(LivePriority(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.forceMode.code: return named(LiveForceMode(rawValue: UInt16(truncatingIfNeeded: v))?.label)
        case LiveProps.usbMode.code: return named([5: "tether", 6: "RAW CONV./BACKUP RESTORE", 8: "webcam"][v] ?? LiveUSBMode.label(v))
        default: return "\(v)"
        }
    }
}

// MARK: - Value enums (raw value = wire value)

/// Two-byte enums whose raw value is exactly what goes on the wire.
public protocol LiveEnum: RawRepresentable, CaseIterable, Sendable, Hashable where RawValue == UInt16 {
    var label: String { get }
}

extension LiveEnum {
    public var bytes: Data { PTPPack.u16(Int(rawValue)) }
    public init?(bytes: Data) {
        guard bytes.count == 2 else { return nil }
        let b = [UInt8](bytes)
        self.init(rawValue: LE.u16(b, 0))
    }
}

/// D001. Same numbering as the slot (D192). X100VI supports 1...20.
public enum LiveFilmSim: UInt16, LiveEnum {
    case provia = 0x01, velvia, astia, proNegHi, proNegStd, monochrome, monochromeYe, monochromeR, monochromeG, sepia
    case classicChrome, acros, acrosYe, acrosR, acrosG, eterna, classicNeg, eternaBleachBypass, nostalgicNeg, realaAce
    /// Auto film simulation; not offered on the X100VI as far as we know.
    case auto = 0x8000

    public var isMonochrome: Bool {
        switch self {
        case .monochrome, .monochromeYe, .monochromeR, .monochromeG, .sepia, .acros, .acrosYe, .acrosR, .acrosG: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .provia: "Provia"
        case .velvia: "Velvia"
        case .astia: "Astia"
        case .proNegHi: "Pro Neg Hi"
        case .proNegStd: "Pro Neg Std"
        case .monochrome: "Monochrome"
        case .monochromeYe: "Monochrome+Ye"
        case .monochromeR: "Monochrome+R"
        case .monochromeG: "Monochrome+G"
        case .sepia: "Sepia"
        case .classicChrome: "Classic Chrome"
        case .acros: "Acros"
        case .acrosYe: "Acros+Ye"
        case .acrosR: "Acros+R"
        case .acrosG: "Acros+G"
        case .eterna: "Eterna"
        case .classicNeg: "Classic Neg"
        case .eternaBleachBypass: "Eterna Bleach Bypass"
        case .nostalgicNeg: "Nostalgic Neg"
        case .realaAce: "Reala Ace"
        case .auto: "Auto"
        }
    }
}

/// 5005 (and slot D199).
public enum LiveWB: UInt16, LiveEnum {
    case auto = 0x0002
    case autoWhitePriority = 0x8020
    case autoAmbiencePriority = 0x8021
    case daylight = 0x0004
    case incandescent = 0x0006
    case underwater = 0x0008
    case fluorescent1 = 0x8001
    case fluorescent2 = 0x8002
    case fluorescent3 = 0x8003
    case shade = 0x8006
    case kelvin = 0x8007
    case custom1 = 0x8008
    case custom2 = 0x8009
    case custom3 = 0x800A
    case custom4 = 0x800B
    case custom5 = 0x800C

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .autoWhitePriority: "Auto (white priority)"
        case .autoAmbiencePriority: "Auto (ambience priority)"
        case .daylight: "Daylight"
        case .incandescent: "Incandescent"
        case .underwater: "Underwater"
        case .fluorescent1: "Fluorescent 1"
        case .fluorescent2: "Fluorescent 2"
        case .fluorescent3: "Fluorescent 3"
        case .shade: "Shade"
        case .kelvin: "Kelvin"
        case .custom1: "Custom 1"
        case .custom2: "Custom 2"
        case .custom3: "Custom 3"
        case .custom4: "Custom 4"
        case .custom5: "Custom 5"
        }
    }
}

/// D007 live DR. Auto is 0xFFFF here (the slot table says 0; don't assume they match).
public enum LiveDR: UInt16, LiveEnum {
    case auto = 0xFFFF
    case dr100 = 100
    case dr200 = 200
    case dr400 = 400
    case dr800 = 800

    public var label: String {
        switch self {
        case .auto: "DR Auto"
        case .dr100: "DR100"
        case .dr200: "DR200"
        case .dr400: "DR400"
        case .dr800: "DR800"
        }
    }

    /// The ISO floor the camera enforces on a base-125 X-Trans V body (DR200 ≥ 250, DR400 ≥ 500).
    public var minimumISO: Int? {
        switch self {
        case .dr200: 250
        case .dr400: 500
        case .dr800: 1000
        default: nil
        }
    }
}

/// D02E D-Range Priority.
public enum LiveDRangePriority: UInt16, LiveEnum {
    case off = 0
    case weak = 1
    case strong = 2
    case level3 = 3
    case auto = 0x8000

    public var label: String {
        switch self {
        case .off: "Off"
        case .weak: "Weak"
        case .strong: "Strong"
        case .level3: "Level 3"
        case .auto: "Auto"
        }
    }
}

/// Color Chrome, CC FX Blue, Smooth Skin.
public enum LiveEffect: UInt16, LiveEnum {
    case off = 1, weak = 2, strong = 3

    public var label: String {
        switch self {
        case .off: "Off"
        case .weak: "Weak"
        case .strong: "Strong"
        }
    }
}

/// D023 grain. Write `.off` as 1; the camera keeps the last size and reads back 6 (Off, small) or 7 (Off, large).
/// Never write 6 or 7.
public enum LiveGrain: Sendable, Hashable {
    case off(large: Bool?)
    case weakSmall, strongSmall, weakLarge, strongLarge

    public init?(wire: Int) {
        switch wire {
        case 1: self = .off(large: nil)
        case 2: self = .weakSmall
        case 3: self = .strongSmall
        case 4: self = .weakLarge
        case 5: self = .strongLarge
        case 6: self = .off(large: false)
        case 7: self = .off(large: true)
        default: return nil
        }
    }

    /// What to send. Off is always 1.
    public var wire: Int {
        switch self {
        case .off: 1
        case .weakSmall: 2
        case .strongSmall: 3
        case .weakLarge: 4
        case .strongLarge: 5
        }
    }

    public var bytes: Data { PTPPack.u16(wire) }
    public var isOff: Bool { if case .off = self { true } else { false } }

    public var label: String {
        switch self {
        case .off(let large):
            switch large {
            case nil: "Off"
            case true?: "Off (large)"
            case false?: "Off (small)"
            }
        case .weakSmall: "Weak, small"
        case .strongSmall: "Strong, small"
        case .weakLarge: "Weak, large"
        case .strongLarge: "Strong, large"
        }
    }
}

/// Tone-style dials sent as dial x 10 (INT16), with each setting's legal range and step.
public enum LiveTone {
    public struct Spec: Sendable, Hashable {
        public let min: Double
        public let max: Double
        public let step: Double
    }

    public static let highlight = Spec(min: -2, max: 4, step: 0.5)
    public static let shadow = Spec(min: -2, max: 4, step: 0.5)
    public static let color = Spec(min: -4, max: 4, step: 1)
    public static let sharpness = Spec(min: -4, max: 4, step: 1)
    public static let clarity = Spec(min: -5, max: 5, step: 1)
    public static let mono = Spec(min: -18, max: 18, step: 1)

    /// Dial position → wire (x10, INT16).
    public static func encode(_ dial: Double, _ spec: Spec) throws -> Data {
        guard dial >= spec.min, dial <= spec.max else { throw LiveCodecError.outOfRange("\(dial) not in \(spec.min)...\(spec.max)") }
        let steps = (dial - spec.min) / spec.step
        guard abs(steps - steps.rounded()) < 1e-9 else { throw LiveCodecError.notOnStep("\(dial) step \(spec.step)") }
        return PTPPack.i16(Int((dial * 10).rounded()))
    }

    public static func decode(_ data: Data) -> Double? {
        guard let v = try? LiveCodec.decode(data, as: .int16) else { return nil }
        return Double(v) / 10
    }

    static func dialString(_ wire: Int) -> String {
        let d = Double(wire) / 10
        return d == d.rounded() ? String(format: "%+d", Int(d)) : String(format: "%+.1f", d)
    }

    /// High ISO NR: Fujifilm's non-linear table (same as the slot).
    public static let nrEncode: [Int: Int] = [
        -4: 0x8000, -3: 0x7000, -2: 0x4000, -1: 0x3000, 0: 0x2000, 1: 0x1000, 2: 0x0000, 3: 0x6000, 4: 0x5000,
    ]

    public static func encodeNR(_ level: Int) throws -> Data {
        guard let v = nrEncode[level] else { throw LiveCodecError.outOfRange("NR \(level) not in -4...4") }
        return PTPPack.u16(v)
    }

    public static func decodeNR(_ wire: Int) -> Int? { nrEncode.first { $0.value == wire }?.key }
}

/// 500A.
public enum LiveFocusMode: UInt16, LiveEnum {
    case manual = 0x0001, afs = 0x8001, afc = 0x8002

    public var label: String {
        switch self {
        case .manual: "MF"
        case .afs: "AF-S"
        case .afc: "AF-C"
        }
    }
}

/// 501C (and D02A...D02D per orientation).
public enum LiveAFMode: UInt16, LiveEnum {
    case multi = 0x0002, singlePoint = 0x8001, zone = 0x8002, wideTracking = 0x8003, all = 0x8004
    public var label: String {
        switch self {
        case .multi: "Multi"
        case .singlePoint: "Single point"
        case .zone: "Zone"
        case .wideTracking: "Wide/Tracking"
        case .all: "All"
        }
    }
}

/// D020.
public enum LiveFaceDetection: UInt16, LiveEnum {
    case on = 1, off = 2
    public var label: String { self == .on ? "Face detection on" : "Face detection off" }
}

/// D024.
public enum LiveEyeAF: UInt16, LiveEnum {
    case off = 1, auto = 2, rightPriority = 3, leftPriority = 4
    public var label: String {
        switch self {
        case .off: "Eye AF off"
        case .auto: "Eye auto"
        case .rightPriority: "Right eye"
        case .leftPriority: "Left eye"
        }
    }
}

/// D351.
public enum LiveISMode: UInt16, LiveEnum {
    case continuous = 1, shootOnly = 2, off = 3, halfPressAndShoot = 4, continuousMotion = 5, shootMotion = 6
    public var label: String {
        switch self {
        case .continuous: "IS continuous"
        case .shootOnly: "IS shooting only"
        case .off: "IS off"
        case .halfPressAndShoot: "IS half-press + shoot"
        case .continuousMotion: "IS continuous + motion"
        case .shootMotion: "IS shooting + motion"
        }
    }
}

/// 500E.
public enum LiveAEMode: UInt16, LiveEnum {
    case manual = 1, aperturePriority = 3, shutterPriority = 4, program = 6
    public var label: String {
        switch self {
        case .manual: "M"
        case .aperturePriority: "A"
        case .shutterPriority: "S"
        case .program: "P"
        }
    }
}

/// 500B (PTP standard numbering).
public enum LiveMetering: UInt16, LiveEnum {
    case average = 1, centerWeighted = 2, multi = 3, spot = 4
    public var label: String {
        switch self {
        case .average: "Average"
        case .centerWeighted: "Centre-weighted"
        case .multi: "Multi"
        case .spot: "Spot"
        }
    }
}

/// D207.
public enum LivePriority: UInt16, LiveEnum {
    case camera = 1, pc = 2
    public var label: String { self == .camera ? "Camera priority" : "PC priority" }
}

/// D230.
public enum LiveForceMode: UInt16, LiveEnum {
    case shoot = 1, playback = 2
    public var label: String { self == .shoot ? "Shooting" : "Playback" }
}

/// D201 drive mode. Three tables are in circulation: a per-model table (X-T3 ... X-M5, GFX100 II: S 0x0004, CL 0x1000,
/// CH 0x10F0, BKT 0x4000, movie 0x0008), a generic table (CH 2, CL 3, S 4, then 5...0x12 for other modes) and
/// libgphoto2's (older bodies: S 1, CL 2, CH 3, timer 4). Only S = 4 and movie = 8 agree between the first two, so this
/// type keeps the raw value and names it cautiously. Read D201 on the body before writing anything but S.
public struct LiveDrive: Sendable, Hashable {
    public let wire: Int
    public init(wire: Int) { self.wire = wire }

    public static let single = LiveDrive(wire: 0x0004)
    public static let movie = LiveDrive(wire: 0x0008)

    /// Agreed by the per-model and generic tables.
    public var isConfident: Bool { wire == 0x0004 || wire == 0x0008 }

    public var label: String {
        switch wire {
        case 0x0004: "S"
        case 0x0008: "Movie"
        case 0x1000: "CL (per-model table)"
        case 0x10F0: "CH (per-model table)"
        case 0x4000: "BKT (per-model table)"
        case 0x0002: "CH? (generic table) / CL? (libgphoto2)"
        case 0x0003: "CL? (generic table) / CH? (libgphoto2)"
        case 0x0005: "multiple exposure (generic table)"
        case 0x0006: "advanced filter (generic table)"
        case 0x0007: "panorama (generic table)"
        case 0x0009: "HDR (generic table)"
        case 0x000A: "AE bracket (generic table)"
        case 0x000B: "ISO bracket (generic table)"
        case 0x000C: "film sim bracket (generic table)"
        case 0x000D: "WB bracket (generic table)"
        case 0x000E: "DR bracket (generic table)"
        case 0x000F: "focus bracket (generic table)"
        default: String(format: "unknown 0x%04X", wire)
        }
    }

    public var bytes: Data { PTPPack.u16(wire) }
}

/// 500F ISO (INT32). Our reading: the ISO number as is; negatives select auto presets. Older references flag
/// auto with bit 31 instead, so decoding accepts both and encoding uses the plain form.
public enum LiveISO: Sendable, Hashable {
    case iso(Int)
    /// Auto preset 1...4 (-1...-4 on the wire).
    case autoPreset(Int)
    /// Generic auto (-10).
    case auto
    /// Bit-31 form (libgphoto2): auto with this ceiling.
    case autoCeiling(Int)
    case unknown(Int)

    public init(wire: Int) {
        let v32 = Int32(truncatingIfNeeded: wire)
        let u32 = UInt32(bitPattern: v32)
        if v32 > 0 && u32 & 0xC000_0000 == 0 {
            self = .iso(Int(v32))
        } else if (-4)...(-1) ~= Int(v32) {
            self = .autoPreset(-Int(v32))
        } else if v32 == -10 {
            self = .auto
        } else if u32 & 0x8000_0000 != 0 && u32 & 0x00FF_FFFF != 0 && v32 < -10_000 {
            self = .autoCeiling(Int(u32 & 0x00FF_FFFF))
        } else {
            self = .unknown(Int(v32))
        }
    }

    public var wire: Int? {
        switch self {
        case .iso(let v): v
        case .autoPreset(let n): (1...4).contains(n) ? -n : nil
        case .auto: -10
        case .autoCeiling, .unknown: nil
        }
    }

    public var bytes: Data? { wire.map { PTPPack.u32(UInt32(bitPattern: Int32($0))) } }

    public var label: String {
        switch self {
        case .iso(let v): "ISO \(v)"
        case .autoPreset(let n): "Auto ISO \(n)"
        case .auto: "Auto ISO"
        case .autoCeiling(let c): "Auto ISO (max \(c))"
        case .unknown(let v): "ISO? \(v)"
        }
    }
}

/// Exposure encodings: shutter (500D, µs), aperture (5007, f x 100), compensation (5010, milli-EV).
public enum LiveExposure {
    /// Fujifilm's shutter table for whole and third stops from 1/8000 s to 30 s.
    public static let shutterMicroseconds: [(label: String, us: Int)] = [
        ("1/8000", 122), ("1/6400", 153), ("1/5000", 193), ("1/4000", 244), ("1/3200", 307), ("1/2500", 387),
        ("1/2000", 488), ("1/1600", 615), ("1/1250", 775), ("1/1000", 976), ("1/800", 1230), ("1/640", 1550),
        ("1/500", 1953), ("1/400", 2460), ("1/320", 3100), ("1/250", 3906), ("1/200", 4921), ("1/160", 6200),
        ("1/125", 7812), ("1/100", 9843), ("1/80", 12401), ("1/60", 15625), ("1/50", 19686), ("1/40", 24803),
        ("1/30", 31250), ("1/25", 39372), ("1/20", 49606), ("1/15", 62500), ("1/13", 78745), ("1/10", 99212),
        ("1/8", 125000), ("1/6", 157490), ("1/5", 198425), ("1/4", 250000), ("1/3", 314980), ("1/2.5", 396850),
        ("1/2", 500000), ("1/1.6", 629960), ("1/1.3", 793700), ("1", 1_000_000), ("1.3", 1_259_921), ("1.6", 1_587_401),
        ("2", 2_000_000), ("2.5", 2_519_842), ("3", 3_174_802), ("4", 4_000_000), ("5", 5_039_684), ("6", 6_349_604),
        ("8", 8_000_000), ("10", 10_079_368), ("13", 12_699_208), ("15", 16_000_000), ("20", 20_158_736),
        ("25", 25_398_416), ("30", 32_000_000),
    ]

    /// Wire value for a shutter label from the table ("1/250" → 3906).
    public static func shutter(_ label: String) -> Int? { shutterMicroseconds.first { $0.label == label }?.us }

    static func shutterString(microseconds v: Int) -> String {
        if let hit = shutterMicroseconds.first(where: { $0.us == v }) { return hit.label + " s" }
        return v > 0 ? String(format: "%.5f s", Double(v) / 1_000_000) : "special"
    }

    /// f-number → 5007 wire (f/2 → 200).
    public static func aperture(_ f: Double) throws -> Data {
        let v = Int((f * 100).rounded())
        guard v >= 0x5A, v <= 0xFFFF else { throw LiveCodecError.outOfRange("f/\(f)") }
        return PTPPack.u16(v)
    }

    static func apertureString(_ v: Int) -> String {
        v >= 0x5A ? String(format: "f/%.1f", Double(v) / 100) : "special"
    }

    /// Thirds of a stop → 5010 wire (milli-EV, x * 333.333 rounded away from zero). The X100VI's C position
    /// reaches ±5 EV; desktop tethering only sends ±3.
    public static func exposureBias(thirds: Int) throws -> Data {
        guard (-15...15).contains(thirds) else { throw LiveCodecError.outOfRange("\(thirds) thirds") }
        let milli = Int((Double(thirds) * 1000 / 3).rounded(.toNearestOrAwayFromZero))
        return PTPPack.i16(milli)
    }

    /// 5010 wire → thirds, nil if not on a third.
    public static func thirds(milliEV v: Int) -> Int? {
        let t = (Double(v) * 3 / 1000).rounded()
        return abs(Double(v) - t * 1000 / 3) < 1 ? Int(t) : nil
    }

    static func evString(milliEV v: Int) -> String {
        guard let t = thirds(milliEV: v) else { return "\(v) mEV" }
        return t == 0 ? "0 EV" : String(format: "%+.1f EV", Double(t) / 3)
    }
}

/// D208 release codes: high byte = what to press, low byte = what to let go afterwards.
public enum LiveRelease {
    public static let shoot: UInt16 = 0x0100
    public static let halfPress: UInt16 = 0x0200
    public static let fullPress: UInt16 = 0x0300
    /// Full press then release S1 (what libgphoto2 sends to shoot).
    public static let fullPressReleaseHalf: UInt16 = 0x0304
    public static let oneShotAF: UInt16 = 0x0600
    /// Cancel a half-press.
    public static let releaseHalf: UInt16 = 0x0004
    public static let cancel: UInt16 = 0x000F
}

// MARK: - Apply a look live (and undo it)

/// Turns a Recipe into writes to the live (C0) codes, reusing the slot encoder's byte-for-byte encoding, and turns a
/// snapshot of the live state back into restore writes. No camera I/O here.
public enum LiveLook {
    /// Live codes a look touches, in the order to snapshot them before applying.
    public static let snapshotCodes: [UInt16] = [
        LiveProps.filmSimulation.code, LiveProps.dRangePriority.code, LiveProps.dynamicRange.code, LiveProps.grain.code,
        LiveProps.colorChrome.code, LiveProps.colorChromeFxBlue.code, LiveProps.smoothSkin.code,
        LiveProps.whiteBalance.code, LiveProps.colorTemperature.code, LiveProps.wbShiftR.code, LiveProps.wbShiftB.code,
        LiveProps.highlight.code, LiveProps.shadow.code, LiveProps.color.code, LiveProps.sharpness.code,
        LiveProps.noiseReduction.code, LiveProps.clarity.code, LiveProps.monoWarmCool.code, LiveProps.monoMagentaGreen.code,
    ]

    /// Live writes for a recipe, in camera order: film sim, mono toning (mono sims), D-Range Priority Off, DR,
    /// effects, WB then Kelvin, shifts, tones, NR, clarity. Same bytes as the slot write, different codes.
    public static func writes(for recipe: Recipe) -> [PropWrite] { writes(for: PresetValues(recipe: recipe)) }

    public static func writes(for values: PresetValues) -> [PropWrite] {
        var out: [PropWrite] = []
        for w in SlotEncoder.writes(for: values) {
            guard let live = LiveProps.liveCodeForSlotCode[w.propID] else { continue }
            out.append(PropWrite(propID: live, bytes: w.bytes))
            if w.propID == FujiProp.filmSimulation && values.isMonochrome {
                // The slot write order leaves mono toning out; live, it goes right after the film sim.
                let preset = SlotEncoder.presetProps(values)
                for slotCode in [FujiProp.monoWarmCool, FujiProp.monoMagentaGreen] {
                    if let p = preset.first(where: { $0.propID == slotCode }), let code = LiveProps.liveCodeForSlotCode[slotCode] {
                        out.append(PropWrite(propID: code, bytes: p.bytes))
                    }
                }
            }
        }
        return out
    }

    /// Writes that put a snapshot (taken with `snapshotCodes` before applying) back, in an order the gates allow:
    /// film sim → mono toning → DR/tones while D-Range Priority is still Off → D-Range Priority → WB/Kelvin → rest.
    /// Values the camera owned at snapshot time (DR reading 0xFFFF under D-Range Priority) are not written back;
    /// grain 6/7 is written as 1. Missing codes are skipped.
    public static func restoreWrites(from snapshot: [UInt16: Data]) -> [PropWrite] {
        func u16(_ code: UInt16) -> Int? { snapshot[code].flatMap { try? LiveCodec.decode($0, as: .uint16) } }
        var out: [PropWrite] = []
        func add(_ code: UInt16, _ bytes: Data? = nil) {
            if let b = bytes ?? snapshot[code] { out.append(PropWrite(propID: code, bytes: b)) }
        }
        let sim = u16(LiveProps.filmSimulation.code).flatMap { LiveFilmSim(rawValue: UInt16($0)) }
        add(LiveProps.filmSimulation.code)
        if sim?.isMonochrome == true {
            add(LiveProps.monoWarmCool.code)
            add(LiveProps.monoMagentaGreen.code)
        }
        let drpOriginal = u16(LiveProps.dRangePriority.code) ?? 0
        if drpOriginal == 0 {
            add(LiveProps.dynamicRange.code)
            add(LiveProps.highlight.code)
            add(LiveProps.shadow.code)
        }
        add(LiveProps.dRangePriority.code)
        if u16(LiveProps.whiteBalance.code) == Int(LiveWB.kelvin.rawValue) {
            add(LiveProps.whiteBalance.code)
            add(LiveProps.colorTemperature.code)
        } else {
            add(LiveProps.whiteBalance.code)
        }
        if let g = u16(LiveProps.grain.code), let grain = LiveGrain(wire: g) { add(LiveProps.grain.code, grain.bytes) }
        add(LiveProps.colorChrome.code)
        add(LiveProps.colorChromeFxBlue.code)
        add(LiveProps.smoothSkin.code)
        if sim?.isMonochrome != true {
            add(LiveProps.wbShiftR.code)
            add(LiveProps.wbShiftB.code)
            add(LiveProps.color.code)
        }
        add(LiveProps.sharpness.code)
        add(LiveProps.noiseReduction.code)
        add(LiveProps.clarity.code)
        return out
    }
}
