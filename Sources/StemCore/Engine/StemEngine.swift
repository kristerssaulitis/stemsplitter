import Accelerate
import Foundation
import os

// ============================================================================================
// StemEngine — the pipeline actor (plan Approach B / T-series; StemEngineProtocol).
//
// Topology (eng E1 bounded inter-stage queues; each queue holds at most
// `Configuration.queueCapacity` in-flight chunks — the enforcing mechanism of the
// memory invariant "no whole-file float buffers, peak <400 MB on the gate device"):
//
//   AudioExtractor pull           chunk+STFT          StemModel        ISTFT+crossfade       WAVWriter×2
//   ┌──────────────────┐   q1   ┌───────────┐  q2   ┌──────────┐  q3   ┌──────────────┐      ┌───────────┐
//   │ decode → 44.1k   │──────▶│ fixed 6144│─────▶│ separate │─────▶│ mask·ISTFT·  │─────▶│ vocals    │
//   │ stereo, chunk,   │ cap=3 │ per chan  │ cap=3│ (model)  │ cap=3│ complement·  │      │ instru-   │
//   │ accumulate       │       │ +magnitudes│     │          │      │ crossfade    │      │ mental    │
//   └──────────────────┘       └───────────┘      └──────────┘      └──────────────┘      └───────────┘
//
// The stages run as child tasks of a throwing task group owned by a detached driver
// task; the engine actor only orchestrates and never holds audio buffers.
//
// Decisions encoded here, all from the approved plan:
// - Complement subtraction: instrumental is DERIVED, never a second model output — in the
//   spectral domain inst_spec = src_spec − voc_spec (plan channel/gain policy: "instrumental
//   := source − vocals in the float domain … so stems sum to the source exactly"). The mask
//   is applied to the COMPLEX spectra (phase-preserving); the model itself only ever sees
//   magnitudes (StemModel contract). Chunk outputs overlap by 1024 samples and are blended
//   with a linear crossfade whose weights sum to 1 at every sample, so
//   (vocals + instrumental) == crossfaded source within float error (Section 6 sum-to-unity).
// - Gain conditioning (plan gain policy): before the int24 write, if a block would clip,
//   ONE shared headroom attenuation is applied to BOTH stems (monotone ratchet — never
//   restored upward mid-split) and the applied gain is logged. No per-stem normalization.
// - Cancellation is cooperative at chunk boundaries (eng E1): cancel() cancels the driver
//   task; every stage stops at its next inter-stage boundary and the writer tears down via
//   abortAndDelete; the session dir is removed — partial output never survives (protocol).
// - ONE event surface to the UI (eng E2): phase transitions (.downloading → .decoding →
//   .splitting, the frozen contract's order), progress, per-chunk peaks, two-phase ETA
//   (calibrator pre-start figure with isInitial == true, then the measured first-chunk
//   takeover with isInitial == false), and exactly one terminal event.
// - Preflights before any chunk (plan pre-flight step + eng E4/E5): audio probe, disk gate
//   (writer math ×1.2 margin + tmp source-copy projection + same-session split dirs + 1 GB
//   headroom), model acquisition via ModelStore (awaits/triggers the launch preload so the
//   first split pays no model-load latency, CEO row 15), Low Power Mode-adjusted initial
//   estimate (eng E4 — adjusted by the calibrator, disclosed by the isInitial flag).
// - Per-chunk os.Logger timings under the 'engine' category (CEO row 16).
// ============================================================================================

// MARK: - Pipeline stage identifiers

/// The five pipeline stages, in data-flow order. Exposed for the per-chunk-boundary
/// test/observability hook (`StemEngine.Configuration.Hooks.onChunkBoundary`) and logging.
public enum PipelineStage: String, CaseIterable, Sendable {
    /// AudioExtractor pull: AVAssetReader decode + 44.1 kHz conversion + chunk accumulation.
    case decode
    /// STFT of each fixed-size chunk (both channels) + magnitude extraction.
    case stft
    /// StemModel.separate on the chunk's magnitudes.
    case separate
    /// Masked ISTFT + overlap-add crossfade + spectral complement subtraction.
    case synthesize
    /// Shared-gain conditioning + streaming 24-bit WAV write (both stems).
    case write
}

// MARK: - Bounded inter-stage channel (eng E1)

/// A FIFO channel with a hard capacity bound: `send` suspends while `capacity` elements
/// are buffered, so the producing stage can never run ahead of the consuming stage by
/// more than `capacity` in-flight chunks. This is the memory invariant's enforcing
/// mechanism (eng E1: "bounded inter-stage queue — max 2-3 in-flight chunks per stage").
///
/// All state is guarded by one lock; every waiter is registered under the lock with a
/// fresh identity and removed under the lock by whoever resumes it, so each continuation
/// is resumed exactly once. Cancellation is cooperative: a suspended `send`/`receive`
/// throws `CancellationError` when its task is cancelled, so stages stop at chunk
/// boundaries. `finish()` marks the channel closed; already-buffered elements remain
/// readable (EOF drains in order), suspended receivers wake with `nil`, and suspended
/// senders fail with `ChannelFailure.closed`.
public final class BoundedChannel<Element: Sendable>: @unchecked Sendable {

    /// Sending after `finish()`. Never raised by the pipeline itself (the sole sender of
    /// each channel is also its finisher); public for tests.
    public enum ChannelFailure: Error, Equatable {
        case closed
    }

    private enum Wake: Sendable {
        case element(Element)
        case finished
    }

    /// Sender wakeup: a freed slot, or channel-closed (a cancelled sender instead has
    /// its continuation resumed with a thrown `CancellationError`).
    private enum SenderWake: Sendable {
        case slot
        case closed
    }

