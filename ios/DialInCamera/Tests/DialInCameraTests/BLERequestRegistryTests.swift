import Foundation
import Testing
@testable import DialInCamera

@Suite("BLE request lifetime")
struct BLERequestRegistryTests {
    @Test("A completed frame's delayed timeout cannot cancel a subsequent frame on the same characteristic")
    func staleTimeout() {
        var waiters = BLERequestRegistry<String>()
        let first = waiters.insert("first frame", for: "partial-data")
        #expect(waiters.take("partial-data") == "first frame")
        let second = waiters.insert("second frame", for: "partial-data")
        #expect(waiters.take("partial-data", token: first.token) == nil)
        #expect(waiters.take("partial-data", token: second.token) == "second frame")
        #expect(waiters.take("partial-data", token: second.token) == nil)
    }

    @Test("Disconnect clears pending subscriptions and old timeouts cannot consume reconnect waiters")
    func reconnect() {
        var waiters = BLERequestRegistry<String>()
        let old = waiters.insert("old subscription", for: "backup-state")
        #expect(waiters.takeAll() == ["old subscription"])
        let fresh = waiters.insert("new subscription", for: "backup-state")
        #expect(waiters.take("backup-state", token: old.token) == nil)
        #expect(waiters.take("backup-state", token: fresh.token) == "new subscription")
    }

    @Test("Unavailable backup notifications stop the request before a transfer begins")
    func subscriptionRequired() async throws {
        let gatt = FakeGATT()
        await gatt.configure { $0.present.remove(FujiBLE.backupState) }
        await #expect(throws: FujiBLEError.self) { _ = try await FujiBLEFlows.backupSettings(gatt) }
        #expect(await !gatt.writes.contains { $0.0 == FujiBLE.backupRequest })
        #expect(await !gatt.writes.contains { $0.0 == FujiBLE.filePartialData })
    }
}
