import Accelerate
import CoreML
import Foundation

/// Fixed-length segment in, N stereo waveforms out. Exists so `SplitPipeline` can be tested
/// without a 100 MB model (see `PassthroughSeparator` in tests).
public protocol MultiStemSeparator: AnyObject {
    /// Source names in output order, e.g. ["drums", "bass", "other", "vocals"].
    var sources: [String] { get }
    /// Samples per channel the model consumes per call.
    var segmentLength: Int { get }
    /// `segment`: planar stereo `[L..., R...]`, `2 * segmentLength` floats.
    /// Returns planar `[source][channel][sample]`, `sources.count * 2 * segmentLength` floats.
    func separate(_ segment: [Float]) throws -> [Float]
}

public enum SeparatorError: Error, LocalizedError {
    case modelMissing(String)
    case badModel(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let p): "Separation model not found at \(p). Run tools/convert_htdemucs.py."
        case .badModel(let m): "Separation model is not usable: \(m)"
        }
    }
}

/// htdemucs core converted by tools/convert_htdemucs.py. STFT/iSTFT happen here.
// ponytail: @unchecked — immutable after init; one split at a time calls `separate` serially.
public final class HTDemucsSeparator: MultiStemSeparator, @unchecked Sendable {
    public let sources: [String]
    public let segmentLength: Int
    private let model: MLModel
    private let stft = DemucsSTFT()
    private let frames: Int

    /// `url`: compiled `.mlmodelc`. GPU is the fast path on Mac: the ANE compiler rejects this graph.
    public init(modelURL url: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SeparatorError.modelMissing(url.path) }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: config)
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard let names = meta["sources"], let seg = meta["segment_samples"].flatMap(Int.init) else {
            throw SeparatorError.badModel("missing sources/segment_samples metadata")
        }
        sources = names.split(separator: ",").map(String.init)
        segmentLength = seg
        frames = DemucsSTFT.frameCount(seg)
    }

    public func separate(_ segment: [Float]) throws -> [Float] {
        let L = segmentLength, T = frames, B = DemucsSTFT.bins, S = sources.count
        precondition(segment.count == 2 * L)

        let mix = try MLMultiArray(shape: [1, 2, NSNumber(value: L)], dataType: .float32)
        let spec = try MLMultiArray(shape: [1, 4, NSNumber(value: B), NSNumber(value: T)], dataType: .float32)
        try write(segment, to: mix)
        let plane = B * T
        var cac = [Float](repeating: 0, count: 4 * plane)
        segment.withUnsafeBufferPointer { seg in
            cac.withUnsafeMutableBufferPointer { c in
                for ch in 0..<2 {
                    let x = UnsafeBufferPointer(rebasing: seg[(ch * L)..<((ch + 1) * L)])
                    stft.forward(x, re: c.baseAddress! + (2 * ch) * plane, im: c.baseAddress! + (2 * ch + 1) * plane)
                }
            }
        }
        try write(cac, to: spec)

        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mix": mix, "spec": spec]))
        guard let freq = out.featureValue(for: "freq")?.multiArrayValue,
              let time = out.featureValue(for: "time")?.multiArrayValue else {
            throw SeparatorError.badModel("missing freq/time outputs")
        }
        // time: (1, S*2, L) → result directly; freq: (1, S*4, B, T) → iSTFT added on top.
        var result = try read(time, count: S * 2 * L)
        let freqFlat = try read(freq, count: S * 4 * plane)
        freqFlat.withUnsafeBufferPointer { f in
            result.withUnsafeMutableBufferPointer { r in
                for s in 0..<S {
                    for ch in 0..<2 {
                        let base = f.baseAddress! + (s * 4 + ch * 2) * plane
                        stft.inverseAdd(re: base, im: base + plane, frames: T,
                                        into: r.baseAddress! + (s * 2 + ch) * L, length: L)
                    }
                }
            }
        }
        return result
    }

    /// Copy a dense row-major float array into an MLMultiArray honoring its strides.
    private func write(_ src: [Float], to dst: MLMultiArray) throws {
        let shape = dst.shape.map(\.intValue), strides = dst.strides.map(\.intValue)
        let inner = shape.last!, rows = src.count / inner
        dst.withUnsafeMutableBufferPointer(ofType: Float.self) { d, _ in
            src.withUnsafeBufferPointer { s in
                for r in 0..<rows {
                    var off = 0, rem = r
                    for dim in stride(from: shape.count - 2, through: 0, by: -1) {
                        off += (rem % shape[dim]) * strides[dim]
                        rem /= shape[dim]
                    }
                    (d.baseAddress! + off).update(from: s.baseAddress! + r * inner, count: inner)
                }
            }
        }
    }

    /// Read an MLMultiArray (fp32 or fp16, possibly padded strides) into a dense row-major array.
    private func read(_ a: MLMultiArray, count: Int) throws -> [Float] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        let inner = shape.last!, rows = count / inner
        guard shape.reduce(1, *) == count else { throw SeparatorError.badModel("unexpected output shape \(shape)") }
        var out = [Float](repeating: 0, count: count)
        func offset(_ r: Int) -> Int {
            var off = 0, rem = r
            for dim in stride(from: shape.count - 2, through: 0, by: -1) {
                off += (rem % shape[dim]) * strides[dim]
                rem /= shape[dim]
            }
            return off
        }
        out.withUnsafeMutableBufferPointer { o in
            switch a.dataType {
            case .float32:
                a.withUnsafeBufferPointer(ofType: Float.self) { p in
                    for r in 0..<rows { (o.baseAddress! + r * inner).update(from: p.baseAddress! + offset(r), count: inner) }
                }
            case .float16:
                a.withUnsafeBufferPointer(ofType: Float16.self) { p in
                    for r in 0..<rows {
                        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: p.baseAddress! + offset(r)),
                                                height: 1, width: vImagePixelCount(inner), rowBytes: inner * 2)
                        var dst = vImage_Buffer(data: o.baseAddress! + r * inner, height: 1,
                                                width: vImagePixelCount(inner), rowBytes: inner * 4)
                        vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
                    }
                }
            default:
                break
            }
        }
        return out
    }
}
