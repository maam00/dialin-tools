import Foundation
import Testing
@testable import DialInCamera

@Suite("Camera preparation evidence and guided baseline")
struct CameraReadinessTests {
    private var session: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
    private var nextSession: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000002")! }
    private var identity: CameraReadiness.Identity {
        CameraReadiness.Identity(model: "X100VI", serial: "READINESS-TEST", firmware: "1.10")!
    }

    private func complete(identity: CameraReadiness.Identity?, sessionID: UUID) -> CameraReadiness.BaselineRecord {
        var guide = CameraReadiness.BaselineGuide(identity: identity, sessionID: sessionID)
        for step in CameraReadiness.BaselineStepID.allCases { _ = guide.confirm(step: step) }
        return guide.completion!
    }

    private func assess(
        identity: CameraReadiness.Identity? = nil, sessionID: UUID? = nil,
        look: CameraReadiness.LookState = .verified(slot: 4, name: "Color"),
        baseline: CameraReadiness.BaselineRecord? = nil,
        selected: CameraReadiness.SessionSelection? = nil, actions: [String] = [],
        transport: CameraReadiness.Transport = .bluetooth
    ) -> CameraReadiness.Assessment {
        CameraReadiness.assess(model: "X100VI", firmware: "1.10", identity: identity, transport: transport,
                              sessionID: sessionID ?? session, lookState: look, baseline: baseline,
                              activeSlotConfirmation: selected, requiredPhysicalActions: actions)
    }

    @Test("Recipe capability never implies automatic ISO, AF, dials or active-bank recall")
    func capabilities() {
        let usb = CameraReadiness.capabilities(model: "X100VI", firmware: "1.10", transport: .usb)
        #expect(usb.first { $0.feature == .savedColorLooks }?.support == .hardwareTestedPath)
        #expect(usb.filter { $0.feature != .savedColorLooks }.allSatisfy { !$0.canPrepareAutomatically && $0.support == .guidedOnCamera })
        let ble = CameraReadiness.capabilities(model: "X100VI", firmware: "1.10", transport: .bluetooth)
        #expect(ble.first { $0.feature == .savedColorLooks }?.support == .experimentalPath)
        #expect(ble.allSatisfy { !$0.canPrepareAutomatically })
        let unfamiliar = CameraReadiness.capabilities(model: "X100VI", firmware: "1.11", transport: .usb)
        #expect(unfamiliar.first { $0.feature == .savedColorLooks }?.support == .unavailable)
        #expect(!BLESlotWriter.wirelessWritesValidated)
    }

    @Test("A measured loaded recipe alone stays loaded, never ready")
    func colorAlone() {
        let result = assess(identity: identity)
        #expect(result.status == .needsBaseline && result.title == "C4 loaded")
        #expect(!result.canShootWithConfirmedSetup && !result.isFullyDeviceVerified)
        #expect(!result.remainingActions.isEmpty)
    }

    @Test("Sequential manual confirmations are required; only a complete guide can persist")
    func sequential() {
        var guide = CameraReadiness.BaselineGuide(identity: identity, sessionID: session)
        let skipped = guide.confirm(step: .jpegAvailability)
        #expect(!skipped)
        #expect(guide.completion == nil && guide.currentStep?.id == .automaticDials)
        for step in CameraReadiness.BaselineStepID.allCases {
            let confirmed = guide.confirm(step: step)
            #expect(confirmed)
        }
        #expect(guide.isComplete && guide.completion?.canPersist == true)
        #expect(guide.completion?.isValid(for: identity, sessionID: nextSession) == true)
        guide.reset()
        #expect(!guide.isComplete && guide.completion == nil)
    }

    @Test("Camera, firmware or guide-version changes invalidate remembered setup")
    func binding() throws {
        let record = complete(identity: identity, sessionID: session)
        let other = CameraReadiness.Identity(model: "X100VI", serial: "ANOTHER", firmware: "1.10")!
        let updated = CameraReadiness.Identity(model: "X100VI", serial: "READINESS-TEST", firmware: "1.11")!
        #expect(!record.isValid(for: other, sessionID: session))
        #expect(!record.isValid(for: updated, sessionID: session))
        #expect(!CameraReadiness.BaselineGuide(identity: other, sessionID: session, record: record).isComplete)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        object["guideVersion"] = 0
        let old = try JSONDecoder().decode(CameraReadiness.BaselineRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!old.isValid(for: identity, sessionID: session))
    }

