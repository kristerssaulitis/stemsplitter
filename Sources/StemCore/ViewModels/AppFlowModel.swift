import Foundation
import Combine

// MARK: - Picked video (F1/F4 input facts; the thumbnail Image stays a view concern)

/// Normalized facts about the picked library video. Built by the app layer's
/// importer (PhotosPicker → security-scoped tmp copy, eng E5) and consumed by
/// every screen model. Foundation-only so the models stay testable on macOS.
public struct PickedVideo: Equatable, Sendable {

    public var id: String

    /// Display title (asset title metadata, else filename without extension).
    public var title: String

    /// Duration of the video in seconds.
    public var duration: TimeInterval

    /// Local file URL handed to the engine (`StemEngineProtocol.split`).
    /// For iCloud-Photos-only assets the app layer supplies the URL it wants the
    /// engine to resolve; the engine's `.phase(.downloading)` events drive the
    /// download modal either way (contract `PipelinePhase.downloading`).
    public var localURL: URL?

    /// Total file size in bytes when known (iCloud modal size line, eng E7;
    /// disk preflight projection, eng E5). `nil` = unknown, UI hides the line.
    public var fileSizeBytes: Int64?

    /// True when the asset lives in iCloud Photos and is not on device yet.
    /// Preflight skips the AVFoundation probe for these (probing would trigger
    /// an untracked download outside the modal).
    public var isCloudBacked: Bool

    public init(
        id: String,
        title: String,
        duration: TimeInterval,
        localURL: URL? = nil,
        fileSizeBytes: Int64? = nil,
        isCloudBacked: Bool = false
    ) {
        self.id = id
        self.title = title
        self.duration = duration
        self.localURL = localURL
        self.fileSizeBytes = fileSizeBytes
        self.isCloudBacked = isCloudBacked
    }
}

// MARK: - Flow route (plan S1 state machine, UI projection)

/// The single-flow navigation: picker → pre-flight → processing → result
/// (plan F1/F4/F2/result; "one screen" = single-flow UI, not literally one view).
public enum FlowRoute: Equatable, Sendable {
    case picker
    case preflight
    case processing
    case result
}

// MARK: - AppFlowModel

/// Owns the flow state machine (plan S1: idle → preflight → in-flight phases →
/// done | failed | canceled) and the per-screen child models.
///
/// Single-flight (CEO row 13): `pick` is ignored outside `.picker`, so the
/// picker can never start a second split while one runs. Terminal routing:
/// completed → result; failed → stays on processing with the named/generic
/// copy (F3/F5); cancelled → back to the picker (output discarded, S1).
@MainActor
public final class AppFlowModel: ObservableObject {

    /// F12 start-again modal state (names the video; actions Start again / Discard).
    public struct StartAgainState: Equatable {
        public var videoTitle: String

        public init(videoTitle: String) {
            self.videoTitle = videoTitle
        }
    }

    @Published public private(set) var route: FlowRoute = .picker
    @Published public private(set) var video: PickedVideo?
    @Published public private(set) var preflight: PreflightModel?
    @Published public private(set) var processing: ProcessingModel?
    @Published public private(set) var result: ResultModel?

    /// F9a: inline picker notice "Export first — splits don't persist." shown
    /// after "New split" replaces the result.
    @Published public private(set) var showsExportFirstNotice = false

    /// F12: non-nil while the start-again modal is up.
    @Published public private(set) var startAgain: StartAgainState?

    /// Source URL of the in-flight split (Original playback + retry input).
    private var activeSourceURL: URL?

    private let engine: any StemEngineProtocol

    /// Audio transport factory for the result screen (real: StemUI's
    /// AVStemPlayer; tests: mock). Core stays AVFoundation-free here.
    /// Preflight factory (tests inject a model with a stubbed probe; the
    /// default uses the real AVFoundation probe + disk check).
    private let makePreflight: @MainActor (PickedVideo) -> PreflightModel

    public init(
        engine: any StemEngineProtocol,
        makePreflight: (@MainActor (PickedVideo) -> PreflightModel)? = nil
    ) {
        self.engine = engine
        self.makePreflight = makePreflight ?? { PreflightModel(video: $0) }
    }

