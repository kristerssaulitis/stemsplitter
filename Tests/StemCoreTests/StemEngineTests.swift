import AVFoundation
import XCTest
@testable import StemCore

// StemEngine integration tests (plan TE1/TE6 + eng E1/E2/E4/E5 + Section 6):
//   - bounded inter-stage queue holds at most `queueCapacity` in-flight chunks (E1 bound,
//     asserted — the memory invariant's enforcing mechanism)
//   - cooperative cancel at EACH stage boundary: one terminal event (.cancelled), writers
//     torn down, session dir removed — partial output never survives
//   - end-to-end: a synthesized tone/mix VIDEO fixture (H.264 + AAC) splits to two valid
//     44.1 kHz/24-bit WAVs whose (vocals + instrumental) sum to the decoded source within
//     tolerance (complement-subtraction regression, Section 6 "2am test")
//   - Low Power Mode adjusts the initial estimate (E4), disk preflight refuses before any
//     chunk (E5), ModelStore preload is shared with the first split (CEO row 15),
//     single-flight rejects a second split (CEO row 13), no-audio maps to .noAudio (S2).
//
// All fixtures are synthesized in-code (AAC via the shared AudioFixtureMaker; the MP4
// video via AVAssetWriter right here). MockSeparator supplies the model — deterministic,
// no randomness, no clock dependence.
final class StemEngineTests: XCTestCase {

    // MARK: - Doubles

