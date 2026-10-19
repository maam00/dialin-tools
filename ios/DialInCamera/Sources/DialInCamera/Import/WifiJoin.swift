// Putting this device on the camera's access point, and getting back off it.
//
// macOS (`MacWifiJoiner`): `networksetup -setairportnetwork <iface> <ssid> [password]`, interface from
//   `networksetup -listallhardwareports`. The camera's network has no internet, so the Mac is offline while joined.
//   Leaving: macOS 14.4+ redacts the current SSID (networksetup says "not associated", ipconfig shows <redacted>), so
//   when the previous network is unknown we power-cycle Wi-Fi and let macOS rejoin its preferred network.
// iOS (`HotspotWifiJoiner`, compiled under #if os(iOS), not exercised yet): NEHotspotConfiguration, hidden first then
//   visible, joinOnce. Ported from fuji-bridge FujiBridge/WifiJoin.swift (MIT, Copyright (c) 2026 Thomas Marchand).
//   The app needs the Hotspot Configuration capability (com.apple.developer.networking.HotspotConfiguration) and
//   NSLocalNetworkUsageDescription; iOS shows "“Dial In” wants to join Wi-Fi network “FUJIFILM-…”".
import Foundation
#if os(iOS)
import NetworkExtension
#endif

public enum CameraNetwork {
    /// IPv4 addresses on Wi-Fi-like interfaces (en*) in the same /24 as `host` (the camera hands out 192.168.0.x).
    /// fuji-bridge WifiJoin.swift `addresses(near:)`.
    public static func addresses(near host: String = FujiPTPIP.defaultHost, interface: String? = nil) -> Set<String> {
        let prefix = host.split(separator: ".").prefix(3).joined(separator: ".") + "."
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: Set<String> = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let e = p.pointee
            let name = String(cString: e.ifa_name)
            guard let addr = e.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), name.hasPrefix("en") else { continue }
            if let interface, name != interface { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            let text = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if text.hasPrefix(prefix) { found.insert(text) }
        }
        return found
    }

    /// Every IPv4 address on `interface` (to say which other network macOS moved Wi-Fi to).
    public static func allAddresses(interface: String) -> Set<String> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: Set<String> = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let e = p.pointee
            guard let addr = e.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: e.ifa_name) == interface else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            found.insert(String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return found
    }

    /// Waits until an address next to `host` appears that wasn't there `before`.
    public static func waitForAddress(near host: String = FujiPTPIP.defaultHost, interface: String? = nil,
                                      changedFrom before: Set<String> = [], timeout: Duration) async -> Set<String>? {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if Task.isCancelled { return nil }
            let now = addresses(near: host, interface: interface)
            if !now.isEmpty && now != before { return now }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return nil }
        } while ContinuousClock.now < deadline
        return nil
    }
}

#if os(macOS)
/// Joins and leaves Wi-Fi networks with `networksetup` (no entitlement, no Location permission needed).
public struct MacWifiJoiner: Sendable {
    public let interface: String
    private let log: @Sendable (String) -> Void

    public init(interface: String, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.interface = interface
        self.log = log
    }

    /// "en0": the device listed under "Hardware Port: Wi-Fi".
    public static func wifiInterface() -> String? {
        guard let out = try? run(["-listallhardwareports"]).output else { return nil }
        return parseWifiInterface(out)
    }

