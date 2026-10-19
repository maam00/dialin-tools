import Foundation

/// Preparation is a combination of measured color state and explicitly confirmed physical setup.
/// This layer performs no camera writes and never promotes a manual confirmation to a device read-back.
public enum CameraReadiness {
    public enum Transport: String, Codable, Hashable, Sendable { case usb, bluetooth, demo }

    /// Exact identity within one transport's naming format. Unknown serial/firmware cannot create a durable receipt.
    public struct Identity: Codable, Hashable, Sendable {
        public let model: String
        public let serial: String
        public let firmware: String

        public init?(model: String, serial: String?, firmware: String?) {
            let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let serial = (serial ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, !serial.isEmpty, let firmware = BLESlotWriter.normalizeFirmware(firmware) else { return nil }
            self.model = model
            self.serial = serial
            self.firmware = firmware
        }

        public var supportsGuide: Bool { CameraCompatibility.modelKey(model) == "X100VI" }
    }

    public enum Feature: String, Codable, Hashable, Sendable, CaseIterable {
        case savedColorLooks, activeSlotRecall, automaticExposure, autoISOPolicy, autofocus, physicalDials, jpegAvailability
    }

    public enum Support: String, Codable, Hashable, Sendable {
        /// A implemented write/read-back path with recorded X100VI hardware evidence, scoped to the color recipe.
        case hardwareTestedPath
        /// Software preparation exists; accepted modified BLE uploads still require physical validation.
        case experimentalPath
        /// The manual describes the camera behavior; this app has no validated automatic preparation path.
        case guidedOnCamera
        case unavailable
        case simulation
    }

    public struct Capability: Codable, Hashable, Sendable, Identifiable {
        public let feature: Feature
        public let support: Support
        public let explanation: String
        public var id: Feature { feature }
        public var canPrepareAutomatically: Bool { support == .hardwareTestedPath }
    }

    /// An advertised PTP property or catalog entry does not establish camera-specific automation.
    public static func capabilities(model: String, firmware: String?, transport: Transport) -> [Capability] {
        let supported = CameraCompatibility.modelKey(model) == "X100VI"
        let knownLayout = supported && BLESlotWriter.normalizeFirmware(firmware) == "1.10"
        return Feature.allCases.map { feature in
            let support: Support
            let explanation: String
            if transport == .demo {
                support = .simulation
                explanation = "Preview only. No camera setting was checked."
            } else if !supported {
                support = .unavailable
                explanation = "Preparation for this camera has not been validated."
            } else if feature == .savedColorLooks {
                support = knownLayout ? (transport == .usb ? .hardwareTestedPath : .experimentalPath) : .unavailable
                explanation = knownLayout ? (transport == .usb
                    ? "USB color writes have X100VI read-back evidence. A new load still needs its own checked result."
                    : "One-slot Bluetooth trials are prepared. Production modified writes remain disabled.")
                    : "This firmware's color-writing layout has not been validated."
            } else {
                support = .guidedOnCamera
                switch feature {
                case .activeSlotRecall: explanation = "Choose the loaded C1–C7 bank on the camera. The slot-edit cursor is not active-slot proof."
                case .automaticExposure: explanation = "Set shutter, ISO and aperture to A; confirm P on the camera."
                case .autoISOPolicy: explanation = "Choose Auto ISO limits on the camera. Recipe writes do not prove this policy."
                case .autofocus: explanation = "Confirm the focus switch and AF mode on the camera; use C for moving subjects."
                case .physicalDials: explanation = "The app cannot turn physical dials. A saved setup confirmation is your observation."
                case .jpegAvailability: explanation = "Keep JPEG enabled for the color/import workflow. RAW is optional."
                case .savedColorLooks: explanation = ""
                }
            }
            return Capability(feature: feature, support: support, explanation: explanation)
        }
    }

