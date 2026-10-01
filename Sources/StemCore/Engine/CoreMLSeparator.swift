import Foundation
import CoreML
import os

/// The production `StemModel`: the bundled CoreML 2-stem MDX-class model
/// "StemV2" (plan T4, S1 engine diagram "MDXSeparator (CoreML, ANE)").
///
/// ─────────────────────────────────────────────────────────────────────────────
/// DROPPING IN THE REAL MODEL (it is intentionally absent today; every load
/// then degrades to `StemError.modelMissing` and the ModelStore surfaces the
/// plan's reinstall alert — never a crash, plan S2 row 12):
///
///   1. Weights: pick a 2-stem UVR-MDX-class checkpoint with license verified
///      commercial-OK (CEO amendment: license folds into Day-1 selection).
///   2. Convert with coremltools (Python, macOS). The pipeline contract this
///      actor pins is chunk-in/mask-out over stereo magnitude frames:
///
///         import coremltools as ct
///         mlmodel = ct.convert(onnx_model,
///             inputs=[ct.TensorType(name="magnitudes",
///                                   shape=(1, 2, 256, 1025),  # (batch, channel, frames, bins)
///                                   dtype=np.float32)],
///             outputs=[ct.TensorType(name="vocals")],          # vocal soft mask, same shape
///             compute_units=ct.ComputeUnit.ALL,                # ANE preference (plan E3)
///             minimum_deployment_target=ct.target.iOS17)
///         mlmodel.save("StemV2.mlmodel")
///
///      If the checkpoint emits masked magnitudes rather than a raw mask, wrap
///      the graph so "vocals" is mask = vocals_mag / mixture_mag (div-safe).
///   3. Compile: `xcrun coremlcompiler compile StemV2.mlmodel <outdir>` →
///      `StemV2.mlmodelc`, and add it to the app target's resources.
///      (Alternatively ship the `.mlmodel` and let the OS compile+cache on
///      first launch — plan row 15's compiled-model cache; a precompiled
///      `.mlmodelc` in the bundle keeps first-launch preload latency at zero,
///      which is what T8 measures.)
///
///   Runtime compute placement: `.all` is requested first so the ANE can take
///   the predictor; if that load fails we retry once with `.cpuAndGPU` and log
///   the fallback (S2: ANE→CPU is transparent, only slower). Public CoreML API
///   cannot query which silicon executed a given prediction — residency is
///   verified offline with Instruments' Core ML Trace against the os_signpost
///   intervals emitted here (plan E3), and the effective configuration is
///   logged at load.
/// ─────────────────────────────────────────────────────────────────────────────
public actor CoreMLSeparator: StemModel {

    public static let modelID = "stemv2-mdx-2stem-v1"
    public static let defaultModelName = "StemV2"

    /// Pinned CoreML I/O names/shape contract (see conversion recipe above).
    /// Input  "magnitudes": float32 [1, 2, frames, bins], frame-major, channels L,R.
    /// Output "vocals":     float32 [1, 2, frames, bins], vocal soft mask in [0,1].
    public static let inputName = "magnitudes"
    public static let outputName = "vocals"

    private static let log = Logger(subsystem: "com.stemsplitter.app", category: "model")
    private static let signposter = OSSignposter(subsystem: "com.stemsplitter.app", category: "model")

    /// The compute units the loaded model actually runs under — `.all` when the
    /// ANE-preferred load succeeded, `.cpuAndGPU` after the logged fallback.
    public private(set) var effectiveComputeUnits: MLComputeUnits

    /// Frame/bin dims the model's own description pins (−1 = flexible/wildcard,
    /// in which case any chunk geometry is accepted).
    public private(set) var pinnedFrames: Int
    public private(set) var pinnedBins: Int

    private let box: ModelBox

    /// Protocol witness: default bundle (the app bundle) + default name "StemV2".
    public init(computeUnits: MLComputeUnits) async throws {
        try await self.init(computeUnits: computeUnits, modelURL: nil, bundle: .main)
    }

    /// Full loader. `modelURL` (injected path) wins over the bundle lookup —
    /// tests inject both to exercise the `.modelMissing` / `.modelLoad` arms
    /// without shipping a model.
    public init(computeUnits: MLComputeUnits = .all,
                modelURL: URL? = nil,
                bundle: Bundle = .main,
                modelName: String = CoreMLSeparator.defaultModelName) async throws {
        let resolvedURL: URL
        if let modelURL {
            resolvedURL = modelURL
        } else if let found = bundle.url(forResource: modelName, withExtension: "mlmodelc") {
            resolvedURL = found
        } else {
            Self.log.error("StemV2: resource '\(modelName, privacy: .public).mlmodelc' not found in bundle '\(bundle.bundleURL.lastPathComponent, privacy: .public)'")
            throw StemError.modelMissing(modelName)
        }
        // An injected path can also point at nothing — absence is
        // .modelMissing regardless of how the URL was resolved (S2 row 12's
        // missing-resource arm); a PRESENT-but-invalid model is .modelLoad.
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            Self.log.error("StemV2: no model at \(resolvedURL.path, privacy: .public)")
            throw StemError.modelMissing(modelName)
        }

        // ANE preference first (plan E3); one logged .cpuAndGPU fallback when
        // an explicit .all request fails to load. Other explicit requests
        // (.cpuOnly etc.) are honored without fallback.
        let attempts: [MLComputeUnits] = computeUnits == .all ? [.all, .cpuAndGPU] : [computeUnits]
        var loaded: ModelBox?
        var used = computeUnits
        var pinnedFrames = -1
        var pinnedBins = -1
        var lastError: (any Error)?

        for units in attempts {
            let state = Self.signposter.beginInterval("ModelLoad")
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                let mlModel = try MLModel(contentsOf: resolvedURL, configuration: configuration)
                (pinnedFrames, pinnedBins) = try Self.validateContract(mlModel, modelName: modelName)
                Self.signposter.endInterval("ModelLoad", state)
                loaded = ModelBox(mlModel)
                used = units
                if units != computeUnits {
                    Self.log.error("StemV2: .all load failed, fell back to cpuAndGPU (transparent, S2)")
                }
                Self.log.info("StemV2: loaded \(resolvedURL.lastPathComponent, privacy: .public) — requested \(String(describing: computeUnits), privacy: .public), effective \(String(describing: units), privacy: .public); frames=\(pinnedFrames) bins=\(pinnedBins); ANE residency verifiable via Core ML Trace on these signposts")
                break
            } catch {
                Self.signposter.endInterval("ModelLoad", state)
                lastError = error
                Self.log.error("StemV2: load with \(String(describing: units), privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            }
        }

        guard let loaded else {
            throw StemError.modelLoad("\(modelName): \(Self.describe(lastError))")
        }
        self.box = loaded
        self.effectiveComputeUnits = used
        self.pinnedFrames = pinnedFrames
        self.pinnedBins = pinnedBins
    }

    /// Load-time contract validation: names and multiArray shape. A present but
    /// wrong-contract model is a load failure (`.modelLoad`), not a runtime
    /// surprise per chunk.
    private static func validateContract(_ model: MLModel, modelName: String) throws -> (frames: Int, bins: Int) {
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        guard let inConstraint = inputs[inputName]?.multiArrayConstraint,
              let outConstraint = outputs[outputName]?.multiArrayConstraint else {
            throw StemError.modelLoad("\(modelName): expected multiArray input '\(inputName)' and output '\(outputName)' — reconvert per the header recipe")
        }
        let inShape = inConstraint.shape.map { $0.intValue }
        let outShape = outConstraint.shape.map { $0.intValue }
        guard inShape.count == 4, outShape.count == 4,
              inShape[0] == 1, inShape[1] == 2, outShape[0] == 1, outShape[1] == 2 else {
            throw StemError.modelLoad("\(modelName): shape contract is [1, 2, frames, bins], got in=\(inShape) out=\(outShape)")
        }
        guard inShape[2] == outShape[2], inShape[3] == outShape[3] else {
            throw StemError.modelLoad("\(modelName): mask shape must match input shape, got in=\(inShape) out=\(outShape)")
        }
        return (inShape[2], inShape[3])  // −1 = wildcard (flexible dims)
    }

    public func separate(_ chunk: StereoMagnitudeChunk) async throws -> StereoVocalMask {
        do { try Task.checkCancellation() } catch { throw StemError.cancelled }

        if pinnedFrames > 0 && pinnedFrames != chunk.frameCount
            || pinnedBins > 0 && pinnedBins != chunk.binCount {
            throw StemError.generic("StemV2: chunk geometry \(chunk.frameCount)x\(chunk.binCount) does not match model geometry \(pinnedFrames)x\(pinnedBins)")
        }

        let input: MLDictionaryFeatureProvider
        do {
            input = try Self.makeInput(chunk)
        } catch {
            throw StemError.generic("StemV2: input feature build failed — \(Self.describe(error))")
        }

        let job = PredictionJob(model: box.model, input: input)
        let state = Self.signposter.beginInterval("StemV2.predict")
        let scalars: [Float]
        do {
            // MLModel and the feature values are documented thread-safe and
            // immutable once built; the @unchecked box only bridges that
            // guarantee to Swift 6 sendability. Prediction runs off this
            // actor so a multi-second chunk does not pin a cooperative thread;
            // the job returns plain [Float] so nothing non-Sendable crosses
            // the isolation boundary.
            scalars = try await Task.detached(priority: .userInitiated) { try job.run() }.value
        } catch is CancellationError {
            Self.signposter.endInterval("StemV2.predict", state)
            throw StemError.cancelled
        } catch {
            Self.signposter.endInterval("StemV2.predict", state)
            throw StemError.generic("StemV2: prediction failed — \(Self.describe(error))")
        }
        Self.signposter.endInterval("StemV2.predict", state)

        return Self.mask(from: scalars, frames: chunk.frameCount, bins: chunk.binCount)
    }

    // MARK: - Feature plumbing ([1, 2, frames, bins], channel 0 = L, 1 = R)

    private static func makeInput(_ chunk: StereoMagnitudeChunk) throws -> MLDictionaryFeatureProvider {
        var scalars = [Float](repeating: 0, count: chunk.frameCount * chunk.binCount * 2)
        let bins = chunk.binCount
        for frame in 0..<chunk.frameCount {
            let src = frame * bins
            let dst = src * 2
            for bin in 0..<bins {
                scalars[dst + bin * 2] = chunk.left[src + bin]
                scalars[dst + bin * 2 + 1] = chunk.right[src + bin]
            }
        }
        let shaped = MLShapedArray<Float>(scalars: scalars,
                                          shape: [1, 2, chunk.frameCount, chunk.binCount])
        return try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(shapedArray: shaped)])
    }

    private static func mask(from scalars: [Float], frames: Int, bins: Int) -> StereoVocalMask {
        var left = [Float](repeating: 0, count: frames * bins)
        var right = [Float](repeating: 0, count: frames * bins)
        for frame in 0..<frames {
            let src = frame * bins * 2
            let dst = frame * bins
            for bin in 0..<bins {
                left[dst + bin] = min(max(scalars[src + bin * 2], 0), 1)
                right[dst + bin] = min(max(scalars[src + bin * 2 + 1], 0), 1)
            }
        }
        return StereoVocalMask(frameCount: frames, binCount: bins, left: left, right: right)
    }

    private static func describe(_ error: (any Error)?) -> String {
        guard let error else { return "unknown error" }
        if let nsError = error as NSError? {
            return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
        }
        return String(describing: error)
    }
}

/// Bridges Apple's documented MLModel thread-safety to Swift 6 sendability.
/// MLModel is immutable after load and safe to call from multiple threads
/// (Core ML Framework documentation); the feature values built for the job are
/// likewise immutable once handed over. run() extracts the output scalars on
/// the detached task so only [Float] crosses the isolation boundary.
private struct PredictionJob: @unchecked Sendable {
    let model: MLModel
    let input: MLDictionaryFeatureProvider

    func run() throws -> [Float] {
        let output = try model.prediction(from: input)
        guard let value = output.featureValue(for: CoreMLSeparator.outputName),
              let multiArray = value.multiArrayValue else {
            throw StemError.generic("StemV2: output '\(CoreMLSeparator.outputName)' missing or not a multiArray")
        }
        guard multiArray.dataType == .float32 else {
            throw StemError.generic("StemV2: output '\(CoreMLSeparator.outputName)' must be float32, got \(multiArray.dataType)")
        }
        let scalars = MLShapedArray<Float>(multiArray).scalars
        return scalars
    }
}

private struct ModelBox: @unchecked Sendable {
    let model: MLModel
    init(_ model: MLModel) { self.model = model }
}
