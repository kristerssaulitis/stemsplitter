import Accelerate

/// Bit-for-bit port of HTDemucs `_spec` / `_ispec` (nfft 4096, hop 1024, periodic Hann,
/// `normalized=True`, Nyquist bin dropped). Core ML has no complex tensors, so this runs in Swift.
///
/// Demucs pads the signal by 1536 (reflect) on the left and `1536 + T*1024 - L` on the right,
/// runs a centered torch.stft, then keeps frames `2..<2+T`. Those two paddings cancel out:
/// frame `f` covers padded samples `f*1024 ..< f*1024+4096`, i.e. signal samples starting at
/// `f*1024 - 1536`. That is all this type needs to know.
public final class DemucsSTFT {
    public static let nfft = 4096
    public static let hop = 1024
    public static let bins = 2048
    static let leftPad = hop / 2 * 3

    private let window: [Float]
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    // Scratch, reused across frames.
    private var evens = [Float](repeating: 0, count: nfft / 2)
    private var odds = [Float](repeating: 0, count: nfft / 2)
    private var outR = [Float](repeating: 0, count: nfft / 2)
    private var outI = [Float](repeating: 0, count: nfft / 2)
    private var frame = [Float](repeating: 0, count: nfft)
    // Frame-major [frame][bin] staging; the model wants [bin][frame]. One vDSP_mtrans beats strided access.
    private var stageR: [Float] = []
    private var stageI: [Float] = []

    public init() {
        let n = Self.nfft
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }  // periodic
        forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(n), .INVERSE)!
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    public static func frameCount(_ length: Int) -> Int { (length + hop - 1) / hop }

    /// Reflect-padded read (torch "reflect": edge sample not repeated).
    @inline(__always)
    static func reflect(_ i: Int, _ length: Int) -> Int {
        var i = i
        if i < 0 { i = -i }
        if i >= length { i = 2 * (length - 1) - i }
        return i
    }

    /// One channel → CaC planes. `re`/`im` are `[bin][frame]`, `bins * frames` each.
    public func forward(_ x: UnsafeBufferPointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let n = Self.nfft, half = n / 2, frames = Self.frameCount(x.count)
        // vDSP forward = 2·DFT; torch normalized = DFT/sqrt(n).
        var scale = 0.5 / sqrt(Float(n))
        let B = Self.bins
        if stageR.count < frames * B {
            stageR = [Float](repeating: 0, count: frames * B)
            stageI = stageR
        }
        for f in 0..<frames {
            let start = f * Self.hop - Self.leftPad
            if start >= 0 && start + n <= x.count {
                vDSP_vmul(x.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            } else {
                for k in 0..<n { frame[k] = x[Self.reflect(start + k, x.count)] * window[k] }
            }
            frame.withUnsafeBufferPointer { fr in
                var z: Float = 0
                vDSP_vsadd(fr.baseAddress!, 2, &z, &evens, 1, vDSP_Length(half))
                vDSP_vsadd(fr.baseAddress! + 1, 2, &z, &odds, 1, vDSP_Length(half))
            }
            vDSP_DFT_Execute(forward, evens, odds, &outR, &outI)
            // Bin 0: real DC in outR[0]; outI[0] holds Nyquist, which demucs drops.
            outI[0] = 0
            stageR.withUnsafeMutableBufferPointer { vDSP_vsmul(outR, 1, &scale, $0.baseAddress! + f * B, 1, vDSP_Length(B)) }
            stageI.withUnsafeMutableBufferPointer { vDSP_vsmul(outI, 1, &scale, $0.baseAddress! + f * B, 1, vDSP_Length(B)) }
        }
        vDSP_mtrans(stageR, 1, re, 1, vDSP_Length(B), vDSP_Length(frames))
        vDSP_mtrans(stageI, 1, im, 1, vDSP_Length(B), vDSP_Length(frames))
    }

    /// CaC planes → one channel of `length` samples, added into `out`.
    public func inverseAdd(re: UnsafePointer<Float>, im: UnsafePointer<Float>, frames: Int,
                           into out: UnsafeMutablePointer<Float>, length: Int) {
        let n = Self.nfft, half = n / 2
        // vDSP inverse = n·irfft; torch normalized istft = irfft·sqrt(n); Hann² OLA at hop n/4 sums to 1.5.
        let scale = 1 / (sqrt(Float(n)) * 1.5)
        let B = Self.bins
        if stageR.count < frames * B {
            stageR = [Float](repeating: 0, count: frames * B)
            stageI = stageR
        }
        vDSP_mtrans(re, 1, &stageR, 1, vDSP_Length(frames), vDSP_Length(B))
        vDSP_mtrans(im, 1, &stageI, 1, vDSP_Length(frames), vDSP_Length(B))
        for f in 0..<frames {
            stageR.withUnsafeBufferPointer { s in outR.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: s.baseAddress! + f * B, count: half) } }
            stageI.withUnsafeBufferPointer { s in outI.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: s.baseAddress! + f * B, count: half) } }
            outI[0] = 0  // Nyquist (dropped by the model, padded back as zero)
            vDSP_DFT_Execute(inverse, outR, outI, &evens, &odds)
            frame.withUnsafeMutableBufferPointer { fr in
                var z: Float = 0
                vDSP_vsadd(evens, 1, &z, fr.baseAddress!, 2, vDSP_Length(half))
                vDSP_vsadd(odds, 1, &z, fr.baseAddress! + 1, 2, vDSP_Length(half))
            }
            var s = scale
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))
            vDSP_vsmul(frame, 1, &s, &frame, 1, vDSP_Length(n))
            let start = f * Self.hop - Self.leftPad
            let lo = max(0, -start), hi = min(n, length - start)
            if hi > lo {
                vDSP_vadd(out + start + lo, 1, frame.withUnsafeBufferPointer { $0.baseAddress! + lo }, 1,
                          out + start + lo, 1, vDSP_Length(hi - lo))
            }
        }
    }
}
