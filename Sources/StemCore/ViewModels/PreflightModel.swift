import Foundation
import Combine
import AVFoundation

// MARK: - PreflightModel

/// Pre-flight step between pick and processing (design F4): inline audio probe +
/// disk check (instant), long-video confirm sheet when the estimate > 3 min,
/// and the two-phase ETA rule (plan R3-1: pre-start figure is the persisted
/// calibration or the ~30 s/min gate-class figure, labeled "initial estimate";
/// Low Power Mode adjusts + discloses, eng E4).
@MainActor
public final class PreflightModel: ObservableObject {

    public enum ProbeState: Equatable {
        /// Inline probe + disk check running (instant).
        case checking
        /// Video is processable and there is room for the outputs.
        case allowed
        /// Blocked with a named error; copy comes from `StemError.userMessage`
        /// (noAudio / corruptAsset / diskPreflightFail per plan S2).
        case blocked(StemError)
    }

    @Published public private(set) var probe: ProbeState = .checking
    @Published public private(set) var longVideoConfirmed = false
    @Published public private(set) var showsLongVideoConfirm = false

    /// Pre-start estimate. Always `isInitial == true` here; the measured
    /// takeover arrives later as `.eta(isInitial: false)` events (R3-1).
    @Published public private(set) var estimate: ETAEstimate

    /// True when Low Power Mode adjusted the estimate — disclosed in UI (E4).
    @Published public private(set) var lowPowerAdjusted: Bool

    public let video: PickedVideo

    /// F4 gate: the confirm sheet fires when the pre-start estimate exceeds
    /// 3 minutes of processing.
    public static let longVideoThreshold: TimeInterval = 3 * 60

    /// Gate-class figure: ~30 s of processing per minute of audio (plan R3-1,
    /// the pre-calibration default).
    public static let gateClassSecondsPerMinute: Double = 30

    /// Low Power Mode adjustment factor (eng E4: adjust or discard, disclosed).
    public static let lowPowerFactor: Double = 1.5

    private let probeCheck: @MainActor (PickedVideo) async -> StemError?

    public init(
        video: PickedVideo,
        estimateSeconds: ((TimeInterval) -> TimeInterval)? = nil,
        isLowPowerMode: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        probeCheck: (@MainActor (PickedVideo) async -> StemError?)? = nil
    ) {
        self.video = video
        self.probeCheck = probeCheck ?? { await PreflightModel.standardProbe($0) }

        let provider = estimateSeconds ?? { Self.gateClassSecondsPerMinute * $0 / 60 }
        var seconds = provider(video.duration)
        let lpm = isLowPowerMode()
        self.lowPowerAdjusted = lpm
        if lpm { seconds *= Self.lowPowerFactor }
        self.estimate = ETAEstimate(seconds: max(0, seconds), isInitial: true)
    }

    /// Long-video confirm gate (F4): estimate > 3 min.
    public var needsLongVideoConfirm: Bool {
        estimate.seconds > Self.longVideoThreshold
    }

    public func requestLongVideoConfirm() {
        showsLongVideoConfirm = true
    }

    public func confirmLongVideo() {
        longVideoConfirmed = true
        showsLongVideoConfirm = false
    }

    public func declineLongVideo() {
        showsLongVideoConfirm = false
    }

    /// Runs the inline probe + disk check (F4 "inline, instant"). Then the view
    /// calls `AppFlowModel.proceedFromPreflight()`.
    public func check() async {
        probe = .checking
        let error = await probeCheck(video)
        probe = (error == nil) ? .allowed : .blocked(error!)
    }

    // MARK: - Standard probe (real checks)

    /// AVFoundation decode probe + plan disk preflight:
    ///   - unreadable container → `.corruptAsset` (F5 copy)
    ///   - no/zero-length audio track → `.noAudio` (S2)
    ///   - free space < required → `.diskPreflightFail` (plan: ~32 MB per output
    ///     minute ×1.2 margin + 1 GB headroom; eng E5 extends with the tmp copy
    ///     projection, approximated here by the known file size when present)
    /// Cloud-backed assets skip the AVFoundation probe (probing would trigger
    /// an on-demand download outside the modal) — the split stream surfaces
    /// `.phase(.downloading)` / offline errors itself (contract S2).
    nonisolated public static func standardProbe(_ video: PickedVideo) async -> StemError? {
        if video.isCloudBacked {
            return diskCheck(video)
        }
        guard let url = video.localURL else { return .corruptAsset }

        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return .corruptAsset // container AVFoundation cannot open (F5)
        }
        if tracks.isEmpty {
            return .noAudio // no audio track (S2 row 1)
        }
        let duration = (try? await asset.load(.duration)) ?? .zero
        if duration.seconds <= 0 {
            return .noAudio // zero-length audio path (S2 Chunker row)
        }
        return diskCheck(video)
    }

    nonisolated private static func diskCheck(_ video: PickedVideo) -> StemError? {
        let required = requiredBytes(forDuration: video.duration, extraBytes: video.fileSizeBytes ?? 0)
        let free = Self.freeDiskBytes() ?? 0
        if free < required {
            return .diskPreflightFail(requiredBytes: required, freeBytes: free)
        }
        return nil
    }

    /// Plan disk formula: ~32 MB per output minute (two 24-bit 44.1k stereo
    /// stems) ×1.2 margin + 1 GB headroom, plus the projected tmp source copy.
    nonisolated public static func requiredBytes(forDuration duration: TimeInterval, extraBytes: Int64 = 0) -> Int64 {
        let outputBytesPerMinute: Double = 32 * 1024 * 1024
        let minutes = max(0, duration) / 60
        let outputs = Int64((minutes * outputBytesPerMinute * 1.2).rounded())
        let headroom: Int64 = 1_073_741_824
        return outputs + headroom + max(0, extraBytes)
    }

    nonisolated private static func freeDiskBytes() -> Int64? {
        try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? Int64
    }
}
