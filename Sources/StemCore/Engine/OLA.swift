import Accelerate
import Foundation

// ============================================================================================
// Chunker + STFT/ISTFT overlap-add (plan T3: "Chunker + STFT/ISTFT + overlap-add"; review
// Section 1 engine diagram "Chunker (size+overlap)" and "STFT/ISTFT (vDSP)"; Section 6 test
// coverage: OLA round-trip -60 dB, chunk-boundary null, sub-chunk pad case).
//
// MODEL-CONTRACT CONSTANTS (the choice this file documents):
//
//   windowSize = 6144, hopSize = 1024  (hop = windowSize / 6)
//   chunkSize  = 6144, chunkOverlap = 1024  (chunk advance 5120 = 5 hops)
//
// 6144/1024 is MDX-Net's STFT contract (n_fft 6144, hop_length 1024) — the plan's chosen v1
// model family ("2-stem MDX-class", Section 1; 0I hour 2-3: "STFT window/hop must exactly
// match the model's training contract"). At hop = N/6 the sum of SQUARED periodic-Hann
// windows is exactly constant (COLA for w^2, measured 2.25), so weighted overlap-add —
// divide the window-sum accumulator by the summed squared window — reconstructs unity
// everywhere, including the first and last sample, given centered framing:
//
//   Framing (librosa-style, centered): frame k covers the signal at original coordinates
//   [k*H - N/2, k*H - N/2 + N), with zeros outside [0, L). The signal therefore occupies
//   frame coordinates [N/2, N/2 + L), and frame k = 0 supplies a full-magnitude window
//   (w[N/2] = 1) over the signal's first sample — no N/2-sample unreconstructable taper at
//   either edge, which plain frame-at-0 framing would have (click at sample 0).
//
// Chunking: the separator consumes fixed-size 6144-sample chunks advancing by 5120 (1024
// shared samples = 1 hop of crossfade band at chunk edges — plan "Chunker (size+overlap)",
// click-free chunk blending is the separator's (T4) responsibility). Chunk starts stay
// hop-aligned (multiples of 1024) so chunk and frame grids never fight; the tail chunk is
// zero-padded to the fixed size (Section 2: "audio < 1 chunk: pad + process, documented").
//
// Streaming/memory: `ISTFTAccumulator` ingests one frame at a time and emits every sample
// that no future frame can touch (all samples before the just-ingested frame's start).
// Its accumulators hold at most N + H floats (~28 KB) — bounded, per the memory invariant
// (no whole-file float buffers, peak < 400 MB). Zero-length input yields zero chunks and a
// zero-frame spectrogram (Section 2: Chunker empty path → engine maps to NoAudibleTrackError).
//
// Purity: Accelerate/vDSP only, no AVFoundation, no clock, no randomness — deterministic
// pure functions. Nyquist-bin imaginary part is discarded on inverse (standard irfft
// convention); for a real signal it is float-roundoff small. The Day-1 spike can override
// window/hop via init parameters if the chosen model's contract differs.
// ============================================================================================

/// Model-contract constants (see the file header for rationale).
public enum OLA {
    /// STFT analysis/synthesis window length in samples (MDX-Net n_fft).
    public static let windowSize = 6144
    /// STFT hop in samples (MDX-Net hop_length); windowSize/hop = 6x overlap.
    public static let hopSize = 1024
    /// Separator chunk length in samples (MDX-Net processing window).
    public static let chunkSize = 6144
    /// Samples shared between consecutive chunks (chunk advance = 5120 = 5 hops).
    public static let chunkOverlap = 1024
}

/// Error raised when Accelerate cannot provide the DFT plan (environment failure).
/// The engine's sanctioned sink (`StemError.generic`) maps this at the pipeline boundary.
public enum OLAError: Error, Equatable, Sendable {
    case dftUnavailable
}

// MARK: - Chunker

/// One fixed-size chunk of the source signal.
public struct Chunk: Equatable, Sendable {
    /// Chunk ordinal, 0-based, in emission order.
    public var index: Int
    /// First sample index of the chunk in the source signal.
    public var start: Int
    /// Chunk length in samples — always exactly `chunkSize` (fixed-size contract).
    public var length: Int
    /// Number of zero-pad samples appended at the tail (`start + length` may exceed
    /// `totalSamples` for the final chunk; Section 2 "audio < 1 chunk: pad + process").
    public var padding: Int