    private final class EngineMemoryPersistence: KeyValuePersistence, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }
        func set(_ data: Data?, forKey key: String) {
            lock.lock(); defer { lock.unlock() }
            if let data { values[key] = data } else { values.removeValue(forKey: key) }
        }
    }

    /// Thread-safe factory-call counter (preload-sharing assertion).
    private final class FactoryCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// Late-bound engine reference so a chunk-boundary hook can cancel the engine it
    /// belongs to (the hook is installed before the engine exists).
    private final class EngineBox: @unchecked Sendable {
        weak var engine: StemEngine?
    }

    /// Blocking gate for the single-flight test: the FIRST chunk boundary parks the
    /// decode stage until the test releases it; later boundaries pass through. Async-
    /// safe (actor + continuations).
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var enteredCount = 0
        private var released = false

        func arrive() async {
            enteredCount += 1
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func openAll() {
            released = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    // MARK: - Fixtures

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemEngineTests-\(UUID().uuidString)-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeEngine(
        splitBase: URL,
        lowPower: @escaping @Sendable () -> Bool = { false },
        factoryCount: FactoryCounter? = nil,
        hooks: StemEngine.Configuration.Hooks = .init(),
        freeDiskBytes: (@Sendable (URL) throws -> Int64)? = nil
    ) -> StemEngine {
        let store = ModelStore(factory: { units in
            factoryCount?.increment()
            return MockSeparator(computeUnits: units)
        })
        let calibrator = ETACalibrator(
            persistence: EngineMemoryPersistence(),
            isLowPowerModeEnabled: lowPower)
        return StemEngine(
            modelStore: store,
            calibrator: calibrator,
            splitStore: SplitStore(baseDirectory: splitBase),
            configuration: StemEngine.Configuration(hooks: hooks, freeDiskBytes: freeDiskBytes))
    }

    /// Consumes the split stream to completion with a watchdog so a deadlocked pipeline
    /// fails the test instead of hanging the run. Returns every event in order.
    private func collect(
        _ engine: StemEngine, _ sourceURL: URL, timeout seconds: UInt64 = 60
    ) async -> [PipelineEvent] {
        let stream = await engine.split(sourceURL)
        return await withTaskGroup(of: [PipelineEvent]?.self) { group in
            group.addTask {
                var events: [PipelineEvent] = []
                for await event in stream { events.append(event) }
                return events
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? []
            group.cancelAll()
            await group.waitForAll()
            return first ?? []
        }
    }

    private func terminal(of events: [PipelineEvent]) -> PipelineEvent? {
        events.last
    }

    private func phaseList(_ events: [PipelineEvent]) -> [PipelinePhase] {
        events.compactMap { event in
            if case .phase(let phase) = event { return phase }
            return nil
        }
    }

    private func etaList(_ events: [PipelineEvent]) -> [ETAEstimate] {
        events.compactMap { event in
            if case .eta(let estimate) = event { return estimate }
            return nil
        }
    }

    // MARK: - E1: bounded inter-stage queue

    /// The queue bound is the memory invariant's enforcing mechanism (eng E1): with a
    /// non-consuming receiver, a producer of 5 elements must hold at most `capacity`
    /// buffered and must SUSPEND on the 4th send; draining resumes it in FIFO order.
    func testBoundedChannelHoldsAtMostCapacityInFlight() async throws {
        let channel = BoundedChannel<Int>(capacity: 3)
        let sent = FactoryCounter()
        let producer = Task {
            for value in 1...5 {
                try await channel.send(value)
                sent.increment()
            }
            channel.finish()
        }

        // Producer must stall after the capacity is reached: 3 buffered, 4th unsent.
        try await pollUntil(timeout: 5) { channel.bufferedCount == 3 }
        XCTAssertEqual(sent.value, 3, "4th send must be suspended while 3 chunks are in flight")
        XCTAssertEqual(channel.bufferedCount, 3)

        // Receiving one element frees a slot; the producer refills to exactly 3 again.
        let first = try await channel.receive()
        XCTAssertEqual(first, 1)
        try await pollUntil(timeout: 5) { sent.value == 4 }
        XCTAssertEqual(channel.bufferedCount, 3, "bound must hold across the refill too")

        // Drain in FIFO order; the closed channel then yields nil.
        var drained: [Int] = []
        while let value = try await channel.receive() { drained.append(value) }
        XCTAssertEqual(drained, [2, 3, 4, 5])
        try await pollUntil(timeout: 5) { producer.isCancelled == false }
        _ = await producer.result
    }

    /// A cancelled receiver stops cooperatively (the stage-unwind path). The channel is
    /// empty, so the receive can only suspend-or-see-the-cancel — either way it must
    /// throw `CancellationError`, never hang.
    func testBoundedChannelReceiveCancellation() async throws {
        let channel = BoundedChannel<Int>(capacity: 2)
        let task = Task { try await channel.receive() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled receive must throw")
        } catch is CancellationError {
            // expected — both interleavings (cancel before/after registration) throw
        }
    }

    // MARK: - E1: cooperative cancellation at each stage + writer teardown

    /// Cancels the engine from inside the chunk boundary of EACH stage. Asserts: exactly
    /// one terminal event, it is `.failure(.cancelled)`, no `.completed` leaked, and the
    /// session directory (with any partial WAVs) is GONE — writer teardown on cancel.
    func testCancelAtEachStageTearsDownPartialOutput() async throws {
        let fixture = try AudioFixtureMaker.fixture(.stereo48k)  // 2 s → 18 model chunks
        for stage in PipelineStage.allCases {
            let base = try makeTempDir("cancel-\(stage.rawValue)")
            let box = EngineBox()
            let engine = makeEngine(
                splitBase: base,
                hooks: StemEngine.Configuration.Hooks(onChunkBoundary: { seen, index in
                    if seen == stage && index == 1 {
                        await box.engine?.cancel()
                    }
                }))
            box.engine = engine

            let events = await collect(engine, fixture)
            guard case .failure(let error)? = terminal(of: events) else {
                XCTFail("\(stage): stream must end in exactly one terminal event, got \(String(describing: events.last))")
                continue
            }
            XCTAssertEqual(error, .cancelled, "\(stage): terminal must be .cancelled")
            XCTAssertFalse(
                events.contains { if case .completed = $0 { return true }; return false },
                "\(stage): no completion may leak past a cancel")
            XCTAssertEqual(phaseList(events), [.downloading, .decoding, .splitting],
                           "\(stage): phase contract holds even when cancelled")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? ["?"]
            XCTAssertEqual(leftovers, [], "\(stage): partial output must be torn down")
        }
    }

    // MARK: - End-to-end: synthesized video fixture, sum-to-source

    /// THE end-to-end check: a 2 s MP4 (H.264 video + AAC 44.1 kHz stereo mix, built
    /// in-code) splits into two valid 44.1 kHz/24-bit WAVs whose sum equals the decoded
    /// source within tolerance (complement subtraction, plan Section 6).
    func testEndToEndVideoFixtureSumsToSource() async throws {
        let videoURL = try makeTempDir("e2e").appendingPathComponent("mix-video.mp4")
        try SplitVideoFixtureMaker.makeMixedVideo(url: videoURL, seconds: 2.0)

        let base = try makeTempDir("e2e-splits")
        let engine = makeEngine(splitBase: base)
        let events = await collect(engine, videoURL)

        // — Event contract (eng E2): phases in frozen order, two-phase ETA, peaks.
        XCTAssertEqual(phaseList(events), [.downloading, .decoding, .splitting])
        let etas = etaList(events)
        XCTAssertEqual(etas.first?.isInitial, true, "first ETA must be the initial estimate")
        XCTAssertTrue(etas.contains { !$0.isInitial },
                      "measured first-chunk takeover must supersede the initial estimate")
        let peaks = events.compactMap { event -> StereoPeaks? in
            if case .peaks(let p) = event { return p }
            return nil
        }
        XCTAssertGreaterThanOrEqual(peaks.count, 2, "per-chunk peaks must stream")
        let progress = events.compactMap { event -> Double? in
            if case .progress(let fraction) = event { return fraction }
            return nil
        }
        XCTAssertEqual(progress.last, 1.0)
        guard case .completed(let outputs)? = terminal(of: events) else {
            return XCTFail("e2e split failed: \(String(describing: terminal(of: events)))")
        }

        // — Session lifecycle: the .inprogress marker is removed on completion.
        let sessionDir = outputs.vocalsURL.deletingLastPathComponent()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sessionDir.appendingPathComponent(SplitStore.markerFileName).path),
            "completed session must not carry the .inprogress marker")

        // — Decode the source the way the engine saw it (44.1 kHz stereo floats).
        var source: [Float] = []
        for try await chunk in AudioExtractor().chunks(from: videoURL) {
            source.append(contentsOf: chunk.interleavedSamples)
        }
        let sourceFrames = source.count / 2
        XCTAssertGreaterThan(sourceFrames, 0)

        // — Two valid WAVs with correct headers (44.1 kHz, stereo, 24-bit, full length).
        let vocals = try decodeWAV24(outputs.vocalsURL)
        let instrumental = try decodeWAV24(outputs.instrumentalURL)
        for (name, wav) in [("vocals", vocals), ("instrumental", instrumental)] {
            XCTAssertEqual(wav.magic, "RIFF", name)
            XCTAssertEqual(wav.sampleRate, 44_100, name)
            XCTAssertEqual(wav.channels, 2, name)
            XCTAssertEqual(wav.bitsPerSample, 24, name)
            XCTAssertEqual(wav.interleaved.count, sourceFrames * 2,
                           "\(name): output must cover the whole decoded source")
            XCTAssertEqual(
                WAVWriter.validateHeader(at: name == "vocals" ? outputs.vocalsURL : outputs.instrumentalURL),
                .finalized(dataBytes: Int64(wav.interleaved.count) * 3),
                "\(name): fully valid, backpatched WAV")
        }

        // — SUM TO SOURCE (Section 6 complement-subtraction regression): the tolerance
        // is a few int24 LSBs + float transform error; 1e-4 is orders above both.
        var maxError: Float = 0
        for i in 0..<source.count {
            let sum = vocals.interleaved[i] + instrumental.interleaved[i]
            maxError = max(maxError, abs(sum - source[i]))
        }
        XCTAssertLessThan(maxError, 1e-4, "vocals + instrumental must sum to the source")

        // — Both stems carry real content (the mix is mid-dominant with a side component,
        // so MockSeparator keeps the mid in vocals and the side in instrumental).
        XCTAssertGreaterThan(Self.maxAbs(vocals.interleaved), 0.02, "vocals stem must be non-silent")
        XCTAssertGreaterThan(Self.maxAbs(instrumental.interleaved), 0.02,
                             "instrumental stem must be non-silent")
    }

    // MARK: - Preflights

    /// eng E4: Low Power Mode at preflight inflates the initial estimate ×1.5; without
    /// LPM the un-calibrated initial figure is the gate class (0.5 wall-s / audio-s).
    func testLowPowerModeAdjustsInitialEstimate() async throws {
        let fixture = try AudioFixtureMaker.fixture(.stereo44k)  // 1 s

        let lpmBase = try makeTempDir("lpm")
        let lpmEngine = makeEngine(splitBase: lpmBase, lowPower: { true })
        let lpmEvents = await collect(lpmEngine, fixture)
        let lpmInitial = etaList(lpmEvents).first
        XCTAssertEqual(lpmInitial?.isInitial, true)
        XCTAssertEqual(lpmInitial?.seconds ?? 0, 1.0 * 0.5 * 1.5, accuracy: 1e-6,
                       "LPM initial estimate = duration × gate × 1.5")

        let normalBase = try makeTempDir("no-lpm")
        let normalEngine = makeEngine(splitBase: normalBase)
        let normalEvents = await collect(normalEngine, fixture)
        let normalInitial = etaList(normalEvents).first
        XCTAssertEqual(normalInitial?.seconds ?? 0, 1.0 * 0.5, accuracy: 1e-6,
                       "without LPM the initial estimate is the gate-class figure")
    }

    /// eng E5: the disk gate (writer math ×1.2 + tmp copy + session dirs + 1 GB headroom)
    /// refuses BEFORE any chunk — no session dir is created, and the terminal carries
    /// required vs free bytes.
    func testDiskPreflightRefusal() async throws {
        let base = try makeTempDir("disk")
        let engine = makeEngine(
            splitBase: base,
            freeDiskBytes: { _ in 100 })  // 100 bytes free → refused
        let events = await collect(engine, try AudioFixtureMaker.fixture(.stereo44k))
        guard case .failure(.diskPreflightFail(let required, let free))? = terminal(of: events) else {
            return XCTFail("expected .diskPreflightFail, got \(String(describing: terminal(of: events)))")
        }
        XCTAssertEqual(free, 100)
        // 1 s stereo: 44100×2×3×2 stems ×1.2 + tmp copy + 1 GB headroom ≫ 1 MB.
        XCTAssertGreaterThan(required, 1_000_000_000)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? ["?"], [],
                       "preflight refusal must not create a session dir")
    }

    // MARK: - ModelStore preload wiring (CEO row 15)

    /// The engine acquires the model through the store, so a launch-time preload is
    /// REUSED by the first split — the factory runs exactly once across prewarm + split.
    func testModelPreloadSharedWithFirstSplit() async throws {
        let base = try makeTempDir("preload")
        let counter = FactoryCounter()
        let store = ModelStore(factory: { units in
            counter.increment()
            return MockSeparator(computeUnits: units)
        })
        let engine = StemEngine(
            modelStore: store,
            calibrator: ETACalibrator(
                persistence: EngineMemoryPersistence(), isLowPowerModeEnabled: { false }),
            splitStore: SplitStore(baseDirectory: base))

        await engine.prewarmModel()
        XCTAssertEqual(counter.value, 1, "prewarm loads the model once")

        let events = await collect(
            engine, try AudioFixtureMaker.fixture(.stereo44k))
        guard case .completed = terminal(of: events) else {
            return XCTFail("split after preload failed: \(String(describing: terminal(of: events)))")
        }
        XCTAssertEqual(counter.value, 1,
                       "the first split must reuse the preloaded model (no load latency)")
    }

    // MARK: - Single-flight (CEO row 13)

    /// A second split while one is in flight is rejected immediately with
    /// `.failure(.generic)` and never interleaves with the running pipeline.
    func testSingleFlightRejectsSecondSplit() async throws {
        let fixture = try AudioFixtureMaker.fixture(.stereo44k)
        let base = try makeTempDir("single-flight")
        let gate = Gate()
        let engine = makeEngine(
            splitBase: base,
            hooks: StemEngine.Configuration.Hooks(onChunkBoundary: { _, _ in
                await gate.arrive()
            }))

        let firstStream = await engine.split(fixture)
        try await pollUntil(timeout: 10) { await gate.enteredCount >= 1 }
        let heldCount = await gate.enteredCount
        XCTAssertEqual(heldCount, 1,
                       "first split must be parked at its first chunk boundary")

        let secondStream = await engine.split(fixture)
        var rejection: [PipelineEvent] = []
        for await event in secondStream { rejection.append(event) }
        XCTAssertEqual(rejection.count, 1)
        XCTAssertEqual(rejection.first, .failure(.generic(
            "StemEngine: second split rejected — one split at a time (CEO row 13)")))

        await gate.openAll()
        var firstEvents: [PipelineEvent] = []
        for await event in firstStream { firstEvents.append(event) }
        guard case .completed = terminal(of: firstEvents) else {
            return XCTFail("first split must complete after release: \(String(describing: terminal(of: firstEvents)))")
        }
    }

    // MARK: - S2 row 1: no-audio video

    func testNoAudioVideoFailsWithNoAudio() async throws {
        let base = try makeTempDir("no-audio")
        let engine = makeEngine(splitBase: base)
        let events = await collect(engine, try AudioFixtureMaker.fixture(.videoNoAudio))
        XCTAssertEqual(terminal(of: events), .failure(.noAudio))
    }

    // MARK: - Gain conditioning (plan gain policy)

    /// One shared attenuation, monotone, only when the int24 conversion would clip.
    func testHeadroomGainConditioning() {
        XCTAssertEqual(StemEngine.conditionedGain(current: 1, peak: 0.9), 1,
                       "no attenuation below the rail")
        let clipped = StemEngine.conditionedGain(current: 1, peak: 1.4)
        XCTAssertEqual(clipped, 0.95 / 1.4, accuracy: 1e-6)
        XCTAssertEqual(StemEngine.conditionedGain(current: clipped, peak: 1.1), clipped,
                       "monotone: never restored upward within a split")
        XCTAssertEqual(StemEngine.conditionedGain(current: 0.5, peak: 1.4), 0.5,
                       "existing attenuation wins over a weaker requirement")
        XCTAssertEqual(StemEngine.conditionedGain(current: 1, peak: 0), 1,
                       "silence never attenuates")
    }

    // MARK: - WAV decoding (test-side)

    private struct DecodedWAV {
        var magic: String
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        var interleaved: [Float]
    }

    /// Minimal RIFF parser: fmt fields + int24 LE → Float on the ±0x7FFFFF rail.
    private func decodeWAV24(_ url: URL) throws -> DecodedWAV {
        let data = try Data(contentsOf: url)
        guard data.count >= 12, data.subdata(in: 0..<4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            throw FixtureError("not a RIFF/WAVE file: \(url.lastPathComponent)")
        }
        var sampleRate = 0
        var channels = 0
        var bits = 0
        var payload = Data()
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(le32(data, offset + 4))
            guard offset + 8 + size <= data.count else { break }
            let body = data.subdata(in: offset + 8..<offset + 8 + size)
            if id == "fmt ", body.count >= 16 {
                channels = Int(le16(body, 2))
                sampleRate = Int(le32(body, 4))
                bits = Int(le16(body, 14))
            }
            if id == "data" { payload = body }
            offset += 8 + size + (size % 2)
        }
        guard bits == 24, channels == 2 else {
            throw FixtureError("expected 24-bit stereo, got \(bits)-bit ×\(channels)")
        }
        var out = [Float]()
        out.reserveCapacity(payload.count / 3)
        var u: UInt32 = 0
        for p in stride(from: 0, to: payload.count - 2, by: 3) {
            u = UInt32(payload[p]) | (UInt32(payload[p + 1]) << 8) | (UInt32(payload[p + 2]) << 16)
            if u & 0x0080_0000 != 0 { u |= 0xFF00_0000 }
            out.append(Float(Int32(bitPattern: u)) / 8_388_607)
        }
        return DecodedWAV(
            magic: "RIFF", sampleRate: sampleRate, channels: channels,
            bitsPerSample: bits, interleaved: out)
    }

    private func le16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }

    private func le32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(le16(d, o)) | (UInt32(le16(d, o + 2)) << 16)
    }

    private static func maxAbs(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    private func pollUntil(
        timeout seconds: UInt64, _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(Int64(seconds)))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met within \(seconds)s")
    }

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

