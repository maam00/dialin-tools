// EXPERIMENTAL Bluetooth settings restore: upload a FUJIFILMX-BACKUP file over the camera's file-transfer service.
//
// Two engines:
//   * `restoreSettingsStandard` (the default): the standard restore conversation described in
//     docs/FUJIFILM-PROTOCOL.md §3.7 (Python: ble/fuji_ble/client.py).
//   * `restoreSettings(profile:)`: the older capture-derived profile engine, below.
//
// Port of ble/fuji_ble/restore_profile.py + client.py `_execute_restore`. Every parameter of a captured restore
// lives in `RestoreProfile`, whose JSON is the Python one ("fuji-ble-restore-profile/1", snake_case):
//   python -m fuji_ble.capture TRACE.pklg --replay R.json      # PacketLogger capture of a restore on your own camera
//   python -m fuji_ble.restore_profile R.json -o profile.json   # derive + review the profile
//   dialin-cam ble-restore FILE --profile profile.json --i-understand-this-is-experimental
// The default profile mirrors the documented download (fuji-bridge FujiBackup.swift) and has NO restore request, so
// it can't send anything: restore stays `unsupported` until a capture fills R1 in.
import Foundation

extension FujiBLEFlows {
    public struct RestoreProfile: Codable, Equatable, Sendable {
        public struct SetupOp: Codable, Equatable, Sendable {
            /// "file_information" (name), "write_u32" (char, value) or "write" (char, value_hex, replayed verbatim).
            public var op: String
            public var name: String?
            public var char: String?
            public var value: Int?
            public var valueHex: String?

            enum CodingKeys: String, CodingKey { case op, name, char, value, valueHex = "value_hex" }

            public init(op: String, name: String? = nil, char: String? = nil, value: Int? = nil, valueHex: String? = nil) {
                self.op = op
                self.name = name
                self.char = char
                self.value = value
                self.valueHex = valueHex
            }
        }

        public var requestChar: String?
        public var requestValue: String?
        public var requestWithResponse = true
        public var subscribe: [String] = [FujiBLE.fileTransactionState, FujiBLE.backupState] + FujiBLE.restoreStateCandidates
        public var readyChar: String?
        public var readyValuePrefix: String?
        public var readyTimeout = 10.0
        public var requestWait = 10.0
        public var setup: [SetupOp] = [
            SetupOp(op: "file_information", name: "backup.dat"),
            SetupOp(op: "write_u32", char: FujiBLE.filePartialSize, value: Int(FujiBLE.backupPartialSize)),
            SetupOp(op: "write_u32", char: FujiBLE.fileTransferIndex, value: 0),
        ]
        public var chunkSize = Int(FujiBLE.backupPartialSize)
        public var seqStart = 0
        public var lastSeq: Int? = Int(FujiBLE.lastSeq)
        public var trailerSum = true
        public var frameWithResponse = true
        /// "auto" (learn from the first frame), "ack" (wait for ackChar after each frame), "fixed" (gapMs)
        public var pacing = "auto"
        public var gapMs = 20.0
        public var ackChar = FujiBLE.fileTransactionState
        public var ackTimeout = 5.0
        public var completeChar: String? = FujiBLE.fileTransactionState
        public var completeValuePrefix: String?
        public var completeTimeout = 20.0
        public var finishChar: String? = FujiBLE.fileTransferResult
        public var finishValue: String? = "0300"
        public var finishAfterComplete = true
        public var source = "mirrored from the documented download (fuji-bridge FujiBackup.swift); every step INFERRED"
        public var captured = false

        public init() {}

