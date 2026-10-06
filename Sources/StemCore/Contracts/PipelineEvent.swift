import Foundation

/// The single event surface between the engine and SwiftUI (plan eng E2: one
/// PipelineEvent stream; views never reach into engine internals).
///
/// FROZEN CONTRACT. A split emits, in order:
///   1. `phase` transitions, exactly once each: `.downloading` → `.decoding` →
///      `.splitting` (the plan S1 state machine's in-flight states; the `idle`,
///      `done`, `failed`, `canceled` states are implicit — the stream starts and
///      the terminal events below end it).
///   2. zero or more `progress` / `peaks` / `eta` events while chunks complete
///      (per-chunk stereo peaks feed the progressive waveform; the first `eta`
///      event has `isInitial == true` and is superseded by the measured
///      first-chunk takeover with `isInitial == false`, plan R3-1 remedy).
///   3. exactly ONE terminal event — `.failure(StemError)` or
///      `.completed(SplitOutputs)` — after which the stream finishes. Cancellation
///      arrives as `.failure(.cancelled)` (the plan's `canceled` terminal state).
public enum PipelineEvent: Equatable, Sendable {

    /// Session phase changed (plan S1 state machine, in-flight states only).
    case phase(PipelinePhase)

    /// Overall progress through the source audio as a fraction in 0.0...1.0
    /// (fraction of audio duration processed, linear in wall-clock per plan S1).
    case progress(fraction: Double)

    /// Per-chunk stereo peaks, normalized 0.0...1.0 per channel. Emitted
    /// incrementally during streaming so the waveform fills as chunks complete
    /// (plan design F7/F10; peaks computed incrementally during streaming).
    case peaks(StereoPeaks)

    /// Honest ETA in seconds. `isInitial == true`: the pre-start figure — last-known
    /// persisted per-device calibration if one exists, else the ~30s/min gate-class
    /// (iPhone 17) figure, labeled "initial estimate" in UI (plan R3-1 remedy).
    /// `isInitial == false`: the measured first-chunk-throughput takeover.
    case eta(ETAEstimate)

    /// Terminal failure. Cancelled splits arrive as `.failure(.cancelled)`.
    case failure(StemError)

    /// Terminal success: the two output WAVs, 44.1 kHz/24-bit stereo
    /// (vocals + complement-derived instrumental), inside the session's
    /// Caches/Splits/<uuid>/ directory (plan output lifecycle).
    case completed(SplitOutputs)
}

/// In-flight split phases (plan S1 state machine). Emitted in this order, once each.
public enum PipelinePhase: Equatable, Sendable {

    /// On-demand download of an iCloud-Photos-only asset (online; progress via
    /// `progress`/`eta` events; offline fails with `.icloudDownload(.offline)`).
    case downloading

    /// AVAssetReader decode + explicit 44.1 kHz conversion stage (plan channel
    /// policy: sources at other sample rates pass AVAudioConverter 44.1 kHz).
    case decoding

    /// Chunked inference: chunk → STFT → model → ISTFT+OLA → complement →
    /// streaming WAV write. WAV writing happens inside this phase; the plan's
    /// state machine has no separate writing state.
    case splitting
}

/// Left/right channel peaks for one processed chunk, each normalized 0.0...1.0.
public struct StereoPeaks: Equatable, Sendable {

    /// Peak absolute amplitude of the left channel in this chunk (0.0...1.0).
    public var left: Float

    /// Peak absolute amplitude of the right channel in this chunk (0.0...1.0).
    public var right: Float

    public init(left: Float, right: Float) {
        self.left = left
        self.right = right
    }
}

/// A duration estimate for the split (plan R3-1 two-phase ETA).
public struct ETAEstimate: Equatable, Sendable {

    /// Estimated remaining-or-total wall-clock seconds; non-negative.
    public var seconds: Double

    /// `true` while the displayed figure is the pre-start estimate (persisted
    /// calibration or the labeled "initial estimate"); `false` once the measured
    /// first-chunk throughput takes over. Calibration persists across sessions
    /// and is keyed by model ID/version (eng E8) — persistence lives in
    /// Support/ETACalibrator, not in this event.
    public var isInitial: Bool

    public init(seconds: Double, isInitial: Bool) {
        self.seconds = seconds
        self.isInitial = isInitial
    }
}

/// Terminal outputs of a successful split (plan success criteria: WAV 44.1 kHz/
/// 24-bit, vocals + instrumental; instrumental derived by complement subtraction
/// so stems sum to the source exactly).
public struct SplitOutputs: Equatable, Sendable {

    /// File URL of the vocals stem WAV.
    public var vocalsURL: URL

    /// File URL of the instrumental stem WAV (source − vocals in the float domain).
    public var instrumentalURL: URL

    /// Every stem the model produced (4-stem models: drums, bass, other, vocals),
    /// plus instrumental. Empty for 2-stem engines.
    public var stems: [StemTrack]

    /// The engine's `SplitStore` session dir holding these outputs. The app layer
    /// writes display metadata there on completion (history persistence);
    /// `nil` for engines runs that never created a session (mocks, tests).
    public var sessionID: UUID?

    public init(vocalsURL: URL, instrumentalURL: URL, stems: [StemTrack] = [], sessionID: UUID? = nil) {
        self.vocalsURL = vocalsURL
        self.instrumentalURL = instrumentalURL
        self.stems = stems
        self.sessionID = sessionID
    }
}

/// One written stem: 44.1 kHz/24-bit stereo WAV plus waveform peaks
/// (`StemTrack.peaksPerSecond` max-|sample| values per second, 0...1).
public struct StemTrack: Equatable, Sendable, Identifiable {
    public static let peaksPerSecond = 50

    public var name: String
    public var url: URL
    public var peaks: [Float]

    public var id: String { name }

    public init(name: String, url: URL, peaks: [Float]) {
        self.name = name
        self.url = url
        self.peaks = peaks
    }
}