    // MARK: Pick (empty state → pre-flight)

    /// Single-flight guard (CEO row 13 / S4): picking during pre-flight,
    /// processing, or result is ignored — the picker control is disabled in
    /// those states and this is the enforcing backstop.
    public func pick(_ video: PickedVideo) {
        guard route == .picker else { return }
        showsExportFirstNotice = false
        self.video = video
        preflight = makePreflight(video)
        route = .preflight
    }

    public func cancelPreflight() {
        preflight = nil
        video = nil
        route = .picker
    }

    // MARK: Pre-flight gate (F4)

    /// Called by the pre-flight view after the inline probe + disk check land.
    /// Proceeds only when allowed; long videos (estimate > 3 min) first raise
    /// the F4 confirm sheet and come back here after Continue.
    public func proceedFromPreflight() {
        guard route == .preflight, let preflight else { return }
        guard preflight.probe == .allowed else { return }
        if preflight.needsLongVideoConfirm && !preflight.longVideoConfirmed {
            preflight.requestLongVideoConfirm()
            return
        }
        beginSplit()
    }

    private func beginSplit() {
        guard let video, let url = video.localURL else {
            // App-layer bug (no source URL at all) — never hang; return to picker.
            cancelPreflight()
            return
        }
        let model = ProcessingModel(engine: engine, video: video, sourceURL: url)
        activeSourceURL = url
        model.onTerminal = { [weak self] terminal in
            self?.processingDidTerminate(terminal)
        }
        processing = model
        route = .processing
        model.start()
    }

    // MARK: Terminal routing (plan S1)

    private func processingDidTerminate(_ terminal: ProcessingModel.Terminal) {
        switch terminal {
        case .completed(let outputs):
            guard let sourceURL = activeSourceURL else { return }
            result = ResultModel(
                title: video?.title ?? "Split",
                sourceURL: sourceURL,
                outputs: outputs,
                splitSeconds: processing?.elapsed ?? 0
            )
            route = .result // AppFlowView fires the landing haptic on this transition (CEO-2)
        case .failed:
            // Stay on .processing; ProcessingView shows the error copy
            // (F3 generic / F5 corrupt / S2 named messages) with Try again.
            break
        case .cancelled:
            processing = nil
            route = .picker // cancel discards partial output (S1/plan row 14)
        }
    }

    /// F3 "Split failed — try again": restart the same video from scratch.
    public func tryAgain() {
        processing?.start()
    }

    /// Leave processing for the picker (failure escape hatch / discard).
    /// The engine is retry-safe by contract; orphan dir purge is SplitStore's
    /// launch/Start-again concern, not the UI's.
    public func abandonSplit() {
        processing?.stop()
        processing = nil
        activeSourceURL = nil
        route = .picker
    }

    // MARK: Session navigation (F9a)

    /// "New split" replaces the result with the picker and the export-first
    /// notice. Splits don't persist — Share / Save to Files is the persistence
    /// path (plan output lifecycle).
    public func newSplit() {
        guard route == .result else { return }
        result?.stop()
        result = nil
        processing = nil
        preflight = nil
        video = nil
        route = .picker
        showsExportFirstNotice = true
    }

    // MARK: Interruption (F12)

    /// Call when the split is interrupted (app suspended mid-split). Names the
    /// video in the Start-again modal; never restarts automatically — a
    /// user-confirmed restart, never an automatic re-spend of CPU (constraint).
    public func interruptSplit() {
        guard route == .processing, let video else { return }
        startAgain = StartAgainState(videoTitle: video.title)
    }

    /// "Start again": purge-then-restart. The engine is safe to retry by
    /// contract (it never requires caller cleanup); SplitStore purges the
    /// orphaned Caches/Splits/<uuid>/ dir on launch / Start-again.
    public func startAgainConfirmed() {
        guard startAgain != nil else { return }
        startAgain = nil
        processing?.start()
    }

    /// "Discard": back to the empty picker state.
    public func startAgainDiscarded() {
        startAgain = nil
        abandonSplit()
    }
}
