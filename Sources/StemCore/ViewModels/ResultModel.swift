import Foundation
import Combine

// MARK: - AudioControlling

/// The transport seam the result screen plays through. Real implementation:
/// StemUI's `AVStemPlayer` (AVPlayer-backed, AVAudioSession on iOS). Kept
/// Foundation-only here so ResultModel is unit-testable with a mock.
public protocol AudioControlling: AnyObject {

    /// Current playback position in seconds.
    var position: TimeInterval { get }

    /// Total duration of the loaded source in seconds.
    var duration: TimeInterval { get }

    var isPlaying: Bool { get }

    /// Load a source and start from `position` (F10: shared transport reloads
    /// the new segment at the preserved position).
    func load(_ url: URL, at position: TimeInterval, play: Bool)

    func play()
    func pause()
    func seek(to time: TimeInterval)
}

// MARK: - ResultModel

/// View-model for the result screen: segmented Original / Vocals / Instrumental
/// selector with a shared position-preserving transport (F10), share payloads
/// (primary Share-both + CEO-3 long-press per-stem), and the export toast (F6).
@MainActor
public final class ResultModel: ObservableObject {

    public enum Source: String, CaseIterable, Identifiable {
        case original
        case vocals
        case instrumental

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .original: "Original"
            case .vocals: "Vocals"
            case .instrumental: "Instrumental"
            }
        }
    }

    @Published public private(set) var selected: Source = .original
    @Published public private(set) var isPlaying = false

    /// F6: brief confirmation toast after share / Save to Files completes.
    @Published public private(set) var exportToastVisible = false

    /// Extracted source audio (Original selector state = audio-only playback of
    /// the extracted source, plan obligation) — the app layer's tmp copy URL.
    public let sourceAudioURL: URL

    /// The two stem WAVs (44.1 kHz/24-bit, complement-derived instrumental).
    public let outputs: SplitOutputs

    /// Combined per-chunk peaks streamed during processing (F10: mini waveforms
    /// come from the same incremental peak stream).
    public let peaks: [Float]

    /// Wall-clock seconds the split took (result header: "split in Xs").
    public let splitSeconds: TimeInterval

    private let audio: any AudioControlling

    public init(
        sourceAudioURL: URL,
        outputs: SplitOutputs,
        peaks: [Float],
        splitSeconds: TimeInterval,
        audio: any AudioControlling,
        autoplay: Bool = false
    ) {
        self.sourceAudioURL = sourceAudioURL
        self.outputs = outputs
        self.peaks = peaks
        self.splitSeconds = splitSeconds
        self.audio = audio
        audio.load(sourceAudioURL, at: 0, play: autoplay)
        isPlaying = audio.isPlaying
    }

    // MARK: Transport

    public var position: TimeInterval { audio.position }
    public var duration: TimeInterval { audio.duration }

    public func togglePlay() {
        if audio.isPlaying { audio.pause() } else { audio.play() }
        isPlaying = audio.isPlaying
    }

    /// Waveform scrub (F10 tap+drag): `fraction` is 0...1 of the duration.
    public func scrub(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        audio.seek(to: clamped * audio.duration)
    }

    // MARK: Source selector (F10 — shared, position-preserving)

    /// Switch segments while preserving transport position (and play state):
    /// the shared transport reloads the new source at the current position.
    public func select(_ source: Source) {
        guard source != selected else { return }
        let position = audio.position
        let wasPlaying = audio.isPlaying
        selected = source
        audio.load(url(for: source), at: position, play: wasPlaying)
        isPlaying = wasPlaying
    }

    /// Select a segment and make sure it is playing (stem card play buttons).
    public func playSource(_ source: Source) {
        select(source)
        if !audio.isPlaying {
            audio.play()
            isPlaying = true
        }
    }

    public func url(for source: Source) -> URL {
        switch source {
        case .original: sourceAudioURL
        case .vocals: outputs.vocalsURL
        case .instrumental: outputs.instrumentalURL
        }
    }

    // MARK: Share payloads

    /// Primary "Share stems" payload: both stem WAVs.
    public var shareStemsPayload: [URL] {
        [outputs.vocalsURL, outputs.instrumentalURL]
    }

    /// CEO-3 long-press per-stem share. Applies to stems only — the Original
    /// segment shares nothing (plan: long-press share applies to stems only).
    public func sharePayload(for source: Source) -> [URL] {
        switch source {
        case .original: []
        case .vocals: [outputs.vocalsURL]
        case .instrumental: [outputs.instrumentalURL]
        }
    }

    // MARK: Export feedback (F6)

    /// The share sheet / Save to Files completed successfully — show the toast
    /// (the view pairs it with the success haptic, iOS-only).
    public func exportFinished() {
        exportToastVisible = true
    }

    /// View dismisses the toast after its brief display window.
    public func dismissExportToast() {
        exportToastVisible = false
    }
}
