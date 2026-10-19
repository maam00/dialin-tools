// Supervised lab review for ONE Bluetooth single-slot settings write (X100VI fw 1.10 layout only).
//
// Offline half: from a camera-made settings backup, build exactly the file `BLESlotWriter.writeExperimental` would
// send for one placement, refuse anything outside that slot's record + the checksum's low half, and record the byte
// diff as a reviewable `Review`. Live half (called from the writer's callbacks by `dialin-cam ble-trial-write`): the
// writer's fresh backup, taken on the SAME connection as the upload, must hold exactly the reviewed C1–C7 bytes, and
// the file it is about to send must carry exactly the reviewed changes. Anything else stops before a restore request.
//
// This never contacts a camera, never widens RestoreGuard, and never changes `BLESlotWriter.wirelessWritesValidated`.
import CryptoKit
import Foundation

public enum BLESlotTrialLab {
    public struct Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    /// One changed byte (absolute offset in the expanded settings file).
    public struct Change: Codable, Equatable, Hashable, Sendable {
        public var offset: Int
        public var before: Int
        public var after: Int
        public init(offset: Int, before: Int, after: Int) {
            self.offset = offset
            self.before = before
            self.after = after
        }
    }

    /// What a reviewer approves before the live run. Contains no serial (only its last four characters).
    public struct Review: Codable, Equatable, Sendable {
        public static let currentSchema = "dialin.ble-slot-trial-review.v1"
        public var schema: String
        public var slot: Int
        public var recipe: Recipe
        public var model: String
        public var serialSuffix: String
        public var baselineSHA256: String
        public var preparedSHA256: String
        /// Half-open [lower, upper) of the target slot's record, preamble included.
        public var slotRegion: [Int]
        /// Changed bytes outside the checksum field, ascending by offset.
        public var changes: [Change]
        public var checksumBefore: Int
        public var checksumAfter: Int
        public var patchLines: [String]
        /// Always false: a review is not hardware validation.
        public var wirelessWritesValidated: Bool

        /// The checksum movement, mod 2^16; identical for the same slot edit whatever the camera's counters hold.
        public var checksumDelta: Int { (checksumAfter - checksumBefore) & 0xFFFF }
    }

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Recipe input for a single trial: a bare recipe object, `{"recipes":[one]}`, or a camera-preparation
    /// `{"placements":[{"slot":N,"recipe":{…}}]}` whose single slot must equal `slot`. Never guesses a slot.
    public static func placement(fromJSON data: Data, slot: Int) throws -> FujiSettingsFile.LookPlacement {
        guard (1...7).contains(slot) else { throw Refusal("--slot must be 1…7 (got \(slot))") }
        let any = try JSONSerialization.jsonObject(with: data)
        func recipe(_ object: Any) throws -> Recipe {
            try JSONDecoder().decode(Recipe.self, from: JSONSerialization.data(withJSONObject: object))
        }
        if let object = any as? [String: Any] {
            if let placements = object["placements"] as? [[String: Any]] {
                guard placements.count == 1, let p = placements.first, let r = p["recipe"] else {
                    throw Refusal("a trial needs exactly one placement (got \(placements.count))")
                }
                guard (p["slot"] as? Int) == slot else {
                    throw Refusal("the file places its recipe in slot \(p["slot"].map { "\($0)" } ?? "?"), not C\(slot)")
                }
                return .init(slot: slot, recipe: try recipe(r))
            }
            if let recipes = object["recipes"] as? [Any] {
                guard recipes.count == 1, let r = recipes.first else {
                    throw Refusal("a trial needs exactly one recipe (got \(recipes.count))")
                }
                return .init(slot: slot, recipe: try recipe(r))
            }
            return .init(slot: slot, recipe: try recipe(object))
        }
        if let array = any as? [Any] {
            guard array.count == 1, let r = array.first else { throw Refusal("a trial needs exactly one recipe (got \(array.count))") }
            return .init(slot: slot, recipe: try recipe(r))
        }
        throw Refusal("no recipe found")
    }

