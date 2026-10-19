import Foundation
import Testing
@testable import DialInCamera

@Suite("A complete C1–C7 day palette")
struct PaletteReadinessTests {
    private let banks = Set(1...7)
    private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
    private let laterSession = UUID(uuidString: "00000000-0000-0000-0000-000000000072")!
    private var identity: CameraReadiness.Identity {
        CameraReadiness.Identity(model: "X100VI", serial: "PALETTE-TEST", firmware: "1.10")!
    }

    private func completedBaseline(identity: CameraReadiness.Identity?, sessionID: UUID) -> CameraReadiness.BaselineRecord {
        var guide = CameraReadiness.BaselineGuide(identity: identity, sessionID: sessionID)
        for step in CameraReadiness.BaselineStepID.allCases { _ = guide.confirm(step: step) }
        return guide.completion!
    }

    private func assess(planned: Set<Int> = Set(1...7), verified: Set<Int> = Set(1...7),
                        baseline: CameraReadiness.BaselineRecord? = nil,
                        selected: CameraReadiness.SessionSelection? = nil, currentSlot: Int? = 4,
                        actions: [String] = [], transport: CameraReadiness.Transport = .usb) -> CameraReadiness.Assessment {
        CameraReadiness.assessPalette(model: "X100VI", firmware: "1.10", identity: identity, transport: transport,
                                      sessionID: session, plannedSlots: planned, verifiedSlots: verified,
                                      baseline: baseline, activeSlotConfirmation: selected, currentSlot: currentSlot,
                                      requiredPhysicalActions: actions)
    }

    @Test("One checked current-use look cannot stand in for the day palette")
    func oneLookIsNotTheDay() {
        let baseline = completedBaseline(identity: identity, sessionID: session)
        let selected = CameraReadiness.SessionSelection(sessionID: session, slot: 4)!
        let result = assess(verified: [4], baseline: baseline, selected: selected)
        #expect(result.status == .needsVerification && result.title == "1 of 7 looks checked")
        #expect(!result.canShootWithConfirmedSetup && !result.isFullyDeviceVerified)
        #expect(result.remainingActions.joined().contains("C1") && result.remainingActions.joined().contains("C7"))
    }

    @Test("Missing or duplicated planned banks cannot be a complete seven-look day")
    func incompletePlan() {
        let duplicatePlan = Set([1, 2, 2, 3, 4, 5, 6])
        let result = assess(planned: duplicatePlan, verified: banks)
        #expect(result.status == .needsLook && result.title == "6 of 7 looks checked")
        #expect(result.remainingActions.joined().contains("C7"))
        #expect(!result.canShootWithConfirmedSetup)
    }

    @Test("A refused bank stays unchecked even when the other six succeeded")
    func refusedBank() {
        let result = assess(verified: banks.subtracting([3]))
        #expect(result.status == .needsVerification && result.title == "6 of 7 looks checked")
        #expect(result.remainingActions.joined().contains("C3"))
        #expect(!result.canShootWithConfirmedSetup)
    }

    @Test("Upload acknowledgement with no successful read-back is zero checked looks")
    func unverifiedUpload() {
        let baseline = completedBaseline(identity: identity, sessionID: session)
        let selected = CameraReadiness.SessionSelection(sessionID: session, slot: 4)!
        let result = assess(verified: [], baseline: baseline, selected: selected)
        #expect(result.status == .needsVerification && result.title == "0 of 7 looks checked")
        #expect(!result.canShootWithConfirmedSetup)
    }

    @Test("Invalid bank metadata prevents aggregate readiness")
    func invalidBanks() {
        let baseline = completedBaseline(identity: identity, sessionID: session)
        let selected = CameraReadiness.SessionSelection(sessionID: session, slot: 4)!
        let plan = assess(planned: banks.union([99]), baseline: baseline, selected: selected)
        let readback = assess(verified: banks.union([0]), baseline: baseline, selected: selected)
        #expect(plan.status == .needsLook && !plan.canShootWithConfirmedSetup)
        #expect(readback.status == .needsVerification && !readback.canShootWithConfirmedSetup)
    }

    @Test("All seven color looks alone are loaded, not fully prepared")
    func colorsStillNeedBaseline() {
        let result = assess()
        #expect(result.status == .needsBaseline && result.title == "Seven looks loaded")
        #expect(!result.canShootWithConfirmedSetup && !result.isFullyDeviceVerified)
        #expect(!result.remainingActions.isEmpty)
    }

    @Test("Unknown camera software cannot turn reported slot counts into readiness")
    func unknownLayout() {
        for firmware in [nil, "1.11"] as [String?] {
            let result = CameraReadiness.assessPalette(model: "X100VI", firmware: firmware, identity: nil, transport: .usb,
                sessionID: session, plannedSlots: banks, verifiedSlots: banks, baseline: completedBaseline(identity: nil, sessionID: session),
                activeSlotConfirmation: .init(sessionID: session, slot: 4), currentSlot: 4)
            #expect(result.status == .needsVerification && result.title == "0 of 7 looks checked")
            #expect(!result.canShootWithConfirmedSetup)
        }
    }

