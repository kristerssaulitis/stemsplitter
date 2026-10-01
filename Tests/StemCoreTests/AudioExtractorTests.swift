import AVFoundation
import AudioToolbox
import XCTest

@testable import StemCore

/// AudioExtractor tests (plan T2 verify: no-audio / mono / 48k / HE-AAC / corrupt
/// fixtures; approved test plan edge cases; Section 6 coverage map).
///
/// All fixtures are generated programmatically by `AudioFixtureMaker` (AAC via
/// ExtAudioFile, video via AVAssetWriter, corrupt via truncation) into
/// `Tests/Fixtures/Audio/` — regenerated once per test-bundle process, so the
/// checked-in files are just the latest run's artifacts and tests self-heal if
/// they are missing.
final class AudioExtractorTests: XCTestCase {

    // MARK: - probe()

    func testProbeStereo44kHzReportsDurationHasAudioCodecAndRate() async throws {
        let url = try AudioFixtureMaker.fixture(.stereo44k)
        let extractor = AudioExtractor()
        let probe = try await extractor.probe(at: url)
        XCTAssertEqual(probe.hasAudio, true)
        XCTAssertEqual(probe.codec, "aac")
        XCTAssertEqual(probe.sampleRate ?? 0, 44_100, accuracy: 1)
        XCTAssertEqual(probe.duration, 1.0, accuracy: 0.1)
    }

    func testProbeVideoWithoutAudioReportsHasAudioFalse() async throws {
        let url = try AudioFixtureMaker.fixture(.videoNoAudio)
        let extractor = AudioExtractor()
        let probe = try await extractor.probe(at: url)
        XCTAssertEqual(probe.hasAudio, false)
        XCTAssertNil(probe.codec)
        XCTAssertNil(probe.sampleRate)
        XCTAssertEqual(probe.duration, 1.0, accuracy: 0.1)
    }

    func testProbe48kHzReportsSourceSampleRatePreConversion() async throws {
        let url = try AudioFixtureMaker.fixture(.stereo48k)
        let extractor = AudioExtractor()
        let probe = try await extractor.probe(at: url)
        // probe() reports the source stream rate, pre-44.1k conversion.
        XCTAssertEqual(probe.sampleRate ?? 0, 48_000, accuracy: 1)
        XCTAssertEqual(probe.hasAudio, true)
    }

    func testProbeHEAACReportsCodec() async throws {
        let url = try AudioFixtureMaker.fixture(.heAAC)
        let extractor = AudioExtractor()
        let probe = try await extractor.probe(at: url)
        XCTAssertEqual(probe.hasAudio, true)
        XCTAssertEqual(probe.codec, "aac")
    }

    // MARK: - Decode happy path