    /// Offline: the exact file the experimental writer builds from `baseline` for `placement`, plus its review.
    public static func prepare(baseline: Data, placement: FujiSettingsFile.LookPlacement,
                               codes: ConfirmedCodes = .x100vi) throws -> (file: Data, review: Review) {
        let slot = placement.slot
        guard (1...7).contains(slot) else { throw Refusal("slot must be 1…7 (got \(slot))") }
        let refused = BLESlotWriter.unverified([placement], codes: codes)
        guard refused.isEmpty else { throw Refusal(BLESlotWriter.WriteError.unverified(refused).description) }
        let original: FujiSettingsFile
        do { original = try FujiSettingsFile(baseline) } catch { throw Refusal("baseline: \(error)") }
        let identity = BackupIdentity(baseline)
        guard identity.model == FujiSettingsFile.model, !identity.serial.isEmpty else {
            throw Refusal("the baseline does not identify an X100VI body")
        }
        let patch: FujiSettingsFile.LookPatch
        do { patch = try original.applyingLooks([placement], allowInferred: false) } catch { throw Refusal("\(error)") }
        let total = patch.file.names.reduce(0) { $0 + $1.count }
        guard total <= FujiSettingsFile.nameBudget else {
            throw Refusal("the seven names would total \(total) characters; the writer refuses more than \(FujiSettingsFile.nameBudget)")
        }
        let file = patch.file.data
        do { try RestoreGuard.check(file, against: baseline, slots: [slot]) } catch { throw Refusal("RestoreGuard: \(error)") }
        let changes = try narrowChanges(file, from: baseline, slot: slot, allowed: patch.allowed)
        let region = original.slotRegion(slot)
        let review = Review(
            schema: Review.currentSchema, slot: slot, recipe: placement.recipe, model: identity.model,
            serialSuffix: identity.serialSuffix, baselineSHA256: sha256(baseline), preparedSHA256: sha256(file),
            slotRegion: [region.lowerBound, region.upperBound], changes: changes,
            checksumBefore: Int(original.storedChecksum), checksumAfter: Int(patch.file.storedChecksum),
            patchLines: patch.lines, wirelessWritesValidated: BLESlotWriter.wirelessWritesValidated)
        return (file, review)
    }

    /// Every changed byte of `candidate` vs `fresh`, outside the checksum. Throws unless all of them sit inside `slot`'s
    /// record (and inside `allowed`, the patcher's exact field bytes, when given), the header and the checksum's high
    /// half are untouched, and at least one byte changed.
    public static func narrowChanges(_ candidate: Data, from fresh: Data, slot: Int, allowed: Set<Int>? = nil) throws -> [Change] {
        let c = [UInt8](candidate), f = [UInt8](fresh)
        guard c.count == f.count else { throw Refusal("size differs (\(c.count) vs \(f.count))") }
        let file: FujiSettingsFile
        do { file = try FujiSettingsFile(bytes: f) } catch { throw Refusal("\(error)") }
        let region = file.slotRegion(slot)
        let low = FujiSettingsFile.checksumOffset..<FujiSettingsFile.checksumOffset + 2
        var changes: [Change] = [], stray: [Int] = [], outsideFields: [Int] = []
        for i in 0..<c.count where c[i] != f[i] {
            if low.contains(i) { continue }
            if !region.contains(i) { stray.append(i); continue }
            if let allowed, !allowed.contains(i) { outsideFields.append(i) }
            changes.append(Change(offset: i, before: Int(f[i]), after: Int(c[i])))
        }
        func list(_ offsets: [Int]) -> String { offsets.prefix(6).map { String(format: "0x%X", $0) }.joined(separator: ", ") + (offsets.count > 6 ? ", …" : "") }
        guard stray.isEmpty else { throw Refusal("\(stray.count) byte(s) outside C\(slot)'s record would change (\(list(stray)))") }
        guard outsideFields.isEmpty else { throw Refusal("\(outsideFields.count) byte(s) inside C\(slot) but outside the look's fields would change (\(list(outsideFields)))") }
        guard !changes.isEmpty else { throw Refusal("C\(slot) already holds this look: nothing to send, so this cannot be a write trial") }
        return changes
    }

    /// Live, on the writer's fresh same-connection backup: same body, same size, and every C1–C7 byte (each record with
    /// its preamble, to the end of the file) identical to the reviewed baseline. Bytes before C1 may differ (frame
    /// counters, menu state); they are carried from the FRESH file and returned for the record.
    @discardableResult
    public static func requireReviewedSlots(fresh: Data, reviewedBaseline: Data) throws -> [Int] {
        guard fresh.count == reviewedBaseline.count else { throw Refusal("the fresh backup's size differs from the reviewed baseline") }
        let a = BackupIdentity(fresh), b = BackupIdentity(reviewedBaseline)
        guard a.isSameCamera(as: b) else { throw Refusal("the fresh backup is not from the reviewed camera (header model/serial differ)") }
        let f: FujiSettingsFile, r: FujiSettingsFile
        do {
            f = try FujiSettingsFile(fresh)
            r = try FujiSettingsFile(reviewedBaseline)
        } catch { throw Refusal("\(error)") }
        let start = r.slotRegion(1).lowerBound
        guard f.slotRegion(1).lowerBound == start, f.bytes[start...] == r.bytes[start...] else {
            let changedSlots = (1...7).filter { f.bytes[f.slotRegion($0)] != r.bytes[r.slotRegion($0)] }
            throw Refusal("C1–C7 changed since the review (\(changedSlots.map { "C\($0)" }.joined(separator: ", "))). Take a new backup and review again")
        }
        return (0..<start).filter { f.bytes[$0] != r.bytes[$0] }
    }