        enum CodingKeys: String, CodingKey {
            case requestChar = "request_char", requestValue = "request_value", requestWithResponse = "request_with_response"
            case subscribe, readyChar = "ready_char", readyValuePrefix = "ready_value_prefix", readyTimeout = "ready_timeout"
            case requestWait = "request_wait", setup, chunkSize = "chunk_size", seqStart = "seq_start", lastSeq = "last_seq"
            case trailerSum = "trailer_sum", frameWithResponse = "frame_with_response", pacing, gapMs = "gap_ms"
            case ackChar = "ack_char", ackTimeout = "ack_timeout", completeChar = "complete_char"
            case completeValuePrefix = "complete_value_prefix", completeTimeout = "complete_timeout"
            case finishChar = "finish_char", finishValue = "finish_value", finishAfterComplete = "finish_after_complete"
            case source, captured, format
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = RestoreProfile()
            if let format = try c.decodeIfPresent(String.self, forKey: .format), format != Self.format {
                throw FujiBLEError.unsupported("not a \(Self.format) profile (format \(format))")
            }
            func opt<T: Decodable>(_ k: CodingKeys, _ fallback: T?) throws -> T? {
                c.contains(k) ? try c.decodeIfPresent(T.self, forKey: k) : fallback
            }
            requestChar = try opt(.requestChar, d.requestChar).map(FujiBLE.normalize)
            requestValue = try opt(.requestValue, d.requestValue)
            requestWithResponse = try c.decodeIfPresent(Bool.self, forKey: .requestWithResponse) ?? d.requestWithResponse
            subscribe = (try c.decodeIfPresent([String].self, forKey: .subscribe) ?? d.subscribe).map(FujiBLE.normalize)
            readyChar = try opt(.readyChar, d.readyChar).map(FujiBLE.normalize)
            readyValuePrefix = try opt(.readyValuePrefix, d.readyValuePrefix)
            readyTimeout = try c.decodeIfPresent(Double.self, forKey: .readyTimeout) ?? d.readyTimeout
            requestWait = try c.decodeIfPresent(Double.self, forKey: .requestWait) ?? d.requestWait
            setup = (try c.decodeIfPresent([SetupOp].self, forKey: .setup) ?? d.setup).map { op in
                var o = op
                o.char = o.char.map(FujiBLE.normalize)
                return o
            }
            chunkSize = try c.decodeIfPresent(Int.self, forKey: .chunkSize) ?? d.chunkSize
            seqStart = try c.decodeIfPresent(Int.self, forKey: .seqStart) ?? d.seqStart
            lastSeq = try opt(.lastSeq, d.lastSeq)
            trailerSum = try c.decodeIfPresent(Bool.self, forKey: .trailerSum) ?? d.trailerSum
            frameWithResponse = try c.decodeIfPresent(Bool.self, forKey: .frameWithResponse) ?? d.frameWithResponse
            pacing = try c.decodeIfPresent(String.self, forKey: .pacing) ?? d.pacing
            gapMs = try c.decodeIfPresent(Double.self, forKey: .gapMs) ?? d.gapMs
            ackChar = FujiBLE.normalize(try c.decodeIfPresent(String.self, forKey: .ackChar) ?? d.ackChar)
            ackTimeout = try c.decodeIfPresent(Double.self, forKey: .ackTimeout) ?? d.ackTimeout
            completeChar = try opt(.completeChar, d.completeChar).map(FujiBLE.normalize)
            completeValuePrefix = try opt(.completeValuePrefix, d.completeValuePrefix)
            completeTimeout = try c.decodeIfPresent(Double.self, forKey: .completeTimeout) ?? d.completeTimeout
            finishChar = try opt(.finishChar, d.finishChar).map(FujiBLE.normalize)
            finishValue = try opt(.finishValue, d.finishValue)
            finishAfterComplete = try c.decodeIfPresent(Bool.self, forKey: .finishAfterComplete) ?? d.finishAfterComplete
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? d.source
            captured = try c.decodeIfPresent(Bool.self, forKey: .captured) ?? d.captured
            try validate()
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Self.format, forKey: .format)
            try c.encode(requestChar, forKey: .requestChar)
            try c.encode(requestValue, forKey: .requestValue)
            try c.encode(requestWithResponse, forKey: .requestWithResponse)
            try c.encode(subscribe, forKey: .subscribe)
            try c.encode(readyChar, forKey: .readyChar)
            try c.encode(readyValuePrefix, forKey: .readyValuePrefix)
            try c.encode(readyTimeout, forKey: .readyTimeout)
            try c.encode(requestWait, forKey: .requestWait)
            try c.encode(setup, forKey: .setup)
            try c.encode(chunkSize, forKey: .chunkSize)
            try c.encode(seqStart, forKey: .seqStart)
            try c.encode(lastSeq, forKey: .lastSeq)
            try c.encode(trailerSum, forKey: .trailerSum)
            try c.encode(frameWithResponse, forKey: .frameWithResponse)
            try c.encode(pacing, forKey: .pacing)
            try c.encode(gapMs, forKey: .gapMs)
            try c.encode(ackChar, forKey: .ackChar)
            try c.encode(ackTimeout, forKey: .ackTimeout)
            try c.encode(completeChar, forKey: .completeChar)
            try c.encode(completeValuePrefix, forKey: .completeValuePrefix)
            try c.encode(completeTimeout, forKey: .completeTimeout)
            try c.encode(finishChar, forKey: .finishChar)
            try c.encode(finishValue, forKey: .finishValue)
            try c.encode(finishAfterComplete, forKey: .finishAfterComplete)
            try c.encode(source, forKey: .source)
            try c.encode(captured, forKey: .captured)
        }

