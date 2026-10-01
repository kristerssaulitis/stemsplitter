import Foundation
import Combine

// MARK: - ProcessingModel

/// View-model for the processing screen (design F2/F7/F11 + plan S1 terminal
/// states). Subscribes to the engine's single `PipelineEvent` stream (eng E2)
/// and projects it: progressive waveform peaks, progress, two-phase ETA,
/// cancel confirmation gating, and the failure copy (F3/F5/S2).
@MainActor
public final class ProcessingModel: ObservableObject {

    /// How a run ended (plan S1 terminal states). Delivered exactly once per run.
    public enum Terminal: Equatable {
        case completed(SplitOutputs)
        case failed(StemError)
        case cancelled
    }

    // MARK: Published projected state

    /// Current in-flight phase; `.downloading` shows the iCloud modal (F4/E7).
    @Published public private(set) var phase: PipelinePhase?

    /// Fraction of the source audio processed, 0.0...1.0.
    @Published public private(set) var progress: Double = 0

    /// One combined peak per completed chunk (max of both channels), in arrival
    /// order — drives the progressive waveform fill (F7).
    @Published public private(set) var peaks: [Float] = []

    /// Latest ETA; `isInitial` drives the "initial estimate" label (R3-1).
    @Published public private(set) var eta: ETAEstimate?

    /// Non-nil when the run failed (not cancelled). The view shows
    /// `failure.userMessage`; `.generic` yields F3's "Split failed — try again".
    @Published public private(set) var failure: StemError?

    /// F11: the cancel confirmation alert is up (engine NOT cancelled yet).
    @Published public private(set) var showsCancelConfirmation = false

    @Published public private(set) var isRunning = false

    public let video: PickedVideo

    /// Set exactly once per run, on the terminal event.
    public var onTerminal: ((Terminal) -> Void)?

    // MARK: Private

    private let engine: any StemEngineProtocol
    private let sourceURL: URL
    private let now: () -> Date
    private var startDate: Date
    private var runTask: Task<Void, Never>?
    private var finished = false

    /// F11 gate: the confirmation alert appears once elapsed > 30 s; under
    /// 30 s, cancel is immediate (nothing of value to lose yet).
    public static let cancelConfirmationThreshold: TimeInterval = 30

    public init(
        engine: any StemEngineProtocol,
        video: PickedVideo,
        sourceURL: URL,
        now: @escaping () -> Date = Date.init
    ) {
        self.engine = engine
        self.video = video
        self.sourceURL = sourceURL
        self.now = now
        self.startDate = now()
    }

    /// Seconds since this run started (drives the F11 cancel gate).
    public var elapsed: TimeInterval {
        now().timeIntervalSince(startDate)
    }

    // MARK: Run control

    /// Starts (or restarts) the split. Safe to call again after a terminal
    /// event — F3 "Try again" and F12 "Start again" both land here.
    public func start() {
        runTask?.cancel()
        phase = nil
        progress = 0
        peaks = []
        eta = nil
        failure = nil
        showsCancelConfirmation = false
        finished = false
        startDate = now()
        isRunning = true

        let engine = self.engine
        let sourceURL = self.sourceURL
        runTask = Task {
            let stream = await engine.split(sourceURL)
            for await event in stream {
                guard !Task.isCancelled else { break }
                self.handle(event)
            }
        }
    }

    /// Stops consuming (leaving processing mid-flight via app-level navigation).
    /// The engine stays retry-safe; partial output is its own concern.
    public func stop() {
        runTask?.cancel()
        isRunning = false
    }

    // MARK: Cancel (F11)

    public func requestCancel() {
        guard !finished else { return }
        if elapsed > Self.cancelConfirmationThreshold {
            showsCancelConfirmation = true // gate: ask before discarding 30+ s of work
        } else {
            performCancel()
        }
    }

    public func confirmCancel() {
        showsCancelConfirmation = false
        performCancel()
    }

    public func keepGoing() {
        showsCancelConfirmation = false
    }

    private func performCancel() {
        let engine = self.engine
        Task { await engine.cancel() } // actor-serialized; stream ends with .failure(.cancelled)
    }

    // MARK: Event projection (eng E2 single event surface)

    /// Projects one `PipelineEvent` into view state. Internal so tests can
    /// drive it deterministically; `start()`'s task feeds it live events.
    func handle(_ event: PipelineEvent) {
        guard !finished else { return }
        switch event {
        case .phase(let newPhase):
            phase = newPhase
        case .progress(let fraction):
            progress = min(max(fraction, 0), 1)
        case .peaks(let stereo):
            peaks.append(max(stereo.left, stereo.right))
        case .eta(let estimate):
            eta = estimate // isInitial flips false on the measured takeover (R3-1)
        case .failure(let error):
            finished = true
            isRunning = false
            showsCancelConfirmation = false
            if error == .cancelled {
                onTerminal?(.cancelled) // S1 canceled: no failure UI, back to picker
            } else {
                failure = error
                onTerminal?(.failed(error))
            }
        case .completed(let outputs):
            finished = true
            isRunning = false
            onTerminal?(.completed(outputs))
        }
    }
}
