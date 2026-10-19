// Bluetooth → camera Wi-Fi: after the BLE registration (`FujiBluetoothLink.connect`, the package's BLE link), read the
// camera's SSID, ask it to start its access point for image viewing, read the password, and wait for "AP up".
//
// Ported from fuji-bridge FujiBridge/FujiBluetooth.swift `FujiWake.run` (MIT, Copyright (c) 2026 Thomas Marchand), which
// woke an X100VI (fw 1.32) this way, and libfuji lib/bluetooth.c:310-380 `fuji_bluetooth_connect_to_wifi` (MIT, Copyright
// (c) 2026 Daniel Cook):
// - SSID: read bf6dc9cf (Wi-Fi service 4e941240) before the launch.
// - FUNCTION_LAUNCH 600655e6 (service 6514eb81): 03 00 (image viewing) to import; libfuji's 04 00 is remote
//   shooting, and an X100VI then ignores an image-viewing client's init (fuji-bridge).
// - Password: read e809256a. Only secure-profile firmware has it (X100VI fw 1.31+, fffw gatt-ad14d4.yaml); on the
//   basic profile (fw 1.11, gatt-76ab62.yaml, and fw 1.10 as tested) it doesn't exist and libfuji joins an
//   open, visible network. With a password the SSID is hidden (libfuji sets is_hidden).
// - AP_STATE a68e3f66 (service 4c0020fe) indicates a u16 LE: 0x8001 launched (01 80), 0x8002 launching
//   (02 80: keep waiting), 0x8000 not launched (00 80: busy), 0x8003 launched for a reserved transfer
//   (docs/FUJIFILM-PROTOCOL.md §3.8). Older readings (01 up / 00 busy) still work. Busy: wait 200 ms and ask again (×3).
// - BSSID: the camera's Wi-Fi address 49a12959 ("-" separated), used as the BSSID when joining.
import Foundation

/// The camera's access point, as read over Bluetooth (or typed in by hand).
public struct CameraWifiCredentials: Sendable, Equatable, CustomStringConvertible {
    public var ssid: String
    /// Empty on older firmware: an open network.
    public var password: String
    /// Bluetooth-started APs on secure firmware hide their SSID.
    public var hidden: Bool
    /// The camera's Wi-Fi MAC from 49a12959, colon-separated; used as the BSSID when joining. Empty when the body
    /// doesn't expose it.
    public var bssid: String

    public init(ssid: String, password: String = "", hidden: Bool? = nil, bssid: String = "") {
        self.ssid = ssid
        self.password = password
        self.hidden = hidden ?? !password.isEmpty
        self.bssid = bssid
    }

    public var description: String {
        "\(ssid) (\(password.isEmpty ? "open" : "password \(password.count) chars")\(hidden ? ", hidden" : ""))"
    }
}

public enum FujiWifiWake {
    /// R/W/N 32: camera SSID.
    public static let ssidCharacteristic = "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4"
    /// R 20: Wi-Fi password (secure firmware only).
    public static let passwordCharacteristic = "e809256a-915c-4967-92e8-53b7d4cad213"
    /// FUNCTION_LAUNCH codes (fuji-bridge): 1 image import, 3 image viewing, 4 remote shooting.
    public static let inCameraViewing: UInt16 = 3
    public static let remoteShooting: UInt16 = 4

    /// Run over a registered GATT link. Throws `FujiBLEError.busy` after three busy answers.
    public static func run(_ gatt: any GATTClient, function: UInt16 = inCameraViewing, apTimeout: Duration = .seconds(12),
                           log: @Sendable (String) -> Void = { _ in }) async throws -> CameraWifiCredentials {
        try Task.checkCancellation()
        guard await gatt.has(ssidCharacteristic) else {
            throw FujiBLEError.missingCharacteristic("\(ssidCharacteristic) (camera Wi-Fi name); this body can't start its Wi-Fi over Bluetooth")
        }
        guard await gatt.has(FujiBLE.functionLaunch) else {
            throw FujiBLEError.missingCharacteristic("\(FujiBLE.functionLaunch) (function launch)")
        }
        await gatt.subscribe(FujiBLE.apState)
        let ssid = text(try await gatt.read(ssidCharacteristic))
        guard !ssid.isEmpty else { throw FujiBLEError.unexpected("The camera sent an empty Wi-Fi name.") }
        log("camera SSID \"\(ssid)\"")
        var password = ""
        if await gatt.has(passwordCharacteristic) {
            password = text(try await gatt.read(passwordCharacteristic))
            log(password.isEmpty ? "password characteristic empty" : "password: \(password.count) characters")
        } else {
            log("no password characteristic (older firmware): the network should be open")
        }
        var bssid = ""
        if await gatt.has(FujiBLE.cameraMacAddress), let mac = try? await gatt.read(FujiBLE.cameraMacAddress) {
            bssid = text(mac).replacingOccurrences(of: "-", with: ":")
        }
        try Task.checkCancellation()
        // Credential reads can deliver a subscription's initial cached AP value. Drain immediately before this
        // launch so it is not mistaken for the new image-viewing AP becoming ready.
        for v in await gatt.drain(FujiBLE.apState) { log("dropped stale AP state \(v.hexString)") }
        let code = PTPPack.u16(Int(function))
        try await gatt.write(FujiBLE.functionLaunch, code)
        log("asked the camera to start its Wi-Fi (FUNCTION_LAUNCH \(code.hexString))")
        var busy = 0
        var deadline = ContinuousClock.now + apTimeout
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, let answer = await gatt.nextValue(FujiBLE.apState, timeout: remaining) else {
                try Task.checkCancellation()
                log("no AP-state answer within \(apTimeout); trying the network anyway")
                break
            }
            log("AP state \(answer.hexString)")
            guard let up = FujiBLE.apStateUp(answer) else { continue }  // 0x8002 Launching: wait for Launched
            if up { break }
            busy += 1
            if busy >= 3 { throw FujiBLEError.busy }
            try await Task.sleep(for: .milliseconds(200))
            try await gatt.write(FujiBLE.functionLaunch, code)
            deadline = ContinuousClock.now + apTimeout
            log("asked again after a busy answer (\(busy))")
        }
        try Task.checkCancellation()
        return CameraWifiCredentials(ssid: ssid, password: password, bssid: bssid)
    }

    /// NUL-padded fixed-size string fields.
    static func text(_ d: Data) -> String {
        String(decoding: d.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