    private let capacity: Int
    private let lock = NSLock()
    private var elements: [Element] = []
    private var closed = false
    private var receivers: [(id: UUID, continuation: CheckedContinuation<Wake, Error>)] = []
    private var senders: [(id: UUID, continuation: CheckedContinuation<SenderWake, Error>)] = []

    /// - Precondition: `capacity > 0` (the plan bound is 2-3; default 3).
    public init(capacity: Int = 3) {
        precondition(capacity > 0, "BoundedChannel capacity must be positive")
        self.capacity = capacity
    }

    /// Elements currently buffered — the test seam for the E1 bound assertion.
    public var bufferedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return elements.count
    }

    /// Sends one element, suspending while the buffer is full. A waiting receiver takes
    /// the element hand-to-hand (it never occupies buffer capacity). Throws
    /// `CancellationError` when the sending task is cancelled, `ChannelFailure.closed`
    /// after `finish()`.
    public func send(_ element: Element) async throws {
        while true {
            try Task.checkCancellation()
            switch attemptSend(element) {
            case .delivered, .buffered:
                return
            case .closed:
                throw ChannelFailure.closed
            case .full:
                // Suspend until a slot frees (true), the channel closes (false →
                // .closed), or the sending task cancels (throws).
                if try await awaitingSlot() { continue }
                throw ChannelFailure.closed
            }
        }
    }

    /// Receives the next element (FIFO), or `nil` once the channel is closed AND drained.
    /// Throws `CancellationError` when the receiving task is cancelled.
    public func receive() async throws -> Element? {
        let waiterID = UUID()
        let wake = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Wake, Error>) in
                registerReceiver(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            removeReceiver(id: waiterID)
        }
        switch wake {
        case .element(let element): return element
        case .finished: return nil
        }
    }

    /// Marks the channel closed. Buffered elements stay readable (drain in order);
    /// suspended receivers wake with `nil`, suspended senders fail with `.closed`.
    /// Idempotent.
    public func finish() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let waitingReceivers = receivers
        receivers = []
        let waitingSenders = senders
        senders = []
        lock.unlock()
        waitingReceivers.forEach { $0.continuation.resume(returning: .finished) }
        waitingSenders.forEach { $0.continuation.resume(returning: .closed) }
    }

    // MARK: Private plumbing (all lock sections live in synchronous functions —
    // NSLock's lock()/unlock() are unavailable from async contexts on this SDK)

    private enum SendOutcome {
        case delivered   // handed to a waiting receiver
        case buffered    // appended within capacity
        case full        // capacity reached — sender must suspend
        case closed      // channel closed — send throws
    }

    private func attemptSend(_ element: Element) -> SendOutcome {
        lock.lock()
        var outcome = SendOutcome.full
        var receiver: CheckedContinuation<Wake, Error>?
        if closed {
            outcome = .closed
        } else if let waiting = receivers.first {
            receivers.removeFirst()
            receiver = waiting.continuation
            outcome = .delivered
        } else if elements.count < capacity {
            elements.append(element)
            outcome = .buffered
        }
        lock.unlock()
        // Continuation resumption never runs user code on this thread, but resume
        // strictly outside the critical section anyway.
        if let receiver {
            receiver.resume(returning: .element(element))
        }
        return outcome
    }

    private func registerReceiver(id: UUID, continuation: CheckedContinuation<Wake, Error>) {
        lock.lock()
        if let element = elements.first {
            elements.removeFirst()
            var freedSender: CheckedContinuation<SenderWake, Error>?
            if let sender = senders.first {
                senders.removeFirst()
                freedSender = sender.continuation
            }
            lock.unlock()
            freedSender?.resume(returning: .slot)
            continuation.resume(returning: .element(element))
            return
        }
        if closed {
            lock.unlock()
            continuation.resume(returning: .finished)
            return
        }
        if Task.isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        receivers.append((id, continuation))
        lock.unlock()
    }

    /// Sender suspension; resumes `.slot` when a slot frees, `.closed` when the channel
    /// closes, throws on task cancellation.
    private func awaitingSlot() async throws -> Bool {
        let waiterID = UUID()
        let wake = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SenderWake, Error>) in
                registerSender(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            removeSender(id: waiterID)
        }
        switch wake {
        case .slot: return true
        case .closed: return false
        }
    }

    private func registerSender(id: UUID, continuation: CheckedContinuation<SenderWake, Error>) {
        lock.lock()
        if closed {
            lock.unlock()
            continuation.resume(returning: .closed)
            return
        }
        if Task.isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        senders.append((id, continuation))
        lock.unlock()
    }

    /// Removes the receiver registered under `id` (if still present — registration and
    /// removal are mutually excluded by the lock) and resumes it with cancellation.
    private func removeReceiver(id: UUID) {
        lock.lock()
        guard let index = receivers.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = receivers.remove(at: index)
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Sender counterpart of `removeReceiver(id:)`: cancellation of a suspended sender
    /// THROWS (it must surface as `.cancelled` downstream, never as channel-closed).
    private func removeSender(id: UUID) {
        lock.lock()
        guard let index = senders.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = senders.remove(at: index)
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
    }
}

// MARK: - Engine