        public static let format = "fuji-ble-restore-profile/1"

        public static func decode(_ data: Data) throws -> RestoreProfile {
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .useDefaultKeys
            return try dec.decode(RestoreProfile.self, from: data)
        }

        public func validate() throws {
            for hex in [requestValue, readyValuePrefix, completeValuePrefix, finishValue].compactMap({ $0 }) where Data(hexString: hex) == nil {
                throw FujiBLEError.unsupported("profile value \(hex) isn't hex")
            }
            guard (1...FujiBLE.maxChunkPayload).contains(chunkSize) else {
                throw FujiBLEError.unsupported("chunk_size must be 1…\(FujiBLE.maxChunkPayload)")
            }
            guard ["auto", "ack", "fixed"].contains(pacing) else { throw FujiBLEError.unsupported("pacing must be auto, ack or fixed") }
            for op in setup where !["file_information", "write_u32", "write"].contains(op.op) {
                throw FujiBLEError.unsupported("unknown setup op \(op.op)")
            }
        }

        public var hasRequest: Bool { requestChar != nil && !(requestValue ?? "").isEmpty }

        /// Upload frames: u16 seq, u32 len, data; the last frame (seq 0xFFFF by default) carries the u16 sum of every
        /// data byte. Same bytes as Python `RestoreProfile.frames` / `gatt.plan_upload_frames`.
        public func frames(_ data: Data) -> [Data] {
            let bytes = [UInt8](data)
            let tail = trailerSum ? 2 : 0
            var pieces: [[UInt8]] = stride(from: 0, to: bytes.count, by: chunkSize).map { Array(bytes[$0..<min($0 + chunkSize, bytes.count)]) }
            if pieces.isEmpty { pieces = [[]] }
            if tail > 0, let last = pieces.last, last.count > chunkSize - tail {
                pieces.removeLast()
                pieces.append(Array(last[0..<(chunkSize - tail)]))
                pieces.append(Array(last[(chunkSize - tail)...]))
            }
            let sum = byteSum16(data)
            return pieces.enumerated().map { i, piece in
                let final = i == pieces.count - 1
                let seq = final && lastSeq != nil ? lastSeq! : seqStart + i
                var body = Data(piece)
                if final && trailerSum { body += PTPPack.u16(sum) }
                return FileChunk.build(seq: UInt16(truncatingIfNeeded: seq), payload: body)
            }
        }

