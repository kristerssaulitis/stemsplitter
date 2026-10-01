import XCTest
@testable import StemCore

/// WAVWriter suite — governed by the approved test plan artifact (eng findings
/// E5/E6/E9; coverage rows "24-bit golden bytes", "disk-full preflight +
/// mid-write", "RF64 >4GB"). RF64 is verified via injected byte counts only —
/// no real 4 GB file is ever written.
final class WAVWriterTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WAVWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String = "out.wav") -> URL {
        dir.appendingPathComponent(name)
    }

    // MARK: - 24-bit little-endian packing, golden bytes (test plan row 1)

    /// The whole 62-byte file is pinned byte-for-byte: 44-byte RIFF header
    /// (placeholder sizes backpatched to 54/18) + golden int24 packing of
    /// (0.0, 0.5), (-0.5, 1.0), (-1.0, 0.0) →
    /// 0x000000, 0x400000, 0xC00000, 0x7FFFFF, 0x800001, 0x000000 little-endian.
    /// 0.5 × 0x7FFFFF = 4194303.5 → ties-away-from-zero rounds to 0x400000.
    func testGoldenBytes_PackingAndBackpatchedHeader() throws {
        let writer = try WAVWriter(url: url())
        try writer.append(interleaved: [0.0, 0.5, -0.5, 1.0, -1.0, 0.0])
        try writer.finalize()

        let golden: [UInt8] = [
            // "RIFF" + (62-8) + "WAVE"
            0x52, 0x49, 0x46, 0x46, 0x36, 0x00, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45,
            // "fmt " + 16 + PCM + stereo + 44100 + byteRate 264600 + blockAlign 6 + 24 bits
            0x66, 0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x02, 0x00, 0x44, 0xAC, 0x00, 0x00,
            0x98, 0x09, 0x04, 0x00, 0x06, 0x00, 0x18, 0x00,
            // "data" + 18
            0x64, 0x61, 0x74, 0x61, 0x12, 0x00, 0x00, 0x00,
            // int24 LE packed frames
            0x00, 0x00, 0x00, // 0.0
            0x00, 0x00, 0x40, // 0.5 → 4194304
            0x00, 0x00, 0xC0, // -0.5 → -4194304
            0xFF, 0xFF, 0x7F, // 1.0 → 8388607
            0x01, 0x00, 0x80, // -1.0 → -8388607 (0x800001 LE)
            0x00, 0x00, 0x00, // 0.0
        ]
        let bytes = try Data(contentsOf: url())
        XCTAssertEqual([UInt8](bytes), golden)
        XCTAssertEqual(bytes.count, 62)
        XCTAssertEqual(writer.dataBytesWritten, 18)
        XCTAssertEqual(writer.framesAppended, 3)
        XCTAssertEqual(WAVWriter.validateHeader(at: url()), .finalized(dataBytes: 18))
    }

    /// Streaming append: two separate appends accumulate (each sample is 3
    /// bytes, so one stereo frame = 6 bytes); finalize backpatches both size
    /// fields; finalize is idempotent and appends are refused after it.
    func testStreamingAppend_BackpatchAndIdempotentFinalize() throws {
        let writer = try WAVWriter(url: url())
        try writer.append(interleaved: [0.25, 0.0])
        XCTAssertEqual(writer.dataBytesWritten, 6)
        XCTAssertEqual(writer.framesAppended, 1)
        try writer.append(interleaved: [-0.25, 0.0, 0.5, -0.5])
        XCTAssertEqual(writer.dataBytesWritten, 18)
        try writer.finalize()
        try writer.finalize() // no-op

        let bytes = try Data(contentsOf: url())
        XCTAssertEqual(bytes.count, 44 + 18)
        XCTAssertEqual(bytes.subdata(in: 4..<8), Data([0x36, 0x00, 0x00, 0x00])) // 54 = file-8
        XCTAssertEqual(bytes.subdata(in: 40..<44), Data([0x12, 0x00, 0x00, 0x00])) // 18 data bytes
        // 0.25 → 2097151.75 → 2097152 = 0x200000; -0.25 → -2097152 = 0xE00000
        XCTAssertEqual([UInt8](bytes.subdata(in: 44..<62)),
                       [0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0xE0, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x40, 0x00, 0x00, 0xC0])
        XCTAssertThrowsError(try writer.append(interleaved: [0, 0])) { error in
            XCTAssertEqual(error as? StemError, .writeFailure("append after finalize"))
        }
    }

    /// Clipping rails and non-finite input: ±1.5 clamp to the rails; NaN/∞
    /// quantize to silence (dither-free, deterministic).
    func testClippingAndNonFiniteQuantizeToSilence() throws {
        let writer = try WAVWriter(url: url())
        try writer.append(interleaved: [1.5, -1.5, Float.nan, Float.infinity, -Float.infinity, 0.0])
        try writer.finalize()

        let bytes = try Data(contentsOf: url())
        XCTAssertEqual([UInt8](bytes.subdata(in: 44..<62)), [
            0xFF, 0xFF, 0x7F, // +1.5 clamped → 0x7FFFFF
            0x01, 0x00, 0x80, // -1.5 clamped → -8388607 (0x800001 LE)
            0x00, 0x00, 0x00, // NaN → 0
            0x00, 0x00, 0x00, // +∞ → 0
            0x00, 0x00, 0x00, // -∞ → 0
            0x00, 0x00, 0x00, // 0.0
        ])
    }

    // MARK: - RF64 (eng E6) — injected sizes only, never a real 4 GB write

    /// Decision boundary: RIFF holds data up to UInt32.max - 36 = 4294967259;
    /// one byte more (and a fortiori anything > 4 GB) requires RF64.
    func testUsesRF64DecisionBoundary() {
        XCTAssertFalse(WAVWriter.usesRF64(projectedDataBytes: 0))
        XCTAssertFalse(WAVWriter.usesRF64(projectedDataBytes: 4_294_967_259))
        XCTAssertTrue(WAVWriter.usesRF64(projectedDataBytes: 4_294_967_260))
        XCTAssertTrue(WAVWriter.usesRF64(projectedDataBytes: 4_294_967_296)) // exactly 4 GiB
        XCTAssertTrue(WAVWriter.usesRF64(projectedDataBytes: Int64(UInt64(5) * 1024 * 1024 * 1024)))
    }

    /// The 80-byte RF64 header is pinned byte-for-byte in placeholder form, then
    /// the ds64 fields are asserted as real little-endian bytes after finalize:
    /// riffSize = file-8 = 90, dataSize = 18, sampleCount = 3 frames.
    func testRF64HeaderBytes_FromInjectedProjection() throws {
        let writer = try WAVWriter(url: url(), projectedDataBytes: 4_294_967_296) // > 4 GiB, injected
        try writer.append(interleaved: [0.0, 0.5, -0.5, 1.0, -1.0, 0.0])
        try writer.finalize()

        let bytes = try Data(contentsOf: url())
        XCTAssertEqual(bytes.count, 98) // 80-byte header + 18 data bytes — no 4 GB write
        let b = [UInt8](bytes)
        XCTAssertEqual(Array(b[0..<16]), [
            0x52, 0x46, 0x36, 0x34, // "RF64"
            0xFF, 0xFF, 0xFF, 0xFF, // not-a-real-size
            0x57, 0x41, 0x56, 0x45, // "WAVE"
            0x64, 0x73, 0x36, 0x34, // "ds64"
        ])
        XCTAssertEqual(Array(b[16..<20]), [0x1C, 0x00, 0x00, 0x00]) // ds64 payload = 28
        XCTAssertEqual(Array(b[20..<28]), [0x5A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // riffSize 90
        XCTAssertEqual(Array(b[28..<36]), [0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // dataSize 18
        XCTAssertEqual(Array(b[36..<44]), [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // 3 frames
        XCTAssertEqual(Array(b[44..<48]), [0x00, 0x00, 0x00, 0x00]) // empty table
        XCTAssertEqual(Array(b[48..<60]), [0x66, 0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00,
                                           0x01, 0x00, 0x02, 0x00]) // "fmt ", 16, PCM, stereo
        XCTAssertEqual(Array(b[72..<80]), [0x64, 0x61, 0x74, 0x61,
                                           0xFF, 0xFF, 0xFF, 0xFF]) // "data" + not-a-real-size
        XCTAssertEqual(WAVWriter.validateHeader(at: url()), .finalized(dataBytes: 18))
    }

    /// RIFF is still chosen for sub-ceiling projections.
    func testRIFFChosenBelowThreshold() throws {
        _ = try WAVWriter(url: url(), projectedDataBytes: 1_000_000)
        let bytes = try Data(contentsOf: url())
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(bytes.count, 44)
    }

    // MARK: - Disk-full injection (eng E5/S2): NO partial files survive

    /// Mid-append ENOSPC: the write succeeds for the placeholder header, then
    /// fails. The partial file must be deleted before the error surfaces, and
    /// the writer is poisoned.
    func testDiskFullMidAppendDeletesPartial() throws {
        var writes = 0
        let writer = try WAVWriter(url: url(), writeHandler: { data in
            writes += 1
            if writes > 1 { throw POSIXError(POSIXErrorCode.ENOSPC) }
            _ = data
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url().path)) // placeholder exists
        XCTAssertThrowsError(try writer.append(interleaved: [0.5, -0.5])) { error in
            XCTAssertEqual(error as? StemError, .diskFull)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url().path), "partial file survived disk-full")
        XCTAssertThrowsError(try writer.append(interleaved: [0.5, -0.5])) { error in
            XCTAssertEqual(error as? StemError, .writeFailure("writer failed; file was deleted"))
        }
    }

    /// Disk-full during the placeholder header write: init throws `.diskFull`
    /// and leaves no file at all.
    func testDiskFullAtInitLeavesNoFile() throws {
        XCTAssertThrowsError(
            try WAVWriter(url: url(), writeHandler: { _ in throw POSIXError(POSIXErrorCode.ENOSPC) })
        ) { error in
            XCTAssertEqual(error as? StemError, .diskFull)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url().path))
    }

    /// Cancel-path teardown (eng E1): abortAndDelete removes the open partial.
    func testAbortAndDeleteRemovesPartial() throws {
        let writer = try WAVWriter(url: url())
        try writer.append(interleaved: [0.5, -0.5])
        writer.abortAndDelete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url().path))
        XCTAssertThrowsError(try writer.append(interleaved: [0.5, -0.5]))
        writer.abortAndDelete() // idempotent
        XCTAssertFalse(FileManager.default.fileExists(atPath: url().path))
    }

    /// Non-ENOSPC write errors map to `.writeFailure` (frozen StemError surface)
    /// and still delete the partial. The handler lets the placeholder header
    /// write (call 1) through so the failure lands mid-append.
    func testNonENOSPCWriteErrorMapsToWriteFailureAndCleansUp() throws {
        var writes = 0
        let writer = try WAVWriter(url: url(), writeHandler: { _ in
            writes += 1
            if writes > 1 { throw NSError(domain: "test", code: 5, userInfo: nil) }
        })
        XCTAssertThrowsError(try writer.append(interleaved: [0.5, -0.5])) { error in
            guard case .writeFailure = error as? StemError else {
                return XCTFail("expected .writeFailure, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url().path))
    }

    // MARK: - Rescue path (eng E9): validate, delete, never leave partials

    func testRescueValidatesThenDeletes() throws {
        // (a) Garbage file (bad magic, ≥ 12 bytes so the length check passes).
        var garbage = Data([0xDE, 0xAD, 0xBE, 0xEF])
        garbage.append(Data(repeating: 0, count: 12))
        try garbage.write(to: url("garbage.wav"))
        XCTAssertEqual(WAVWriter.validateHeader(at: url("garbage.wav")),
                       .invalid(reason: "bad magic \(String(decoding: [0xDE, 0xAD, 0xBE, 0xEF], as: UTF8.self))"))
        XCTAssertTrue(WAVWriter.rescuePartial(at: url("garbage.wav")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("garbage.wav").path))

        // (b) Plausible but interrupted: placeholder header + appended data,
        // sizes never backpatched. The writer is abandoned without finalize —
        // the on-disk file keeps the placeholder sizes. The RIFF-size mismatch
        // is what validation reports (checked before the data-size field).
        let interrupted = try WAVWriter(url: url("interrupted.wav"))
        try interrupted.append(interleaved: [0.25, -0.25])
        XCTAssertEqual(WAVWriter.validateHeader(at: url("interrupted.wav")),
                       .invalid(reason: "RIFF size 0 ≠ file-8 (42) — interrupted backpatch"))
        XCTAssertTrue(WAVWriter.rescuePartial(at: url("interrupted.wav")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("interrupted.wav").path))

        // (c) Truncated after a successful finalize: sizes no longer match.
        let good = try WAVWriter(url: url("truncated.wav"))
        try good.append(interleaved: [0.5, -0.5, 0.5, -0.5])
        try good.finalize()
        var bytes = try Data(contentsOf: url("truncated.wav"))
        try bytes.prefix(bytes.count - 5).write(to: url("truncated.wav"))
        guard case .invalid = WAVWriter.validateHeader(at: url("truncated.wav")) else {
            return XCTFail("truncated finalized file must be invalid")
        }
        XCTAssertTrue(WAVWriter.rescuePartial(at: url("truncated.wav")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("truncated.wav").path))

        // (d) A fully valid finalized WAV is KEPT (rescue returns false).
        let keeper = try WAVWriter(url: url("keeper.wav"))
        try keeper.append(interleaved: [0.0, 0.5])
        try keeper.finalize()
        XCTAssertFalse(WAVWriter.rescuePartial(at: url("keeper.wav")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("keeper.wav").path))

        // (e) Missing file: nothing to rescue, returns false.
        XCTAssertFalse(WAVWriter.rescuePartial(at: url("missing.wav")))
    }

    // MARK: - Disk preflight math (eng E5, verification bar formula)

    /// required = duration × rate × channels × 3 bytes × 2 stems + tmp copy projection.
    /// 60 s @44.1k stereo 24-bit = 31,752,000 bytes/stem; 3-min with a 1 GB tmp copy.
    func testPreflightMathExactFormula() {
        XCTAssertEqual(
            WAVWriter.requiredDiskBytes(durationSeconds: 60, sampleRate: 44_100, channels: 2, stemCount: 2, tmpCopyBytes: 0),
            31_752_000
        )
        XCTAssertEqual(
            WAVWriter.requiredDiskBytes(durationSeconds: 180, sampleRate: 44_100, channels: 2, stemCount: 2, tmpCopyBytes: 1_000_000_000),
            95_256_000 + 1_000_000_000
        )
        // Projection helper feeding the writer's RF64 decision.
        XCTAssertEqual(
            WAVWriter.projectedDataBytes(durationSeconds: 60, sampleRate: 44_100, channels: 2),
            15_876_000
        )
    }

    /// The plan obligation layer on top: ×1.2 margin on stem bytes, un-margined
    /// tmp + same-session split dirs, +1 GB headroom.
    func testPreflightGateAppliesMarginHeadroomAndAccumulation() {
        XCTAssertEqual(
            WAVWriter.preflightRequiredBytes(durationSeconds: 180,
                                             tmpCopyBytes: 500_000_000,
                                             sameSessionSplitDirBytes: 95_256_000),
            Int64((Double(95_256_000) * 1.2).rounded()) + 500_000_000 + 95_256_000 + 1_073_741_824
        )
    }
}
