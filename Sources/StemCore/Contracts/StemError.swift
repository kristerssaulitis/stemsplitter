import Foundation

/// The single error surface for the split pipeline.
///
/// FROZEN CONTRACT. Each case encodes a decision from the plan's Review Section 2
/// (Error & Rescue Map); `userMessage` carries the plan-approved user copy verbatim
/// so UI layers never re-derive it. No catch-all handlers are permitted in engine
/// code (Section 2: every rescue names its class) — `generic` is the one sanctioned
/// sink for non-enumerated pipeline errors and routes to the generic failure state
/// "Split failed — try again" (design fix F3).
public enum StemError: Error, Equatable, Sendable {

    /// Plan S2 `NoAudibleTrackError`. No audio track in the container, or a
    /// zero-length audio path. Copy: "No audible audio track found in this video".
    case noAudio

    /// Plan S2 rows 2/5: an audio codec AVAssetReader cannot decode, or a decode/
    /// resample-stage failure (`DecodeFailure`). Copy follows the reason: codec →
    /// the no-audio copy (S2 row 2 "same copy"); resample → "Couldn't read this
    /// video's audio".
    case undecodable(DecodeFailureReason)

    /// Plan S2 + design fix F5: corrupt/truncated container (e.g. truncated moov
    /// atom) that AVFoundation cannot open as media. Distinct from `noAudio`.
    /// Copy: "This video can't be processed".
    case corruptAsset

    /// Plan S2 `ICloudOfflineError` / `DownloadStalled`: the picked PhotosPicker
    /// asset is not on device. `.offline` copy: "This video isn't downloaded to
    /// your iPhone yet — try again online". `.stalled` has no dedicated copy —
    /// the UI shows download progress + a cancel prompt.
    case icloudDownload(ICloudDownloadFailure)

    /// Plan S2 `DiskFullError`, mid-write: free space ran out while streaming WAV
    /// output. Rescue: delete partial outputs, show the preflight message.
    /// Copy: "Not enough free space on your iPhone for this split".
    case diskFull

    /// Disk preflight refused to start (plan obligation: ~32 MB per output minute
    /// ×1.2 margin + 1 GB headroom, including the tmp source-copy projection and
    /// same-session split dirs, eng E5). Copy: same as `diskFull`.
    case diskPreflightFail(requiredBytes: Int64, freeBytes: Int64)

    /// Plan S2 `ModelLoadError` (row 12): the bundled model resource exists but
    /// failed to load/compile. Rescue: preload-check at launch, alert.
    /// Copy: "StemSplitter couldn't start — reinstall".
    case modelLoad(String)

    /// Plan S2 `ModelLoadError` (missing-resource arm): the model resource is
    /// absent from the bundle. Copy: "StemSplitter couldn't start — reinstall".
    case modelMissing(String)

    /// Plan S2 `WAVWriter.write` failure other than disk-full (file-handle/IO
    /// error). Rescue: fail the split, clean up partials.
    /// Copy: "Split failed — try again".
    case writeFailure(String)

    /// Cooperative cancellation (plan row 14, E1: cancel at chunk boundaries,
    /// discard partial output). The plan's `canceled` terminal state arrives on
    /// the event stream as `.failure(.cancelled)`. User-initiated: no copy.
    case cancelled

    /// The sanctioned catch-all (plan S2 forbids unnamed catch-alls; design F3
    /// routes every non-enumerated pipeline error — e.g. `PredictionError`,
    /// `ExportError`, `CalibrationCorrupt` raised inside the pipeline — here).
    /// Copy: "Split failed — try again".
    case generic(String)

    /// Why a decode-stage failure happened (see `undecodable`).
    public enum DecodeFailureReason: Equatable, Sendable {
        /// The audio codec is not decodable on device (S2 row 2).
        case codec
        /// The decode/resample conversion itself failed (S2 `DecodeFailure`).
        case resample
    }

    /// Why an iCloud on-demand download failed (see `icloudDownload`).
    public enum ICloudDownloadFailure: Equatable, Sendable {
        /// Asset not on device and the device is offline (S2 `ICloudOfflineError`).
        case offline
        /// Download timed out / stalled (S2 `DownloadStalled`).
        case stalled
    }

    /// Plan-approved user copy (S2 "USER SEES" column + design fixes F3/F5).
    /// `nil` where the plan defines no dedicated copy (user-initiated cancel;
    /// stalled download, which is surfaced as progress + cancel prompt).
    public var userMessage: String? {
        switch self {
        case .noAudio:
            return "No audible audio track found in this video"
        case .undecodable(.codec):
            return "No audible audio track found in this video"
        case .undecodable(.resample):
            return "Couldn't read this video's audio"
        case .corruptAsset:
            return "This video can't be processed"
        case .icloudDownload(.offline):
            return "This video isn't downloaded to your iPhone yet — try again online"
        case .icloudDownload(.stalled):
            return nil
        case .diskFull, .diskPreflightFail:
            return "Not enough free space on your iPhone for this split"
        case .modelLoad, .modelMissing:
            return "StemSplitter couldn't start — reinstall"
        case .writeFailure:
            return "Split failed — try again"
        case .cancelled:
            return nil
        case .generic:
            return "Split failed — try again"
        }
    }
}