    public enum LookState: Codable, Hashable, Sendable {
        case notLoaded
        case unverified(slot: Int)
        /// Only create from a successful camera read-back for this preparation session.
        case verified(slot: Int, name: String)
    }

    /// Selecting a new look or starting another session invalidates this observation.
    public struct SessionSelection: Codable, Hashable, Sendable {
        public let sessionID: UUID
        public let slot: Int
        public let confirmedAt: Date
        public init?(sessionID: UUID, slot: Int, confirmedAt: Date = Date()) {
            guard (1...7).contains(slot) else { return nil }
            self.sessionID = sessionID; self.slot = slot; self.confirmedAt = confirmedAt
        }
    }

    public enum Status: String, Codable, Hashable, Sendable {
        case unsupportedCamera, preview, needsLook, needsVerification, needsBaseline, needsShootAdjustment, needsSlotSelection, readyWithUserSetup
    }

    public struct Assessment: Hashable, Sendable {
        public let status: Status
        public let title: String
        public let detail: String
        public let remainingActions: [String]
        public let capabilities: [Capability]
        /// This deliberately remains false: full automatic exposure/focus/recall is not implemented and verified.
        public var isFullyDeviceVerified: Bool { false }
        public var canShootWithConfirmedSetup: Bool { status == .readyWithUserSetup }
    }

    public static func assess(
        model: String, firmware: String?, identity: Identity?, transport: Transport, sessionID: UUID,
        lookState: LookState, baseline: BaselineRecord?, activeSlotConfirmation: SessionSelection?,
        requiredPhysicalActions: [String] = []
    ) -> Assessment {
        let capabilities = capabilities(model: model, firmware: firmware, transport: transport)
        func result(_ status: Status, _ title: String, _ detail: String, _ actions: [String] = []) -> Assessment {
            Assessment(status: status, title: title, detail: detail, remainingActions: actions, capabilities: capabilities)
        }
        if transport == .demo { return result(.preview, "Preview", "No camera has been prepared.") }
        guard CameraCompatibility.modelKey(model) == "X100VI" else {
            return result(.unsupportedCamera, "Camera setup needed", "This camera's preparation has not been validated.")
        }
        let slot: Int
        switch lookState {
        case .notLoaded: return result(.needsLook, "Prepare your look", "Your recommendation has not been loaded.")
        case .unverified(let pending):
            return result(.needsVerification, "Check the camera", "C\(pending) has not been verified.", ["Read the look back before marking it loaded."])
        case .verified(let loaded, _): slot = loaded
        }
        guard (1...7).contains(slot) else {
            return result(.needsVerification, "Check the camera", "The confirmed slot is invalid.")
        }
        let identityMatchesProfile = identity.map {
            CameraCompatibility.modelKey($0.model) == CameraCompatibility.modelKey(model)
                && $0.firmware == BLESlotWriter.normalizeFirmware(firmware)
        } ?? true
        guard identityMatchesProfile, baseline?.isValid(for: identity, sessionID: sessionID) == true else {
            return result(.needsBaseline, "C\(slot) loaded", "Set up automatic shooting once on this camera.",
                          ["Confirm the automatic dials, Auto ISO, focus/drive and JPEG setup."])
        }
        let actions = requiredPhysicalActions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !actions.isEmpty {
            return result(.needsShootAdjustment, "C\(slot) loaded", "Confirm the remaining camera setup for this shoot.", actions)
        }
        guard activeSlotConfirmation?.sessionID == sessionID, activeSlotConfirmation?.slot == slot else {
            return result(.needsSlotSelection, "C\(slot) loaded", "Choose C\(slot) on the camera.",
                          ["IMAGE QUALITY SETTING → SELECT CUSTOM SETTING → CUSTOM \(slot)."])
        }
        return result(.readyWithUserSetup, "Ready to shoot", "Color checked. Automatic setup and C\(slot) selection confirmed by you. Use the exposure dial as you shoot.")
    }
}
