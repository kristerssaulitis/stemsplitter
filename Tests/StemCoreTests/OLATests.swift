import XCTest
import Accelerate
@testable import StemCore

/// OLA/STFT verification per the approved test plan (plan Section 6 "Chunker/STFT/OLA ->
/// unit: OLA round-trip (STFT->ISTFT identity within -60 dB), chunk-boundary null test
/// (no clicks), sub-chunk pad case"; eng-review CRITICAL paths "OLA round-trip +
/// chunk-boundary null" and "Chunker yields fixed-size hop-aligned chunks with correct
/// pad on the tail").
///
/// All signals are deterministic (xorshift64* + fixed-tone mixture) — no randomness or
/// clock dependence (test-plan flakiness rule).
final class OLATests: XCTestCase {

    // MARK: - Deterministic fixtures

    /// xorshift64* generator state stepping.
    private func nextRandom(_ state: inout UInt64) -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let m = state &* 2_685_821_657_736_338_717
        return Double(m >> 11) / Double(UInt64(1) << 53)
    }

    /// Mixture that stresses every failure mode the OLA contract protects against:
    /// two tones (spectral content), DC offset, broadband noise, and unit impulses at
    /// both edges and at every chunk boundary (a broken overlap-add turns these into
    /// loud clicks). Amplitudes keep the peak well under full scale.
    private func makeTestSignal(_ count: Int) -> [Float] {
        var signal = [Float](repeating: 0, count: count)
        var state: UInt64 = 0x853C_49E6_748F_EA9B
        for i in 0..<count {
            let t = Float(i) / 44_100.0
            let noise = Float(nextRandom(&state)) * 2.0 - 1.0
            signal[i] = 0.40 * sin(2.0 * .pi * 440.0 * t)
                + 0.25 * sin(2.0 * .pi * 3_100.0 * t + 1.1)
                + 0.15 * noise
                + 0.10
        }
        signal[0] += 0.9
        if count > 0 { signal[count - 1] += 0.9 }
        let chunker = Chunker(totalSamples: count)
        for chunk in chunker.allChunks() where chunk.index > 0 {
            signal[chunk.start] += 0.9
        }
        return signal
    }

    /// Relative error 10*log10(||a-b||^2 / ||a||^2) in dB.
    private func relativeErrorDB(_ reference: [Float], _ candidate: [Float]) -> Float {
        precondition(reference.count == candidate.count)
        var diff = reference
        // vDSP_vsub(B, A, C): C = A - B (B/A swapped per the header note).
        vDSP_vsub(candidate, 1, reference, 1, &diff, 1, vDSP_Length(diff.count))
        var errorEnergy: Float = 0
        var signalEnergy: Float = 0
        vDSP_svesq(diff, 1, &errorEnergy, vDSP_Length(diff.count))
        vDSP_svesq(reference, 1, &signalEnergy, vDSP_Length(reference.count))
        if signalEnergy == 0 { return errorEnergy == 0 ? -200 : 0 }
        return 10 * log10(errorEnergy / signalEnergy)
    }

    private func roundTrip(_ signal: [Float], stft: STFT) -> [Float] {
        let spectrogram = stft.forward(signal)
        return stft.inverse(spectrogram, outputLength: signal.count)
    }

    // MARK: - CRITICAL: STFT/ISTFT round-trip identity on a 10 s signal (-60 dB bar)

    func testRoundTripIdentityTenSeconds() throws {
        let sampleRate = 44_100
        let count = sampleRate * 10 // the ask's scale: a 10 s signal
        let signal = makeTestSignal(count)
        let stft = try STFT()

        let spectrogram = stft.forward(signal)
        XCTAssertEqual(spectrogram.frameCount, stft.frameCount(forSignalLength: count))
        XCTAssertEqual(spectrogram.binCount, OLA.windowSize / 2 + 1)
        XCTAssertEqual(spectrogram.real.count, spectrogram.frameCount * spectrogram.binCount)

        let reconstructed = stft.inverse(spectrogram, outputLength: count)
        XCTAssertEqual(reconstructed.count, count)

        let errorDB = relativeErrorDB(signal, reconstructed)
        let maxAbsError = zip(signal, reconstructed).map { abs($0 - $1) }.max() ?? 0
        print("OLA round-trip 10s: relative error \(errorDB) dB, max abs error \(maxAbsError)")
        XCTAssertLessThanOrEqual(errorDB, -60.0, "CRITICAL bar: round-trip identity within -60 dB")
        XCTAssertTrue(reconstructed.allSatisfy { $0.isFinite }, "no NaN/Inf may leak out of the accumulator")
    }

    // MARK: - CRITICAL: boundary null test (first/last samples, no clicks at seams)

    func testBoundaryNullFirstLastSamplesAndSeams() throws {
        let count = 44_100 * 10
        let signal = makeTestSignal(count)
        let stft = try STFT()
        let reconstructed = roundTrip(signal, stft: stft)

        // First and last samples reconstruct: centered framing gives sample 0 a
        // full-magnitude window (w[N/2] = 1), so no edge taper -> no click.
        XCTAssertEqual(reconstructed.first!, signal.first!, accuracy: 1e-5, "first sample must reconstruct (no attack click)")
        XCTAssertEqual(reconstructed.last!, signal.last!, accuracy: 1e-5, "last sample must reconstruct (no release click)")

        // Null test at every seam: max abs error inside +/- one hop of each STFT frame
        // seam (1024 grid) AND each chunker boundary (5120 grid) stays under the -60 dB
        // equivalent of a unit-scale signal (1e-3). A click would spike one window.
        let seamGrids = [OLA.hopSize, OLA.chunkSize]
        for grid in seamGrids {
            var seam = grid
            while seam < count {
                let lo = max(0, seam - OLA.hopSize)
                let hi = min(count, seam + OLA.hopSize + 1)
                for i in lo..<hi {
                    let error = abs(signal[i] - reconstructed[i])
                    XCTAssertLessThanOrEqual(error, 1e-3,
                        "click at sample \(i) near seam \(seam) (grid \(grid)): error \(error)")
                }
                seam += grid
            }
        }
    }

    // MARK: - Sub-chunk final pad case

    func testSubChunkFinalPadCase() throws {
        // Shorter than one chunk AND one window: 1 chunk, fully zero-padded tail.
        let count = 1000
        let chunker = Chunker(totalSamples: count)
        XCTAssertEqual(chunker.chunkCount, 1)
        let only = chunker.chunk(at: 0)
        XCTAssertEqual(only.start, 0)
        XCTAssertEqual(only.length, OLA.chunkSize, "chunk is fixed-size even when the signal is shorter")
        XCTAssertEqual(only.padding, OLA.chunkSize - count, "tail is padded up to the fixed size")

        let signal = makeTestSignal(count)
        let stft = try STFT()
        XCTAssertEqual(stft.frameCount(forSignalLength: count), 1 + (count + OLA.hopSize - 1) / OLA.hopSize)

        let reconstructed = roundTrip(signal, stft: stft)
        XCTAssertEqual(reconstructed.count, count)
        XCTAssertLessThanOrEqual(relativeErrorDB(signal, reconstructed), -60.0)
        XCTAssertEqual(reconstructed.first!, signal.first!, accuracy: 1e-5)
        XCTAssertEqual(reconstructed.last!, signal.last!, accuracy: 1e-5)

        // Degenerate micro-signal still round-trips (edge coverage of centered framing).
        let tiny = makeTestSignal(3)
        let tinyBack = roundTrip(tiny, stft: stft)
        for (a, b) in zip(tiny, tinyBack) {
            XCTAssertEqual(a, b, accuracy: 1e-4)
        }

        // Zero-length path: zero chunks, zero-frame spectrogram (Section 2 empty path).
        XCTAssertEqual(Chunker(totalSamples: 0).chunkCount, 0)
        let empty = stft.forward([])
        XCTAssertEqual(empty.frameCount, 0)
        XCTAssertEqual(stft.inverse(empty, outputLength: 0), [])
    }

    // MARK: - CRITICAL: chunker yields fixed-size hop-aligned chunks, tail pad

    func testChunkerYieldsFixedSizeHopAlignedChunksWithTailPad() {
        // 20000 samples, defaults: advance 5120, chunkSize 6144, overlap 1024.
        let chunker = Chunker(totalSamples: 20_000)
        XCTAssertEqual(chunker.advance, 5120)
        XCTAssertEqual(chunker.chunkCount, 4)
        let chunks = chunker.allChunks()
        XCTAssertEqual(chunks.map(\.start), [0, 5120, 10_240, 15_360], "starts advance by the fixed hop-aligned step")
        XCTAssertTrue(chunks.allSatisfy { $0.start % OLA.hopSize == 0 }, "every chunk start is hop-aligned")
        XCTAssertTrue(chunks.allSatisfy { $0.length == 6144 }, "every chunk is fixed-size")
        XCTAssertEqual(chunks.map(\.padding), [0, 0, 0, 1504], "only the final chunk carries tail pad (15360+6144-20000)")
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.start + a.length - b.start, OLA.chunkOverlap, "consecutive chunks share exactly the 1024-sample overlap")
        }

        // Signal exactly one chunk long still needs a padded tail chunk: chunk 2 starts
        // at 5120, so pad = 5120 + 6144 - 6144 = 5120 (= advance).
        let oneChunk = Chunker(totalSamples: OLA.chunkSize)
        XCTAssertEqual(oneChunk.chunkCount, 2)
        XCTAssertEqual(oneChunk.chunk(at: 1).padding, oneChunk.advance)

        // Sub-chunk signal: single chunk, everything past the signal is pad.
        let sub = Chunker(totalSamples: 100)
        XCTAssertEqual(sub.chunkCount, 1)
        XCTAssertEqual(sub.chunk(at: 0).padding, OLA.chunkSize - 100)
    }

    // MARK: - Streaming accumulator: bounded emissions, identical to batch

    func testStreamingAccumulatorEmitsCompletedSamplesMatchingBatch() throws {
        let count = 44_100 // 1 s
        let signal = makeTestSignal(count)
        let stft = try STFT()
        let spectrogram = stft.forward(signal)

        // Stream frame by frame.
        let accumulator = ISTFTAccumulator(stft: stft)
        var streamed: [Float] = []
        var emissions: [Int] = []
        for k in 0..<spectrogram.frameCount {
            let chunk = accumulator.ingest(spectrogram.frame(at: k))
            emissions.append(chunk.count)
            streamed.append(contentsOf: chunk)
        }
        streamed.append(contentsOf: accumulator.finish())

        // Frame 0 emits nothing (nothing is final yet); every later frame releases
        // exactly one hop; finish releases the final window.
        XCTAssertEqual(emissions.first, 0)
        XCTAssertEqual(emissions, [0] + Array(repeating: OLA.hopSize, count: spectrogram.frameCount - 1))
        XCTAssertEqual(streamed.count, stft.coveredLength(forFrameCount: spectrogram.frameCount))

        // Identical to the batch inverse (same weighted-OLA path), after the standard
        // frame-coordinate slice.
        let batch = stft.inverse(spectrogram, outputLength: count)
        let lo = OLA.windowSize / 2
        XCTAssertEqual(Array(streamed[lo ..< lo + count]), batch)
        XCTAssertLessThanOrEqual(relativeErrorDB(signal, batch), -60.0)
    }
}
