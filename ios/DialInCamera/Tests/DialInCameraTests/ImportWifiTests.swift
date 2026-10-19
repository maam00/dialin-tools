// Wi-Fi import against the in-process fake X100VI over real loopback TCP. The byte layouts come from libfuji
// (lib/fujiptp.h, lib/fuji.c, lib/data.c; MIT, Copyright (c) 2026 Daniel Cook) and fuji-bridge (FujiBridge/Bytes.swift,
// Session.swift, VirtualBody.swift, tools/fakecam.py; MIT, Copyright (c) 2026 Thomas Marchand), cited per test.
import Foundation
import Synchronization
import Testing
@testable import DialInCamera

private let day = "2026-10-09"

@Suite("Wi-Fi import (PTP/IP)", .serialized)
struct ImportWifiTests {
    // MARK: Packets

    @Test("Init packet: exactly 82 bytes, Fuji version before the GUID, UTF-16LE name at 28 (libfuji fuji.c:502-514)")
    func initPacket() {
        let p = FujiPTPIP.initPacket(clientName: "Dial In")
        #expect(p.count == 82)
        #expect(p.prefix(28).hexString == "52000000" + "01000000" + "f2e4538f" + "ada5485d" + "87b27f0b" + "d3d5ded0" + "00000000")
        #expect(p.subdata(in: 28..<42) == Data("Dial In".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
        #expect(p.subdata(in: 42..<82).allSatisfy { $0 == 0 })
        // A long name is cut so a UTF-16 NUL still ends the field (fuji-bridge Packets.initCommand).
        let long = FujiPTPIP.initPacket(clientName: String(repeating: "A", count: 40))
        #expect(long.count == 82)
        #expect(long[80] == 0 && long[81] == 0)
        #expect(long[78] == 0x41)
    }

