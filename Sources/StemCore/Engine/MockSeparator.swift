import Foundation
import CoreML

/// Deterministic reference `StemModel` (plan T4 "CPU-fallback mock test",
/// Section 6 "MDXSeparator → CPU fallback (mock)").
///
/// Actually separates: center-panned (mid) content is kept, hard-panned (side)
/// content is attenuated, via a simple 3-bin spectral median across frequency
/// within each frame. It is a pure function of the frames it is given — no
/// randomness, no time dependence, no shared mutable state — so downstream
/// sum-to-source and separation-direction tests are meaningful and stable.
///
/// Algorithm per frame, per frequency bin (magnitudes only):
///     mid  = (L + R) / 2
///     side = |L − R|
///     m    = median3(mid across bins)      // smooths narrowband impulses
///     s    = median3(side across bins)
///     mask = m / (m + s + ε)               // ε = 1e-8, clamped to [0,1]
/// Equal mid/side share resolves to 0.5; center-only content → ~1; side-only
/// content → ~0. The same per-bin mask is applied to both channels: pan
/// position is a per-bin property, so dual-pass channel processing shares it
/// (plan channel policy: "mono-input models process channels independently
/// and recombine" — here the shared mask IS the recombination).
///
/// Trade-off (deliberate, mock-only): a median across frequency suppresses
/// peaks narrower than ~3 bins; the real model carries the trained spectral
/// priors instead. Geometry-agnostic: accepts any frame/bin counts.
public actor MockSeparator: StemModel {

    public static let modelID = "mock-midside-spectralmedian-v1"

    private static let epsilon: Float = 1e-8

    /// The preference is accepted per contract and recorded for assertions/
    /// logging; the mock computes on CPU regardless (S2: ANE fallback is
    /// "transparent (slower, no error)").
    public let computeUnitsPreference: MLComputeUnits

    public init(computeUnits: MLComputeUnits = .all) {
        self.computeUnitsPreference = computeUnits
    }

    public func separate(_ chunk: StereoMagnitudeChunk) async throws -> StereoVocalMask {
        do {
            try Task.checkCancellation()
        } catch {
            throw StemError.cancelled
        }

        let bins = chunk.binCount
        var mask = [Float](repeating: 0, count: chunk.frameCount * bins)
        var mid = [Float](repeating: 0, count: bins)
        var side = [Float](repeating: 0, count: bins)

        for frame in 0..<chunk.frameCount {
            let base = frame * bins
            for bin in 0..<bins {
                let l = chunk.left[base + bin]
                let r = chunk.right[base + bin]
                mid[bin] = (l + r) * 0.5
                side[bin] = abs(l - r)
            }
            let m = Self.median3(mid)
            let s = Self.median3(side)
            for bin in 0..<bins {
                let value = m[bin] / (m[bin] + s[bin] + Self.epsilon)
                mask[base + bin] = min(max(value, 0), 1)
            }
        }

        // Shared per-bin mask for both channels (see header rationale).
        return StereoVocalMask(frameCount: chunk.frameCount,
                               binCount: chunk.binCount,
                               left: mask,
                               right: mask)
    }

    /// 3-tap median across a 1-D array with edge clamping. Deterministic.
    static func median3(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        if x.count == 1 { return x }
        var out = [Float](repeating: 0, count: x.count)
        var a: Float
        var b: Float
        var c: Float
        var t: Float
        for i in x.indices {
            a = x[i > 0 ? i - 1 : 0]
            b = x[i]
            c = x[i < x.count - 1 ? i + 1 : x.count - 1]
            if a > b { t = a; a = b; b = t }
            if b > c { t = b; b = c; c = t }
            if a > b { t = a; a = b; b = t }
            out[i] = b
        }
        return out
    }
}