/// The split pipeline actor (plan Approach B; `StemEngineProtocol` implementation).
///
/// One `split` runs the five-stage streaming pipeline described in the file header.
/// Single-flight (CEO row 13): a second `split` before the in-flight stream finishes is
/// a caller bug and is rejected with an immediate `.failure(.generic)` stream.
public actor StemEngine: StemEngineProtocol {

    // MARK: Configuration (injectable seams, all defaulted to production values)

    public struct Configuration: Sendable {

        /// Per-stage in-flight chunk bound (eng E1; plan: 2-3, default 3).
        public var queueCapacity: Int

        /// Per-chunk-boundary hooks (see `Hooks`).
        public var hooks: Hooks

        /// Free disk bytes at the split target volume. Default: the volume capacity
        /// behind the session directory. Injectable for the preflight tests.
        public var freeDiskBytes: @Sendable (URL) throws -> Int64

        /// Projected tmp source-copy bytes in the disk gate (eng E5). Default: the
        /// source file's size on disk (by the time the engine sees the URL it IS the
        /// security-scoped tmp copy; its bytes must stay resident for the split).
        public var tmpCopyBytes: @Sendable (URL) -> Int64

        /// Bytes already accumulated under the split base directory (eng E5: same-
        /// session split-dir accumulation). Default: recursive size of the base dir.
        public var sameSessionSplitDirBytes: @Sendable (URL) -> Int64

        public struct Hooks: Sendable {
            /// Invoked at the start of each chunk in each stage, BEFORE the chunk is
            /// processed. Throwing unwinds the pipeline (the error maps through the
            /// frozen `StemError` surface); `StemEngine.cancel()` from inside makes the
            /// split stop cooperatively at the next boundary. `nil` in production.
            public var onChunkBoundary: (@Sendable (PipelineStage, _ chunkIndex: Int) async throws -> Void)?

            public init(
                onChunkBoundary: (@Sendable (PipelineStage, _ chunkIndex: Int) async throws -> Void)? = nil
            ) {
                self.onChunkBoundary = onChunkBoundary
            }
        }

        public init(
            queueCapacity: Int = 3,
            hooks: Hooks = Hooks(),
            freeDiskBytes: (@Sendable (URL) throws -> Int64)? = nil,
            tmpCopyBytes: (@Sendable (URL) -> Int64)? = nil,
            sameSessionSplitDirBytes: (@Sendable (URL) -> Int64)? = nil
        ) {
            precondition(queueCapacity > 0, "queueCapacity must be positive")
            self.queueCapacity = queueCapacity
            self.hooks = hooks
            self.freeDiskBytes = freeDiskBytes ?? Self.defaultFreeDiskBytes
            self.tmpCopyBytes = tmpCopyBytes ?? Self.defaultTmpCopyBytes
            self.sameSessionSplitDirBytes =
                sameSessionSplitDirBytes ?? Self.defaultSameSessionSplitDirBytes
        }

        /// Free space for important usage on the volume containing `url` (the split
        /// output volume). Unreadable capacity throws — the engine surfaces `.generic`
        /// rather than guessing (zero silent failures, plan S2).
        static let defaultFreeDiskBytes: @Sendable (URL) throws -> Int64 = { url in
            let values = try url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let free = values.volumeAvailableCapacityForImportantUsage else {
                throw CocoaError(.fileReadUnknown)
            }
            return free
        }

        static let defaultTmpCopyBytes: @Sendable (URL) -> Int64 = { url in
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        }

        static let defaultSameSessionSplitDirBytes: @Sendable (URL) -> Int64 = { base in
            directorySize(at: base)
        }

        private static func directorySize(at url: URL) -> Int64 {
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            else { return 0 }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]),
                    values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }
    }

    // MARK: Dependencies

    private let modelStore: ModelStore
    private let calibrator: ETACalibrator
    private let splitStore: SplitStore
    private let extractor: AudioExtractor
    private let configuration: Configuration

    nonisolated private let log = Logger(subsystem: "com.stemsplitter.app", category: "engine")

    // MARK: Single-flight state (CEO row 13)

    private var isRunning = false
    private var pipelineTask: Task<Void, Never>?

    /// - Parameters:
    ///   - modelStore: the app's model store. The engine acquires the model through
    ///     `modelStore.model()`, which awaits (or triggers) the launch preload — the
    ///     first split therefore pays no model-load latency (CEO row 15 / plan T8).
    ///   - calibrator: two-phase ETA calibrator (persisted, model-keyed, LPM-aware).
    ///   - splitStore: owner of the Caches/Splits/<uuid>/ session directory.
    ///   - extractor: decode stage (injectable for tests).
    ///   - configuration: queue bound, hooks, and preflight probes.
    public init(
        modelStore: ModelStore = .shared,
        calibrator: ETACalibrator? = nil,
        splitStore: SplitStore? = nil,
        extractor: AudioExtractor = AudioExtractor(),
        configuration: Configuration = Configuration()
    ) {
        self.modelStore = modelStore
        self.calibrator = calibrator ?? ETACalibrator.defaultShared
        self.splitStore = splitStore ?? SplitStore(baseDirectory: SplitStore.defaultBaseDirectory())
        self.extractor = extractor
        self.configuration = configuration
    }

    /// Launch-side hook: warms the model through the store's single-flight preload so a
    /// later `split` finds it loaded (CEO row 15). Idempotent; safe to call at app start.
    public func prewarmModel() async {
        await modelStore.preload()
    }

    // MARK: StemEngineProtocol

    public func split(_ sourceURL: URL) async -> AsyncStream<PipelineEvent> {
        guard !isRunning else {
            // Frozen contract: a second split before the first stream finishes is a
            // caller bug — reject immediately, never interleave two pipelines.
            log.error("split rejected: another split is in flight (single-flight, CEO row 13)")
            return Self.rejectionStream()
        }
        isRunning = true
        let (stream, continuation) = AsyncStream.makeStream(
            of: PipelineEvent.self, bufferingPolicy: .unbounded)
        let run = PipelineRun(
            sourceURL: sourceURL,
            modelStore: modelStore,
            calibrator: calibrator,
            splitStore: splitStore,
            extractor: extractor,
            configuration: configuration,
            events: continuation,
            log: log)
        let onDone: @Sendable () async -> Void = { [weak self] in
            await self?.finishRun()
        }
        let task = Task.detached(priority: .userInitiated) {
            let outcome = await run.run()
            switch outcome {
            case .completed(let outputs):
                continuation.yield(.completed(outputs))
            case .failed(let error):
                continuation.yield(.failure(error))
            }
            continuation.finish()
            await onDone()
        }
        self.pipelineTask = task
        // A consumer that stops iterating (or deallocates the stream) cancels the
        // pipeline; stages unwind through the same cooperative chunk boundaries.
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    /// Cooperatively cancel the in-flight split at the next chunk boundary (eng E1).
    /// Serialized with pipeline state by actor isolation; no-op after the stream
    /// finished. The stream then emits `.failure(.cancelled)` and finishes.
    public func cancel() async {
        guard let task = pipelineTask else { return }
        log.info("cancel requested — unwinding at the next chunk boundary")
        task.cancel()
    }

    /// Shared headroom conditioning (plan gain policy). Returns the gain to apply to
    /// BOTH stems: unchanged while `current × peak` stays under the 0.95 rail target,
    /// otherwise ratcheted down to `0.95 / peak` (never restored upward mid-split).
    /// Internal so the conditioning regression test exercises the exact pipeline rule.
    static func conditionedGain(current: Float, peak: Float) -> Float {
        guard peak > 0, peak.isFinite else { return current }
        let ceiling: Float = 0.95
        if current * peak <= ceiling { return current }
        return min(current, ceiling / peak)
    }

    private func finishRun() {
        isRunning = false
        pipelineTask = nil
    }

    nonisolated private static func rejectionStream() -> AsyncStream<PipelineEvent> {
        AsyncStream { continuation in
            continuation.yield(
                .failure(.generic("StemEngine: second split rejected — one split at a time (CEO row 13)")))
            continuation.finish()
        }
    }
}

