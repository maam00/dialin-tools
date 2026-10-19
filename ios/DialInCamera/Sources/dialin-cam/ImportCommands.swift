// dialin-cam import-*: copy today's X100VI photos to ~/Pictures/Dial In/<YYYY-MM-DD>/ without taking the SD card out.
// The engine is the DialInCamera library's PhotoImporter (the iPhone app reuses it); this file is only the Mac glue:
// argument parsing, printing, and (for Wi-Fi) Bluetooth wake + joining/leaving the camera's network.
// Runbook: ios/DialInCamera/IMPORT.md.
#if os(macOS)
import DialInCamera
import Foundation
import Synchronization

@MainActor
enum ImportCLI {
    static let commands: Set<String> = ["import-usb", "import-wifi", "import-folder", "import-photos"]

    static let usage = """
        dialin-cam import-usb    [--since YYYY-MM-DD | --all] [--thumbs-only] [--ptp]
            Camera: CONNECTION MODE › USB CARD READER, USB-C data cable. Copies today's JPEG/RAF/HEIF.
        dialin-cam import-wifi   [--ssid NAME [--password PW]] [--pair] [--since …] [--thumbs-only]
            Camera Wi-Fi. Bluetooth wakes it (paired Mac), or pass --ssid/--password. The Mac is offline while joined.
            --no-join (already on the camera network)  --keep-network  --interface en0  --client-state 20  --function 3
            --local-ip A.B.C.D  (init packet's own-address field; default: this Mac's address on the camera network,
                                 accepted by an X100VI fw 1.10; 0.0.0.0 = the zeros older tools send)
            --rehearse  (whole path against a built-in fake camera on 127.0.0.1; changes nothing)
        dialin-cam import-folder <dir> [--since …]    an SD card in a reader (/Volumes/…/DCIM) or an Image Capture folder
        dialin-cam import-photos [--since …] [--deep]  X100VI photos already in this Mac's Photos library
        common: --dest <dir> (default ~/Pictures/Dial In)  --no-raw  --movies  --no-thumbs  --dry-run  --limit N
                --last N (only the newest N files on the card, any date; RAF and JPEG count separately)
                --reimport  --timeout <s> (wait for the camera, default 60)  --catalog <s> (USB card listing, default 180)
                --verbose  --result-file <new JSON file> (machine summary, including partial transfers)
        """

    struct Args {
        var command = ""
        var positional: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var invalid: [String] = []

        static let valued: Set<String> = [
            "--since", "--dest", "--ssid", "--password", "--interface", "--host", "--port", "--name", "--timeout",
            "--catalog", "--client-state", "--function", "--limit", "--local-ip", "--last", "--result-file",
        ]

        init(_ argv: [String]) {
            var it = argv.makeIterator()
            while let a = it.next() {
                if Self.valued.contains(a) {
                    if values[a] != nil { invalid.append("duplicate \(a)") }
                    let value = it.next() ?? ""
                    if value.isEmpty || value.hasPrefix("--") { invalid.append("missing value for \(a)") }
                    values[a] = value
                } else if a.hasPrefix("-") {
                    flags.insert(a == "-v" ? "--verbose" : a)
                } else if command.isEmpty {
                    command = a
                } else {
                    positional.append(a)
                }
            }
        }

        var verbose: Bool { flags.contains("--verbose") }
        func int(_ k: String) -> Int? { values[k].flatMap { Int($0) } }
        func seconds(_ k: String, _ d: Int) -> Duration { .seconds(int(k) ?? d) }