    public init(index: Int, start: Int, length: Int, padding: Int) {
        self.index = index
        self.start = start
        self.length = length
        self.padding = padding
    }
}

/// Cuts a signal of `totalSamples` into fixed-size, hop-aligned chunks with a zero-padded
/// tail (plan Section 1 "Chunker (size+overlap)", Section 2 pad rows). Pure descriptor
/// math — copying samples into chunk buffers is the caller's job.
public struct Chunker: Sendable {
    public let totalSamples: Int
    public let chunkSize: Int
    public let overlap: Int
    public let hopSize: Int

    /// Samples advanced per chunk (fixed size minus shared overlap).
    public var advance: Int { chunkSize - overlap }

    /// - Preconditions: `chunkSize > 0`, `0 <= overlap < chunkSize`, and the advance is a
    ///   multiple of `hopSize` so chunk starts stay hop-aligned (defaults: 5120 = 5 x 1024).
    public init(totalSamples: Int,
                chunkSize: Int = OLA.chunkSize,
                overlap: Int = OLA.chunkOverlap,
                hopSize: Int = OLA.hopSize) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        precondition(overlap >= 0 && overlap < chunkSize, "overlap must be in 0..<chunkSize")
        precondition(hopSize > 0, "hopSize must be positive")
        precondition((chunkSize - overlap) % hopSize == 0,
                     "chunk advance \(chunkSize - overlap) must be a multiple of hopSize \(hopSize) (hop-aligned chunks)")
        self.totalSamples = totalSamples
        self.chunkSize = chunkSize
        self.overlap = overlap
        self.hopSize = hopSize
    }

    /// Zero-length audio yields zero chunks (Section 2 Chunker empty path).
    public var chunkCount: Int {
        totalSamples <= 0 ? 0 : (totalSamples + advance - 1) / advance
    }

    public func chunk(at index: Int) -> Chunk {
        precondition(index >= 0 && index < chunkCount, "chunk index \(index) out of 0..<\(chunkCount)")
        let start = index * advance
        let padding = max(0, start + chunkSize - totalSamples)
        return Chunk(index: index, start: start, length: chunkSize, padding: padding)
    }

    public func allChunks() -> [Chunk] {
        (0..<chunkCount).map { chunk(at: $0) }
    }
}

// MARK: - Spectrogram types

/// One frame's non-redundant spectrum: `binCount = windowSize/2 + 1` split real/imag bins.
public struct STFTFrame: Equatable, Sendable {
    public var real: [Float]
    public var imag: [Float]

    public init(real: [Float], imag: [Float]) {
        self.real = real
        self.imag = imag
    }
}

/// Batch of STFT frames, frame-major packed real/imag arrays (`frameCount * binCount`).
public struct Spectrogram: Equatable, Sendable {
    public let frameCount: Int
    public let binCount: Int
    public var real: [Float]
    public var imag: [Float]

    public init(frameCount: Int, binCount: Int, real: [Float], imag: [Float]) {
        self.frameCount = frameCount
        self.binCount = binCount
        self.real = real
        self.imag = imag
    }

    public func frame(at index: Int) -> STFTFrame {
        precondition(index >= 0 && index < frameCount, "frame index \(index) out of 0..<\(frameCount)")
        let lo = index * binCount
        return STFTFrame(real: Array(real[lo ..< lo + binCount]),
                         imag: Array(imag[lo ..< lo + binCount]))
    }
}

// MARK: - STFT

/// `vDSP.DiscreteFourierTransform` is immutable after creation; per-call buffers are locals.
/// Instances are used serially (the pipeline runs the STFT inside the single engine actor),
/// so boxing only confers safe movement across isolation domains, not concurrent mutation.
private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Pure-vDSP STFT with centered (librosa-style) framing, and its inverse via weighted
/// overlap-add. Round trip is unity to float32 transform precision (measured in
/// OLATests at about -100 dB, bar is -60 dB) including the first and last sample.
public struct STFT: Sendable {
    /// Window length N (even — the Hermitian reconstruction requires a Nyquist bin).
    public let windowSize: Int
    /// Hop H.
    public let hopSize: Int
    /// Non-redundant bins per frame: N/2 + 1.
    public let binCount: Int