    static func parseWifiInterface(_ out: String) -> String? {
        let lines = out.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() where line.hasPrefix("Hardware Port:") {
            let port = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
            guard port == "Wi-Fi" || port == "AirPort" else { continue }
            if i + 1 < lines.count, lines[i + 1].hasPrefix("Device:") {
                return lines[i + 1].dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The network the Mac is on now, if macOS will say (often it won't: SSIDs are redacted without Location access).
    public func currentNetwork() -> String? {
        if let out = try? Self.run(["-getairportnetwork", interface]).output,
           let r = out.range(of: "Current Wi-Fi Network: ") {
            let name = out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if let out = try? Self.shell("/usr/sbin/ipconfig", ["getsummary", interface]).output {
            for line in out.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("SSID : ") {
                    let name = String(t.dropFirst("SSID : ".count))
                    if !name.isEmpty && name != "<redacted>" { return name }
                }
            }
        }
        return nil
    }

    public func preferredNetworks() -> [String] {
        guard let out = try? Self.run(["-listpreferredwirelessnetworks", interface]).output else { return [] }
        return out.components(separatedBy: .newlines).dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `networksetup -setairportnetwork`. It often exits 0 on failure, so the text decides; the caller should still
    /// wait for an address on the camera's subnet (`CameraNetwork.waitForAddress`).
    public func join(_ creds: CameraWifiCredentials) throws {
        var args = ["-setairportnetwork", interface, creds.ssid]
        if !creds.password.isEmpty { args.append(creds.password) }
        log("networksetup -setairportnetwork \(interface) \(creds.ssid)\(creds.password.isEmpty ? "" : " ••••")")
        let r = try Self.run(args)
        let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status != 0 || text.localizedCaseInsensitiveContains("could not") || text.localizedCaseInsensitiveContains("failed")
            || text.localizedCaseInsensitiveContains("error") {
            throw ImportError.wifiJoin("macOS couldn't join \(creds.ssid): \(text.isEmpty ? "exit \(r.status)" : text)")
        }
    }

    /// Back to the previous network: by name when known, else Wi-Fi off/on so macOS picks its preferred network.
    public func leave(cameraSSID: String, previous: String?) async {
        if let previous, previous != cameraSSID {
            log("rejoining \(previous)")
            if (try? join(CameraWifiCredentials(ssid: previous))) != nil { return }
            log("couldn't rejoin \(previous) by name; turning Wi-Fi off and on instead")
        } else {
            log("turning Wi-Fi off and on so macOS rejoins its usual network")
        }
        _ = try? Self.run(["-setairportpower", interface, "off"])
        try? await Task.sleep(for: .seconds(2))
        _ = try? Self.run(["-setairportpower", interface, "on"])
    }

    /// Drop the camera from the preferred list so the Mac doesn't hop onto it later. Usually needs admin rights;
    /// returns false (and the caller prints the sudo command) when refused.
    public func forget(_ ssid: String) -> Bool {
        guard let r = try? Self.run(["-removepreferredwirelessnetwork", interface, ssid]) else { return false }
        return r.status == 0 && !r.output.localizedCaseInsensitiveContains("error")
    }

    // MARK: Process

    struct Result { var status: Int32; var output: String }

    static func run(_ args: [String]) throws -> Result { try shell("/usr/sbin/networksetup", args) }

    static func shell(_ path: String, _ args: [String]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
#endif

#if os(iOS)
/// iPhone: joins the camera's network with NEHotspotConfiguration (system prompt, join once). Not exercised yet.
/// Requires the Hotspot Configuration capability. iOS won't join for a backgrounded app.
public enum HotspotWifiJoiner {
    public static func join(_ creds: CameraWifiCredentials, host: String = FujiPTPIP.defaultHost,
                            log: @Sendable (String) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        guard !creds.ssid.isEmpty else { throw ImportError.wifiJoin("The camera did not provide a Wi-Fi network name.") }
        let lease = HotspotJoinRegistry.shared.begin(creds.ssid)
        var succeeded = false
        defer {
            if !succeeded, HotspotJoinRegistry.shared.isCurrent(creds.ssid, lease) {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: creds.ssid)
            }
        }
        var lastError: ImportError?
        // Bluetooth-started APs hide their SSID; some firmware broadcasts it anyway, and a hidden join of a visible
        // network can fail: try the other way once (fuji-bridge).
        for hidden in creds.hidden ? [true, false] : [false, true] {
            try Task.checkCancellation()
            let cfg = creds.password.isEmpty
                ? NEHotspotConfiguration(ssid: creds.ssid)
                : NEHotspotConfiguration(ssid: creds.ssid, passphrase: creds.password, isWEP: false)
            cfg.hidden = hidden
            cfg.joinOnce = true
            do {
                try await apply(cfg, ssid: creds.ssid, lease: lease)
                log("iOS accepted \(creds.ssid) (\(hidden ? "hidden" : "visible"))")
            } catch let e as NSError where e.domain == NEHotspotConfigurationErrorDomain {
                switch NEHotspotConfigurationError(rawValue: e.code) {
                case .alreadyAssociated:
                    log("already on \(creds.ssid)")
                case .userDenied:
                    throw ImportError.wifiJoin("Joining \(creds.ssid) was cancelled.")
                default:
                    lastError = .wifiJoin("iOS couldn't join \(creds.ssid): \(e.localizedDescription)")
                    continue
                }
            }
            try Task.checkCancellation()
            // apply() returns when iOS accepts the configuration, not when the phone is on the network.
            // An unchanged DHCP address is valid after an alreadyAssociated answer. A stale pre-join address alone
            // is not evidence; confirm the current Wi-Fi interface and, when entitled, the SSID/BSSID.
            if await CameraNetwork.waitForAddress(near: host, interface: "en0", timeout: .seconds(15)) != nil {
                try Task.checkCancellation()
                if let network = await NEHotspotNetwork.fetchCurrent() {
                    try Task.checkCancellation()
                    guard network.ssid == creds.ssid else {
                        lastError = .wifiJoin("This iPhone is still on another Wi-Fi network. Join \(creds.ssid) and try again.")
                        continue
                    }
                    if !creds.bssid.isEmpty, network.bssid.lowercased() != creds.bssid.lowercased() {
                        throw ImportError.wifiJoin("This Wi-Fi network belongs to a different camera. Connect to \(creds.ssid) and try again.")
                    }
                }
                try Task.checkCancellation()
                succeeded = true
                return
            }
            try Task.checkCancellation()
            lastError = .wifiJoin("This iPhone didn't end up on \(creds.ssid).")
        }
        throw lastError ?? .wifiJoin("Couldn't join \(creds.ssid).")
    }

    /// Forget the camera network (joinOnce also drops it when the app leaves the foreground).
    public static func leave(_ ssid: String) {
        HotspotJoinRegistry.shared.invalidate(ssid)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }

    /// iOS may keep a system join prompt open after its task is cancelled. The late callback must not revive that
    /// network or remove a later session's configuration. A per-SSID lease identifies only this opening attempt.
    private static func apply(_ cfg: NEHotspotConfiguration, ssid: String, lease: UUID) async throws {
        let waiter = WirelessCallbackWait<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                guard waiter.install(cont) else { return }
                NEHotspotConfigurationManager.shared.apply(cfg) { error in
                    if waiter.isCancelled, HotspotJoinRegistry.shared.isCurrent(ssid, lease) {
                        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
                    }
                    if let error { waiter.finish(.failure(error)) } else { waiter.finish(.success(())) }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
            if HotspotJoinRegistry.shared.isCurrent(ssid, lease) {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            }
        }
    }
}

private final class HotspotJoinRegistry: @unchecked Sendable {
    static let shared = HotspotJoinRegistry()
    private let lock = NSLock()
    private var leases: [String: UUID] = [:]

    func begin(_ ssid: String) -> UUID {
        lock.withLock { let id = UUID(); leases[ssid] = id; return id }
    }

    func isCurrent(_ ssid: String, _ id: UUID) -> Bool { lock.withLock { leases[ssid] == id } }
    func invalidate(_ ssid: String) { lock.withLock { leases[ssid] = nil } }
}
#endif