        func validate() throws {
            let commonFlags: Set<String> = ["--all", "--no-raw", "--movies", "--no-thumbs", "--thumbs-only", "--dry-run", "--reimport", "--verbose"]
            let commonValues: Set<String> = ["--since", "--dest", "--limit", "--last", "--result-file"]
            let routeFlags: Set<String> = command == "import-wifi" ? ["--pair", "--no-join", "--keep-network", "--rehearse"] : command == "import-usb" ? ["--ptp"] : command == "import-photos" ? ["--deep"] : []
            let routeValues: Set<String> = command == "import-wifi" ? ["--ssid", "--password", "--interface", "--host", "--port", "--name", "--timeout", "--client-state", "--function", "--local-ip"] : command == "import-usb" ? ["--timeout", "--catalog"] : []
            let unknown = flags.subtracting(commonFlags.union(routeFlags)).union(Set(values.keys).subtracting(commonValues.union(routeValues)))
            guard invalid.isEmpty, unknown.isEmpty else { throw ImportError.invalid("Invalid import options: \((invalid + unknown.sorted()).joined(separator: ", ")). No device contacted.") }
            guard positional.count == (command == "import-folder" ? 1 : 0) else { throw ImportError.invalid("Only import-folder takes exactly one source folder.") }
            for key in ["--limit", "--last", "--timeout", "--catalog", "--port", "--function", "--client-state"] {
                if let raw = values[key] {
                    let maximum = ["--port", "--function"].contains(key) ? 65535 : 100000
                    guard let n = Int(raw), n > 0, n <= maximum else { throw ImportError.invalid("\(key) must be 1–\(maximum).") }
                }
            }
            guard !(flags.contains("--all") && values["--since"] != nil) else { throw ImportError.invalid("Choose --all or --since, not both.") }
            if flags.contains("--rehearse") && (flags.contains("--pair") || flags.contains("--keep-network") || flags.contains("--no-join") || !Set(values.keys).isDisjoint(with: routeValues)) {
                throw ImportError.invalid("Rehearsal cannot accept pairing or live network options.")
            }
            if let path = values["--result-file"], FileManager.default.fileExists(atPath: path) { throw ImportError.invalid("Result file exists; choose a new file.") }
            if let ip = values["--local-ip"], FujiPTPIP.ipv4(ip) == nil { throw ImportError.invalid("--local-ip must be an IPv4 address.") }
        }
    }

    static func run(_ argv: [String]) async throws {
        let a = Args(argv)
        if a.flags.contains("--help") || a.flags.contains("-h") {
            print(usage)
            return
        }
        try a.validate()
        _ = try options(a) // Reject dates and counts BEFORE connecting, pairing or changing networks.
        switch a.command {
        case "import-usb": try await usb(a)
        case "import-wifi": try await wifi(a)
        case "import-folder": try await folder(a)
        case "import-photos": try await photos(a)
        default: throw ImportError.invalid("unknown import command \(a.command)\n\n\(usage)")
        }
    }

    // MARK: Routes

    static func usb(_ a: Args) async throws {
        let library = try library(a)
        print("USB import. Camera on, MENU › NETWORK/USB SETTING › CONNECTION MODE › USB CARD READER, USB-C data cable.")
        print("If Photos or Image Capture opens, quit it. Waiting up to \(a.seconds("--timeout", 60)) for the camera…")
        let say: @Sendable (String) -> Void = { print("  · \($0)") }
        if a.flags.contains("--ptp") {
            // Raw PTP through ImageCaptureCore: fuji-bridge's measured path (GetObjectHandles + GetPartialObject).
            let transport = ImageCaptureTransport(catalogTimeout: a.seconds("--catalog", 180), commandTimeout: .seconds(30))
            transport.trace = a.verbose ? say : { line in if !line.contains("PTP 0x") { say(line) } }
            try await transport.open(timeout: a.seconds("--timeout", 60))
            print("connected: \(transport.cameraName ?? "camera") (raw PTP)")
            let card = PTPCardSource(transport: transport, layout: .standard, route: .usb, log: say)
            do {
                try report(try await importRun(card, a, library), a)
            } catch {
                await card.close()
                await transport.close()
                throw error
            }
            await card.close()
            await transport.close()
        } else {
            let src = ImageCaptureFileSource(deviceTimeout: a.seconds("--timeout", 60), catalogTimeout: a.seconds("--catalog", 180))
            src.trace = say
            do {
                do {
                    try await src.connect()
                } catch let e as ImportError {
                    if case .noCamera = e, let card = cardVolumes().first {
                        throw ImportError.noCamera("\(e.description)\nA memory card is mounted at \(card.path): dialin-cam import-folder \"\(card.path)\"")
                    }
                    throw e
                }
                print("connected: \(src.cameraName ?? "camera")")
                if !src.catalogComplete {
                    print("  ! the camera hadn't finished listing its card; today's photos may be missing. If so: --catalog 600, or --ptp")
                }
                try report(try await importRun(src, a, library), a)
            } catch {
                await src.close()
                throw error
            }
            await src.close()
        }
    }