    func testDecodeHappyPathStereo44kHzEmitsStereo44_1FloatChunks() async throws {
        let url = try AudioFixtureMaker.fixture(.stereo44k)
        let extractor = AudioExtractor(chunkFrames: 4096)
        var chunks: [AudioChunk] = []
        for try await chunk in extractor.chunks(from: url) {
            chunks.append(chunk)
        }
        XCTAssertGreaterThan(chunks.count, 1, "4096-frame chunks should tile a 1 s source")
        for chunk in chunks {
            XCTAssertEqual(chunk.sampleRate, 44_100)
            XCTAssertEqual(chunk.channels, 2)
            XCTAssertLessThanOrEqual(chunk.frameCount, 4096)
        }
        let frames = chunks.reduce(0) { $0 + $1.frameCount }
        XCTAssertEqual(Double(frames), 44_100.0, accuracy: 2_048, "total ≈ 1 s at 44.1 kHz")
        // Content sanity: the 440 Hz tone must actually be in the samples.
        let peak = chunks.flatMap(\.interleavedSamples).map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "decoded audio should not be silent")
        // 44.1 kHz native source must not be resampled away from its rate.
        XCTAssertLessThanOrEqual(abs(frames - 44_100), 2_048)
    }

    // MARK: - Error mapping (Section 2 rows 1-2, F5)

    func testNoAudioVideoSurfacesNoAudioOnFirstPull() async throws {
        let url = try AudioFixtureMaker.fixture(.videoNoAudio)
        let extractor = AudioExtractor()
        // probe() path
        let probe = try await extractor.probe(at: url)
        XCTAssertEqual(probe.hasAudio, false)
        // decode path: the stream throws instead of finishing empty.
        let iterator = extractor.chunks(from: url).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected StemError.noAudio")
        } catch let error as StemError {
            XCTAssertEqual(error, .noAudio)
            XCTAssertEqual(error.userMessage, "No audible audio track found in this video")
        }
    }

    func testCorruptContainerSurfacesCorruptAssetDistinctFromNoAudio() async throws {
        let url = try AudioFixtureMaker.fixture(.corrupt)
        let extractor = AudioExtractor()
        // probe() path
        do {
            _ = try await extractor.probe(at: url)
            XCTFail("expected StemError.corruptAsset from probe")
        } catch let error as StemError {
            XCTAssertEqual(error, .corruptAsset)
            XCTAssertEqual(error.userMessage, "This video can't be processed")
            XCTAssertNotEqual(error, .noAudio, "corrupt must be distinct from no-audio")
        }
        // decode path
        let iterator = extractor.chunks(from: url).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected StemError.corruptAsset from decode")
        } catch let error as StemError {
            XCTAssertEqual(error, .corruptAsset)
        }
    }

    func testMissingFileSurfacesGenericCallerBug() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("stemsplitter-missing-\(UUID().uuidString).m4a")
        let extractor = AudioExtractor()
        let iterator = extractor.chunks(from: missing).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected StemError.generic")
        } catch let error as StemError {
            guard case .generic = error else {
                return XCTFail("expected .generic, got \(error)")
            }
        }
    }

    // MARK: - Mono → stereo (Section 4 edge case)

    func testMonoSourceUpmixedToDualMonoStereo() async throws {
        let url = try AudioFixtureMaker.fixture(.mono44k)
        let extractor = AudioExtractor(chunkFrames: 8192)
        var left: [Float] = []
        var right: [Float] = []
        for try await chunk in extractor.chunks(from: url) {
            XCTAssertEqual(chunk.channels, 2, "mono source must emerge as stereo")
            XCTAssertEqual(chunk.sampleRate, 44_100)
            for i in stride(from: 0, to: chunk.interleavedSamples.count, by: 2) {
                left.append(chunk.interleavedSamples[i])
                right.append(chunk.interleavedSamples[i + 1])
            }
        }
        XCTAssertGreaterThan(left.count, 40_000)
        // Dual mono: both channels carry the identical upmixed signal.
        let maxDelta = zip(left, right).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(maxDelta, 1e-4, "mono upmix must be dual-mono (L == R)")
        // And it is the source tone, not silence in one channel.
        let rmsLeft = Self.rms(left)
        XCTAssertEqual(rmsLeft, 0.5 / Float(2).squareRoot(), accuracy: 0.1)
        XCTAssertGreaterThan(rmsLeft, 0.1)
    }

    // MARK: - 48 kHz resample (CRITICAL)

    /// CRITICAL test (approved test plan): 48 kHz source resampled to 44.1 kHz
    /// with alignment verified — time alignment via the known impulse, total
    /// length, and chunk-size invariance (no dropped/duplicated samples at
    /// converter buffer boundaries, which is what the chunk grid depends on).
    func test48kHzSourceResampledTo44_1kHzWithAlignmentVerified() async throws {
        let url = try AudioFixtureMaker.fixture(.stereo48k)
        let extractor = AudioExtractor(chunkFrames: 4096)
        var samples: [Float] = []
        var totalFrames = 0
        for try await chunk in extractor.chunks(from: url) {
            XCTAssertEqual(chunk.sampleRate, 44_100, "output rate must be 44.1 kHz")
            XCTAssertEqual(chunk.channels, 2)
            samples.append(contentsOf: chunk.interleavedSamples)
            totalFrames += chunk.frameCount
        }
        // 2.0 s at 48 kHz = 96 000 frames in → ≈ 88 200 frames out.
        XCTAssertEqual(
            Double(totalFrames), 88_200, accuracy: 2_048,
            "total resampled length \(totalFrames) deviates from expected 88 200")

        // Time alignment: the source carries an impulse exactly at t = 1.0 s
        // (frame 48 000 @ 48 kHz); after resampling its peak must sit at
        // frame 44 100 (± half a converter buffer), i.e. still at t = 1.0 s.
        let leftChannel = samples.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let windowStart = 44_100 - 2_048
        let windowEnd = 44_100 + 2_048
        var peakFrame = windowStart
        var peakValue = Float(0)
        for frame in windowStart..<min(windowEnd, leftChannel.count) {
            if abs(leftChannel[frame]) > peakValue {
                peakValue = abs(leftChannel[frame])
                peakFrame = frame
            }
        }
        XCTAssertGreaterThan(peakValue, 0.5, "impulse must survive decode+resample")
        XCTAssertTrue(
            abs(peakFrame - 44_100) <= 256,
            "impulse landed at frame \(peakFrame); alignment drift breaks the chunk grid")

        // No stray earlier spike: before the impulse, the signal is a 0.4 sine.
        let prePeak = leftChannel[0..<32_000].map { abs($0) }.max() ?? 0
        XCTAssertLessThan(prePeak, 0.6, "unexpected spike before the expected impulse")
    }

    /// Chunk-grid precondition: the concatenated sample stream is identical
    /// regardless of the buffer granularity pulled — i.e. the extractor never
    /// drops, duplicates, or reorders samples at its own buffer boundaries.
    func testChunkSizeInvarianceStreamIdenticalAcrossGrainSizes() async throws {
        let url = try AudioFixtureMaker.fixture(.stereo48k)
        func concatenated(chunkFrames: Int) async throws -> [Float] {
            let extractor = AudioExtractor(chunkFrames: chunkFrames)
            var all: [Float] = []
            for try await chunk in extractor.chunks(from: url) {
                all.append(contentsOf: chunk.interleavedSamples)
            }
            return all
        }
        let fine = try await concatenated(chunkFrames: 512)
        let coarse = try await concatenated(chunkFrames: 1 << 16)
        XCTAssertEqual(fine.count, coarse.count, "sample counts must match across grain sizes")
        XCTAssertEqual(fine, coarse, "streams must be byte-identical across grain sizes")
    }

    // MARK: - HE-AAC (Section 4 edge case)

    func testHEAACSourceDecodesToStereo44_1kHz() async throws {
        let url = try AudioFixtureMaker.fixture(.heAAC)
        let extractor = AudioExtractor(chunkFrames: 4096)
        var chunks: [AudioChunk] = []
        for try await chunk in extractor.chunks(from: url) {
            chunks.append(chunk)
        }
        XCTAssertFalse(chunks.isEmpty)
        let frames = chunks.reduce(0) { $0 + $1.frameCount }
        XCTAssertEqual(Double(frames), 88_200, accuracy: 2_048, "≈ 2 s at 44.1 kHz")
        for chunk in chunks {
            XCTAssertEqual(chunk.sampleRate, 44_100)
            XCTAssertEqual(chunk.channels, 2)
        }
        let peak = chunks.flatMap(\.interleavedSamples).map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1)
    }

    // MARK: - Pipeline contract

    func testMissingFileSurfacesGenericOnProbeToo() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("stemsplitter-missing-\(UUID().uuidString).m4a")
        do {
            _ = try await AudioExtractor().probe(at: missing)
            XCTFail("expected .generic")
        } catch let error as StemError {
            guard case .generic = error else { return XCTFail("expected .generic, got \(error)") }
        }
    }

    func testCancellationSurfacesStemErrorCancelled() async throws {
        let url = try AudioFixtureMaker.fixture(.stereo48k)
        // firstChunk signals "one chunk pulled"; go releases the task back into
        // its loop after the test has cancelled it — no race, deterministic.
        let (firstChunk, firstChunkCont) = AsyncStream.makeStream(of: Void.self)
        let (go, goCont) = AsyncStream.makeStream(of: Void.self)
        let task = Task<StemError?, Error> {
            let extractor = AudioExtractor(chunkFrames: 2048)
            let iterator = extractor.chunks(from: url).makeAsyncIterator()
            _ = try await iterator.next()
            firstChunkCont.yield()
            var goIterator = go.makeAsyncIterator()
            await goIterator.next()
            do {
                while try await iterator.next() != nil {}
                return nil  // finished cleanly without seeing cancellation
            } catch let error as StemError {
                return error
            }
        }
        var firstIterator = firstChunk.makeAsyncIterator()
        await firstIterator.next()
        task.cancel()
        goCont.yield()
        let observed = try await task.value
        XCTAssertEqual(observed, .cancelled, "mid-stream cancellation must surface .cancelled")
    }

    // MARK: - Helpers

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}

