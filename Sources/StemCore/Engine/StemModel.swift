import Foundation
import CoreML

/// The chunk-based separation-model boundary (plan T4, Approach B engine bet).
///
/// CONTRACT — derived from the approved plan, not from any one model's shapes
/// (Approach B caveat: "the StemSeparator protocol must be written against a
/// chunk/overlap-add contract"). The pipeline composes:
///
///     decode → resample 44.1k → chunk → STFT → [StemModel.separate] → mask
///            → ISTFT+overlap-add → complement (inst = src − voc) → WAV×2
///
/// - The model sees STFT **magnitude frames only** — never time-domain samples.
///   Window/hop choice, padding of sub-chunk audio, and overlap-add all live in
///   the Chunker/OLA stage (plan T3), keeping this boundary model-family agnostic.
/// - One call = one chunk. Async and cancellation-cooperative: implementations
///   must honor `Task` cancellation at chunk boundaries (eng E1) by throwing
///   `StemError.cancelled`.
/// - Errors map to the frozen `StemError` surface (plan S2):
///     load  → `.modelMissing` (resource absent) / `.modelLoad` (present but
///             fails to load/compile/validate);
///     infer → `.generic` (the sanctioned PredictionError sink, S2/F3);
///     cancel→ `.cancelled`.
/// - `modelID` keys the persisted ETA calibration (eng E8: calibration is keyed
///   by model ID/version, so a model swap invalidates stale calibration).
///
/// Compute units: the plan's engine preference is `.all` (Neural Engine
/// residency, plan S1/E3); implementations must accept any `MLComputeUnits`
/// preference so tests can pin `.cpuOnly` deterministically and the store can
/// arm an explicit `.cpuAndGPU` fallback (transparent, slower — S2 row:
/// "ANE unavailable → CPU: transparent (slower, no error)").
///
/// Conforming types ARE actors (async throwing init, serialized `separate`);
/// the refinement is written as `AnyObject, Sendable` rather than `Actor`
/// because the Xcode 27 Swift 6.4 compiler hits an IRGen assertion
/// (`#Actor.unownedExecutor!getter`, getAbstract) lowering witness thunks for
/// async-init requirements on Actor-refining protocols. `Sendable` is what
/// `any StemModel` consumers (ModelStore, engine) actually need.
public protocol StemModel: AnyObject, Sendable {

    /// Stable model identity for ETA-calibration keying (eng E8) and logging.
    static var modelID: String { get }

    /// Load (and compile, if needed) the model with the given compute-unit
    /// preference. Throwing async init: the store treats construction success
    /// as the `.loaded` state (plan T8 preload).
    init(computeUnits: MLComputeUnits) async throws

    /// Separate one chunk: stereo magnitude frames in → vocal soft mask out,
    /// geometry-matched to the input (same frame count and bin count).
    ///
    /// Implementations must be safe to call repeatedly across a stream of
    /// chunks (streaming pipeline, bounded inter-stage queue, eng E1).
    func separate(_ chunk: StereoMagnitudeChunk) async throws -> StereoVocalMask
}

/// One chunk of stereo STFT magnitude frames (plan T4: chunk → STFT → model).
///
/// Layout is frame-major and flattened for zero-friction handoff to
/// Accelerate/CoreML: element `frame * binCount + bin`.
public struct StereoMagnitudeChunk: Sendable, Equatable {

    /// Number of STFT frames in this chunk (model-time axis).
    public let frameCount: Int

    /// Number of frequency bins per frame (e.g. n_fft/2 + 1 for the stage
    /// that produced the frames — owned by the Chunker/STFT stage, plan T3).
    public let binCount: Int

    /// Left-channel magnitudes, frame-major, `frameCount * binCount` elements.
    public let left: [Float]

    /// Right-channel magnitudes, frame-major, `frameCount * binCount` elements.
    public let right: [Float]

    public init(frameCount: Int, binCount: Int, left: [Float], right: [Float]) {
        precondition(left.count == frameCount * binCount,
                     "left channel must hold frameCount*binCount magnitudes")
        precondition(right.count == frameCount * binCount,
                     "right channel must hold frameCount*binCount magnitudes")
        self.frameCount = frameCount
        self.binCount = binCount
        self.left = left
        self.right = right
    }

    public func left(frame: Int, bin: Int) -> Float { left[frame * binCount + bin] }
    public func right(frame: Int, bin: Int) -> Float { right[frame * binCount + bin] }

    /// Vocals := mask ⊙ source, elementwise in the float domain (plan: vocals
    /// are the masked source; instrumental is the complement, never a second
    /// independent model output).
    public func applying(_ mask: StereoVocalMask) -> StereoMagnitudeChunk {
        precondition(mask.frameCount == frameCount && mask.binCount == binCount,
                     "mask geometry must match chunk geometry")
        var out = left
        for i in out.indices { out[i] *= mask.left[i] }
        var outR = right
        for i in outR.indices { outR[i] *= mask.right[i] }
        return StereoMagnitudeChunk(frameCount: frameCount, binCount: binCount, left: out, right: outR)
    }

    /// Instrumental := source − vocals, elementwise (plan channel/gain policy:
    /// "instrumental := source − vocals in the float domain so stems sum to the
    /// source exactly"). At this magnitude-frame level this is the algebra the
    /// engine composes; the sample-domain identity (sum-to-source) holds via
    /// the engine's STFT/OLA stage (plan T3 + Section 6 sum-to-unity test).
    public func subtracting(_ other: StereoMagnitudeChunk) -> StereoMagnitudeChunk {
        precondition(other.frameCount == frameCount && other.binCount == binCount,
                     "geometry must match for complement subtraction")
        var out = left
        for i in out.indices { out[i] -= other.left[i] }
        var outR = right
        for i in outR.indices { outR[i] -= other.right[i] }
        return StereoMagnitudeChunk(frameCount: frameCount, binCount: binCount, left: out, right: outR)
    }
}

/// The vocal soft mask a model produces for one chunk, geometry-matched to its
/// input `StereoMagnitudeChunk`. Values are clamped to 0.0...1.0 by contract.
public struct StereoVocalMask: Sendable, Equatable {

    public let frameCount: Int
    public let binCount: Int

    /// Left-channel mask, frame-major (`frameCount * binCount`), 0.0...1.0.
    public let left: [Float]

    /// Right-channel mask, frame-major (`frameCount * binCount`), 0.0...1.0.
    public let right: [Float]

    public init(frameCount: Int, binCount: Int, left: [Float], right: [Float]) {
        precondition(left.count == frameCount * binCount, "mask must match chunk geometry")
        precondition(right.count == frameCount * binCount, "mask must match chunk geometry")
        self.frameCount = frameCount
        self.binCount = binCount
        self.left = left
        self.right = right
    }

    public func left(frame: Int, bin: Int) -> Float { left[frame * binCount + bin] }
    public func right(frame: Int, bin: Int) -> Float { right[frame * binCount + bin] }
}