    static func wifi(_ a: Args) async throws {
        let rehearse = a.flags.contains("--rehearse")
        var host = a.values["--host"] ?? FujiPTPIP.defaultHost
        var port = UInt16(a.int("--port") ?? Int(FujiPTPIP.commandPort))
        let name = a.values["--name"] ?? "Dial In"
        let say: @Sendable (String) -> Void = { print("  · \($0)") }
        var fake: FakeFujiWifiCamera?
        var a = a
        if rehearse {
            var b = FakeFujiWifiCamera.Behavior()
            b.initFailFirst = true          // the body's usual first-init refusal
            b.okAfterPolls = 3              // "press OK" for ~1 s
            b.dropAfterPartialBytes = 450_000   // one Wi-Fi drop mid-file, to exercise reconnect + resume
            b.dateCreatedOverride = "2"         // like the real X100VI fw 1.10: dates come from each file's EXIF
            let f = FakeFujiWifiCamera(frames: FakeFujiWifiCamera.sampleCard(), behavior: b)
            port = try await f.start()
            host = "127.0.0.1"
            fake = f
            if a.values["--dest"] == nil {
                a.values["--dest"] = FileManager.default.temporaryDirectory.appendingPathComponent("dialin-rehearsal-\(Int(Date().timeIntervalSince1970))").path
            }
            print("REHEARSAL: fake X100VI on 127.0.0.1:\(port) (3 photos today + 1 RAF, 2 from yesterday). No Bluetooth, no network change.")
        }
        let library = try library(a)
        let join = !rehearse && !a.flags.contains("--no-join") && host == FujiPTPIP.defaultHost
        var creds = a.values["--ssid"].map { CameraWifiCredentials(ssid: $0, password: a.values["--password"] ?? "") }
        var ble: FujiBluetoothLink?
        var joiner: MacWifiJoiner?
        var keeper: CameraNetworkKeeper?
        var watchdog: Task<Void, Never>?
        savedThisRun.withLock { $0 = 0 }
        var previous: String?
        var preferredBefore: [String] = []
        var failure: (any Error)?

        do {
            // (a) Bluetooth: wake the camera's Wi-Fi and read its name/password.
            if join && creds == nil {
                try BLETrialCLI.requireNoUSBCamera()
                let link = FujiBluetoothLink(clientName: name, log: say)
                ble = link
                if a.flags.contains("--pair") {
                    print("Pairing: camera MENU › NETWORK/USB SETTING › Bluetooth/SMARTPHONE SETTING › PAIRING REGISTRATION; confirm the same code on the camera and this Mac.")
                } else {
                    print("Bluetooth: looking for the paired camera (camera on, Bluetooth ON)…")
                }
                do {
                    try await link.connect(pairing: a.flags.contains("--pair"))
                } catch let e as FujiBLEError {
                    throw ImportError.wifiJoin("""
                        Bluetooth: \(e.description)
                        Options: pair this Mac once (dialin-cam import-wifi --pair), or skip Bluetooth with --ssid/--password \
                        if you know the camera's network, or use USB: dialin-cam import-usb. (IMPORT.md › Wi-Fi › If Bluetooth won't connect)
                        """)
                }
                let function = UInt16(a.int("--function") ?? Int(FujiWifiWake.inCameraViewing))
                creds = try await FujiWifiWake.run(link, function: function, log: say)
                print("Camera Wi-Fi credentials received (kept private).")
            }

            // (b) Join the camera's network (macOS).
            if join, let creds {
                guard let iface = a.values["--interface"] ?? MacWifiJoiner.wifiInterface() else {
                    throw ImportError.wifiJoin("No Wi-Fi interface found (networksetup -listallhardwareports). Pass --interface en0.")
                }
                let j = MacWifiJoiner(interface: iface, log: say)
                joiner = j
                previous = j.currentNetwork()
                preferredBefore = j.preferredNetworks()
                print("Joining \(creds.ssid) on \(iface). This Mac has NO INTERNET until the import ends; it goes back to \(previous ?? "your usual Wi-Fi") afterwards.")
                print("  (If macOS hops back to your usual Wi-Fi mid-import, this command re-joins the camera within ~1 s, up to \(CameraNetworkKeeper.maxRejoins) times. Saved networks are never changed.)")
                let before = CameraNetwork.addresses(near: host, interface: iface)
                var waitFor: Duration = .seconds(30)
                do {
                    try j.join(creds)
                } catch {
                    print("  ! \(error)")
                    print("  Join it by hand now using the camera's network details. The Wi-Fi password is not printed in logs. Waiting 2 minutes…")
                    waitFor = .seconds(120)
                }
                if let got = await CameraNetwork.waitForAddress(near: host, interface: iface, changedFrom: before, timeout: waitFor) {
                    print("on the camera's network: \(got.sorted().joined(separator: ", "))")
                } else if !before.isEmpty {
                    print("  ! this Mac already had a 192.168.0.x address before joining; trying the camera anyway")
                } else {
                    throw ImportError.wifiJoin("This Mac never got an address on \(creds.ssid). Is the camera still showing its Wi-Fi screen? Run again, or use USB.")
                }
            } else if !rehearse && !join {
                print("Assuming this Mac is already on the camera's Wi-Fi (\(host)).")
            }

            // (c)–(e) PTP/IP session, list, thumbnails, files, close.
            let rejoin: (@Sendable () async -> Bool)?
            if let j = joiner, let c = creds {
                let k = CameraNetworkKeeper(joiner: j, creds: c, host: host, say: say)
                keeper = k
                rejoin = { await k.ensure(timeout: .seconds(20)) }
            } else {
                rejoin = nil
            }
            if let ip = a.values["--local-ip"], FujiPTPIP.ipv4(ip) == nil { throw ImportError.invalid("--local-ip \(ip) isn't an IPv4 address") }
            let config = FujiWifiCamera.Config(transport: .init(host: host, port: port, clientName: name, localIP: a.values["--local-ip"]),
                                               clientState: a.int("--client-state") ?? FujiWifiProp.clientStateGallery)
            let cam = FujiWifiCamera(config: config, log: say, prompt: { print("  → \($0)") }, rejoin: rejoin)
            if a.verbose { await cam.setTrace({ print("    \($0)") }) }
            // Watchdog for the whole session: re-join the camera's network the moment macOS leaves it, keep an idle
            // PTP/IP session warm, and say if the Bluetooth link drops (no Bluetooth traffic is added).
            let k = keeper, link = ble
            watchdog = Task {
                var bleWasUp = true
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { break }
                    if let k, !(await k.isOnCameraNetwork()) {
                        _ = await k.ensure(timeout: .seconds(20))
                        continue
                    }
                    await cam.keepAlive(idle: .seconds(3))
                    if let link {
                        let up = await link.isLinkUp
                        if bleWasUp && !up { say("note: the Bluetooth link to the camera dropped (Wi-Fi continues; not reconnecting it)") }
                        bleWasUp = up
                    }
                }
            }
            do {
                let g = try await cam.connect()
                print("connected to \(g.cameraName ?? "the camera") over Wi-Fi: \(g.handles.count) photos on the card"
                      + (g.clientState == nil ? " (camera refused gallery mode; trying anyway)" : ""))
                try report(try await importRun(cam, a, library), a)
            } catch {
                failure = error
            }
            watchdog?.cancel()
            await watchdog?.value
            await cam.close()
        } catch {
            failure = error
        }
        watchdog?.cancel()