// MARK: - Fixture generation

/// The fixture set for AudioExtractor tests. Everything is synthesized here —
/// no checked-in binary dependencies; `Tests/Fixtures/Audio/` holds the
/// regenerated artifacts.
enum AudioFixtureMaker {

    enum Fixture: String, CaseIterable {
        case videoNoAudio = "no-audio.mp4"
        case corrupt = "corrupt.mp4"
        case mono44k = "mono-44k1s.m4a"
        case stereo44k = "stereo-44k1s.m4a"
        case stereo48k = "stereo-48k2s.m4a"
        case heAAC = "he-aac2s.m4a"
    }

    nonisolated(unsafe) private static var generated = Set<Fixture>()
    private static let lock = NSLock()

    static func fixture(_ fixture: Fixture) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        return try fixtureLocked(fixture)
    }

    /// Lock-free body; `fixture` wraps it, and the `.corrupt` case recurses
    /// here for its source without re-entering the lock.
    private static func fixtureLocked(_ fixture: Fixture) throws -> URL {
        if generated.contains(fixture) {
            return url(for: fixture)
        }
        try? FileManager.default.createDirectory(
            at: directory(), withIntermediateDirectories: true)
        switch fixture {
        case .videoNoAudio:
            try makeVideoOnly(url: url(for: fixture))
        case .mono44k:
            try makeAAC(
                url: url(for: fixture), sampleRate: 44_100, channels: 1, seconds: 1.0,
                subtype: kAudioFormatMPEG4AAC, signal: .tone(freq: 1_000, amp: 0.5))
        case .stereo44k:
            try makeAAC(
                url: url(for: fixture), sampleRate: 44_100, channels: 2, seconds: 1.0,
                subtype: kAudioFormatMPEG4AAC, signal: .tone(freq: 440, amp: 0.5))
        case .stereo48k:
            try makeAAC(
                url: url(for: fixture), sampleRate: 48_000, channels: 2, seconds: 2.0,
                subtype: kAudioFormatMPEG4AAC,
                signal: .toneWithImpulse(freq: 440, amp: 0.4, impulseFrame: 48_000))
        case .heAAC:
            try makeAAC(
                url: url(for: fixture), sampleRate: 44_100, channels: 2, seconds: 2.0,
                subtype: kAudioFormatMPEG4AAC_HE,
                signal: .toneWithImpulse(freq: 440, amp: 0.5, impulseFrame: 44_100))
        case .corrupt:
            try makeCorrupt(
                url: url(for: fixture),
                from: try fixtureLocked(.stereo48k))
        }
        generated.insert(fixture)
        return url(for: fixture)
    }

    private static func url(for fixture: Fixture) -> URL {
        // #filePath: …/Tests/StemCoreTests/AudioExtractorTests.swift
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/StemCoreTests
            .deletingLastPathComponent()  // Tests
        return testsDir
            .appendingPathComponent("Fixtures/Audio", isDirectory: true)
            .appendingPathComponent(fixture.rawValue)
    }

    private static func directory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Audio", isDirectory: true)
    }

    enum Signal {
        case tone(freq: Double, amp: Double)
        case toneWithImpulse(freq: Double, amp: Double, impulseFrame: Int)

        func sample(_ frame: Int, rate: Double) -> Float {
            switch self {
            case .tone(let freq, let amp):
                return Float(amp * sin(2.0 * .pi * freq * Double(frame) / rate))
            case .toneWithImpulse(let freq, let amp, let impulseFrame):
                if frame == impulseFrame {
                    return 1.0
                }
                return Float(amp * sin(2.0 * .pi * freq * Double(frame) / rate))
            }
        }
    }

    /// Encodes Float32 PCM to an `.m4a` (AAC-LC or HE-AAC) via ExtAudioFile.
    static func makeAAC(
        url: URL, sampleRate: Double, channels: Int, seconds: Double,
        subtype: AudioFormatID, signal: Signal
    ) throws {
        let frameCount = Int(sampleRate * seconds)
        var pcm = [Float](repeating: 0, count: frameCount * channels)
        for frame in 0..<frameCount {
            let value = signal.sample(frame, rate: sampleRate)
            for channel in 0..<channels {
                pcm[frame * channels + channel] = value
            }
        }

        var destinationASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: subtype,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0)

        var extFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileM4AType, &destinationASBD, nil,
            AudioFileFlags.eraseFile.rawValue, &extFile)
        guard status == noErr, let extFile else {
            throw FixtureError("ExtAudioFileCreateNew failed: \(status)")
        }
        defer { ExtAudioFileDispose(extFile) }

        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        status = ExtAudioFileSetProperty(
            extFile, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD)
        guard status == noErr else {
            throw FixtureError("ExtAudioFileSetProperty(ClientDataFormat) failed: \(status)")
        }

        try pcm.withUnsafeMutableBytes { raw in
            var bufferList = AudioBufferList()
            bufferList.mNumberBuffers = 1
            bufferList.mBuffers = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(raw.count),
                mData: raw.baseAddress)
            let writeStatus = ExtAudioFileWrite(
                extFile, AVAudioFrameCount(frameCount), &bufferList)
            guard writeStatus == noErr else {
                throw FixtureError("ExtAudioFileWrite failed: \(writeStatus)")
            }
        }
    }

    /// 1 s of 320×180 H.264 black video, no audio track (AVAssetWriter).
    static func makeVideoOnly(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 180,
            ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw FixtureError("AVAssetWriter cannot add video input")
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError("startWriting failed: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = 30
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                usleep(2_000)
            }
            let pixelBuffer = try Self.blackPixelBuffer(width: 320, height: 180)
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            if !adaptor.append(pixelBuffer, withPresentationTime: time) {
                throw FixtureError("append failed: \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw FixtureError("finishWriting failed: \(String(describing: writer.error))")
        }
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

    /// Truncated container (moov destroyed) — design fix F5 hostile fixture.
    static func makeCorrupt(url: URL, from source: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let bytes = try Data(contentsOf: source)
        try bytes.prefix(1_024).write(to: url)
    }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