/// Application-default calibrator construction: persisted under Application Support
/// (never under the purged Caches/Splits tree), Low Power Mode read from `ProcessInfo`.
extension ETACalibrator {
    public static var defaultShared: ETACalibrator {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("StemSplitter/eta-calibration.json")
        return ETACalibrator(persistence: FileKeyValuePersistence(fileURL: url))
    }
}

// MARK: - Pipeline run (all audio state lives here, off the actor)

/// One split's working state. A `Sendable` value passed into the detached driver task;
/// the per-stage mutable buffers are locals of the stage tasks, so no lock is needed
/// beyond the channels.
private struct PipelineRun: Sendable {

    enum TerminalOutcome {
        case completed(SplitOutputs)
        case failed(StemError)
    }

    let sourceURL: URL
    let modelStore: ModelStore
    let calibrator: ETACalibrator
    let splitStore: SplitStore
    let extractor: AudioExtractor
    let configuration: StemEngine.Configuration
    let events: AsyncStream<PipelineEvent>.Continuation
    let log: Logger

    func run() async -> TerminalOutcome {
        let started = ContinuousClock.now
        // Frozen contract phase order: .downloading → .decoding → .splitting. The
        // engine's input is a local file URL (the app layer performed the security-
        // scoped copy); .downloading passes through instantly and keeps the UI's
        // download-modal wiring uniform (`PickedVideo` doc, contract `PipelinePhase`).
        events.yield(.phase(.downloading))
        events.yield(.phase(.decoding))

        // — Preflight 1: audio probe (S2 rows 1/2 + design F5 mapped by the extractor).
        let probe: AudioProbe
        do {
            probe = try await extractor.probe(at: sourceURL)
        } catch {
            return .failed(Self.map(error, context: "audio probe"))
        }
        guard probe.hasAudio, probe.duration > 0 else {
            log.error("preflight: no audible audio track (duration \(probe.duration, format: .fixed(precision: 2))s)")
            return .failed(.noAudio)
        }
        // Progress/ETA denominator: the probe's audio duration (contract: progress is
        // the fraction of audio DURATION processed). The final block emits exactly 1.0.
        let estimatedTotalSamples = max(
            Int((probe.duration * extractor.outputSampleRate).rounded()), 1)

        // — Preflight 2: disk gate (eng E5): writer math ×1.2 + tmp copy projection +
        // same-session split dirs + 1 GB headroom. Before ANY chunk is processed.
        let tmpBytes = configuration.tmpCopyBytes(sourceURL)
        let sessionBytes = configuration.sameSessionSplitDirBytes(splitStore.baseDirectory)
        let required = WAVWriter.preflightRequiredBytes(
            durationSeconds: probe.duration,
            tmpCopyBytes: tmpBytes,
            sameSessionSplitDirBytes: sessionBytes)
        let free: Int64
        do {
            free = try configuration.freeDiskBytes(splitStore.baseDirectory)
        } catch {
            return .failed(.generic("disk free-space probe failed: \(String(describing: error))"))
        }
        guard free >= required else {
            log.error("preflight: disk refused — required \(required), free \(free)")
            return .failed(.diskPreflightFail(requiredBytes: required, freeBytes: free))
        }

        // — Preflight 3: the model. Acquisition goes through ModelStore so the launch
        // preload is reused and the first split pays no model-load latency (CEO row 15).
        let model: any StemModel
        do {
            model = try await modelStore.model()
        } catch {
            return .failed(Self.map(error, context: "model load"))
        }
        let modelID = type(of: model).modelID

        // — Phase-1 ETA (R3-1): persisted calibration if present, else the gate-class
        // figure — flagged isInitial (the UI's "initial estimate" disclosure). eng E4:
        // Low Power Mode inflates the pre-start figure inside the calibrator; the
        // adjustment is logged here and disclosed via the event contract.
        let initial = calibrator.preStartEstimate(modelID: modelID, audioDuration: probe.duration)
        if calibrator.isLowPowerAdjustmentActive {
            log.info("preflight: Low Power Mode on — initial estimate ×\(ETACalibrator.lowPowerMultiplier) (disclosed via isInitial)")
        }
        log.info("preflight ok: \(String(format: "%.1f", probe.duration))s audio, disk required \(required) free \(free), model \(modelID, privacy: .public), initial ETA \(String(format: "%.1f", initial.seconds))s")
        events.yield(.eta(initial))
        events.yield(.phase(.splitting))

        // — Session directory (plan output lifecycle: Caches/Splits/<uuid>/).
        let session: SplitSession
        do {
            session = try splitStore.createSession()
        } catch {
            return .failed(.generic("session directory create failed: \(String(describing: error))"))
        }
        log.info("session \(session.id.uuidString, privacy: .public) at \(session.directory.path, privacy: .public)")

        // — The streaming pipeline (eng E1): stages joined by bounded channels.
        let capacity = configuration.queueCapacity
        let qChunks = BoundedChannel<ChunkJob>(capacity: capacity)
        let qSeparated = BoundedChannel<SeparatedChunk>(capacity: capacity)
        let qOutput = BoundedChannel<OutputBlock>(capacity: capacity)
        let outputs = OutputBox()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.decodeStage(into: qChunks) }
                group.addTask {
                    try await self.separateStage(
                        from: qChunks, model: model, modelID: modelID, into: qSeparated)
                }
                group.addTask { try await self.synthesizeStage(from: qSeparated, into: qOutput) }
                group.addTask {
                    outputs.result = try await self.writeStage(
                        from: qOutput, session: session, modelID: modelID,
                        estimatedTotalSamples: estimatedTotalSamples)
                }
                do {
                    try await group.waitForAll()
                } catch {
                    // First failure cancels the group; let the other stages unwind
                    // through their cancellation boundaries before propagating.
                    group.cancelAll()
                    try? await group.waitForAll()
                    throw error
                }
            }
            guard let result = outputs.result else {
                throw StemError.generic("pipeline finished without writer output")
            }
            do {
                try splitStore.markCompleted(session)
            } catch {
                log.error("markCompleted failed (output kept): \(String(describing: error), privacy: .public)")
            }
            let elapsed = ContinuousClock.now - started
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            log.info("split completed: \(String(format: "%.1f", seconds))s wall clock, model \(modelID, privacy: .public)")
            return .completed(result)
        } catch {
            // Writers tore their files down themselves (eng E1/E9); remove the session
            // directory so no partial output survives a failure or cancel (protocol).
            try? FileManager.default.removeItem(at: session.directory)
            let stemError = Self.map(error, context: "pipeline")
            if stemError != .cancelled {
                log.error("split failed: \(String(describing: stemError), privacy: .public)")
            }
            return .failed(stemError)
        }
    }

    // MARK: Stage 1 — decode → chunk → STFT

    private func decodeStage(into channel: BoundedChannel<ChunkJob>) async throws {
        defer { channel.finish() }
        let stageStart = ContinuousClock.now
        let stft = try STFT()
        let chunker = StreamChunker()
        let iterator = extractor.chunks(from: sourceURL).makeAsyncIterator()

        while let buffer = try await iterator.next() {
            chunker.append(buffer)
            while let piece = chunker.nextCompleteChunk() {
                try await boundary(.decode, piece.index)
                try await channel.send(try makeJob(piece, stft: stft))
            }
        }

        let totalFrames = chunker.totalFrames
        guard totalFrames > 0 else {
            // S2 Chunker empty path (the extractor already guards this; belt & braces).
            throw StemError.noAudio
        }
        // Tail chunks, zero-padded to the fixed size (Section 2: "audio < 1 chunk: pad").
        while let piece = chunker.nextTailChunk(totalFrames: totalFrames) {
            try await boundary(.decode, piece.index)
            try await channel.send(try makeJob(piece, stft: stft))
        }
        log.debug("decode+chunk+stft stage done: \(chunker.chunksEmitted) chunks in \(Self.ms(since: stageStart)) ms")
    }

    private func makeJob(_ piece: StreamChunker.Piece, stft: STFT) async throws -> ChunkJob {
        // The STFT sub-stage has its own chunk boundary: cancellation (and the
        // test/observability hook) stops here before the transform runs.
        try await boundary(.stft, piece.index)
        let t0 = ContinuousClock.now
        var left = [Float](repeating: 0, count: OLA.chunkSize)
        var right = [Float](repeating: 0, count: OLA.chunkSize)
        for frame in 0..<OLA.chunkSize {
            left[frame] = piece.source[frame * 2]
            right[frame] = piece.source[frame * 2 + 1]
        }
        let leftSpec = stft.forward(left)
        let rightSpec = stft.forward(right)
        let count = leftSpec.frameCount * leftSpec.binCount
        var leftMag = [Float](repeating: 0, count: count)
        var rightMag = [Float](repeating: 0, count: count)
        // Magnitude = √(re² + im²), frame-major — the model's only view (StemModel).
        vDSP_vdist(leftSpec.real, 1, leftSpec.imag, 1, &leftMag, 1, vDSP_Length(count))
        vDSP_vdist(rightSpec.real, 1, rightSpec.imag, 1, &rightMag, 1, vDSP_Length(count))
        let magnitudes = StereoMagnitudeChunk(
            frameCount: leftSpec.frameCount,
            binCount: leftSpec.binCount,
            left: leftMag,
            right: rightMag)
        log.debug("chunk \(piece.index): stft \(Self.ms(since: t0)) ms (\(leftSpec.frameCount)×\(leftSpec.binCount) bins)")
        return ChunkJob(
            chunk: Chunk(
                index: piece.index, start: piece.start,
                length: OLA.chunkSize, padding: piece.padding),
            source: piece.source,
            leftSpec: leftSpec,
            rightSpec: rightSpec,
            magnitudes: magnitudes)
    }

    // MARK: Stage 2 — separate (the model)

    private func separateStage(
        from input: BoundedChannel<ChunkJob>,
        model: any StemModel,
        modelID: String,
        into output: BoundedChannel<SeparatedChunk>
    ) async throws {
        defer { output.finish() }
        while let job = try await input.receive() {
            try await boundary(.separate, job.chunk.index)
            let t0 = ContinuousClock.now
            let mask = try await model.separate(job.magnitudes)
            log.debug("chunk \(job.chunk.index): separate \(Self.ms(since: t0)) ms [\(modelID, privacy: .public)]")
            try await output.send(SeparatedChunk(job: job, mask: mask))
        }
    }

    // MARK: Stage 3 — masked ISTFT + crossfade + spectral complement

    private func synthesizeStage(
        from input: BoundedChannel<SeparatedChunk>,
        into output: BoundedChannel<OutputBlock>
    ) async throws {
        defer { output.finish() }
        let stft = try STFT()
        var pendingVocals: [Float] = []
        var pendingInstrumental: [Float] = []
        var havePending = false
        var lastStart = 0
        var totalFrames = 0
        let advance = OLA.chunkSize - OLA.chunkOverlap

        while let separated = try await input.receive() {
            let chunk = separated.job.chunk
            totalFrames = chunk.start + chunk.length - chunk.padding
            try await boundary(.synthesize, chunk.index)
            let t0 = ContinuousClock.now

            // Vocals: mask ⊙ source in the spectral domain (phase preserved). The
            // instrumental is the DERIVED complement: inst_spec = src_spec − voc_spec
            // (plan: never a second independent model output; sum-to-unity by algebra).
            let left = maskedComplement(
                spec: separated.job.leftSpec, mask: separated.mask.left, stft: stft)
            let right = maskedComplement(
                spec: separated.job.rightSpec, mask: separated.mask.right, stft: stft)
            let vocals = Self.interleave(left.vocals, right.vocals)
            let instrumental = Self.interleave(left.instrumental, right.instrumental)

            // Overlap-add across chunks: consecutive chunks share `OLA.chunkOverlap`
            // samples; a linear crossfade (weights sum to 1 at every sample) blends the
            // band click-free. Emitted per chunk: [start, start + emitFrames) — final.
            // The zero-padded tail of the LAST chunk never reaches the output: its
            // emission is clipped at the true total (`padding > 0` marks that chunk;
            // interior chunk descriptors cannot know the total mid-stream and never
            // need the clamp — their advance range lies strictly inside the signal).
            let emitFrames: Int
            if chunk.padding > 0 {
                emitFrames = max(0, min(advance, totalFrames - chunk.start))
            } else {
                emitFrames = advance
            }
            let bandFrames = min(OLA.chunkOverlap, emitFrames)
            let interiorFrames = emitFrames - bandFrames
            var blockVocals: [Float]
            var blockInstrumental: [Float]
            if havePending {
                blockVocals = [Float](repeating: 0, count: bandFrames * 2)
                blockInstrumental = [Float](repeating: 0, count: bandFrames * 2)
                for i in 0..<bandFrames {
                    let t = Float(i) / Float(OLA.chunkOverlap)
                    let inverse = 1 - t
                    for c in 0..<2 {
                        blockVocals[i * 2 + c] =
                            inverse * pendingVocals[i * 2 + c] + t * vocals[i * 2 + c]
                        blockInstrumental[i * 2 + c] =
                            inverse * pendingInstrumental[i * 2 + c] + t * instrumental[i * 2 + c]
                    }
                }
                blockVocals.append(contentsOf:
                    vocals[(OLA.chunkOverlap * 2)..<(OLA.chunkOverlap * 2 + interiorFrames * 2)])
                blockInstrumental.append(contentsOf:
                    instrumental[(OLA.chunkOverlap * 2)..<(OLA.chunkOverlap * 2 + interiorFrames * 2)])
            } else {
                // First chunk: nothing before it — its head is un-blended (weight 1).
                blockVocals = Array(vocals[0..<emitFrames * 2])
                blockInstrumental = Array(instrumental[0..<emitFrames * 2])
            }
            try await output.send(OutputBlock(
                vocals: blockVocals, instrumental: blockInstrumental))

            pendingVocals = Array(vocals[(advance * 2)..<(OLA.chunkSize * 2)])
            pendingInstrumental = Array(instrumental[(advance * 2)..<(OLA.chunkSize * 2)])
            havePending = true
            lastStart = chunk.start
            log.debug("chunk \(chunk.index): istft+ola \(Self.ms(since: t0)) ms")
        }

        // After the final chunk there is no successor: its held tail is emitted as-is,
        // clipped at the true total (the zero-padded padding region is dropped).
        if havePending {
            let start = lastStart + advance
            let end = min(lastStart + OLA.chunkSize, totalFrames)
            if end > start {
                let count = (end - start) * 2
                try await output.send(OutputBlock(
                    vocals: Array(pendingVocals[0..<count]),
                    instrumental: Array(pendingInstrumental[0..<count])))
            }
        }
    }

    /// Applies the vocal mask to the COMPLEX spectrum (phase preserved) and derives the
    /// instrumental complement by spectral subtraction; returns both time-domain stems.
    private func maskedComplement(
        spec: Spectrogram, mask: [Float], stft: STFT
    ) -> (vocals: [Float], instrumental: [Float]) {
        var vocalsReal = spec.real
        var vocalsImag = spec.imag
        for i in vocalsReal.indices {
            vocalsReal[i] *= mask[i]
            vocalsImag[i] *= mask[i]
        }
        var instrumentalReal = spec.real
        var instrumentalImag = spec.imag
        for i in instrumentalReal.indices {
            instrumentalReal[i] -= vocalsReal[i]
            instrumentalImag[i] -= vocalsImag[i]
        }
        let vocals = stft.inverse(
            Spectrogram(
                frameCount: spec.frameCount, binCount: spec.binCount,
                real: vocalsReal, imag: vocalsImag),
            outputLength: OLA.chunkSize)
        let instrumental = stft.inverse(
            Spectrogram(
                frameCount: spec.frameCount, binCount: spec.binCount,
                real: instrumentalReal, imag: instrumentalImag),
            outputLength: OLA.chunkSize)
        return (vocals, instrumental)
    }

    // MARK: Stage 4 — shared-gain conditioning + streaming write + observability

    private func writeStage(
        from input: BoundedChannel<OutputBlock>,
        session: SplitSession,
        modelID: String,
        estimatedTotalSamples: Int
    ) async throws -> SplitOutputs {
        // RF64 vs RIFF is decided up front from the projection (eng E6).
        let projected = WAVWriter.projectedDataBytes(durationSeconds: estimatedTotalSamples > 0
            ? Double(estimatedTotalSamples) / extractor.outputSampleRate : 0)
        let vocals = try WAVWriter(url: session.vocalsURL, projectedDataBytes: projected)
        let instrumental: WAVWriter
        do {
            instrumental = try WAVWriter(url: session.instrumentalURL, projectedDataBytes: projected)
        } catch {
            vocals.abortAndDelete()  // never leave one stem behind (eng E9)
            throw error
        }
        do {
            var appliedGain: Float = 1
            var written = 0
            var blockIndex = 0
            var lastWall = ContinuousClock.now

            while let block = try await input.receive() {
                try await boundary(.write, blockIndex)
                let t0 = ContinuousClock.now
                let frames = block.vocals.count / 2

                // Per-chunk peaks (design F7: the progressive waveform fills as chunks
                // complete) — vocals channel levels, normalized 0...1.
                let peaks = Self.channelPeaks(block.vocals)
                events.yield(.peaks(peaks))

                // Shared headroom gain (plan gain policy): one attenuation applied to
                // BOTH stems when the int24 conversion would clip; monotone within a
                // split; the applied value is logged.
                let blockPeak = max(
                    Self.maxAbs(block.vocals), Self.maxAbs(block.instrumental))
                let conditioned = StemEngine.conditionedGain(current: appliedGain, peak: blockPeak)
                if conditioned != appliedGain {
                    appliedGain = conditioned
                    log.info("headroom gain \(appliedGain, format: .fixed(precision: 4)) applied at output block \(blockIndex) (peak \(blockPeak, format: .fixed(precision: 4)))")
                }
                try vocals.append(interleaved: Self.scaled(block.vocals, by: appliedGain))
                try instrumental.append(interleaved: Self.scaled(block.instrumental, by: appliedGain))

                written += frames
                events.yield(.progress(
                    fraction: min(1, Double(written) / Double(estimatedTotalSamples))))

                // R3-1 phase 2: measured throughput takes over the ETA; every record is
                // persisted keyed by model ID (eng E8) so later pre-starts get truer.
                let now = ContinuousClock.now
                let wall = lastWall.duration(to: now)
                lastWall = now
                let wallSeconds = Double(wall.components.seconds)
                    + Double(wall.components.attoseconds) / 1e18
                calibrator.recordMeasuredChunk(
                    modelID: modelID,
                    audioSeconds: Double(frames) / extractor.outputSampleRate,
                    wallClockSeconds: wallSeconds)
                if let measured = calibrator.measuredEstimate(
                    modelID: modelID,
                    remainingAudioSeconds: Double(max(estimatedTotalSamples - written, 0))
                        / extractor.outputSampleRate) {
                    events.yield(.eta(measured))
                }
                log.debug("write block \(blockIndex): \(frames) frames in \(Self.ms(since: t0)) ms (gain \(appliedGain, format: .fixed(precision: 4)))")
                blockIndex += 1
            }

            // All output written: pin the displayed progress at unity before the
            // terminal event (the probe-based denominator can be ± an AAC frame).
            events.yield(.progress(fraction: 1))
            try vocals.finalize()
            try instrumental.finalize()
            return SplitOutputs(vocalsURL: session.vocalsURL, instrumentalURL: session.instrumentalURL)
        } catch {
            // Cancel/failure teardown (eng E1/E9): close and DELETE both partial files.
            vocals.abortAndDelete()
            instrumental.abortAndDelete()
            throw error
        }
    }

    /// Per-chunk-boundary hook + cooperative cancellation point (eng E1).
    private func boundary(_ stage: PipelineStage, _ chunkIndex: Int) async throws {
        try await configuration.hooks.onChunkBoundary?(stage, chunkIndex)
    }

    // MARK: Helpers

    private static func maxAbs(_ interleaved: [Float]) -> Float {
        var peak: Float = 0
        for value in interleaved {
            let magnitude = abs(value)
            if magnitude > peak { peak = magnitude }
        }
        return peak
    }

    private static func channelPeaks(_ interleaved: [Float]) -> StereoPeaks {
        var left: Float = 0
        var right: Float = 0
        var index = 0
        while index + 1 < interleaved.count {
            left = max(left, abs(interleaved[index]))
            right = max(right, abs(interleaved[index + 1]))
            index += 2
        }
        return StereoPeaks(left: min(left, 1), right: min(right, 1))
    }

    private static func scaled(_ samples: [Float], by gain: Float) -> [Float] {
        guard gain != 1 else { return samples }
        var out = samples
        var g = gain
        vDSP_vsmul(samples, 1, &g, &out, 1, vDSP_Length(samples.count))
        return out
    }

    private static func interleave(_ left: [Float], _ right: [Float]) -> [Float] {
        precondition(left.count == right.count, "channel lengths must match")
        var out = [Float](repeating: 0, count: left.count * 2)
        for i in left.indices {
            out[i * 2] = left[i]
            out[i * 2 + 1] = right[i]
        }
        return out
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int((Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18) * 1000)
    }

    /// Maps any stage error onto the frozen `StemError` surface (S2: every rescue names
    /// its class; `generic` is the one sanctioned sink).
    static func map(_ error: Error, context: String) -> StemError {
        switch error {
        case let stemError as StemError:
            return stemError
        case is CancellationError:
            return .cancelled
        case let olaError as OLAError:
            return .generic("\(context): \(olaError)")
        default:
            return .generic("\(context): \(String(describing: error))")
        }
    }
}