    @Test("Init packet carries our IPv4 at 24–27 (192.168.0.2 → 02 00 a8 c0, docs/FUJIFILM-PROTOCOL.md §5.3)")
    func initPacketIP() throws {
        let ip = try #require(FujiPTPIP.ipv4("192.168.0.2"))
        #expect(ip == 0xC0A8_0002)
        let p = FujiPTPIP.initPacket(clientName: "Dial In", localIPv4: ip)
        #expect(p.count == 82 && p.subdata(in: 24..<28) == Data([0x02, 0x00, 0xA8, 0xC0]))
        var zeros = FujiPTPIP.initPacket(clientName: "Dial In")
        zeros.replaceSubrange(24..<28, with: [0x02, 0x00, 0xA8, 0xC0])
        #expect(p == zeros, "nothing else moves")
        #expect(FujiPTPIP.ipv4String(ip) == "192.168.0.2")
        for bad in ["192.168.0", "192.168.0.256", "a.b.c.d", "1.2.3.4.5", "", "1..2.3"] { #expect(FujiPTPIP.ipv4(bad) == nil, "\(bad)") }
    }

    @Test("Over TCP the init carries the socket's own address; localIP 0.0.0.0 sends the old zeros")
    func initIPOverTCP() async throws {
        let fake = FakeFujiWifiCamera(frames: [])
        let port = try await fake.start()
        defer { fake.stop() }
        let auto = FujiPTPIPTransport(config: .init(host: "127.0.0.1", port: port, connectTimeout: .seconds(3), readTimeout: .seconds(3)))
        try await auto.open(timeout: .seconds(3))
        #expect(await auto.localIPv4Sent == 0x7F00_0001)
        await auto.close()
        let legacy = FujiPTPIPTransport(config: .init(host: "127.0.0.1", port: port, connectTimeout: .seconds(3), readTimeout: .seconds(3),
                                                      localIP: "0.0.0.0"))
        try await legacy.open(timeout: .seconds(3))
        await legacy.close()
        let packets = fake.record.initPackets
        #expect(packets.count == 2)
        #expect(packets.first?.subdata(in: 24..<28) == Data([0x01, 0x00, 0x00, 0x7F]))
        #expect(packets.last == FujiPTPIP.initPacket(clientName: "Dial In"))
    }

    @Test("Init replies: ACK type 2 with the camera name at 28; Init Fail type 5 with a reason")
    func initReplies() {
        var ack = Data(count: 68)
        ack[0] = 0x44; ack[4] = 2
        ack.replaceSubrange(12..<28, with: FujiPTPIP.cameraGUID)
        for (i, u) in "X100VI".utf16.enumerated() { ack[28 + i * 2] = UInt8(u) }
        #expect(FujiPTPIP.parseInitReply(ack) == .ack(cameraName: "X100VI"))
        var fail = Data()
        fail.appendLE32(12); fail.appendLE32(5); fail.appendLE32(0x2019)
        #expect(FujiPTPIP.parseInitReply(fail) == .fail(reason: 0x2019))
        ack[12] ^= 1
        #expect(FujiPTPIP.parseInitReply(ack) == .unexpected(type: 2))
        ack.append(0)
        #expect(FujiPTPIP.parseInitReply(ack) == .unexpected(type: 2))
    }

    @Test("D212 change list: DF00 found wherever it sits (D222 first, fuji-bridge VirtualBody)")
    func events() {
        let d = FujiEvents.encode([(0xD222, 1802), (0xDF00, 2)])
        #expect(d.hexString == "0200" + "22d2" + "0a070000" + "00df" + "02000000")
        let ev = FujiEvents.parse(d)
        #expect(ev[0xDF00] == 2)
        #expect(ev[0xD222] == 1802)
        #expect(FujiEvents.parse(Data([0x05, 0x00, 0x22])).isEmpty)
    }

    @Test("Fujifilm Wi-Fi ObjectInfo: libfuji's captured bytes parse (size @13, name @52, date after it)")
    func libfujiObjectInfoSample() throws {
        // lib/data.c:77-82: the variable part of a real Fuji ObjectInfo, after the 52 fixed bytes.
        let sample = """
            0D 44 00 53 00 43 00 46 00 35 00 30 00 38 00 37 00 2E 00 4A 00 50 00 47 00
            00 00 10 32 00 30 00 31 00 35 00 30 00 35 00 32 00 34 00 54 00 30 00 31 00
            31 00 37 00 31 00 30 00 00 00 00 0E 4F 00 72 00 69 00 65 00 6E 00 74 00 61
            00 74 00 69 00 6F 00 6E 00 3A 00 31 00 00 00 0C 00 00 00 03 00 01 20 0E 00
            00 00 00
            """
        let tail = try #require(Data(hexString: sample.filter { !$0.isWhitespace }))
        var head = Data(count: 52)
        head[4] = 0x01; head[5] = 0x38              // 0x3801 EXIF/JPEG
        head[8] = 0x00; head[9] = 0x00; head[10] = 0x10   // fuji_max_partial_size 0x100000 @8
        let size: UInt32 = 6_123_456
        for k in 0..<4 { head[13 + k] = UInt8(size >> (8 * UInt32(k)) & 0xFF) }   // compressed_size @13 (unaligned)
        let info = try #require(PTPObjectInfo(head + tail, layout: .fujiWifi))
        #expect(info.filename == "DSCF5087.JPG")
        #expect(info.size == 6_123_456)
        #expect(info.captureDate == "20150524T011710")
        #expect(CaptureTime.parsePTP(info.captureDate!)?.iso == "2015-05-24T01:17:10")
        // The same bytes read with the USB layout take the size from offset 8 instead.
        #expect(PTPObjectInfo(head + tail, layout: .standard)?.size == 0x0010_0000)
    }

    // MARK: Whole import over TCP

    @Test("Import over TCP: Init Fail retried, OK wait, DF01 = 20, fast path, D226 2 → 0, files byte-identical, CloseSession + goodbye")
    func fullImport() async throws {
        var b = FakeFujiWifiCamera.Behavior()
        b.initFailFirst = true
        b.okAfterPolls = 2
        let run = try await WifiRun(behavior: b)
        defer { run.cleanup() }
        let summary = try await run.importAll()
        #expect(summary.saved.count == 4)                       // 3 JPEGs + 1 RAF today; 2 from yesterday left alone
        #expect(summary.plan.tooOld == 2)
        #expect(summary.thumbnails == 4)
        try run.expectFilesIdentical(summary)
        await run.cam.close()
        let r = try await run.recordAfterClose()

        // Init: refused once, sent again on the same socket (fuji-bridge wifiHandshake).
        #expect(r.initPackets.count == 2)
        #expect(r.connections == 1)
        // Bytes 24–27 carry our own address (here the loopback socket's, 127.0.0.1).
        #expect(r.initPackets.allSatisfy { $0 == FujiPTPIP.initPacket(clientName: "Dial In", localIPv4: 0x7F00_0001) })
        // OpenSession first, at transaction id 1 (libfuji fuji.c:369-372).
        #expect(r.commands.first?.op == PTP.Op.openSession)
        #expect(r.commands.first?.tid == 1)
        #expect(r.commands.first?.params == [1])
        #expect(r.openSessionTids == [1])
        // Transaction ids count up from there.
        let tids = r.commands.map(\.tid)
        #expect(tids == Array(1...UInt32(tids.count)))
        // OK wait: D212 polled until DF00 ≠ 0 (two "press OK" answers, then access), before DF01 is set.
        let df01 = try #require(r.commands.firstIndex { $0.op == PTP.Op.setDevicePropValue && $0.params == [0xDF01] })
        let polls = r.commands[..<df01].filter { $0.op == PTP.Op.getDevicePropValue && $0.params == [0xD212] }.count
        #expect(polls == 3)
        #expect(r.sets.first { $0.prop == 0xDF01 }?.value == Data([20, 0]))
        // Gallery sequence (libfuji's gallery setup): 9054/9055 with 0x10000001, 9050, 9053(0, 30000), D620, D621.
        #expect(r.commands.contains { $0.op == 0x9054 && $0.params == [0x1000_0001] })
        #expect(r.commands.contains { $0.op == 0x9055 && $0.params == [0x1000_0001] })
        #expect(r.commands.contains { $0.op == 0x9053 && $0.params == [0, 30000] })
        #expect(r.commands.contains { $0.op == PTP.Op.getDevicePropValue && $0.params == [0xD621] })
        // D226: 0 in the gallery setup, 2 (originals) for the import, 0 at the end.
        #expect(r.sets.filter { $0.prop == 0xD226 }.map(\.value) == [Data([0, 0]), Data([2, 0]), Data([0, 0])])
        // Fast path: object properties describe files. GetObjectInfo comes only right before a file's thumbnail or
        // data (libfuji; an X100VI 1.10 stopped answering without it on 2026-10-16), never once per listed file.
        #expect(r.commands.contains { $0.op == 0x9803 && $0.params.last == 0xDC04 })
        for (i, c) in r.commands.enumerated() where c.op == PTP.Op.getThumb || c.op == PTP.Op.getPartialObject {
            #expect(r.commands[..<i].last { $0.op != PTP.Op.getPartialObject }.map { $0.op == PTP.Op.getObjectInfo && $0.params.first == c.params.first } == true)
        }
        // Windows are 1 MB and start on 512-byte boundaries.
        #expect(r.partials.allSatisfy { $0.length <= 1 << 20 && $0.offset % 512 == 0 })
        // Goodbye: CloseSession, then 08 00 00 00 FF FF FF FF (libfuji fuji.c:46-55).
        #expect(r.closeSessions == 1)
        #expect(r.goodbyes == 1)
        // Manifest.
        let m = try await run.library.manifest(for: day)
        #expect(m.files.count == 4)
        #expect(m.files.allSatisfy { $0.route == "wifi" })
        #expect(m.files.map(\.captured) == ["2026-10-09T09:00:00", "2026-10-09T10:00:00", "2026-10-09T10:00:00", "2026-10-09T11:00:00"])
        #expect(Set(m.files.map(\.file)) == ["DSCF0003.JPG", "DSCF0004.JPG", "DSCF0004.RAF", "DSCF0005.JPG"])
    }

    @Test("No object properties: D227 = 1 before GetObjectInfo, so the size isn't Fuji's 100 KB placeholder")
    func objectInfoFallback() async throws {
        var b = FakeFujiWifiCamera.Behavior()
        b.answersObjectProps = false
        b.lieAboutSize = true
        let run = try await WifiRun(behavior: b)
        defer { run.cleanup() }
        let summary = try await run.importAll()
        #expect(summary.saved.count == 4)
        try run.expectFilesIdentical(summary)
        await run.cam.close()
        let r = try await run.recordAfterClose()
        #expect(r.sets.filter { $0.prop == 0xD227 }.map(\.value) == [Data([0, 0]), Data([1, 0]), Data([0, 0])])
        let setReal = try #require(r.commands.indices.filter { r.commands[$0].op == PTP.Op.setDevicePropValue && r.commands[$0].params == [0xD227] }.dropFirst().first)
        let firstInfo = try #require(r.commands.firstIndex { $0.op == PTP.Op.getObjectInfo })
        #expect(setReal < firstInfo)
    }

    @Test("Size placeholder and no D227: the download keeps asking past the announced size until the camera has no more")
    func untrustedSize() async throws {
        var b = FakeFujiWifiCamera.Behavior()
        b.answersObjectProps = false
        b.lieAboutSize = true
        b.refuseProps = [0xD227]
        // Files bigger than the 102400-byte placeholder, so stopping at the announced size would truncate them.
        let run = try await WifiRun(behavior: b, jpegBytes: 300_000)
        defer { run.cleanup() }
        let summary = try await run.importAll()
        #expect(summary.saved.count == 4)
        try run.expectFilesIdentical(summary)
    }

    @Test("No D621 list: ask GetObjectHandles rather than assuming IDs are 1…D222")
    func noImportHandles() async throws {
        var b = FakeFujiWifiCamera.Behavior()
        b.listsHandles = false
        let run = try await WifiRun(behavior: b)
        defer { run.cleanup() }
        let summary = try await run.importAll()
        #expect(summary.saved.count == 4)
        try run.expectFilesIdentical(summary)
        #expect(run.fake.record.commands.contains { $0.op == PTP.Op.getObjectHandles })
    }

    @Test("Socket dies mid-file: new socket, init, OpenSession at tid 1 again, resume from the 512-aligned offset")
    func dropAndResume() async throws {
        var b = FakeFujiWifiCamera.Behavior()
        // Frames are ~2.5 MB (3 windows). Newest first: DSCF0005.JPG whole (2.5 MB), then DSCF0004.RAF's second window dies.
        b.dropAfterPartialBytes = 3_600_000
        let run = try await WifiRun(behavior: b, jpegBytes: 2_500_000)
        defer { run.cleanup() }
        let summary = try await run.importAll()
        #expect(summary.saved.count == 4)
        #expect(!summary.interrupted)
        try run.expectFilesIdentical(summary)
        await run.cam.close()
        let r = try await run.recordAfterClose()
        #expect(r.drops == 1)
        #expect(r.connections == 2)
        #expect(r.openSessionTids == [1, 1])
        // The window that died was asked again from the same offset (1 MB in), not from 0.
        let repeated = Dictionary(grouping: r.partials, by: { "\($0.handle)@\($0.offset)" }).filter { $0.value.count > 1 }
        #expect(repeated.count == 1)
        let again = try #require(repeated.values.first?.first)
        #expect(again.offset == 1 << 20)
        // After the reconnect D226 = 2 is set again before the next window.
        #expect(r.sets.filter { $0.prop == 0xD226 && $0.value == Data([2, 0]) }.count == 2)
    }

    @Test("First socket never answers the init (X100VI just woken): a fresh socket and init")
    func silentFirstInit() async throws {
        var b = FakeFujiWifiCamera.Behavior()
        b.silentFirstInit = true
        var cfg = WifiRun.config
        cfg.transport.readTimeout = .milliseconds(700)
        let run = try await WifiRun(behavior: b, config: cfg)
        defer { run.cleanup() }
        let summary = try await run.importAll()
        #expect(summary.saved.count == 4)
        #expect(run.fake.record.connections == 2)
    }

    @Test("DF01 = 20 refused: falls back to 2 (view all), skips the gallery calls, still imports")
    func clientStateFallback() async throws {
        var b = FakeFujiWifiCamera.Behavior()
        b.refuseClientStates = [20]
        let run = try await WifiRun(behavior: b)
        defer { run.cleanup() }
        let summary = try await run.importAll()
        #expect(summary.saved.count == 4)
        let g = try #require(await run.cam.gallery)
        #expect(g.clientState == 2)
        let r = run.fake.record
        #expect(r.sets.filter { $0.prop == 0xDF01 }.map(\.value) == [Data([20, 0]), Data([2, 0])])
        #expect(!r.commands.contains { $0.op == 0x9054 })
    }

    @Test("Thumbnails that need GetObjectInfo first (libfuji fuji.c:640-646): info is always sent before a thumbnail")
    func thumbsNeedInfo() async throws {
        var b = FakeFujiWifiCamera.Behavior()
        b.thumbNeedsInfo = true
        let run = try await WifiRun(behavior: b)
        defer { run.cleanup() }
        let summary = try await run.importAll(thumbsOnly: true)
        #expect(summary.thumbnails == 4)
        #expect(summary.saved.isEmpty)
        let thumbs = try FileManager.default.contentsOfDirectory(atPath: run.library.folder(for: day).appendingPathComponent(".thumbs").path)
        #expect(thumbs.count == 4)
        #expect(run.fake.record.partials.isEmpty)   // thumbs-only fetched no file bytes
    }

    @Test("Listing walks newest first and stops after 8 photos older than --since (each describe costs Wi-Fi time)")
    func listingStopsEarly() async throws {
        let run = try await WifiRun(behavior: FakeFujiWifiCamera.Behavior(), olderCount: 30, todayCount: 2)
        defer { run.cleanup() }
        let summary = try await run.importAll()
        #expect(summary.saved.count == 3)            // 2 JPEGs + the RAF
        let names = run.fake.record.commands.filter { $0.op == 0x9803 && $0.params.last == 0xDC07 }.count
        #expect(names <= 3 + 8)
    }

    @Test("Nobody presses OK: a clear error after the timeout")
    func okTimeout() async throws {
        var b = FakeFujiWifiCamera.Behavior()
        b.okAfterPolls = 10_000
        var cfg = WifiRun.config
        cfg.accessTimeout = .milliseconds(300)
        let run = try await WifiRun(behavior: b, config: cfg)
        defer { run.cleanup() }
        await #expect(throws: ImportError.pressOKTimedOut) { try await run.cam.connect() }
    }

    @Test("Nothing listening: noCamera, not a hang")
    func unreachable() async throws {
        let probe = FakeFujiWifiCamera(frames: [])
        let port = try await probe.start()
        probe.stop()
        try await Task.sleep(for: .milliseconds(100))
        let cam = FujiWifiCamera(config: .init(transport: .init(host: "127.0.0.1", port: port, connectTimeout: .seconds(2), readTimeout: .seconds(1))))
        do {
            try await cam.connect()
            Issue.record("connected to nothing")
        } catch let e as ImportError {
            if case .noCamera = e {} else if case .link = e {} else { Issue.record("unexpected \(e)") }
        }
    }

    // MARK: Bluetooth → Wi-Fi

    @Test("Wake, secure firmware: SSID, FUNCTION_LAUNCH 03 00, password, AP up → hidden network with password")
    func wakeSecure() async throws {
        let g = WakeGATT(password: "abcd1234", apAnswers: [Data([1])])
        let creds = try await FujiWifiWake.run(g, apTimeout: .milliseconds(50))
        #expect(creds == CameraWifiCredentials(ssid: "FUJIFILM-X100VI-1D7B", password: "abcd1234", hidden: true))
        let writes = await g.writes
        #expect(writes.map(\.0) == [FujiBLE.functionLaunch])
        #expect(writes.first?.1 == Data([0x03, 0x00]))
        // SSID read before the launch (fuji-bridge FujiWake.run, libfuji bluetooth.c:321).
        let order = await g.steps
        #expect(order.firstIndex(of: "read bf6dc9cf")! < order.firstIndex(of: "write 600655e6")!)
    }

    @Test("Wake, basic firmware (no e809256a, like fw 1.11 / the tested 1.10): open, visible network")
    func wakeBasic() async throws {
        let g = WakeGATT(password: nil, apAnswers: [Data([1])])
        let creds = try await FujiWifiWake.run(g, apTimeout: .milliseconds(50))
        #expect(creds.password.isEmpty)
        #expect(!creds.hidden)
    }

    @Test("Wake: busy (00) is asked again after 200 ms; three busy answers give up")
    func wakeBusy() async throws {
        let g = WakeGATT(password: "pw", apAnswers: [Data([0]), Data([1])])
        _ = try await FujiWifiWake.run(g, apTimeout: .milliseconds(50))
        #expect(await g.writes.count == 2)
        let g3 = WakeGATT(password: "pw", apAnswers: [Data([0]), Data([0]), Data([0])])
        await #expect(throws: FujiBLEError.busy) { try await FujiWifiWake.run(g3, apTimeout: .milliseconds(50)) }
    }

    @Test("Wake: --function 4 sends 04 00 (libfuji's remote shooting)")
    func wakeFunction() async throws {
        let g = WakeGATT(password: "pw", apAnswers: [])
        _ = try await FujiWifiWake.run(g, function: 4, apTimeout: .milliseconds(20))
        #expect(await g.writes.first?.1 == Data([0x04, 0x00]))
    }

    #if os(macOS)
    @Test("Wi-Fi interface from networksetup -listallhardwareports (synthetic output in the same format)")
    func wifiInterface() {
        let out = """
            Hardware Port: Ethernet Adapter (en3)
            Device: en3
            Ethernet Address: 02:00:00:00:00:01

            Hardware Port: Wi-Fi
            Device: en0
            Ethernet Address: 02:00:00:00:00:02

            Hardware Port: Thunderbolt 1
            Device: en1
            """
        #expect(MacWifiJoiner.parseWifiInterface(out) == "en0")
        #expect(MacWifiJoiner.parseWifiInterface("Hardware Port: Ethernet\nDevice: en5\n") == nil)
    }
    #endif
}

// MARK: - Harness

/// One fake camera + one FujiWifiCamera + a temp library.
struct WifiRun {
    static var config: FujiWifiCamera.Config {
        FujiWifiCamera.Config(transport: .init(host: "127.0.0.1", port: 0, connectTimeout: .seconds(3), readTimeout: .seconds(3)),
                              accessTimeout: .seconds(10), pollInterval: .milliseconds(20),
                              reconnectPauses: [.zero, .milliseconds(50), .milliseconds(100)])
    }

