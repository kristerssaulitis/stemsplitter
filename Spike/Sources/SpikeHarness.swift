import AVFoundation
import CoreMedia
import CoreML
import Foundation
import StemCore

// ============================================================================================
// SpikeHarness — Day-1 benchmark harness (plan T1 / TE2, eng E3).
//
//   spike <corpus-dir> [--out <dir>]     run the FULL shipping-path pipeline over every
//                                        corpus file; per-file + per-stage wall-clock and a
//                                        machine-readable JSON summary
//   spike gen <dir> [--seconds 30,90,180]
//                                        write a synthetic stereo AAC corpus (tone+noise,
//                                        48 kHz, 128 kbps AVAssetWriter) for PLUMBING runs
//   spike help                           this text
//
// The run path IS the shipping path: StemEngine's five-stage streaming pipeline
// (AudioExtractor decode → 44.1 kHz stereo resample → fixed-chunk STFT → StemModel.separate
// → masked ISTFT + overlap-add + spectral complement → 24-bit WAV ×2), driven through the
// public actor with per-stage timing collected via `Hooks.onChunkTimed`.
//
// VALIDATION SCOPE (important): runs recorded with the MockSeparator on macOS prove the
// harness plumbing only. They are NOT the Day-1 device gate. The gate (plan premise 4 +
// 2026-10-01 addendum) is: 3-minute 96-128 kbps AAC stereo source splits in <90 s wall-clock
// ON an iPhone 17 (A19) with the real CoreML model, ANE residency verified (eng E3). See
// Spike/SPIKE.md for the on-device protocol.
// ============================================================================================

enum SpikeHarness {

    static let version = "spike/1.0"

    // MARK: - CLI entry

    /// Returns the process exit code: 0 = all files split, 1 = pipeline failure,
    /// 2 = usage error.
    static func run(arguments: [String]) async -> Int32 {
        let args = Array(arguments.dropFirst())
        guard let first = args.first else {
            usage()
            return 2
        }
        if first == "help" || first == "-h" || first == "--help" {
            usage()
            return 0
        }
        if first == "gen" {
            guard let dir = args.dropFirst().first else {
                FileHandle.standardError.write("spike gen: missing output directory\n".data(using: .utf8)!)
                return 2
            }
            let seconds = flagValue(args, "--seconds").map {
                $0.split(separator: ",").compactMap { Double($0) }
            } ?? [30, 90, 180]
            do {
                try generateCorpus(into: URL(fileURLWithPath: dir), durationsSeconds: seconds)
            } catch {
                FileHandle.standardError.write("spike gen failed: \(error)\n".data(using: .utf8)!)
                return 1
            }
            return 0
        }

        // Default mode: `spike <corpus-dir> [--out <dir>]`
        let corpusDir = URL(fileURLWithPath: first, isDirectory: true)
        let outDir = URL(fileURLWithPath: flagValue(args, "--out") ?? ".work/spike-out",
                         isDirectory: true)
        return await runSplits(corpusDir: corpusDir, outDir: outDir)
    }