    @Test("A stale identity-profile pairing invalidates the purported palette checks")
    func mismatchedIdentityProfile() {
        let result = CameraReadiness.assessPalette(model: "X100VI", firmware: "1.10",
            identity: .init(model: "X100VI", serial: "PALETTE-TEST", firmware: "1.11"), transport: .usb,
            sessionID: session, plannedSlots: banks, verifiedSlots: banks, baseline: nil,
            activeSlotConfirmation: .init(sessionID: session, slot: 4), currentSlot: 4)
        #expect(result.status == .needsVerification && result.title == "0 of 7 looks checked")
        #expect(!result.canShootWithConfirmedSetup)
    }

    @Test("A camera switch clears checks and cannot reuse another body's baseline")
    func cameraSwitch() {
        let other = CameraReadiness.Identity(model: "X100VI", serial: "OTHER-BODY", firmware: "1.10")!
        let result = CameraReadiness.assessPalette(model: "X100VI", firmware: "1.10", identity: other, transport: .usb,
            sessionID: laterSession, plannedSlots: banks, verifiedSlots: [], baseline: completedBaseline(identity: identity, sessionID: session),
            activeSlotConfirmation: .init(sessionID: laterSession, slot: 4), currentSlot: 4)
        #expect(result.status == .needsVerification && !result.canShootWithConfirmedSetup)
        let rechecked = CameraReadiness.assessPalette(model: "X100VI", firmware: "1.10", identity: other, transport: .usb,
            sessionID: laterSession, plannedSlots: banks, verifiedSlots: banks, baseline: completedBaseline(identity: identity, sessionID: session),
            activeSlotConfirmation: .init(sessionID: laterSession, slot: 4), currentSlot: 4)
        #expect(rechecked.status == .needsBaseline && !rechecked.canShootWithConfirmedSetup)
    }

    @Test("Current bank confirmation must belong to this preparation and agree with the current-use bank")
    func currentConfirmation() {
        let baseline = completedBaseline(identity: identity, sessionID: session)
        #expect(assess(baseline: baseline).status == .needsSlotSelection)
        #expect(assess(baseline: baseline, selected: .init(sessionID: laterSession, slot: 4)).status == .needsSlotSelection)
        #expect(assess(baseline: baseline, selected: .init(sessionID: session, slot: 3)).status == .needsSlotSelection)
        #expect(assess(baseline: baseline, selected: .init(sessionID: session, slot: 4), currentSlot: 99).status == .needsSlotSelection)
        let ready = assess(baseline: baseline, selected: .init(sessionID: session, slot: 4))
        #expect(ready.status == .readyWithUserSetup && ready.title == "Your day is prepared")
        #expect(ready.canShootWithConfirmedSetup && !ready.isFullyDeviceVerified)
        #expect(ready.detail.contains("Seven color looks checked") && ready.detail.contains("confirmed by you"))
    }

    @Test("Without a recommendation, any bank confirmed by the user can be the current-use look")
    func recommendationIsSecondary() {
        let result = assess(baseline: completedBaseline(identity: identity, sessionID: session),
                            selected: .init(sessionID: session, slot: 7), currentSlot: nil)
        #expect(result.status == .readyWithUserSetup && result.detail.contains("C7 selection confirmed by you"))
    }

    @Test("Remaining physical actions block readiness and are not mistaken for device preparation")
    func physicalExceptions() {
        let result = assess(baseline: completedBaseline(identity: identity, sessionID: session),
            selected: .init(sessionID: session, slot: 4), actions: [" Use continuous focus for the moving subject. ", "", "Use continuous focus for the moving subject."])
        #expect(result.status == .needsShootAdjustment && result.title == "Seven looks loaded")
        #expect(result.remainingActions == ["Use continuous focus for the moving subject."])
        #expect(!result.canShootWithConfirmedSetup)
    }

    @Test("Anonymous setup records remain limited to their single preparation session")
    func sessionLocalBaseline() {
        let record = completedBaseline(identity: nil, sessionID: session)
        let result = CameraReadiness.assessPalette(model: "X100VI", firmware: "1.10", identity: nil, transport: .usb,
            sessionID: laterSession, plannedSlots: banks, verifiedSlots: banks, baseline: record,
            activeSlotConfirmation: .init(sessionID: laterSession, slot: 4), currentSlot: 4)
        #expect(result.status == .needsBaseline && !result.canShootWithConfirmedSetup)
    }

    @Test("Simulation and unsupported cameras never become a real prepared day")
    func previewAndUnsupported() {
        let baseline = completedBaseline(identity: identity, sessionID: session)
        let demo = assess(baseline: baseline, selected: .init(sessionID: session, slot: 4), transport: .demo)
        #expect(demo.status == .preview && demo.title == "Preview" && demo.detail.contains("No camera settings were checked"))
        #expect(!demo.canShootWithConfirmedSetup && !demo.isFullyDeviceVerified)
        let unknown = CameraReadiness.assessPalette(model: "X100V", firmware: "1.10", identity: nil, transport: .usb,
            sessionID: session, plannedSlots: banks, verifiedSlots: banks, baseline: nil,
            activeSlotConfirmation: nil, currentSlot: nil)
        #expect(unknown.status == .unsupportedCamera && !unknown.canShootWithConfirmedSetup)
    }
}