    let fake: FakeFujiWifiCamera
    let cam: FujiWifiCamera
    let root: URL
    let library: ImportLibrary

    init(behavior: FakeFujiWifiCamera.Behavior, config: FujiWifiCamera.Config = WifiRun.config,
         jpegBytes: Int = 40_000, olderCount: Int = 2, todayCount: Int = 3) async throws {
        let frames = FakeFujiWifiCamera.sampleCard(day: day, todayCount: todayCount, olderCount: olderCount, jpegBytes: jpegBytes)
        fake = FakeFujiWifiCamera(frames: frames, behavior: behavior)
        let port = try await fake.start()
        var cfg = config
        cfg.transport.port = port
        cam = FujiWifiCamera(config: cfg)
        root = try TempDir.make("wifi")
        library = ImportLibrary(root: root)
    }

    func importAll(thumbsOnly: Bool = false) async throws -> ImportSummary {
        try await PhotoImporter.run(source: cam, library: library, options: ImportOptions(since: day, thumbsOnly: thumbsOnly))
    }

    /// Every saved file equals what the camera served.
    func expectFilesIdentical(_ s: ImportSummary) throws {
        for e in s.saved {
            let frame = try #require(fake.frames.first { $0.name == e.originalName })
            let got = try Data(contentsOf: library.folder(for: day).appendingPathComponent(e.file))
            #expect(got == frame.data, "\(e.file) differs")
            #expect(e.size == frame.data.count)
        }
    }