    /// Live, on the file the writer is about to send: exactly the reviewed byte changes on top of the fresh backup,
    /// the same checksum movement, and RestoreGuard still satisfied.
    public static func requireMatchesReview(prepared: Data, fresh: Data, review: Review) throws {
        guard review.schema == Review.currentSchema, !review.wirelessWritesValidated else { throw Refusal("unexpected review file") }
        do { try RestoreGuard.check(prepared, against: fresh, slots: [review.slot]) } catch { throw Refusal("RestoreGuard: \(error)") }
        let changes = try narrowChanges(prepared, from: fresh, slot: review.slot)
        guard changes == review.changes else {
            throw Refusal("the file about to be sent differs from the reviewed change set (\(changes.count) vs \(review.changes.count) bytes)")
        }
        let p: FujiSettingsFile, f: FujiSettingsFile
        do {
            p = try FujiSettingsFile(prepared)
            f = try FujiSettingsFile(fresh)
        } catch { throw Refusal("\(error)") }
        guard (Int(p.storedChecksum) - Int(f.storedChecksum)) & 0xFFFF == review.checksumDelta else {
            throw Refusal("the checksum movement differs from the reviewed one")
        }
    }

    /// Where two settings files differ, sorted into the places the trial reasons about.
    public struct Comparison: Codable, Equatable, Sendable {
        public var identical: Bool
        public var header: [Int] = []
        public var checksumLow: [Int] = []
        public var checksumHigh: [Int] = []
        /// "1"…"7" → changed offsets inside that slot's record (preamble included).
        public var slots: [String: [Int]] = [:]
        /// `FujiSettingsFile.frameCounterBlock`, which moves with every shot.
        public var frameCounter: [Int] = []
        /// 0xF6BC..<0xF6C5: changed between unchanged reads on 2026-10-13; meaning unproved.
        public var observedChanging: [Int] = []
        /// Everything else: unexplained, so a trial stops for review.
        public var other: [Int] = []

        /// Only `slot`, the checksum's low half, the two known changing spans and (cross-transport) header byte 0x47.
        public func onlyExpected(slot: Int?, crossTransport: Bool) -> Bool {
            let headerOK = header.isEmpty || (crossTransport && header == [0x47])
            let slotsOK = slots.allSatisfy { key, offsets in offsets.isEmpty || Int(key) == slot }
            return headerOK && slotsOK && checksumHigh.isEmpty && other.isEmpty
        }
    }

    public static let observedChangingSpan = 0xF6BC..<0xF6C5

    public static func compare(_ a: Data, _ b: Data) throws -> Comparison {
        guard a.count == b.count else { throw Refusal("sizes differ (\(a.count) vs \(b.count))") }
        let fa: FujiSettingsFile
        do { fa = try FujiSettingsFile(a) } catch { throw Refusal("first file: \(error)") }
        do { _ = try FujiSettingsFile(b) } catch { throw Refusal("second file: \(error)") }
        let x = [UInt8](a), y = [UInt8](b)
        var c = Comparison(identical: x == y)
        for s in 1...7 { c.slots[String(s)] = [] }
        let regions = (1...7).map { fa.slotRegion($0) }
        let low = FujiSettingsFile.checksumOffset..<FujiSettingsFile.checksumOffset + 2
        let high = FujiSettingsFile.checksumOffset + 2..<FujiSettingsFile.checksumOffset + 4
        for i in 0..<x.count where x[i] != y[i] {
            if i < fa.payloadStart { c.header.append(i) }
            else if low.contains(i) { c.checksumLow.append(i) }
            else if high.contains(i) { c.checksumHigh.append(i) }
            else if let s = regions.firstIndex(where: { $0.contains(i) }) { c.slots[String(s + 1), default: []].append(i) }
            else if FujiSettingsFile.frameCounterBlock.contains(i) { c.frameCounter.append(i) }
            else if observedChangingSpan.contains(i) { c.observedChanging.append(i) }
            else { c.other.append(i) }
        }
        return c
    }

    /// Re-run the offline preparation and require it to reproduce the saved review and prepared file exactly.
    public static func revalidate(review: Review, baseline: Data, prepared: Data) throws {
        guard sha256(baseline) == review.baselineSHA256, sha256(prepared) == review.preparedSHA256 else {
            throw Refusal("review files were changed after the review (hash mismatch)")
        }
        let again = try prepare(baseline: baseline, placement: .init(slot: review.slot, recipe: review.recipe))
        guard again.file == prepared, again.review == review else { throw Refusal("the saved review does not reproduce from its baseline") }
    }
}