        ble?.disconnect()
        if let j = joiner, let c = creds, !a.flags.contains("--keep-network") {
            await j.leave(cameraSSID: c.ssid, previous: previous)
            if !preferredBefore.contains(c.ssid), j.preferredNetworks().contains(c.ssid), !j.forget(c.ssid) {
                print("  tip: so the Mac never hops onto the camera later: sudo networksetup -removepreferredwirelessnetwork \(j.interface) \"\(c.ssid)\"")
            }
            let back = await CameraNetwork.waitForAddress(near: "192.168.0.1", interface: j.interface, timeout: .seconds(1))
            print(back == nil ? "Wi-Fi handed back to macOS." : "Wi-Fi handed back to macOS (it may take a few seconds to rejoin your network).")
        }
        fake?.stop()
        if let failure {
            let saved = savedThisRun.withLock { $0 }
            let rejoins: Int
            if let keeper { rejoins = await keeper.rejoins } else { rejoins = 0 }
            print("""

                Wi-Fi import did not finish: \(failure)
                  Saved this run: \(saved) file(s)\(saved > 0 ? " (complete, listed in manifest.json)" : ""). Half-copied files stay in .incoming and resume.
                  Re-joins of the camera's network this run: \(rejoins) of \(CameraNetworkKeeper.maxRejoins).
                  Next: USB cable out of the camera, camera on the shooting screen (half-press), Bluetooth ON, then run the same command again.
                """)
            throw failure
        }
    }

    static func folder(_ a: Args) async throws {
        guard let path = a.positional.first else { throw ImportError.invalid("import-folder needs a folder, e.g. /Volumes/Untitled/DCIM") }
        let library = try library(a)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard url.standardizedFileURL.path != library.root.standardizedFileURL.path else { throw ImportError.invalid("That's the import folder itself.") }
        try report(try await importRun(FolderSource(root: url), a, library), a)
    }

    static func photos(_ a: Args) async throws {
        let library = try library(a)
        print("Photos library: looking for X100VI photos (EXIF Make FUJIFILM, Model X100VI). macOS may ask to allow Photos access for your terminal.")
        let src = PhotoLibrarySource(deepScan: a.flags.contains("--deep"), log: { print("  · \($0)") })
        try report(try await importRun(src, a, library), a)
    }

    // MARK: Shared

    /// Mounted volumes with a DCIM folder (an SD card in a reader, or a camera that mounts as a disk).
    static func cardVolumes() -> [URL] {
        let fm = FileManager.default
        let vols = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return vols.map { URL(fileURLWithPath: "/Volumes").appendingPathComponent($0).appendingPathComponent("DCIM") }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    static func library(_ a: Args) throws -> ImportLibrary {
        if let d = a.values["--dest"] { return ImportLibrary(root: URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)) }
        return ImportLibrary()
    }

    static func options(_ a: Args) throws -> ImportOptions {
        var since: String? = ImportDay.today()
        var last: Int?
        if let text = a.values["--last"] {
            guard let n = Int(text), n > 0 else { throw ImportError.invalid("--last wants a positive number of files, got \(text)") }
            last = n
        }
        if a.flags.contains("--all") {
            since = nil
        } else if let s = a.values["--since"] {
            guard let d = ImportDay.parse(s) else { throw ImportError.invalid("--since wants YYYY-MM-DD (or today / yesterday), got \(s)") }
            since = d
        } else if last != nil {
            since = nil     // --last alone: the newest N files whatever their date
        }
        return ImportOptions(since: since, thumbnails: !a.flags.contains("--no-thumbs"), thumbsOnly: a.flags.contains("--thumbs-only"),
                             includeRAW: !a.flags.contains("--no-raw"), includeMovies: a.flags.contains("--movies"),
                             includeUndated: a.flags.contains("--all") || (last != nil && since == nil), dryRun: a.flags.contains("--dry-run"),
                             reimport: a.flags.contains("--reimport"), limit: a.int("--limit"), last: last)
    }

    static func importRun(_ src: any PhotoSource, _ a: Args, _ library: ImportLibrary) async throws -> ImportSummary {
        let opts = try options(a)
        let verbose = a.verbose
        print("into \(library.root.path)/<date>/ · "
              + (opts.last.map { "the newest \($0) file(s) on the card" + (opts.since.map { " from \($0) on" } ?? "") }
                 ?? opts.since.map { "photos from \($0) on" } ?? "every date on the card")
              + (opts.thumbsOnly ? " · previews only" : "") + (opts.dryRun ? " · DRY RUN (nothing is copied)" : ""))
        let counter = Mutex((index: 0, of: 0, lastPrint: 0))
        return try await PhotoImporter.run(source: src, library: library, options: opts) { event in
            switch event {
            case .note(let s):
                if verbose || !s.hasPrefix("looking for") { print("  · \(s)") }
            case .listed(let n):
                print("  the camera lists \(n) files")
            case .planned(let p):
                var parts = ["\(p.toFetch) new", "\(p.already) already imported"]
                if p.tooOld > 0 { parts.append("\(p.tooOld) from earlier days") }
                if p.otherKinds > 0 { parts.append("\(p.otherKinds) other files skipped") }
                if p.undated > 0 { parts.append("\(p.undated) without a date") }
                print("  found " + parts.joined(separator: " · "))
            case .thumbnail(let item, let url):
                if verbose { print("  preview \(item.name) → \(url.path)") }
            case .downloading(let item, let i, let n):
                counter.withLock { $0.index = i; $0.of = n; $0.lastPrint = 0 }
                print("  downloading [\(i)/\(n)] \(item.name)" + (item.size.map { String(format: " (%.1f MB)…", Double($0) / 1_048_576) } ?? "…"))
            case .progress(let item, let bytes, let total):
                guard verbose, let total, total > 0 else { return }
                let pct = bytes * 100 / total
                let show = counter.withLock { c -> Bool in
                    if pct >= c.lastPrint + 25 { c.lastPrint = pct; return true }
                    return false
                }
                if show { print("    \(item.name) \(pct)%") }
            case .saved(let item, let url, let bytes, let secs):
                let (i, n) = counter.withLock { ($0.index, $0.of) }
                savedThisRun.withLock { $0 += 1 }
                let mb = Double(bytes) / 1_048_576
                print(String(format: "  [%d/%d] %@  %.1f MB  %.1fs  %.2f MB/s  → %@", i, n, item.name, mb, secs, secs > 0 ? mb / secs : 0,
                             url.deletingLastPathComponent().lastPathComponent))
            case .skipped(let item, let why):
                print("  skip \(item.name): \(why)")
            case .failed(let item, let why):
                print("  FAILED \(item.name): \(why)")
            }
        }
    }

    static func report(_ s: ImportSummary, _ a: Args) throws {
        if let path = a.values["--result-file"] {
            // A provisional undated folder can hold thumbnails only, before EXIF dates the originals.
            // Only hand original-bearing folders to photo preparation; retain preview locations separately.
            let originals = s.folders.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            let result: [String: Any] = [
                "schema_version": "dialin.import-summary.v1", "route": s.route.rawValue,
                "saved": s.saved.count, "bytes": s.bytes, "seconds": s.seconds, "thumbnails": s.thumbnails,
                "folders": originals.map(\.path), "preview_folders": s.folders.filter { !originals.contains($0) }.map(\.path),
                "planned": s.plan.toFetch, "already_imported": s.plan.already,
                "failures": s.failures.map { ["name": $0.name, "reason": $0.reason] },
                "interrupted": s.interrupted, "interruption": s.interruption as Any? ?? NSNull(),
                "dry_run": a.flags.contains("--dry-run"), "rehearsal": a.flags.contains("--rehearse"),
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: [.withoutOverwriting])
        }
        if s.plan.toFetch == 0 {
            if s.plan.inRange == 0 && s.plan.tooOld > 0 {
                print("Nothing from that date on the camera (\(s.plan.tooOld) older photos). Try --since YYYY-MM-DD or --all.")
            } else {
                print("Nothing new to copy.")
            }
            return
        }
        let mb = Double(s.bytes) / 1_048_576
        print(String(format: "done in %.0fs: %d saved (%.0f MB, %.2f MB/s overall), %d previews%@", s.seconds, s.saved.count, mb,
                     s.seconds > 0 ? mb / s.seconds : 0, s.thumbnails, s.failures.isEmpty ? "" : ", \(s.failures.count) failed"))
        for f in s.folders {
            print("  open \"\(f.path)\"")
            if s.saved.isEmpty && s.thumbnails > 0 { print("  open \"\(f.appendingPathComponent(".thumbs").path)\"   (previews)") }
        }
        if s.interrupted {
            throw ImportError.incomplete("Stopped early (\(s.interruption ?? "camera lost")). Run the same command again: finished files are kept and a half-copied one resumes.")
        }
        if !s.failures.isEmpty {
            throw ImportError.incomplete("\(s.failures.count) file(s) didn't make it: " + s.failures.map { "\($0.name) (\($0.reason))" }.joined(separator: "; "))
        }
    }

    /// Files saved by the current command (for the final message when it stops early).
    nonisolated static let savedThisRun = Mutex(0)
}