    /// The goodbye arrives just after `close()` returns.
    func recordAfterClose() async throws -> FakeFujiWifiCamera.Record {
        for _ in 0..<40 where fake.record.goodbyes == 0 { try await Task.sleep(for: .milliseconds(25)) }
        return fake.record
    }

    func cleanup() {
        fake.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

/// The GATT side of the Wi-Fi wake (fuji-bridge Tests/BluetoothTests.swift shape): SSID, optional password, scripted AP state.
actor WakeGATT: GATTClient {
    let password: String?
    var apAnswers: [Data]
    private(set) var writes: [(String, Data)] = []
    private(set) var steps: [String] = []

    init(password: String?, apAnswers: [Data]) {
        self.password = password
        self.apAnswers = apAnswers
    }

    func has(_ c: String) async -> Bool {
        [FujiWifiWake.ssidCharacteristic, FujiBLE.functionLaunch, FujiBLE.apState].contains(c)
            || (c == FujiWifiWake.passwordCharacteristic && password != nil)
    }

    func read(_ c: String) async throws -> Data {
        steps.append("read \(c.prefix(8))")
        switch c {
        case FujiWifiWake.ssidCharacteristic: return Data("FUJIFILM-X100VI-1D7B".utf8) + Data(count: 12)
        case FujiWifiWake.passwordCharacteristic: return Data((password ?? "").utf8) + Data(count: 4)
        default: throw FujiBLEError.missingCharacteristic(c)
        }
    }

    func write(_ c: String, _ value: Data) async throws {
        steps.append("write \(c.prefix(8))")
        writes.append((c, value))
    }

    func subscribe(_ c: String) async -> Bool { true }

    func nextValue(_ c: String, timeout: Duration) async -> Data? {
        guard c == FujiBLE.apState, !apAnswers.isEmpty, !writes.isEmpty else { return nil }
        return apAnswers.removeFirst()
    }

    func drain(_ c: String) async -> [Data] { [] }
    var isLinkUp: Bool { true }
}