// MARK: - Inter-stage payload types (bounded buffers — per-chunk size, never per-file)

/// One fixed-size model chunk handed decode/stft → separate. Carries the chunk's COMPLEX
/// spectra (for phase-preserving masked ISTFT) alongside the magnitudes (the model's
/// input) and its (padded) time-domain source. Per-chunk footprint ≈ 0.7 MB; at most
/// `queueCapacity` per stage (eng E1).
private struct ChunkJob: Sendable {
    let chunk: Chunk
    let source: [Float]                 // interleaved stereo, OLA.chunkSize × 2
    let leftSpec: Spectrogram           // complex STFT of the left channel
    let rightSpec: Spectrogram          // complex STFT of the right channel
    let magnitudes: StereoMagnitudeChunk
}

private struct SeparatedChunk: Sendable {
    let job: ChunkJob
    let mask: StereoVocalMask
}

/// Final (crossfaded) output samples: vocals and instrumental interleaved stereo,
/// ready for gain conditioning and the streaming writers.
private struct OutputBlock: Sendable {
    let vocals: [Float]
    let instrumental: [Float]
}

/// Write-stage result handoff (the group's only value-carrying stage).
private final class OutputBox: @unchecked Sendable {
    var result: SplitOutputs?
}

// MARK: - Stream chunker (decode-stage local)

