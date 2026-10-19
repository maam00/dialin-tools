import Foundation
import Synchronization
import Testing
@testable import DialInCamera

@Suite("Wireless photo transfer reliability", .serialized)
struct WifiReliabilityTests {
    private func config(port: UInt16) -> FujiPTPIPTransport.Config {
        .init(host: "127.0.0.1", port: port, connectTimeout: .seconds(2), readTimeout: .seconds(20), initAttempts: 1)
    }

    private func waitForCommand(_ fake: FakeFujiWifiCamera, operation: UInt16? = nil) async throws {
        for _ in 0..<100 {
            let seen = operation.map { op in fake.record.commands.contains { $0.op == op } } ?? !fake.record.initPackets.isEmpty
            if seen { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ImportError.timeout("the test camera did not receive the expected request")
    }

    @Test("An ACK from another responder is rejected before OpenSession")
    func wrongResponder() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.wrongInitGUID = true
        let fake = FakeFujiWifiCamera(frames: [], behavior: behavior)
        let port = try await fake.start()
        defer { fake.stop() }
        let transport = FujiPTPIPTransport(config: config(port: port))
        await #expect(throws: ImportError.self) { try await transport.open(timeout: .seconds(2)) }
        #expect(fake.record.commands.isEmpty)
        #expect(await transport.isOpen == false)
    }

    @Test("A stale response TID breaks the socket instead of becoming another request's photo data")
    func wrongTransaction() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.mismatchedTransactionOperations = [PTP.Op.getDevicePropValue]
        let fake = FakeFujiWifiCamera(frames: [], behavior: behavior)
        let port = try await fake.start()
        defer { fake.stop() }
        let transport = FujiPTPIPTransport(config: config(port: port))
        try await transport.open(timeout: .seconds(2))
        await #expect(throws: ImportError.self) {
            _ = try await transport.transact(PTP.Op.getDevicePropValue, params: [0xD212], dataOut: nil, timeout: nil)
        }
        #expect(await transport.isOpen == false)
        await transport.close()
    }

    @Test("Cancelling a silent handshake returns immediately and never retries or opens a session")
    func cancelHandshake() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.silentFirstInit = true
        let fake = FakeFujiWifiCamera(frames: [], behavior: behavior)
        let port = try await fake.start()
        defer { fake.stop() }
        let transport = FujiPTPIPTransport(config: config(port: port))
        let opening = Task { try await transport.open(timeout: .seconds(2)) }
        try await waitForCommand(fake)
        let started = ContinuousClock.now
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(fake.record.connections == 1)
        #expect(fake.record.openSessionTids.isEmpty)
        #expect(await transport.isOpen == false)
        await transport.close()
    }

    @Test("Closing an opening socket prevents the old handshake from reviving the session")
    func closeDuringHandshake() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.silentFirstInit = true
        let fake = FakeFujiWifiCamera(frames: [], behavior: behavior)
        let port = try await fake.start()
        defer { fake.stop() }
        let transport = FujiPTPIPTransport(config: config(port: port))
        let opening = Task { try await transport.open(timeout: .seconds(2)) }
        try await waitForCommand(fake)
        await transport.close()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(await transport.isOpen == false)
        #expect(fake.record.connections == 1)
        #expect(fake.record.openSessionTids.isEmpty)
    }

    @Test("A cancelled file transfer retains its partial, publishes no original, and does not reconnect")
    func cancelFile() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.silentOperations = [PTP.Op.getPartialObject]
        let run = try await WifiRun(behavior: behavior)
        defer { run.cleanup() }
        let items = try await run.cam.list(hint: ListHint(since: "2026-10-09"))
        let item = try #require(items.first { $0.kind == .jpeg })
        let target = run.root.appendingPathComponent("cancelled.jpg")
        let downloading = Task { try await run.cam.download(item, to: target, progress: { _, _ in }) }
        try await waitForCommand(run.fake, operation: PTP.Op.getPartialObject)
        let started = ContinuousClock.now
        downloading.cancel()
        await #expect(throws: CancellationError.self) { _ = try await downloading.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathExtension("part").path))
        #expect(run.fake.record.connections == 1)
        await run.cam.close()
    }

    @Test("A refused D226 original-size request is surfaced before any file bytes are fetched")
    func originalSizeRefused() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.refuseProps = [FujiWifiProp.forceCompression]
        let run = try await WifiRun(behavior: behavior)
        defer { run.cleanup() }
        await #expect(throws: ImportError.refused("full-size photo transfer", code: PTP.Response.devicePropNotSupported)) {
            _ = try await run.importAll()
        }
        #expect(run.fake.record.partials.isEmpty)
        await run.cam.close()
    }

    @Test("A complete smaller JPEG cannot be published as an explicitly requested original")
    func resizedIsNotOriginal() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.ignoresOriginalRequest = true
        let fake = FakeFujiWifiCamera(frames: ImportResizedTests.frames(), behavior: behavior)
        let port = try await fake.start()
        defer { fake.stop() }
        let root = try TempDir.make("invalid-original")
        defer { try? FileManager.default.removeItem(at: root) }
        let cam = ImportResizedTests.camera(port: port, size: .original)
        let items = try await cam.list(hint: ListHint(since: "2026-10-09"))
        let item = try #require(items.first { $0.kind == .jpeg })
        let target = root.appendingPathComponent("original.jpg")
        await #expect(throws: ImportError.self) { _ = try await cam.download(item, to: target, progress: { _, _ in }) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("part").path))
        await cam.close()
    }

    @Test("The very first reconnect re-joins Wi-Fi even when its configured pause is zero")
    func firstReconnectRejoins() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.dropAfterPartialBytes = 100_000
        let fake = FakeFujiWifiCamera(frames: FakeFujiWifiCamera.sampleCard(day: "2026-10-09", jpegBytes: 400_000), behavior: behavior)
        let port = try await fake.start()
        defer { fake.stop() }
        let rejoins = Mutex(0)
        var cfg = WifiRun.config
        cfg.transport.port = port
        cfg.reconnectPauses = [.zero]
        let cam = FujiWifiCamera(config: cfg, rejoin: { rejoins.withLock { $0 += 1 }; return true })
        let root = try TempDir.make("first-reconnect")
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = try await PhotoImporter.run(source: cam, library: ImportLibrary(root: root), options: .init(since: "2026-10-09"))
        #expect(summary.saved.count == 4)
        #expect(rejoins.withLock { $0 } == 1)
        #expect(fake.record.connections == 2)
        // Gallery/handle discovery is repeated; it is not assumed to survive the closed TCP connection.
        #expect(fake.record.commands.filter { $0.op == PTP.Op.getDevicePropValue && $0.params == [0xD621] }.count == 2)
        await cam.close()
    }

    @Test("Address waits exit on task cancellation instead of spinning until the DHCP timeout")
    func cancelAddressWait() async throws {
        let waiting = Task { await CameraNetwork.waitForAddress(near: "203.0.113.1", interface: "dialin-test-no-interface", timeout: .seconds(20)) }
        waiting.cancel()
        let started = ContinuousClock.now
        #expect(await waiting.value == nil)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("Transient raw PTP busy retries gallery mode instead of falling back to another mode")
    func transientGalleryBusy() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.busyPropWrites = [FujiWifiProp.clientState: 2]
        let run = try await WifiRun(behavior: behavior)
        defer { run.cleanup() }
        let summary = try await run.importAll()
        #expect(summary.saved.count == 4)
        #expect(run.fake.record.sets.filter { $0.prop == FujiWifiProp.clientState }.map(\.value) == [Data([20, 0]), Data([20, 0]), Data([20, 0])])
        #expect(await run.cam.gallery?.clientState == 20)
        await run.cam.close()
    }

    @Test("Missing D621 with sparse card handles imports the actual objects rather than fabricating 1…count")
    func sparseHandlesFallback() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.listsHandles = false
        let frames = FakeFujiWifiCamera.sampleCard(day: "2026-10-09", jpegBytes: 20_000).enumerated().map { index, frame in
            var frame = frame
            frame.handle = UInt32(40 + index * 7)
            return frame
        }
        let fake = FakeFujiWifiCamera(frames: frames, behavior: behavior)
        let port = try await fake.start()
        defer { fake.stop() }
        var cfg = WifiRun.config
        cfg.transport.port = port
        let cam = FujiWifiCamera(config: cfg)
        let root = try TempDir.make("sparse-handles")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ImportLibrary(root: root)
        let summary = try await PhotoImporter.run(source: cam, library: library, options: .init(since: "2026-10-09"))
        #expect(summary.saved.count == 4)
        for record in summary.saved {
            let expected = try #require(frames.first { $0.name == record.originalName })
            #expect(try Data(contentsOf: library.folder(for: "2026-10-09").appendingPathComponent(record.file)) == expected.data)
        }
        #expect(fake.record.commands.contains { $0.op == PTP.Op.getObjectHandles })
        #expect(await cam.gallery?.handles == frames.map(\.handle).sorted())
        await cam.close()
    }

    @Test("A truncated handle dataset is distinguishable from a truly empty card")
    func truncatedHandleList() {
        #expect(FujiArray.decodeValidated(Data()) == nil)
        #expect(FujiArray.decodeValidated(PTPPack.u32(2) + PTPPack.u32(40)) == nil)
        #expect(FujiArray.decodeValidated(PTPPack.u32(UInt32.max)) == nil)
        #expect(FujiArray.decodeValidated(PTPPack.u32(0)) == [])
    }

    @Test("An unsupported optional resize-rate property still allows explicitly selected resized browsing")
    func browseWithDefaultRate() async throws {
        var behavior = FakeFujiWifiCamera.Behavior()
        behavior.refuseProps = [FujiWifiProp.resizeRate]
        let fake = FakeFujiWifiCamera(frames: ImportResizedTests.frames(), behavior: behavior)
        let port = try await fake.start()
        defer { fake.stop() }
        let root = try TempDir.make("default-resize-rate")
        defer { try? FileManager.default.removeItem(at: root) }
        let cam = ImportResizedTests.camera(port: port, size: .resized)
        let library = ImportLibrary(root: root)
        let summary = try await PhotoImporter.run(source: cam, library: library,
                                                  options: .init(since: "2026-10-09", thumbnails: false, includeRAW: false))
        #expect(summary.saved.count == 3)
        for record in summary.saved {
            let frame = try #require(fake.frames.first { $0.name == record.originalName })
            #expect(try Data(contentsOf: library.folder(for: "2026-10-09").appendingPathComponent(record.file)) == frame.resized)
        }
        #expect(fake.record.sets.contains { $0.prop == FujiWifiProp.forceCompression && $0.value == Data([1, 0]) })
        #expect(!fake.record.sets.contains { $0.prop == FujiWifiProp.forceCompression && $0.value == Data([2, 0]) })
        await cam.close()
    }
}