    private static func flagValue(_ args: [String], _ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static func usage() {
        print("""
        \(version) — StemSplitter Day-1 benchmark harness (plan T1/TE2, eng E3)

        USAGE
          spike <corpus-dir> [--out <dir>]   run the full shipping-path pipeline over every
                                             corpus file (m4a/mp4/mov/aac/mp3/wav/caf)
          spike gen <dir> [--seconds 30,90,180]
                                             generate a synthetic stereo AAC corpus
                                             (48 kHz, 128 kbps, tone+noise) — plumbing runs
          spike help

        NOTES
          --out defaults to .work/spike-out (wiped at the start of each run).
          Runs with the built-in MockSeparator on macOS are HARNESS-VALIDATION ONLY.
          The 90 s/3-min gate is measured on an iPhone 17 (A19) with the real model —
          see Spike/SPIKE.md.
        """)
    }

    // MARK: - Split run

    private struct StageWall: Codable {
        var decodeMs = 0.0
        var stftMs = 0.0
        var separateMs = 0.0
        var synthesizeMs = 0.0
        var writeMs = 0.0
    }

    private struct StageCounts: Codable {
        var decode = 0
        var stft = 0
        var separate = 0
        var synthesize = 0
        var write = 0
    }

    private struct OutputReport: Codable {
        var vocalsPath: String
        var instrumentalPath: String
        var vocalsBytes: Int64
        var instrumentalBytes: Int64
        var vocalsWAVHeader: String
        var instrumentalWAVHeader: String
    }

    private struct FileReport: Codable {
        var file: String
        var path: String
        var sourceDurationSeconds: Double
        var sourceCodec: String?
        var sourceSampleRateHz: Double?
        var chunks: Int
        var wallClockSeconds: Double
        var stageWallMs: StageWall
        var stageChunkCounts: StageCounts
        var outputs: OutputReport?
        var failure: String?
    }

    private struct PlatformInfo: Codable {
        var machine: String
        var osVersion: String
        var activeCPUs: Int
        var physicalMemoryBytes: UInt64
        var lowPowerMode: Bool
    }

    private struct ConfigInfo: Codable {
        var modelID: String
        var computeUnits: String
        var queueCapacity: Int
        var outputSampleRateHz: Double
        var outputChannels: Int
    }

    private struct SpikeSummary: Codable {
        var tool: String
        /// What these numbers DO and DO NOT prove (validation scope).
        var validationScope: String
        var platform: PlatformInfo
        var configuration: ConfigInfo
        var modelLoadMs: Double
        var files: [FileReport]
        var totalWallClockSeconds: Double
    }

    /// Lock-protected per-stage accumulator fed by the engine's `onChunkTimed` hook.
    private final class StageTimings: @unchecked Sendable {
        private let lock = NSLock()
        private var sums: [PipelineStage: Double] = [:]
        private var counts: [PipelineStage: Int] = [:]

        func record(_ stage: PipelineStage, _ milliseconds: Double) {
            lock.lock()
            defer { lock.unlock() }
            sums[stage, default: 0] += milliseconds
            counts[stage, default: 0] += 1
        }

        /// Clears the accumulator between files (the harness reuses one engine).
        func reset() {
            lock.lock()
            defer { lock.unlock() }
            sums = [:]
            counts = [:]
        }

        func snapshot() -> (sums: [PipelineStage: Double], counts: [PipelineStage: Int]) {
            lock.lock()
            defer { lock.unlock() }
            return (sums, counts)
        }
    }

    /// Runs the shipping pipeline over every corpus file. Returns an exit code.
    static func runSplits(corpusDir: URL, outDir: URL) async -> Int32 {
        let files = corpusFiles(in: corpusDir)
        guard !files.isEmpty else {
            FileHandle.standardError.write(
                "spike: no corpus files (m4a/mp4/mov/aac/mp3/wav/caf) in \(corpusDir.path)\n"
                    .data(using: .utf8)!)
            return 2
        }

        // Scratch output: wiped per run so accumulated session dirs never skew the
        // engine's same-session disk gate (eng E5) or pad the volume.
        try? FileManager.default.removeItem(at: outDir)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write("spike: cannot create \(outDir.path): \(error)\n"
                .data(using: .utf8)!)
            return 1
        }

        // Harness dependencies: MockSeparator proves the plumbing with the REAL
        // engine/pipeline (model swap is the only substitution — the Day-1 device
        // gate runs CoreMLSeparator via the default factory, see SPIKE.md).
        let modelStore = ModelStore(factory: { units in MockSeparator(computeUnits: units) })
        let calibrator = ETACalibrator(persistence: FileKeyValuePersistence(
            fileURL: outDir.appendingPathComponent("eta-calibration.json")))
        let splitStore = SplitStore(baseDirectory: outDir.appendingPathComponent("Splits"))
        // The engine's disk gate resolves the volume THROUGH the base-directory URL
        // (Configuration.defaultFreeDiskBytes), which requires the dir to exist — in
        // the app Caches/Splits pre-exists; the harness recreates that precondition.
        try? FileManager.default.createDirectory(
            at: splitStore.baseDirectory, withIntermediateDirectories: true)
        let timings = StageTimings()
        var configuration = StemEngine.Configuration()
        configuration.hooks = StemEngine.Configuration.Hooks(onChunkTimed: { stage, _, ms in
            timings.record(stage, ms)
        })
        let engine = StemEngine(
            modelStore: modelStore,
            calibrator: calibrator,
            splitStore: splitStore,
            configuration: configuration)

        let runStart = ContinuousClock.now
        print("StemSplitter \(version) — harness run (MockSeparator, macOS)")
        print("corpus: \(corpusDir.path)  out: \(outDir.path)")

        let prewarmStart = ContinuousClock.now
        await engine.prewarmModel()
        let modelLoadMs = StemEngine.elapsedMsPublic(since: prewarmStart)
        print("model preload: \(String(format: "%.1f", modelLoadMs)) ms")

        var reports: [FileReport] = []
        let extractor = AudioExtractor()

        for file in files {
            print("\n── \(file.lastPathComponent) ──────────────────────────────")
            var report = FileReport(
                file: file.lastPathComponent, path: file.path,
                sourceDurationSeconds: 0, sourceCodec: nil, sourceSampleRateHz: nil,
                chunks: 0, wallClockSeconds: 0,
                stageWallMs: StageWall(), stageChunkCounts: StageCounts(),
                outputs: nil, failure: nil)

            // Source metadata through the shipping probe (codec/rate/duration).
            let probe: AudioProbe
            do {
                probe = try await extractor.probe(at: file)
            } catch {
                report.failure = "probe failed: \(error)"
                reports.append(report)
                print("   PROBE FAILED: \(error)")
                continue
            }
            report.sourceDurationSeconds = probe.duration
            report.sourceCodec = probe.codec
            report.sourceSampleRateHz = probe.sampleRate
            print("   source: \(String(format: "%.2f", probe.duration))s "
                + "\(probe.codec ?? "?") @ \(Int(probe.sampleRate ?? 0)) Hz")

            // The split: consume the engine's single event stream; wall-clock wraps
            // the whole stream (preflights + all five pipeline stages).
            timings.reset()
            var outputs: SplitOutputs?
            var failure: StemError?
            var lastMilestone = 0
            let wallStart = ContinuousClock.now
            let stream = await engine.split(file)
            for await event in stream {
                switch event {
                case .progress(let fraction):
                    let percent = Int(fraction * 100)
                    if percent >= lastMilestone + 25 {
                        lastMilestone = percent - percent % 25
                        print("   progress \(lastMilestone)%")
                    }
                case .completed(let splitOutputs):
                    outputs = splitOutputs
                case .failure(let stemError):
                    failure = stemError
                case .phase, .peaks, .eta:
                    break
                }
            }
            report.wallClockSeconds = StemEngine.elapsedMsPublic(since: wallStart) / 1000

            // Per-stage wall-clock from the engine's own per-chunk measurements.
            let snapshot = timings.snapshot()
            let chunks = snapshot.counts[.separate] ?? 0
            report.chunks = chunks
            report.stageWallMs = StageWall(
                decodeMs: snapshot.sums[.decode] ?? 0,
                stftMs: snapshot.sums[.stft] ?? 0,
                separateMs: snapshot.sums[.separate] ?? 0,
                synthesizeMs: snapshot.sums[.synthesize] ?? 0,
                writeMs: snapshot.sums[.write] ?? 0)
            report.stageChunkCounts = StageCounts(
                decode: snapshot.counts[.decode] ?? 0,
                stft: snapshot.counts[.stft] ?? 0,
                separate: chunks,
                synthesize: snapshot.counts[.synthesize] ?? 0,
                write: snapshot.counts[.write] ?? 0)

            if let failure {
                report.failure = String(describing: failure)
                reports.append(report)
                print("   FAILED: \(failure)")
                continue
            }

            // Output sanity: streaming WAV headers validated by the shipping validator.
            if let outputs {
                let vocalsValidation = WAVWriter.validateHeader(at: outputs.vocalsURL)
                let instrumentalValidation = WAVWriter.validateHeader(at: outputs.instrumentalURL)
                let vocalBytes = (try? outputs.vocalsURL.resourceValues(
                    forKeys: [.fileSizeKey]).fileSize) ?? 0
                let instrumentalBytes = (try? outputs.instrumentalURL.resourceValues(
                    forKeys: [.fileSizeKey]).fileSize) ?? 0
                report.outputs = OutputReport(
                    vocalsPath: outputs.vocalsURL.path,
                    instrumentalPath: outputs.instrumentalURL.path,
                    vocalsBytes: Int64(vocalBytes),
                    instrumentalBytes: Int64(instrumentalBytes),
                    vocalsWAVHeader: String(describing: vocalsValidation),
                    instrumentalWAVHeader: String(describing: instrumentalValidation))
            }

            reports.append(report)
            let wall = report.wallClockSeconds
            print("   wall clock \(String(format: "%.2f", wall))s · "
                + "\(chunks) chunks (\(String(format: "%.0f", Double(chunks) / max(probe.duration, 0.001))) chunks/s of audio)")
            print(stageLine("decode+resample", report.stageWallMs.decodeMs, chunks))
            print(stageLine("stft", report.stageWallMs.stftMs, chunks))
            print(stageLine("separate", report.stageWallMs.separateMs, chunks))
            print(stageLine("istft+ola+complement", report.stageWallMs.synthesizeMs, chunks))
            print(stageLine("wav write", report.stageWallMs.writeMs, chunks))
            if let outputs = report.outputs {
                print("   vocals: \(outputs.vocalsPath) (\(outputs.vocalsBytes) B, header \(outputs.vocalsWAVHeader))")
                print("   instrumental: \(outputs.instrumentalPath) (\(outputs.instrumentalBytes) B, header \(outputs.instrumentalWAVHeader))")
            }
            print("   scope: HARNESS-VALIDATION ONLY (MockSeparator, macOS — not the device gate)")
        }

        let totalWall = StemEngine.elapsedMsPublic(since: runStart) / 1000
        let processInfo = ProcessInfo.processInfo
        let summary = SpikeSummary(
            tool: version,
            validationScope:
                "Harness-plumbing validation: full shipping-path pipeline (stereo decode, "
                + "resample to 44.1 kHz, fixed-chunk STFT, separator, spectral complement, "
                + "overlap-add, 24-bit WAV write) driven through StemEngine with the "
                + "MockSeparator on macOS. NOT the Day-1 device gate: the gate is <90 s for a "
                + "3-minute 96-128 kbps AAC stereo source on an iPhone 17 (A19) with the real "
                + "CoreML model and ANE residency verified (plan premise 4 + 2026-10-01 "
                + "addendum, eng E3). See Spike/SPIKE.md.",
            platform: PlatformInfo(
                machine: machineModel(),
                osVersion: processInfo.operatingSystemVersionString,
                activeCPUs: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory,
                lowPowerMode: processInfo.isLowPowerModeEnabled),
            configuration: ConfigInfo(
                modelID: MockSeparator.modelID,
                computeUnits: String(describing: MLComputeUnits.all),
                queueCapacity: configuration.queueCapacity,
                outputSampleRateHz: extractor.outputSampleRate,
                outputChannels: 2),
            modelLoadMs: modelLoadMs,
            files: reports,
            totalWallClockSeconds: totalWall)

        print("\n═══ machine-readable summary ═══")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let marker = "--- spike-summary-json ---"
        if let data = try? encoder.encode(summary) {
            print(marker)
            print(String(decoding: data, as: UTF8.self))
            print("--- end-spike-summary-json ---")
        } else {
            FileHandle.standardError.write("spike: summary encode failed\n".data(using: .utf8)!)
        }

        return reports.allSatisfy { $0.failure == nil && $0.outputs != nil } ? 0 : 1
    }