/// Slices the extractor's variable 44.1 kHz buffers into fixed, hop-aligned model chunks
/// with a zero-padded tail (plan T3 / OLA.swift contract). Confined to the decode-stage
/// task; the retained prefix never exceeds one chunk plus one input buffer.
private final class StreamChunker {

    struct Piece: Sendable {
        let index: Int
        let start: Int
        let padding: Int
        /// Interleaved stereo, exactly `OLA.chunkSize * 2` scalars (zero-padded tail).
        let source: [Float]
    }

    private var pending: [Float] = []       // interleaved, starts at global frame `base`
    private var base = 0                    // global frame index of pending[0]
    private var nextIndex = 0
    private var accumulatedFrames = 0
    private(set) var chunksEmitted = 0

    private let chunkSize = OLA.chunkSize
    private var advance: Int { chunkSize - OLA.chunkOverlap }

    func append(_ buffer: AudioChunk) {
        precondition(buffer.channels == 2, "engine consumes the extractor's stereo policy")
        pending.append(contentsOf: buffer.interleavedSamples)
        accumulatedFrames += buffer.frameCount
    }

    var totalFrames: Int { accumulatedFrames }

    /// The next chunk fully covered by accumulated audio, or nil.
    func nextCompleteChunk() -> Piece? {
        let start = nextIndex * advance
        guard base + pending.count / 2 >= start + chunkSize else { return nil }
        return take(start: start, index: nextIndex, padding: 0)
    }

    /// The next tail chunk at EOF, zero-padded to the fixed size, or nil when done.
    func nextTailChunk(totalFrames: Int) -> Piece? {
        let count = totalFrames <= 0 ? 0 : (totalFrames + advance - 1) / advance
        guard nextIndex < count else { return nil }
        let start = nextIndex * advance
        return take(
            start: start, index: nextIndex,
            padding: max(0, start + chunkSize - totalFrames))
    }

    private func take(start: Int, index: Int, padding: Int) -> Piece {
        let low = (start - base) * 2
        let available = min(chunkSize, pending.count / 2 - (start - base))
        var samples = Array(pending[low ..< low + available * 2])
        if available < chunkSize {
            samples.append(contentsOf: [Float](repeating: 0, count: (chunkSize - available) * 2))
        }
        nextIndex += 1
        chunksEmitted += 1
        // Drop everything before the next chunk's start; the retained prefix is bounded.
        let keepFrom = nextIndex * advance
        if keepFrom > base {
            let drop = min(pending.count, (keepFrom - base) * 2)
            pending.removeFirst(drop)
            base = keepFrom
        }
        return Piece(index: index, start: start, padding: padding, source: samples)
    }
}