    private let window: [Float]
    private let windowSquared: [Float]
    private let zeros: [Float]
    private let forward: SendableBox<vDSP.DiscreteFourierTransform<Float>>
    private let inverse: SendableBox<vDSP.DiscreteFourierTransform<Float>>

    /// - Parameters: `windowSize`/`hopSize` default to the MDX-Net model contract
    ///   (`OLA.windowSize`/`OLA.hopSize`); the Day-1 spike can pass other values.
    public init(windowSize: Int = OLA.windowSize, hopSize: Int = OLA.hopSize) throws {
        precondition(windowSize > 0, "windowSize must be positive")
        precondition(hopSize > 0 && hopSize <= windowSize, "hopSize must be in 1...windowSize")
        precondition(windowSize % 2 == 0, "windowSize must be even (Nyquist bin symmetry)")
        self.windowSize = windowSize
        self.hopSize = hopSize
        self.binCount = windowSize / 2 + 1

        var hann = [Float](repeating: 0, count: windowSize)
        // vDSP_HANN_DENORM: textbook periodic Hann, w[0] = 0, w[N/2] = 1. Any positive
        // scaling is canceled exactly by the weighted-OLA normalization.
        vDSP_hann_window(&hann, vDSP_Length(windowSize), Int32(vDSP_HANN_DENORM))
        self.window = hann
        self.windowSquared = hann.map { $0 * $0 }
        self.zeros = [Float](repeating: 0, count: windowSize)

        guard let fwd = try? vDSP.DiscreteFourierTransform(count: windowSize,
                                                           direction: .forward,
                                                           transformType: .complexComplex,
                                                           ofType: Float.self),
              let inv = try? vDSP.DiscreteFourierTransform(count: windowSize,
                                                           direction: .inverse,
                                                           transformType: .complexComplex,
                                                           ofType: Float.self) else {
            throw OLAError.dftUnavailable
        }
        self.forward = SendableBox(fwd)
        self.inverse = SendableBox(inv)
    }

    /// Frames needed to cover a signal of `length` samples: `1 + ceil(L/H)` for L > 0
    /// (centered framing), zero frames for the zero-length signal.
    public func frameCount(forSignalLength length: Int) -> Int {
        length <= 0 ? 0 : 1 + (length + hopSize - 1) / hopSize
    }

    /// Total frame-coordinate samples the accumulator will have emitted after ingesting
    /// `frameCount` frames and finishing: `(frameCount - 1) * H + N`. The signal occupies
    /// `[N/2, N/2 + L)` of that range.
    public func coveredLength(forFrameCount frameCount: Int) -> Int {
        frameCount <= 0 ? 0 : (frameCount - 1) * hopSize + windowSize
    }