// MARK: - In-code MP4 fixture maker (H.264 video + AAC audio)

/// Synthesizes a small MP4 "camera video": black H.264 frames + a 44.1 kHz stereo AAC
/// mix — L = mid + side, R = mid − side (MockSeparator keeps the mid in vocals).
enum SplitVideoFixtureMaker {

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func makeMixedVideo(url: URL, seconds: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let sampleRate = 44_100.0
        let totalFrames = Int(sampleRate * seconds)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Video: 320×180 H.264, 30 fps black frames.
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 180,
            ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw FixtureError("cannot add video input") }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ])
        writer.add(videoInput)

        // Audio: linear-PCM input CMSampleBuffers, encoded to AAC by the writer.
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else { throw FixtureError("cannot add audio input") }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw FixtureError("startWriting failed: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(30 * seconds)

        // Host empiricism: spinning on `isReadyForMoreMediaData` from the test's main
        // thread deadlocks on this toolchain — the writer services its inputs through
        // queues the spinning thread starves. Both tracks are driven by the documented
        // `requestMediaDataWhenReady` pumps on background queues, with hard timeouts so
        // a stalled encoder fails the test instead of hanging the run.
        var videoFailure: String?
        let videoPumped = DispatchGroup()
        videoPumped.enter()
        var videoFrame = 0
        let videoQueue = DispatchQueue(label: "stemsplitter.fixture.video")
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                if videoFrame >= frameCount {
                    videoInput.markAsFinished()
                    videoPumped.leave()
                    return
                }
                do {
                    let pixelBuffer = try Self.blackPixelBuffer(width: 320, height: 180)
                    if !adaptor.append(
                        pixelBuffer,
                        withPresentationTime: CMTime(
                            value: CMTimeValue(videoFrame), timescale: 30)) {
                        videoFailure = "video append failed: \(String(describing: writer.error))"
                        videoPumped.leave()
                        return
                    }
                } catch {
                    videoFailure = String(describing: error)
                    videoPumped.leave()
                    return
                }
                videoFrame += 1
            }
        }

        // The mix: mid = 0.4·440 Hz (kept by the mock in vocals), side = 0.1·3 kHz
        // (hard-panned; complement side lands in instrumental).
        var audioFailure: String?
        let audioPumped = DispatchGroup()
        audioPumped.enter()
        var frame = 0
        let audioQueue = DispatchQueue(label: "stemsplitter.fixture.audio")
        audioInput.requestMediaDataWhenReady(on: audioQueue) {
            while audioInput.isReadyForMoreMediaData {
                if frame >= totalFrames {
                    audioInput.markAsFinished()
                    audioPumped.leave()
                    return
                }
                let count = min(1_024, totalFrames - frame)
                let buffer: CMSampleBuffer
                do {
                    buffer = try Self.pcmSampleBuffer(
                        frames: count, startFrame: frame, sampleRate: sampleRate) { position in
                            let t = Double(position) / sampleRate
                            let mid = 0.4 * sin(2.0 * .pi * 440.0 * t)
                            let side = 0.1 * sin(2.0 * .pi * 3_000.0 * t)
                            return (Float(mid + side), Float(mid - side))
                        }
                } catch {
                    audioFailure = String(describing: error)
                    audioPumped.leave()
                    return
                }
                if !audioInput.append(buffer) {
                    audioFailure = "audio append failed: \(String(describing: writer.error))"
                    audioPumped.leave()
                    return
                }
                frame += count
            }
        }

        let pumpTimeout = DispatchTime.now() + 60
        if videoPumped.wait(timeout: pumpTimeout) == .timedOut
            || audioPumped.wait(timeout: pumpTimeout) == .timedOut {
            writer.cancelWriting()
            throw FixtureError(
                "fixture writer pumps stalled (videoFailure=\(videoFailure ?? "none"), audioFailure=\(audioFailure ?? "none"))")
        }
        if let videoFailure {
            writer.cancelWriting()
            throw FixtureError(videoFailure)
        }
        if let audioFailure {
            writer.cancelWriting()
            throw FixtureError(audioFailure)
        }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        if done.wait(timeout: .now() + 60) == .timedOut {
            writer.cancelWriting()
            throw FixtureError("finishWriting stalled")
        }
        guard writer.status == .completed else {
            throw FixtureError("finishWriting failed: \(String(describing: writer.error))")
        }
    }

    /// Wraps interleaved stereo Float32 PCM in a CMSampleBuffer for the writer's AAC
    /// encoder (input format described via CMAudioFormatDescription).
    private static func pcmSampleBuffer(
        frames count: Int, startFrame: Int, sampleRate: Double,
        samples: (Int) -> (Float, Float)
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription) == noErr,
            let formatDescription else {
            throw FixtureError("CMAudioFormatDescriptionCreate failed")
        }

        var pcm = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            let (left, right) = samples(startFrame + i)
            pcm[i * 2] = left
            pcm[i * 2 + 1] = right
        }
        let byteCount = pcm.count * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let blockBuffer else {
            throw FixtureError("CMBlockBufferCreateWithMemoryBlock failed")
        }
        let copyStatus = pcm.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw FixtureError("CMBlockBufferReplaceDataBytes failed: \(copyStatus)")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(count), timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else {
            throw FixtureError("CMSampleBufferCreateReady failed")
        }
        return sampleBuffer
    }

    private static func blackPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw FixtureError("CVPixelBufferCreate failed: \(status)")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}