/// Keeps this Mac on the camera's access point for the session: when macOS moves Wi-Fi elsewhere (e.g. auto-joining
/// a saved network that has internet), re-join the camera at once. One re-join at a time, bounded per command. It never
/// edits, removes or reorders saved networks.
actor CameraNetworkKeeper {
    static let maxRejoins = 6
    let joiner: MacWifiJoiner
    let creds: CameraWifiCredentials
    let host: String
    let say: @Sendable (String) -> Void
    private(set) var rejoins = 0
    private var inFlight: Task<Bool, Never>?

    init(joiner: MacWifiJoiner, creds: CameraWifiCredentials, host: String, say: @escaping @Sendable (String) -> Void) {
        self.joiner = joiner
        self.creds = creds
        self.host = host
        self.say = say
    }

    func isOnCameraNetwork() -> Bool { !CameraNetwork.addresses(near: host, interface: joiner.interface).isEmpty }

    /// True when the Mac is (back) on the camera's network.
    func ensure(timeout: Duration) async -> Bool {
        if isOnCameraNetwork() { return true }
        if let inFlight { return await inFlight.value }
        guard rejoins < Self.maxRejoins else {
            say("not re-joining \(creds.ssid) again: \(Self.maxRejoins) re-joins already this run")
            return false
        }
        rejoins += 1
        let elsewhere = CameraNetwork.allAddresses(interface: joiner.interface).sorted()
        say("this Mac left the camera's network" + (elsewhere.isEmpty ? "" : " (Wi-Fi now has \(elsewhere.joined(separator: ", ")); macOS likely auto-joined another saved network)")
            + "; re-joining \(creds.ssid) now (\(rejoins) of \(Self.maxRejoins))")
        let (j, c, h, say) = (joiner, creds, host, say)
        let task = Task<Bool, Never> {
            do { try j.join(c) } catch { say("re-join: \(error)") }
            let ok = await CameraNetwork.waitForAddress(near: h, interface: j.interface, timeout: timeout) != nil
            say(ok ? "back on \(c.ssid)" : "still not on \(c.ssid) after \(timeout)")
            return ok
        }
        inFlight = task
        let ok = await task.value
        inFlight = nil
        return ok
    }
}
#endif
