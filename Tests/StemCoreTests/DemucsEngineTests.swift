import AVFoundation
import AudioToolbox
import XCTest

@testable import StemCore

/// Runs the real htdemucs model (Models/htdemucs.mlmodelc, copied from
/// ../stemsplitter-mac/Models). Skips when the model is absent.
final class DemucsEngineTests: XCTestCase {

    static let modelURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Models/htdemucs.mlmodelc")

    func testSplitWritesFiveStemsAndInstrumentalIsComplement() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.modelURL.path), "no htdemucs model")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 12 s: more than one 7.8 s segment, so overlap-add and the tail both run.
        let source = tmp.appendingPathComponent("tone.m4a")
        try AudioFixtureMaker.makeAAC(
            url: source, sampleRate: 44_100, channels: 2, seconds: 12,
            subtype: kAudioFormatMPEG4AAC, signal: .tone(freq: 220, amp: 0.4))

        let calibrator = ETACalibrator(persistence: FileKeyValuePersistence(
            fileURL: tmp.appendingPathComponent("eta.json")))
        let engine = DemucsEngine(
            modelURL: Self.modelURL, calibrator: calibrator,
            splitStore: SplitStore(baseDirectory: tmp.appendingPathComponent("Splits")))

        var outputs: SplitOutputs?
        var failure: StemError?
        var lastProgress = 0.0
        for await event in await engine.split(source) {
            switch event {
            case .completed(let o): outputs = o
            case .failure(let e): failure = e
            case .progress(let f): lastProgress = f
            default: break
            }
        }
        XCTAssertNil(failure)
        let out = try XCTUnwrap(outputs)
        XCTAssertEqual(lastProgress, 1)
        XCTAssertEqual(out.stems.map(\.name), ["drums", "bass", "other", "vocals", "instrumental"])

        func read(_ url: URL) throws -> [Float] {
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        let vocals = try read(out.vocalsURL)
        let instrumental = try read(out.instrumentalURL)
        XCTAssertEqual(vocals.count, instrumental.count)
        XCTAssertEqual(Double(vocals.count) / 44_100, 12, accuracy: 0.1)
        for stem in out.stems {
            XCTAssertEqual(try read(stem.url).count, vocals.count, stem.name)
            XCTAssertEqual(stem.peaks.count, 12 * StemTrack.peaksPerSecond, accuracy: 2, stem.name)
        }

        // vocals + instrumental reproduces the decoded source (24-bit quantization only).
        var decoded: [Float] = []
        for try await chunk in AudioExtractor().chunks(from: source) {
            decoded.append(contentsOf: stride(from: 0, to: chunk.interleavedSamples.count, by: 2).map { chunk.interleavedSamples[$0] })
        }
        var maxErr: Float = 0
        for i in 0..<min(decoded.count, vocals.count) {
            maxErr = max(maxErr, abs(vocals[i] + instrumental[i] - decoded[i]))
        }
        XCTAssertLessThan(maxErr, 1e-4)

        // The four model stems must add back up to the mix (demucs is ~additive).
        var sum = [Float](repeating: 0, count: vocals.count)
        for stem in out.stems where stem.name != "instrumental" {
            for (i, v) in try read(stem.url).enumerated() { sum[i] += v }
        }
        var err: Float = 0, ref: Float = 0
        for i in 0..<min(decoded.count, sum.count) {
            err += (sum[i] - decoded[i]) * (sum[i] - decoded[i])
            ref += decoded[i] * decoded[i]
        }
        XCTAssertLessThan(err / ref, 0.1, "stems don't reconstruct the mix (silent model output?)")

        // A pure tone is not vocals: most energy lands outside the vocal stem.
        let vocalEnergy = vocals.reduce(0) { $0 + $1 * $1 }
        let instEnergy = instrumental.reduce(0) { $0 + $1 * $1 }
        XCTAssertLessThan(vocalEnergy, instEnergy)
    }
}
