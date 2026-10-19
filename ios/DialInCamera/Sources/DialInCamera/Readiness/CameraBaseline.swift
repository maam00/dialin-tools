import Foundation

extension CameraReadiness {
    /// Editorial starting point for everyday photography, not a camera-measured or universally optimal policy.
    public struct AutoISOPolicy: Codable, Hashable, Sendable {
        public let baseISO: Int
        public let maximumISO: Int
        public let minimumShutterDenominator: Int
        public static let everyday = AutoISOPolicy(baseISO: 125, maximumISO: 6400, minimumShutterDenominator: 250)
        public var summary: String { "Base \(baseISO) · max \(maximumISO) · minimum 1/\(minimumShutterDenominator) sec" }
        public var caveat: String { "In dim light, the camera can use a slower shutter after reaching the ISO limit. Moving subjects may need a faster shutter and continuous focus." }
    }

    public enum BaselineStepID: String, Codable, Hashable, Sendable, CaseIterable {
        case automaticDials, autoISO, focusAndDrive, jpegAvailability
    }

    public struct BaselineStep: Hashable, Sendable, Identifiable {
        public let id: BaselineStepID
        public let title: String
        public let instruction: String
        public let detail: String
        public let sourceURL: URL
    }

    public struct BaselineRecord: Codable, Hashable, Sendable {
        public let identity: Identity?
        public let sessionID: UUID
        public let guideVersion: Int
        public let completedSteps: Set<BaselineStepID>
        public let policy: AutoISOPolicy
        public let confirmedAt: Date
        public var canPersist: Bool { identity != nil }

        public func isValid(for current: Identity?, sessionID currentSession: UUID) -> Bool {
            guard guideVersion == BaselineGuide.version, completedSteps == Set(BaselineStepID.allCases),
                  policy == .everyday else { return false }
            if let identity { return identity.supportsGuide && identity == current }
            return current == nil && sessionID == currentSession
        }
    }

    /// Pure UI state machine. Completion records USER observations, never machine verification or setting writes.
    /// The caller persists `completion` only when `canPersist`; missing identity stays local to this session.
    public struct BaselineGuide: Hashable, Sendable {
        // Version 3 also confirms ND Off; an old dial-only confirmation does not establish that state.
        public static let version = 3
        public let identity: Identity?
        public let sessionID: UUID
        public private(set) var completedSteps: Set<BaselineStepID>
        public private(set) var confirmedAt: Date?

        public init(identity: Identity?, sessionID: UUID, record: BaselineRecord? = nil) {
            self.identity = identity
            self.sessionID = sessionID
            if record?.isValid(for: identity, sessionID: sessionID) == true {
                completedSteps = record?.completedSteps ?? []
                confirmedAt = record?.confirmedAt
            } else {
                completedSteps = []
                confirmedAt = nil
            }
        }

        public var steps: [BaselineStep] {
            let manual = "https://fujifilm-dsc.com/en-int/manual/x100vi/"
            return [
                BaselineStep(id: .automaticDials, title: "Let the camera handle exposure",
                    instruction: "Set shutter speed, ISO and the aperture ring to A. Start the exposure dial at 0. Turn the ND filter Off. Confirm P on the camera display.",
                    detail: "The exposure dial is your everyday adjustment. An ND filter left On removes four stops of light, including indoors. Revisit this setup if you move a dial or change the filter.",
                    sourceURL: URL(string: manual + "basic_photo/photo_take/")!),
                BaselineStep(id: .autoISO, title: "Set Auto ISO once",
                    instruction: "SHOOTING SETTING → ISO AUTO SETTING → AUTO1: base 125, maximum 6400, minimum shutter 1/250 sec. Leave AUTO1 selected.",
                    detail: AutoISOPolicy.everyday.caveat,
                    sourceURL: URL(string: manual + "taking_photo/iso/")!),
                BaselineStep(id: .focusAndDrive, title: "Start with simple focusing",
                    instruction: "Set the focus switch to S, AF MODE to WIDE, and drive to Single Frame. Half-press to focus before shooting.",
                    detail: "This is the stationary-subject baseline. For moving subjects, use C with Zone or Tracking and a faster shutter. Dial In has not changed those controls for you.",
                    sourceURL: URL(string: manual + "taking_photo/autofocus/index.html")!),
                BaselineStep(id: .jpegAvailability, title: "Keep the camera's color available",
                    instruction: "Check that JPEG is enabled in every C1–C7 bank you will use. Choose JPEG, or RAW + JPEG if you also want RAW originals.",
                    detail: "RAW is optional. A JPEG carries each bank's rendered look into the phone. Color uploads preserve these file settings; this guide does not change them for you.",
                    sourceURL: URL(string: manual + "menu_shooting/image_quality_setting/")!),
            ]
        }

        public var currentStep: BaselineStep? { steps.first { !completedSteps.contains($0.id) } }
        public var isComplete: Bool { completedSteps == Set(BaselineStepID.allCases) && confirmedAt != nil }

        /// Accept one visible step at a time; a caller cannot mark an unseen later step complete.
        @discardableResult
        public mutating func confirm(step: BaselineStepID, at date: Date = Date()) -> Bool {
            guard identity?.supportsGuide ?? true, currentStep?.id == step else { return false }
            completedSteps.insert(step)
            if completedSteps == Set(BaselineStepID.allCases) { confirmedAt = date }
            return true
        }

        public mutating func reset() { completedSteps = []; confirmedAt = nil }

        public var completion: BaselineRecord? {
            guard isComplete, let confirmedAt else { return nil }
            return BaselineRecord(identity: identity, sessionID: sessionID, guideVersion: Self.version,
                                  completedSteps: completedSteps, policy: .everyday, confirmedAt: confirmedAt)
        }
    }
}
