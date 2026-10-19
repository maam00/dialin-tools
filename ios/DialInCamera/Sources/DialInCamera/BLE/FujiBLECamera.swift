// The Bluetooth camera as the app codes against it: the real one (`FujiBluetoothLink`, CoreBluetooth) or the rehearsal
// one (`FakeFujiBLECamera`, no radio). Both are GATT clients, so every flow (registration, backup, restore, Wi-Fi
// wake, the slot writer) runs unchanged on either.
import Foundation

public protocol FujiBLECamera: GATTClient {
    /// Only the in-process fake has no radio and can exercise unvalidated settings-file writes.
    var isSimulated: Bool { get }
    func power() async -> BluetoothPower
    func scan(for duration: Duration) async throws -> [FujiBLESighting]
    /// Basic bodies (fw 1.10/1.11): listen for the SWITCHED-OFF camera's standby advert (.basicStandby: 02 + the
    /// registered key) and remember that key so the next `connect()` presents it (docs/FUJIFILM-PROTOCOL.md §3.4, Python
    /// `fuji_ble adopt`). Only listens. Throws `FujiBLEError.notFound` on timeout.
    func adoptRegisteredKey(timeout: Duration) async throws -> AdoptedKey
    /// Find the camera, connect and run the per-connection handshake. `pairing`: the camera is in PAIRING REGISTRATION
    /// (basic: take the fresh key from its advert; secure: OS bond, 6-digit code on both sides).
    @discardableResult func connect(pairing: Bool, timeout: Duration) async throws -> FujiBLEFlows.Registration
    /// Keys: device_name, model, firmware (when the body has the standard characteristics).
    func identity() async -> [String: String]
    func disconnect()
    /// What this device remembers about its camera (nil = never paired or adopted here).
    var remembered: RememberedBLECamera? { get }
    /// Drop everything remembered (the next connect needs PAIRING REGISTRATION or a new adopt).
    func forget()
    /// The GATT table discovered on the open link (empty when not connected), for Camera Check's fingerprint.
    func gattTable() async -> [GATTEntry]
}

/// One discovered characteristic. CoreBluetooth reports no maximum lengths, so a fingerprint covers UUID + properties.
public struct GATTEntry: Codable, Sendable, Equatable, Hashable {
    public var service: String
    public var characteristic: String
    /// "read", "write", "writeWithoutResponse", "notify", "indicate", … sorted.
    public var properties: [String]

    public init(service: String, characteristic: String, properties: [String]) {
        self.service = FujiBLE.normalize(service)
        self.characteristic = FujiBLE.normalize(characteristic)
        self.properties = properties.sorted()
    }
}

/// A registered key received from a switched-off basic body.
public struct AdoptedKey: Sendable, Equatable {
    public var name: String
    public var token: Data
    public var peripheralID: UUID?

    public init(name: String, token: Data, peripheralID: UUID?) {
        self.name = name
        self.token = token
        self.peripheralID = peripheralID
    }
}

/// The camera this device talks to, as remembered between launches.
public struct RememberedBLECamera: Codable, Sendable, Equatable {
    public var peripheralID: UUID?
    public var name: String
    /// "basic" | "secure" ("" before the first successful handshake).
    public var mode: String
    /// Basic bodies: the 4-byte pairing key, hex.
    public var tokenHex: String?
    /// Secure bodies: the identification number written on every connection.
    public var identificationNumber: UInt32?
    /// True when the key came from `adoptRegisteredKey` (the key the phone's app registered), not a fresh PAIRING REGISTRATION.
    public var adopted: Bool

    /// `mode` as a profile (it is set from the advert / registration, never from a firmware string).
    public var profile: FujiBLEProfile { FujiBLEProfile(rawValue: mode) ?? .unknown }

    public init(peripheralID: UUID?, name: String, mode: String, tokenHex: String?, identificationNumber: UInt32?, adopted: Bool) {
        self.peripheralID = peripheralID
        self.name = name
        self.mode = mode
        self.tokenHex = tokenHex
        self.identificationNumber = identificationNumber
        self.adopted = adopted
    }
}

extension FujiBLECamera { public var isSimulated: Bool { false } }