    @Test("A previous dial-only setup cannot establish the newly required ND state")
    func priorSetupNeedsNDConfirmation() throws {
        let record = complete(identity: identity, sessionID: session)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        object["guideVersion"] = 2
        let previous = try JSONDecoder().decode(CameraReadiness.BaselineRecord.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(!previous.isValid(for: identity, sessionID: session))
        let guide = CameraReadiness.BaselineGuide(identity: identity, sessionID: session, record: previous)
        #expect(!guide.isComplete && guide.currentStep?.id == .automaticDials)
    }

    @Test("Unknown identity can be confirmed for one session but cannot be remembered as a camera")
    func missingIdentity() {
        #expect(CameraReadiness.Identity(model: "X100VI", serial: nil, firmware: "1.10") == nil)
        #expect(CameraReadiness.Identity(model: "X100VI", serial: " ", firmware: "1.10") == nil)
        #expect(CameraReadiness.Identity(model: "X100VI", serial: "TEST", firmware: nil) == nil)
        let local = complete(identity: nil, sessionID: session)
        #expect(!local.canPersist && local.isValid(for: nil, sessionID: session))
        #expect(!local.isValid(for: nil, sessionID: nextSession))
        #expect(!local.isValid(for: identity, sessionID: session))
    }

    @Test("Choosing the loaded slot is a current-session observation separate from baseline")
    func activeSelection() {
        let baseline = complete(identity: identity, sessionID: session)
        #expect(assess(identity: identity, baseline: baseline).status == .needsSlotSelection)
        let wrongSlot = CameraReadiness.SessionSelection(sessionID: session, slot: 3)!
        #expect(assess(identity: identity, baseline: baseline, selected: wrongSlot).status == .needsSlotSelection)
        let oldSession = CameraReadiness.SessionSelection(sessionID: nextSession, slot: 4)!
        #expect(assess(identity: identity, baseline: baseline, selected: oldSession).status == .needsSlotSelection)
        let selected = CameraReadiness.SessionSelection(sessionID: session, slot: 4)!
        let result = assess(identity: identity, baseline: baseline, selected: selected)
        #expect(result.status == .readyWithUserSetup && result.canShootWithConfirmedSetup)
        #expect(!result.isFullyDeviceVerified && result.detail.contains("confirmed by you"))
    }

    @Test("Shoot-specific focus, drive or exposure actions prevent a ready claim")
    func movingSubject() {
        let baseline = complete(identity: identity, sessionID: session)
        let selected = CameraReadiness.SessionSelection(sessionID: session, slot: 4)!
        let result = assess(identity: identity, baseline: baseline, selected: selected,
                            actions: ["Use C with Zone for moving subjects.", " "])
        #expect(result.status == .needsShootAdjustment && !result.canShootWithConfirmedSetup)
        #expect(result.remainingActions == ["Use C with Zone for moving subjects."])
    }

    @Test("Transport completion, demo state and invalid slot cannot fabricate preparedness")
    func noFalseSuccess() {
        let baseline = complete(identity: identity, sessionID: session)
        let selected = CameraReadiness.SessionSelection(sessionID: session, slot: 4)!
        #expect(assess(identity: identity, look: .unverified(slot: 4), baseline: baseline, selected: selected).status == .needsVerification)
        #expect(assess(identity: identity, look: .notLoaded, baseline: baseline, selected: selected).status == .needsLook)
        #expect(assess(identity: identity, look: .verified(slot: 99, name: "Bad"), baseline: baseline, selected: selected).status == .needsVerification)
        let demo = assess(identity: identity, baseline: baseline, selected: selected, transport: .demo)
        #expect(demo.status == .preview && !demo.canShootWithConfirmedSetup)
    }

    @Test("Baseline content is manual, RAW optional, and shutter policy admits low-light limits")
    func contentBoundaries() {
        let guide = CameraReadiness.BaselineGuide(identity: identity, sessionID: session)
        let format = guide.steps.first { $0.id == .jpegAvailability }!
        #expect(format.detail.contains("RAW is optional"))
        #expect(CameraReadiness.AutoISOPolicy.everyday.caveat.contains("slower shutter"))
        let focus = guide.steps.first { $0.id == .focusAndDrive }!
        #expect(focus.detail.contains("moving subjects") && focus.detail.contains("has not changed"))
    }
}