        /// (characteristic, value) for each setup op, with the file's real size.
        public func setupWrites(_ data: Data, name: String = "backup.dat") -> [(String, Data)] {
            setup.compactMap { op in
                switch op.op {
                case "file_information": (FujiBLE.fileInformation, FileInformation.build(name: op.name ?? name, size: data.count))
                case "write_u32": op.char.map { ($0, PTPPack.u32(UInt32(truncatingIfNeeded: op.value ?? 0))) }
                default: op.char.flatMap { c in op.valueHex.flatMap(Data.init(hexString:)).map { (c, $0) } }
                }
            }
        }
    }

    public struct RestoreResult: Sendable, Equatable {
        public var framesSent: Int
        /// The camera's last transfer-state value, or nil when it sent no completion signal (assume NOT applied).
        public var finalState: Data?
        /// Post-restore download compared with what we sent (nil when not checked).
        public var verifiedIdentical: Bool?

        public init(framesSent: Int, finalState: Data?, verifiedIdentical: Bool?) {
            self.framesSent = framesSent
            self.finalState = finalState
            self.verifiedIdentical = verifiedIdentical
        }
    }

    /// Upload `file` per `profile` over an open, registered link. Refuses (unsupported) without a restore request.
    /// Raises `.transfer` if the camera never says it is ready (nothing is uploaded then), stops acknowledging, or ends
    /// with a value other than the profile's completion value. Python: client.py `_execute_restore`.
    public static func restoreSettings(
        _ gatt: any GATTClient, file: Data, profile p: RestoreProfile, firstAckWait: Duration = .seconds(2),
        log: @Sendable (String) -> Void = { _ in }, progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> RestoreResult {
        guard p.hasRequest, let reqChar = p.requestChar, let reqValue = p.requestValue.flatMap(Data.init(hexString:)) else {
            throw restoreUnsupported
        }
        guard await gatt.has(FujiBLE.filePartialData) else { throw FujiBLEError.missingCharacteristic(FujiBLE.filePartialData) }
        for u in p.subscribe { await gatt.subscribe(u) }
        for u in Set([p.ackChar] + [p.readyChar, p.completeChar].compactMap { $0 }) {
            for v in await gatt.drain(u) { log("dropped stale \(u.prefix(8)) \(v.hexString)") }
        }
        if p.requestWithResponse { try await gatt.write(reqChar, reqValue) } else { try await gatt.writeCommand(reqChar, reqValue) }
        log("restore request \(reqChar.prefix(8)) = \(reqValue.hexString)")
        if let ready = p.readyChar {
            let prefix = Data(hexString: p.readyValuePrefix ?? "") ?? Data()
            let deadline = ContinuousClock.now + .milliseconds(Int(p.readyTimeout * 1000))
            var ok = false
            while ContinuousClock.now < deadline, let v = await gatt.nextValue(ready, timeout: deadline - ContinuousClock.now) {
                log("\(ready.prefix(8)) = \(v.hexString)")
                if v.starts(with: prefix) { ok = true; break }
            }
            guard ok else {
                throw FujiBLEError.transfer("The camera never said it was ready (\(ready.prefix(8)) starting \(prefix.hexString)). Nothing was uploaded.")
            }
        } else {
            log("no known ready signal: listening \(p.requestWait) s")
            try await Task.sleep(for: .milliseconds(Int(p.requestWait * 1000)))
        }
        for (c, v) in p.setupWrites(file) { try await gatt.write(c, v) }
        let frames = p.frames(file)
        var acks: Bool? = p.pacing == "ack" ? true : p.pacing == "fixed" ? false : nil
        var lastAck: Data?
        _ = await gatt.drain(p.ackChar)
        for (i, frame) in frames.enumerated() {
            if p.frameWithResponse { try await gatt.write(FujiBLE.filePartialData, frame) } else { try await gatt.writeCommand(FujiBLE.filePartialData, frame) }
            if acks == nil {
                lastAck = await gatt.nextValue(p.ackChar, timeout: firstAckWait)
                acks = lastAck != nil
                log(lastAck.map { "first frame acknowledged: \($0.hexString)" } ?? "first frame not acknowledged; pacing \(p.gapMs) ms")
            } else if acks == true {
                guard let ack = await gatt.nextValue(p.ackChar, timeout: .milliseconds(Int(max(p.ackTimeout, 0.05) * 1000))) else {
                    throw FujiBLEError.transfer("The camera stopped acknowledging after frame \(i + 1)/\(frames.count).")
                }
                lastAck = ack
            } else {
                try await Task.sleep(for: .milliseconds(Int(p.gapMs)))
            }
            progress(i + 1, frames.count)
        }
        func waitComplete() async throws -> Data? {
            guard let cc = p.completeChar else { return nil }
            let prefix = Data(hexString: p.completeValuePrefix ?? "") ?? Data()
            var seen: [Data] = []
            if acks == true, cc == p.ackChar, let la = lastAck { seen.append(la) } // the last ack may be the verdict
            if !(seen.last.map { prefix.isEmpty || $0.starts(with: prefix) } ?? false) {
                let deadline = ContinuousClock.now + .milliseconds(Int(p.completeTimeout * 1000))
                while ContinuousClock.now < deadline, let v = await gatt.nextValue(cc, timeout: deadline - ContinuousClock.now) {
                    seen.append(v)
                    if v.starts(with: prefix) { break }
                }
            }
            if let last = seen.last, !prefix.isEmpty, !last.starts(with: prefix) {
                throw FujiBLEError.transfer("The camera ended with \(last.hexString), not \(prefix.hexString): it probably refused the file (checksum, other body, not a clean state).")
            }
            return seen.last
        }
        func finish() async throws {
            guard let fc = p.finishChar, let fv = p.finishValue.flatMap(Data.init(hexString:)) else { return }
            try await gatt.write(fc, fv)
        }
        var final: Data?
        if p.finishAfterComplete {
            final = try await waitComplete()
            try await finish()
        } else {
            try await finish()
            final = try await waitComplete()
        }
        log(final.map { "final transfer state \($0.hexString)" } ?? "no completion signal (assume NOT applied until proven)")
        return RestoreResult(framesSent: frames.count, finalState: final, verifiedIdentical: nil)
    }

    /// The standard Bluetooth restore, step for step (docs/FUJIFILM-PROTOCOL.md §3.7):
    /// 1 subscribe FILE_TRANSACTION_STATE + RESTORE_STATE; 2 write RESTORE_REQUEST 01 00; 3 wait ≤10 s for RESTORE_STATE,
    /// need 1 (ready, else busy); 4 write FILE_PARTIAL_SIZE u32 120, FILE_TRANSFER_INDEX u32 0, FILE_INFORMATION
    /// "backup.dat" + u32 size; 5 wait ≤10 s for transaction state 1 (started); 6 each 128-byte frame
    /// (`FujiBLE.restoreFrames`) with response, then ≤10 s for the transaction state: 2 next, 3 → write
    /// FILE_TRANSFER_RESULT 03 00 and finish, 0 → write 00 00 and fail, else → write 02 00 and fail. A failed frame
    /// write is how the camera refuses a file (one from another body or an incompatible firmware).
    public static func restoreSettingsStandard(
        _ gatt: any GATTClient, file: Data, stateTimeout: Duration = .seconds(10), ackTimeout: Duration = .seconds(10),
        log: @Sendable (String) -> Void = { _ in }, progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> RestoreResult {
        try Task.checkCancellation()
        guard (1...BLEBackupPayload.maximumSize).contains(file.count) else {
            throw FujiBLEError.transfer("Restore file is empty or exceeds the size limit. No restore request was sent.")
        }
        for c in [FujiBLE.restoreRequest, FujiBLE.restoreState, FujiBLE.filePartialSize, FujiBLE.fileTransferIndex,
                  FujiBLE.fileInformation, FujiBLE.filePartialData, FujiBLE.fileTransactionState, FujiBLE.fileTransferResult] {
            guard await gatt.has(c) else { throw FujiBLEError.unsupported("This camera doesn't offer the Bluetooth settings restore (no \(c)).") }
        }
        let frames = FujiBLE.restoreFrames(file)
        // Intermediates are 128 bytes; an exact 120-byte multiple has a 130-byte terminal frame.
        // Check actual frames before asking the camera to enter restore mode.
        let requiredWrite = max(44, frames.map(\.count).max() ?? 0)
        if let available = await gatt.maximumWriteLength, available < requiredWrite {
            throw FujiBLEError.unsupported("This Bluetooth connection supports \(available)-byte writes; the restore needs \(requiredWrite). No restore request was sent.")
        }
        func finish(_ v: Data) async { if await gatt.isLinkUp { try? await gatt.write(FujiBLE.fileTransferResult, v) } }
        func state(_ v: Data) -> UInt16? { (try? TransactionState.parse(v))?.state }
        guard await gatt.subscribe(FujiBLE.fileTransactionState), await gatt.subscribe(FujiBLE.restoreState) else {
            throw FujiBLEError.unsupported("RESTORE_STATE / FILE_TRANSACTION_STATE can't notify on this camera.")
        }
        for c in [FujiBLE.fileTransactionState, FujiBLE.restoreState] {
            for v in await gatt.drain(c) { log("dropped stale \(c.prefix(8)) \(v.hexString)") }
        }
        try Task.checkCancellation()
        try await gatt.write(FujiBLE.restoreRequest, FujiBLE.restoreRequestSettings)
        log("RESTORE_REQUEST = 01 00")
        guard let rs = await gatt.nextValue(FujiBLE.restoreState, timeout: stateTimeout) else {
            await finish(FujiBLE.resultCancel)
            throw FujiBLEError.transfer("No RESTORE_STATE answer within \(stateTimeout). Nothing was uploaded. (Basic bodies need the saved pairing key: pair again.)")
        }
        log("RESTORE_STATE = \(rs.hexString)")
        guard [UInt8](rs).first == 1 else {
            await finish(FujiBLE.resultCancel)
            throw FujiBLEError.busy
        }
        do {
            try Task.checkCancellation()
            try await gatt.write(FujiBLE.filePartialSize, PTPPack.u32(UInt32(FujiBLE.restoreChunk)))
            try await gatt.write(FujiBLE.fileTransferIndex, PTPPack.u32(0))
            _ = await gatt.drain(FujiBLE.fileTransactionState)
            try await gatt.write(FujiBLE.fileInformation, FileInformation.build(name: FujiBLE.backupFileName, size: file.count))
        } catch {
            await finish(FujiBLE.resultCancel)
            if error is CancellationError { throw error }
            throw FujiBLEError.transfer("The camera refused a restore setup write (\(error)). Nothing was uploaded.")
        }
        let start = await gatt.nextValue(FujiBLE.fileTransactionState, timeout: ackTimeout)
        guard let start, state(start) == FujiBLE.tsStart else {
            await finish(FujiBLE.resultCancel)
            throw FujiBLEError.transfer("The camera didn't report transfer started (1) after FILE_INFORMATION (\(start?.hexString ?? "nothing")). Nothing was uploaded.")
        }
        var sent = 0
        for frame in frames {
            do {
                try Task.checkCancellation()
                try await gatt.write(FujiBLE.filePartialData, frame)
            } catch {
                await finish(FujiBLE.resultCancel)
                if error is CancellationError { throw error }
                throw FujiBLEError.transfer("The camera rejected frame \(sent + 1)/\(frames.count) (\(error)). The camera refuses files from another body or an incompatible firmware: restore only a file this body produced.")
            }
            sent += 1
            guard let ack = await gatt.nextValue(FujiBLE.fileTransactionState, timeout: ackTimeout) else {
                await finish(FujiBLE.resultCancel)
                if !(await gatt.isLinkUp) { throw FujiBLEError.disconnected("after frame \(sent)/\(frames.count)") }
                throw FujiBLEError.transfer("No acknowledgement within \(ackTimeout) after frame \(sent)/\(frames.count).")
            }
            progress(sent, frames.count)
            switch state(ack) {
            case FujiBLE.tsTransferring: continue
            case FujiBLE.tsFileDone:
                guard sent == frames.count else {
                    await finish(FujiBLE.resultCancel)
                    throw FujiBLEError.transfer("The camera reported file received (3) before every frame was sent. Camera state is unverified.")
                }
                // Failure/cancel cleanup is best effort; the success write must be acknowledged.
                do {
                    try Task.checkCancellation()
                    try await gatt.write(FujiBLE.fileTransferResult, FujiBLE.resultEnd)
                } catch {
                    if error is CancellationError { await finish(FujiBLE.resultCancel); throw error }
                    throw FujiBLEError.transfer("Transfer result 03 00 (end) was not acknowledged (\(error)). Camera state is unverified; read it back before retrying.")
                }
                log("file received (3) after \(sent)/\(frames.count) frames; FILE_TRANSFER_RESULT = 03 00 acknowledged; camera read-back still required")
                return RestoreResult(framesSent: sent, finalState: ack, verifiedIdentical: nil)
            case FujiBLE.tsError:
                await finish(FujiBLE.resultFail)
                throw FujiBLEError.transfer("The camera reported Error after frame \(sent)/\(frames.count): it refused the file (checksum, model or firmware).")
            default:
                await finish(FujiBLE.resultCancel)
                throw FujiBLEError.transfer("Unexpected transfer state \(ack.hexString) after frame \(sent)/\(frames.count).")
            }
        }
        await finish(FujiBLE.resultCancel)
        throw FujiBLEError.transfer("Every frame was acknowledged but no file-received state (3) arrived. Camera state is unverified; read it back before retrying.")
    }
}