    /// Forward STFT: windowed centered frames -> packed real/imag half-spectra.
    /// Zero-length input produces a zero-frame spectrogram.
    public func forward(_ signal: [Float]) -> Spectrogram {
        let length = signal.count
        let frames = frameCount(forSignalLength: length)
        guard frames > 0 else {
            return Spectrogram(frameCount: 0, binCount: binCount, real: [], imag: [])
        }

        var real = [Float](repeating: 0, count: frames * binCount)
        var imag = [Float](repeating: 0, count: frames * binCount)
        var frame = [Float](repeating: 0, count: windowSize)
        var windowed = [Float](repeating: 0, count: windowSize)
        var spectrumReal = [Float](repeating: 0, count: windowSize)
        var spectrumImag = [Float](repeating: 0, count: windowSize)

        for k in 0..<frames {
            // Frame k covers original coordinates [k*H - N/2, k*H + N/2); zeros outside.
            let origin = k * hopSize - windowSize / 2
            let sourceLo = max(0, origin)
            let sourceHi = min(length, origin + windowSize)

            vDSP_vclr(&frame, 1, vDSP_Length(windowSize))
            if sourceHi > sourceLo {
                _ = frame.withUnsafeMutableBufferPointer { fp in
                    signal.withUnsafeBufferPointer { sp in
                        memcpy(fp.baseAddress! + (sourceLo - origin),
                               sp.baseAddress! + sourceLo,
                               (sourceHi - sourceLo) * MemoryLayout<Float>.stride)
                    }
                }
            }

            vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(windowSize))
            forward.value.transform(inputReal: windowed,
                                    inputImaginary: zeros,
                                    outputReal: &spectrumReal,
                                    outputImaginary: &spectrumImag)

            let binOrigin = k * binCount
            _ = real.withUnsafeMutableBufferPointer { rp in
                spectrumReal.withUnsafeBufferPointer { sp in
                    memcpy(rp.baseAddress! + binOrigin, sp.baseAddress!,
                           binCount * MemoryLayout<Float>.stride)
                }
            }
            _ = imag.withUnsafeMutableBufferPointer { ip in
                spectrumImag.withUnsafeBufferPointer { sp in
                    memcpy(ip.baseAddress! + binOrigin, sp.baseAddress!,
                           binCount * MemoryLayout<Float>.stride)
                }
            }
        }
        return Spectrogram(frameCount: frames, binCount: binCount, real: real, imag: imag)
    }

    /// Inverse STFT (batch convenience): weighted overlap-add all frames, then slice the
    /// signal out of frame coordinates (`[N/2, N/2 + outputLength)`).
    ///
    /// `outputLength` must be the length of the signal `spectrogram` was computed from
    /// (precondition-checked against covered length).
    public func inverse(_ spectrogram: Spectrogram, outputLength: Int) -> [Float] {
        let covered = coveredLength(forFrameCount: spectrogram.frameCount)
        precondition(outputLength >= 0,
                     "outputLength must be non-negative")
        guard spectrogram.frameCount > 0 else {
            precondition(outputLength == 0, "zero-frame spectrogram reconstructs only the zero-length signal")
            return []
        }
        precondition(windowSize / 2 + outputLength <= covered,
                     "outputLength \(outputLength) exceeds covered length \(max(0, covered - windowSize / 2)) for \(spectrogram.frameCount) frames")

        let accumulator = ISTFTAccumulator(stft: self)
        var output: [Float] = []
        output.reserveCapacity(covered)
        for k in 0..<spectrogram.frameCount {
            output.append(contentsOf: accumulator.ingest(spectrogram.frame(at: k)))
        }
        output.append(contentsOf: accumulator.finish())

        let lo = windowSize / 2
        return Array(output[lo ..< lo + outputLength])
    }

    /// One inverse transform: Hermitian half-spectrum -> time-domain frame (real part,
    /// 1/N scaled — vDSP's inverse DFT is unscaled), window applied by the caller.
    func inverseTransform(_ frame: STFTFrame, into output: inout [Float]) {
        precondition(frame.real.count == binCount && frame.imag.count == binCount,
                     "frame must carry binCount = \(binCount) real/imag bins")
        var fullReal = [Float](repeating: 0, count: windowSize)
        var fullImag = [Float](repeating: 0, count: windowSize)
        var timeReal = [Float](repeating: 0, count: windowSize)
        var timeImag = [Float](repeating: 0, count: windowSize)

        fullReal[0] = frame.real[0]
        fullReal[binCount - 1] = frame.real[binCount - 1] // Nyquist; imag dropped (irfft convention)
        for k in 1..<(binCount - 1) {
            fullReal[k] = frame.real[k]
            fullImag[k] = frame.imag[k]
            fullReal[windowSize - k] = frame.real[k]
            fullImag[windowSize - k] = -frame.imag[k]
        }

        inverse.value.transform(inputReal: fullReal,
                                inputImaginary: fullImag,
                                outputReal: &timeReal,
                                outputImaginary: &timeImag)

        var scale = 1.0 / Float(windowSize)
        vDSP_vsmul(timeReal, 1, &scale, &output, 1, vDSP_Length(windowSize))
    }

    var synthesisWindow: [Float] { window }
    var synthesisWindowSquared: [Float] { windowSquared }
}

// MARK: - Streaming ISTFT (overlap-add accumulator)

/// Streaming weighted overlap-add accumulator (plan Section 1 "ISTFT+OLA", memory
/// invariant: bounded buffers, samples emitted as soon as they are final).
///
/// Coordinate convention: frame k covers frame coordinates `[k*H, k*H + N)`. After
/// ingesting frame k, every sample before `k*H` is final — no later frame can touch it —
/// and is emitted (empty array for frame 0). `finish()` emits the final window's worth.
/// The signal occupies frame coordinates `[N/2, N/2 + L)`; callers slice that range out
/// of the concatenation of emissions (`STFT.inverse` does exactly this).
///
/// Normalization: per sample, output = (sum of windowed frame contributions) /
/// (sum of squared windows). For Hann at H = N/6 the denominator is the constant 2.25 in
/// the interior (COLA for w^2, probe-verified); near the signal edges the centered framing
/// keeps it >= 1 at every *signal* sample (frame 0 peaks at exactly the first sample).
/// Denominator below 1e-6 (padding corners only, always sliced away) emits 0 instead of
/// dividing toward NaN.
///
/// Not Sendable: confined to one task (the engine actor). Frames must arrive in order,
/// one per hop, starting at frame 0.
public final class ISTFTAccumulator {
    public let windowSize: Int
    public let hopSize: Int
    public let binCount: Int

