import Foundation

extension CameraReadiness {
    /// The day is one complete C1–C7 palette. A current-use suggestion is secondary to checking every bank.
    /// `verifiedSlots` must come from successful read-back for this camera, firmware and preparation session;
    /// callers must clear it when any of those bindings change. A transport acknowledgement is not a checked slot.
    /// This assessment performs no writes and keeps manual setup distinct from device-verified color settings.
    public static func assessPalette(
        model: String, firmware: String?, identity: Identity?, transport: Transport, sessionID: UUID,
        plannedSlots: Set<Int>, verifiedSlots: Set<Int>, baseline: BaselineRecord?,
        activeSlotConfirmation: SessionSelection?, currentSlot: Int?, requiredPhysicalActions: [String] = []
    ) -> Assessment {
        let capabilities = capabilities(model: model, firmware: firmware, transport: transport)
        let banks = Set(1...7)
        func result(_ status: Status, _ title: String, _ detail: String, _ actions: [String] = []) -> Assessment {
            Assessment(status: status, title: title, detail: detail, remainingActions: actions, capabilities: capabilities)
        }
        if transport == .demo {
            return result(.preview, "Preview", "Your day palette is a preview. No camera settings were checked.")
        }
        guard CameraCompatibility.modelKey(model) == "X100VI" else {
            return result(.unsupportedCamera, "Camera setup needed", "This camera's day-palette preparation has not been validated.")
        }
        let profileMatches = identity.map {
            CameraCompatibility.modelKey($0.model) == CameraCompatibility.modelKey(model)
                && $0.firmware == BLESlotWriter.normalizeFirmware(firmware)
        } ?? true
        guard profileMatches else {
            return result(.needsVerification, "0 of 7 looks checked", "The camera or its software changed. Check this day palette on the current connection.",
                          ["Read C1–C7 back on this camera before marking the palette loaded."])
        }
        let colorSupport = capabilities.first(where: { $0.feature == .savedColorLooks })?.support
        guard colorSupport == .hardwareTestedPath || colorSupport == .experimentalPath else {
            return result(.needsVerification, "0 of 7 looks checked", "Dial In cannot verify all seven looks on this camera software yet.",
                          ["Use a validated camera-software layout before checking the day palette."])
        }

        let checked = verifiedSlots.intersection(plannedSlots).intersection(banks)
        let progress = "\(checked.count) of 7 looks checked"
        guard plannedSlots == banks else {
            let missing = banks.subtracting(plannedSlots).sorted().map { "C\($0)" }.joined(separator: ", ")
            let action = missing.isEmpty ? "Use each bank from C1 to C7 exactly once in the day palette."
                : "Complete the day palette for \(missing), then check those looks on the camera."
            return result(.needsLook, progress, "Your day needs one look for each bank from C1 to C7.", [action])
        }
        guard verifiedSlots == banks else {
            let remaining = banks.subtracting(checked).sorted().map { "C\($0)" }.joined(separator: ", ")
            let action = remaining.isEmpty ? "Read exactly C1–C7 back before marking the palette loaded."
                : "Check \(remaining) on the camera before marking the day palette loaded."
            return result(.needsVerification, progress, "Every day look needs a successful camera read-back, including looks already kept in place.", [action])
        }
        guard baseline?.isValid(for: identity, sessionID: sessionID) == true else {
            return result(.needsBaseline, "Seven looks loaded", "Set up automatic shooting once on this camera.",
                          ["Confirm the automatic dials, Auto ISO, focus/drive and JPEG setup."])
        }
        var seenActions = Set<String>()
        let actions = requiredPhysicalActions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenActions.insert($0).inserted }
        if !actions.isEmpty {
            return result(.needsShootAdjustment, "Seven looks loaded", "Confirm the remaining camera setup for this day.", actions)
        }
        guard let confirmed = activeSlotConfirmation, confirmed.sessionID == sessionID, banks.contains(confirmed.slot),
              currentSlot.map({ banks.contains($0) && $0 == confirmed.slot }) ?? true else {
            let instruction = currentSlot.flatMap { banks.contains($0) ? "Choose C\($0) on the camera and confirm the look you are using." : nil }
                ?? "Choose a day look from C1 to C7 on the camera, then confirm which bank you are using."
            return result(.needsSlotSelection, "Seven looks loaded", "Choose the look you want to use now.", [instruction])
        }
        return result(.readyWithUserSetup, "Your day is prepared",
                      "Seven color looks checked on your camera. Automatic setup and C\(confirmed.slot) selection confirmed by you. Use the exposure dial as you shoot.")
    }
}