    private static func stageLine(_ name: String, _ ms: Double, _ chunks: Int) -> String {
        let mean = chunks > 0 ? ms / Double(chunks) : 0
        let padded = name.padding(toLength: 22, withPad: " ", startingAt: 0)
        return String(format: "   %@ %9.1f ms total  %6.2f ms/chunk", padded, ms, mean)
    }

    private static func corpusFiles(in dir: URL) -> [URL] {
        let extensions: Set<String> = ["m4a", "aac", "mp4", "mov", "mp3", "wav", "caf"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { extensions.contains((($0 as NSString).pathExtension).lowercased()) }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    static func machineModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            var bytes: [UInt8] = []
            for byte in raw {
                guard byte != 0 else { break }
                bytes.append(byte)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    // MARK: - Synthetic corpus generation (AVAssetWriter → AAC)

    /// Writes deterministic tone+noise stereo AAC files: `corpus-<n>s.m4a`.
    /// 48 kHz (camera-native rate — exercises the 44.1 kHz resample stage), 128 kbps
    /// (inside the plan's 96-128 kbps corpus window), AVAssetWriter per the protocol.
    static func generateCorpus(into dir: URL, durationsSeconds: [Double]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for duration in durationsSeconds {
            let url = dir.appendingPathComponent("corpus-\(Int(duration))s.m4a")
            let start = ContinuousClock.now
            try writeAAC(url: url, durationSeconds: duration)
            let ms = StemEngine.elapsedMsPublic(since: start)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("generated \(url.path): \(Int(duration))s, \(size) B, \(String(format: "%.0f", ms)) ms")
        }
    }

    private static func writeAAC(url: URL, durationSeconds: Double) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: corpusSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: corpusBitrate,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else {
            throw GenerationError.writer(writer.error.map(String.init(describing:)) ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(durationSeconds * corpusSampleRate)
        let state = GenerationState()
        let queue = DispatchQueue(label: "com.stemsplitter.spike.corpusgen")
        let appended = DispatchSemaphore(value: 0)

        input.requestMediaDataWhenReady(on: queue) {
            var ptsFrames: Int64 = 0
            while input.isReadyForMoreMediaData {
                let start = state.emitted
                guard start < totalFrames else {
                    input.markAsFinished()
                    appended.signal()
                    return
                }
                let count = min(blockFrames, totalFrames - start)
                do {
                    let buffer = try sampleBuffer(
                        pcm: toneNoiseMix(frameOffset: Int64(start), frameCount: count,
                                          seed: UInt64(totalFrames)),
                        frameCount: count, ptsFrames: ptsFrames)
                    guard input.append(buffer) else {
                        throw GenerationError.append(
                            writer.error.map(String.init(describing:)) ?? "unknown")
                    }
                } catch {
                    state.error = error
                    input.markAsFinished()
                    appended.signal()
                    return
                }
                ptsFrames += Int64(count)
                state.emitted += count
            }
        }
        appended.wait()
        if let error = state.error { throw error }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw GenerationError.writer(writer.error.map(String.init(describing:)) ?? "unknown")
        }
    }

    static let corpusSampleRate: Double = 48_000  // camera-native; exercises the resample stage
    static let corpusBitrate = 128_000            // inside the plan's 96-128 kbps window
    static let blockFrames = 48_000               // 1 s per CMSampleBuffer

    private enum GenerationError: Error {
        case writer(String)
        case append(String)
        case format(String)
    }

    private final class GenerationState: @unchecked Sendable {
        var emitted = 0
        var error: Error?
    }

    /// Deterministic tone+noise stereo mix (no randomness across runs): three tone
    /// pairs with slight L/R detune plus per-channel seeded white noise, so the corpus
    /// carries both mid and side energy (the shipping separator contract is stereo).
    /// Peak stays under 0.7 — no clipping into the encoder.
    static func toneNoiseMix(frameOffset: Int64, frameCount: Int, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed ^ UInt64(bitPattern: Int64(frameOffset)))
        var pcm = [Float]()
        pcm.reserveCapacity(frameCount * 2)
        for i in 0..<frameCount {
            let t = Double(frameOffset + Int64(i)) / corpusSampleRate
            let wobble = 0.6 + 0.4 * sin(2 * Double.pi * 0.07 * t)
            let toneL = 0.22 * sin(2 * Double.pi * 220.0 * t)
                + 0.16 * sin(2 * Double.pi * 440.5 * t)
                + 0.10 * sin(2 * Double.pi * 660.0 * t)
            let toneR = 0.22 * sin(2 * Double.pi * 221.0 * t)
                + 0.16 * sin(2 * Double.pi * 440.0 * t)
                + 0.10 * sin(2 * Double.pi * 662.0 * t)
            let noiseL = (Double(rng.nextUnit()) * 2 - 1) * 0.07
            let noiseR = (Double(rng.nextUnit()) * 2 - 1) * 0.07
            pcm.append(Float(toneL * wobble + noiseL))
            pcm.append(Float(toneR * wobble + noiseR))
        }
        return pcm
    }

    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func nextUnit() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }
    }

    /// Interleaved float32 stereo PCM → `CMSampleBuffer` for the AVAssetWriter input.
    private static func sampleBuffer(
        pcm: [Float], frameCount: Int, ptsFrames: Int64
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: corpusSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription) == noErr,
            let formatDescription else {
            throw GenerationError.format("CMAudioFormatDescriptionCreate failed")
        }
        let dataLength = pcm.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataLength,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: dataLength, flags: 0, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else {
            throw GenerationError.format("CMBlockBufferCreateWithMemoryBlock failed")
        }
        let copyStatus = pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: dataLength)
        }
        guard copyStatus == noErr else {
            throw GenerationError.format("CMBlockBufferReplaceDataBytes failed: \(copyStatus)")
        }
        let timescale = CMTimeScale(corpusSampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount), timescale: timescale),
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsFrames), timescale: timescale),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr, let sample else {
            throw GenerationError.format("CMSampleBufferCreateReady failed")
        }
        return sample
    }
}

// MARK: - Clock helper (single definition shared by the harness)

extension StemEngine {
    /// Public harness-facing variant of the engine's internal elapsed-ms helper so the
    /// spike measures with the exact same clock idiom as the pipeline.
    static func elapsedMsPublic(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }
}