    private let windowSquared: [Float]
    private let stft: STFT
    private var windowedSum: [Float] = []   // overlap-add accumulator, frame coordinates
    private var windowSquaredSum: [Float] = [] // summed squared windows, same coordinates
    private var nextFrameOffset = 0         // frame coordinate of the next expected frame
    private var finished = false

    public init(stft: STFT) {
        self.stft = stft
        self.windowSize = stft.windowSize
        self.hopSize = stft.hopSize
        self.binCount = stft.binCount
        self.windowSquared = stft.synthesisWindowSquared
    }

    public convenience init(windowSize: Int = OLA.windowSize,
                            hopSize: Int = OLA.hopSize) throws {
        self.init(stft: try STFT(windowSize: windowSize, hopSize: hopSize))
    }

    /// Ingest the next frame (bins in `STFTFrame`); returns samples that became final.
    public func ingest(_ frame: STFTFrame) -> [Float] {
        precondition(!finished, "accumulator already finished")
        let offset = nextFrameOffset

        var timeDomain = [Float](repeating: 0, count: windowSize)
        stft.inverseTransform(frame, into: &timeDomain)
        vDSP_vmul(timeDomain, 1, stft.synthesisWindow, 1, &timeDomain, 1, vDSP_Length(windowSize))

        let writeOffset = offset - drainBase
        let needed = writeOffset + windowSize
        if windowedSum.count < needed {
            let extra = needed - windowedSum.count
            windowedSum.append(contentsOf: [Float](repeating: 0, count: extra))
            windowSquaredSum.append(contentsOf: [Float](repeating: 0, count: extra))
        }

        addIntoAccumulators(timeDomain, at: writeOffset)

        nextFrameOffset += hopSize
        return drain(writeOffset) // everything before this frame's start is now final
    }

    /// Emit the final window's worth of samples. Must be called exactly once, after the
    /// last frame.
    public func finish() -> [Float] {
        precondition(!finished, "accumulator already finished")
        finished = true
        return drain(windowedSum.count)
    }

    // Frame coordinate of windowedSum[0].
    private var drainBase = 0

    /// Emit the first `count` accumulated samples, normalized by the summed squared
    /// window; drop consumed prefixes so live buffers stay bounded (<= N + H samples).
    private func drain(_ count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        windowedSum.withUnsafeMutableBufferPointer { acc in
            windowSquaredSum.withUnsafeBufferPointer { nrm in
                out.withUnsafeMutableBufferPointer { op in
                    // vDSP_vdiv(A, B, C): C = B / A
                    vDSP_vdiv(nrm.baseAddress!, 1, acc.baseAddress!, 1,
                              op.baseAddress!, 1, vDSP_Length(count))
                }
            }
        }
        for i in 0..<count where windowSquaredSum[i] < 1e-6 {
            out[i] = 0
        }
        windowedSum.removeFirst(count)
        windowSquaredSum.removeFirst(count)
        drainBase += count
        return out
    }

    private func addIntoAccumulators(_ contribution: [Float], at offset: Int) {
        windowedSum.withUnsafeMutableBufferPointer { acc in
            contribution.withUnsafeBufferPointer { c in
                // In-place add: destination coincides exactly with the first source.
                vDSP_vadd(acc.baseAddress! + offset, 1, c.baseAddress!, 1,
                          acc.baseAddress! + offset, 1, vDSP_Length(windowSize))
            }
        }
        windowSquaredSum.withUnsafeMutableBufferPointer { acc in
            windowSquared.withUnsafeBufferPointer { c in
                vDSP_vadd(acc.baseAddress! + offset, 1, c.baseAddress!, 1,
                          acc.baseAddress! + offset, 1, vDSP_Length(windowSize))
            }
        }
    }
}
