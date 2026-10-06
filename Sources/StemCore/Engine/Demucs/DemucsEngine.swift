import Accelerate
import CoreML
import Foundation
import os

/// The production engine: htdemucs (4 stems) on time-domain segments.
///
///     AudioExtractor → 7.8 s segments, 25 % overlap → HTDemucsSeparator
///       → triangle-weighted overlap-add (demucs `apply_model`) → WAV × 5
///
/// Writes drums/bass/other/vocals plus instrumental := source − vocals, so
/// vocals + instrumental sums to the source exactly (plan channel/gain policy).
/// Same `PipelineEvent` surface and preflight gates as `StemEngine`; memory is
/// O(segment), never O(song).
public actor DemucsEngine: StemEngineProtocol {

    public static let modelID = "htdemucs-v4-mixed"
    static let overlap = 0.25

    private let modelURL: URL?
    private let calibrator: ETACalibrator
    private let splitStore: SplitStore
    private let extractor: AudioExtractor
    private var loadTask: Task<HTDemucsSeparator, Error>?
    private var pipelineTask: Task<Void, Never>?
    private var isRunning = false

    nonisolated private let log = Logger(subsystem: "com.stemsplitter.app", category: "demucs")

    /// `modelURL`: compiled `.mlmodelc`; default is `htdemucs.mlmodelc` in the main bundle.
    public init(
        modelURL: URL? = nil,
        calibrator: ETACalibrator? = nil,
        splitStore: SplitStore? = nil,
        extractor: AudioExtractor = AudioExtractor()
    ) {
        self.modelURL = modelURL
        self.calibrator = calibrator ?? ETACalibrator.defaultShared
        self.splitStore = splitStore ?? SplitStore(baseDirectory: SplitStore.defaultBaseDirectory())
        self.extractor = extractor
    }

    /// Loads the model once; call at launch so the first split pays no load cost.
    public func prewarmModel() async {
        _ = try? await separator()
    }

    func separator() async throws -> HTDemucsSeparator {
        if let loadTask { return try await loadTask.value }
        let url = modelURL ?? Bundle.main.url(forResource: "htdemucs", withExtension: "mlmodelc")
        let task = Task.detached(priority: .userInitiated) { () throws -> HTDemucsSeparator in
            guard let url else { throw StemError.modelMissing("htdemucs.mlmodelc not in bundle") }
            do {
                #if targetEnvironment(simulator)
                // The Simulator's GPU path returns all-zero stems for this graph.
                return try HTDemucsSeparator(modelURL: url, computeUnits: .cpuOnly)
                #else
                // GPU: the ANE compiler rejects this graph (same as on Mac).
                let gpu = try HTDemucsSeparator(modelURL: url, computeUnits: .cpuAndGPU)
                if try Self.producesAudio(gpu) { return gpu }
                return try HTDemucsSeparator(modelURL: url, computeUnits: .cpuOnly)
                #endif
            } catch SeparatorError.modelMissing(let path) {
                throw StemError.modelMissing(path)
            } catch {
                throw StemError.modelLoad(String(describing: error))
            }
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil  // let a later split retry
            throw error
        }
    }

    /// One synthetic segment through the model: a broken compute path returns silence.
    static func producesAudio(_ separator: HTDemucsSeparator) throws -> Bool {
        let L = separator.segmentLength
        var x = [Float](repeating: 0, count: 2 * L)
        for i in 0..<L {
            let v = Float(0.3 * sin(Double(i) * 0.03) + 0.1 * sin(Double(i) * 0.4))
            x[i] = v
            x[L + i] = v
        }
        var energy: Float = 0
        let y = try separator.separate(x)
        vDSP_svesq(y, 1, &energy, vDSP_Length(y.count))
        return energy.isFinite && energy > 1
    }

    public func split(_ sourceURL: URL) async -> AsyncStream<PipelineEvent> {
        let (stream, events) = AsyncStream.makeStream(of: PipelineEvent.self, bufferingPolicy: .unbounded)
        guard !isRunning else {
            events.yield(.failure(.generic("DemucsEngine: one split at a time")))
            events.finish()
            return stream
        }
        isRunning = true
        let task = Task.detached(priority: .userInitiated) { [self] in
            do {
                let outputs = try await self.run(sourceURL, events: events)
                events.yield(.completed(outputs))
            } catch {
                let mapped = Self.map(error)
                if mapped != .cancelled { log.error("split failed: \(String(describing: mapped), privacy: .public)") }
                events.yield(.failure(mapped))
            }
            events.finish()
            await self.finishRun()
        }
        pipelineTask = task
        events.onTermination = { _ in task.cancel() }
        return stream
    }

    public func cancel() async {
        pipelineTask?.cancel()
    }

    private func finishRun() {
        isRunning = false
        pipelineTask = nil
    }

    // MARK: Pipeline

    private func run(_ sourceURL: URL, events: AsyncStream<PipelineEvent>.Continuation) async throws -> SplitOutputs {
        let started = ContinuousClock.now
        events.yield(.phase(.downloading))
        events.yield(.phase(.decoding))

        let probe = try await extractor.probe(at: sourceURL)
        guard probe.hasAudio, probe.duration > 0 else { throw StemError.noAudio }
        let sr = extractor.outputSampleRate
        let expected = max(Int((probe.duration * sr).rounded()), 1)

        let stemFiles = 5
        let required = WAVWriter.preflightRequiredBytes(
            durationSeconds: probe.duration, stemCount: stemFiles,
            tmpCopyBytes: (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
        try FileManager.default.createDirectory(at: splitStore.baseDirectory, withIntermediateDirectories: true)
        if let free = try? splitStore.baseDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < required {
            throw StemError.diskPreflightFail(requiredBytes: required, freeBytes: free)
        }

        let separator = try await separator()
        events.yield(.eta(calibrator.preStartEstimate(modelID: Self.modelID, audioDuration: probe.duration)))
        events.yield(.phase(.splitting))

        let session = try splitStore.createSession()
        let sources = separator.sources
        guard let vocalsIndex = sources.firstIndex(of: "vocals") else {
            throw StemError.modelLoad("model has no vocals source")
        }
        let names = sources + ["instrumental"]
        let urls = names.map { name -> URL in
            switch name {
            case "vocals": session.vocalsURL
            case "instrumental": session.instrumentalURL
            default: session.directory.appendingPathComponent("\(name).wav")
            }
        }
        let projected = WAVWriter.projectedDataBytes(durationSeconds: probe.duration)
        var writers: [WAVWriter] = []
        do {
            for url in urls { writers.append(try WAVWriter(url: url, projectedDataBytes: projected)) }
        } catch {
            writers.forEach { $0.abortAndDelete() }
            try? FileManager.default.removeItem(at: session.directory)
            throw error
        }
        let peaks = names.map { _ in PeakAccumulator(binSize: Int(sr) / StemTrack.peaksPerSecond) }

        do {
            try await separate(
                sourceURL, separator: separator, vocalsIndex: vocalsIndex, expected: expected,
                writers: writers, peaks: peaks, events: events)
            for writer in writers { try writer.finalize() }
        } catch {
            writers.forEach { $0.abortAndDelete() }
            try? FileManager.default.removeItem(at: session.directory)
            throw error
        }
        try? splitStore.markCompleted(session)
        events.yield(.progress(fraction: 1))
        log.info("split done in \(Self.seconds(since: started), format: .fixed(precision: 1))s for \(probe.duration, format: .fixed(precision: 1))s audio")

        let tracks = names.indices.map { StemTrack(name: names[$0], url: urls[$0], peaks: peaks[$0].finish()) }
        return SplitOutputs(vocalsURL: session.vocalsURL, instrumentalURL: session.instrumentalURL, stems: tracks, sessionID: session.id)
    }

    /// Segment loop. Same weighting as demucs `apply_model`: triangle weights over
    /// each segment, accumulated and normalized by the weight sum.
    private func separate(
        _ sourceURL: URL, separator: HTDemucsSeparator, vocalsIndex: Int, expected: Int,
        writers: [WAVWriter], peaks: [PeakAccumulator], events: AsyncStream<PipelineEvent>.Continuation
    ) async throws {
        let L = separator.segmentLength
        let stride = Int(Double(L) * (1 - Self.overlap))
        let S = separator.sources.count
        let sr = extractor.outputSampleRate

        var weight = [Float](repeating: 0, count: L)
        for i in 0..<L { weight[i] = Float(i < L / 2 ? i + 1 : L - i) }
        var maxW = weight.max()!
        vDSP_vsdiv(weight, 1, &maxW, &weight, 1, vDSP_Length(L))

        // Planar input buffers and accumulators, one segment long.
        var bufL: [Float] = [], bufR: [Float] = []
        var bufStart = 0
        var acc = [Float](repeating: 0, count: S * 2 * L)
        var wsum = [Float](repeating: 0, count: L)
        var emitted = 0
        var gain: Float = 1
        var eof = false
        var lastWall = ContinuousClock.now
        let iterator = extractor.chunks(from: sourceURL).makeAsyncIterator()

        var seg = 0
        while true {
            try Task.checkCancellation()
            let segStart = seg * stride
            while !eof && bufStart + bufL.count < segStart + L {
                guard let chunk = try await iterator.next() else { eof = true; break }
                let n = chunk.frameCount
                let from = bufL.count
                bufL.append(contentsOf: repeatElement(0, count: n))
                bufR.append(contentsOf: repeatElement(0, count: n))
                chunk.interleavedSamples.withUnsafeBufferPointer { src in
                    var zero: Float = 0
                    bufL.withUnsafeMutableBufferPointer {
                        vDSP_vsadd(src.baseAddress!, 2, &zero, $0.baseAddress! + from, 1, vDSP_Length(n))
                    }
                    bufR.withUnsafeMutableBufferPointer {
                        vDSP_vsadd(src.baseAddress! + 1, 2, &zero, $0.baseAddress! + from, 1, vDSP_Length(n))
                    }
                }
            }
            let total = bufStart + bufL.count
            let available = min(L, total - segStart)
            if available <= 0 {
                if seg == 0 { throw StemError.noAudio }
                break
            }

            var input = [Float](repeating: 0, count: 2 * L)
            let o = segStart - bufStart
            input.replaceSubrange(0..<available, with: bufL[o..<(o + available)])
            input.replaceSubrange(L..<(L + available), with: bufR[o..<(o + available)])
            let out = try separator.separate(input)
            try Task.checkCancellation()

            out.withUnsafeBufferPointer { op in
                acc.withUnsafeMutableBufferPointer { ap in
                    for k in 0..<(S * 2) {
                        vDSP_vma(op.baseAddress! + k * L, 1, weight, 1, ap.baseAddress! + k * L, 1,
                                 ap.baseAddress! + k * L, 1, vDSP_Length(L))
                    }
                }
            }
            vDSP_vadd(wsum, 1, weight, 1, &wsum, 1, vDSP_Length(L))

            let isLast = eof && segStart + L >= total
            let count = isLast ? total - segStart : stride

            // Normalized stems for the finished region, interleaved for the writers.
            var inv = [Float](repeating: 0, count: count)
            var one: Float = 1
            vDSP_svdiv(&one, wsum, 1, &inv, 1, vDSP_Length(count))
            var blocks: [[Float]] = []
            for s in 0..<S {
                var block = [Float](repeating: 0, count: count * 2)
                acc.withUnsafeBufferPointer { a in
                    block.withUnsafeMutableBufferPointer { b in
                        for c in 0..<2 {
                            vDSP_vmul(a.baseAddress! + (s * 2 + c) * L, 1, inv, 1, b.baseAddress! + c, 2, vDSP_Length(count))
                        }
                    }
                }
                blocks.append(block)
            }
            // instrumental := source − vocals
            var source = [Float](repeating: 0, count: count * 2)
            bufL.withUnsafeBufferPointer { l in
                bufR.withUnsafeBufferPointer { r in
                    source.withUnsafeMutableBufferPointer { d in
                        var zero: Float = 0
                        vDSP_vsadd(l.baseAddress! + o, 1, &zero, d.baseAddress!, 2, vDSP_Length(count))
                        vDSP_vsadd(r.baseAddress! + o, 1, &zero, d.baseAddress! + 1, 2, vDSP_Length(count))
                    }
                }
            }
            var instrumental = [Float](repeating: 0, count: count * 2)
            vDSP_vsub(blocks[vocalsIndex], 1, source, 1, &instrumental, 1, vDSP_Length(count * 2))
            blocks.append(instrumental)

            // Shared headroom gain across every stem (plan gain policy).
            var blockPeak: Float = 0
            for block in blocks {
                var m: Float = 0
                vDSP_maxmgv(block, 1, &m, vDSP_Length(block.count))
                blockPeak = max(blockPeak, m)
            }
            gain = StemEngine.conditionedGain(current: gain, peak: blockPeak)
            for (i, var block) in blocks.enumerated() {
                if gain != 1 { vDSP_vsmul(block, 1, &gain, &block, 1, vDSP_Length(block.count)) }
                try writers[i].append(interleaved: block)
                peaks[i].add(interleaved: block)
            }
            events.yield(.peaks(StereoPeaks(left: min(blockPeak, 1), right: min(blockPeak, 1))))

            emitted += count
            events.yield(.progress(fraction: min(1, Double(emitted) / Double(expected))))
            let now = ContinuousClock.now
            calibrator.recordMeasuredChunk(
                modelID: Self.modelID, audioSeconds: Double(count) / sr,
                wallClockSeconds: Self.seconds(lastWall, now))
            lastWall = now
            if let eta = calibrator.measuredEstimate(
                modelID: Self.modelID, remainingAudioSeconds: Double(max(expected - emitted, 0)) / sr) {
                events.yield(.eta(eta))
            }
            if isLast { break }

            acc.withUnsafeMutableBufferPointer { ap in
                for k in 0..<(S * 2) {
                    let b = ap.baseAddress! + k * L
                    b.update(from: b + stride, count: L - stride)
                    (b + L - stride).update(repeating: 0, count: stride)
                }
            }
            wsum.withUnsafeMutableBufferPointer { w in
                w.baseAddress!.update(from: w.baseAddress! + stride, count: L - stride)
                (w.baseAddress! + L - stride).update(repeating: 0, count: stride)
            }
            let drop = min(stride, bufL.count)
            bufL.removeFirst(drop)
            bufR.removeFirst(drop)
            bufStart += drop
            seg += 1
        }
    }

    private static func map(_ error: Error) -> StemError {
        switch error {
        case let e as StemError: e
        case is CancellationError: .cancelled
        default: .generic("demucs: \(String(describing: error))")
        }
    }

    private static func seconds(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        seconds(start, .now)
    }
}

/// Max |sample| per bin over both channels. Carries partial bins across calls.
final class PeakAccumulator {
    let binSize: Int
    private var peaks: [Float] = []
    private var current: Float = 0
    private var filled = 0

    init(binSize: Int) { self.binSize = binSize }

    func add(interleaved: [Float]) {
        let frames = interleaved.count / 2
        var i = 0
        interleaved.withUnsafeBufferPointer { p in
            while i < frames {
                let n = min(binSize - filled, frames - i)
                var m: Float = 0
                vDSP_maxmgv(p.baseAddress! + i * 2, 1, &m, vDSP_Length(n * 2))
                current = max(current, m)
                filled += n
                i += n
                if filled == binSize {
                    peaks.append(min(current, 1))
                    current = 0
                    filled = 0
                }
            }
        }
    }

    func finish() -> [Float] {
        if filled > 0 { peaks.append(min(current, 1)); filled = 0; current = 0 }
        return peaks
    }
}
