import Foundation

/// Streaming 24-bit WAV writer — plan T5 / TE4 / TE5 (eng findings E5, E6, E9).
///
/// Emits 44.1 kHz stereo 24-bit PCM WAV by streaming: a placeholder header is
/// written at open, interleaved float frames are appended and packed to
/// little-endian int24 (clipping + dither-free round-to-nearest), and the real
/// sizes are backpatched at finalize. When the *projected* data size exceeds the
/// 4 GB RIFF ceiling the writer emits the RF64 layout from the first byte
/// (eng E6; the decision is driven by the injected projection — never by
/// actually writing 4 GB). Any write failure (disk-full injected or real) tears
/// the writer down and DELETES the partial file — no partial output is ever left
/// behind (eng E9, plan S2 `DiskFullError` rescue). `rescuePartial` is the
/// crash-recovery path: it validates a possibly-garbage/interrupted header and
/// deletes the file unless it is a fully valid, backpatched WAV.
///
/// Layout notes:
/// - Quantization scale is ±0x7FFFFF (symmetric rails, the common CoreAudio
///   convention): -1.0 → -8388607, +1.0 → +8388607. Rounding is
///   `.rounded()` (to-nearest, ties away from zero) — deterministic, no dither.
/// - Non-finite float samples (NaN/∞ — an upstream gain-staging bug) quantize
///   to silence (0) rather than poisoning the stream. The plan's shared
///   headroom-attenuation gain policy is applied upstream (complement staging),
///   NOT here; this writer's only clipping is the final rail clamp.
/// - RIFF (44-byte header) is used while `data ≤ UInt32.max - 36` (36 = bytes
///   between the RIFF size field and EOF); RF64 (EBU Tech 3306, 80-byte header
///   with a `ds64` chunk) otherwise. RIFF: sizes at offsets 4 (file-8) and 40
///   (data). RF64: `ds64` riffSize/dataSize/sampleCount at 20/28/36.
///
/// Owned by one pipeline stage (eng E1: writer teardown on cancel is the
/// engine's job; `abortAndDelete` is the teardown). Not `Sendable` — hold it in
/// the owning actor's isolated state.
public final class WAVWriter {

    // MARK: - Format constants (plan premise 5: WAV 44.1 kHz/24-bit)

    /// Bytes per sample (24-bit).
    private static let bytesPerSample = 3
    /// Placeholder RIFF header size.
    private static let riffHeaderSize = 44
    /// RF64 header size ("RF64"+size+"WAVE" + ds64 chunk + fmt + data chunk header).
    private static let rf64HeaderSize = 80
    /// ds64 chunk payload without a table (riffSize + dataSize + sampleCount + tableLength).
    private static let ds64PayloadSize = 28
    /// 0xFFFFFFFF marker for fields addressed through ds64.
    private static let notARealSize: UInt32 = 0xFFFF_FFFF
    /// Symmetric full scale for 24-bit.
    private static let fullScale = Float(0x007F_FFFF)

    /// PCM format tag.
    private static let pcmFormatTag: UInt16 = 1

    /// Sample rate in Hz (44_100 per the plan's output format).
    public let sampleRate: Int32
    /// Channels per frame (2 = stereo per the plan's output format).
    public let channels: Int

    /// URL of the file under construction. On any failure the file is deleted.
    public let url: URL

    /// Frames (per-channel sample sets) successfully appended so far.
    public private(set) var framesAppended: Int64 = 0
    /// Data-chunk bytes successfully written so far (excludes the header).
    public private(set) var dataBytesWritten: Int64 = 0
    /// True once `finalize()` has backpatched the sizes.
    public private(set) var isFinalized = false

    /// Injection seam for write failures (disk-full tests inject `POSIXError(.ENOSPC)`).
    /// `nil` once the writer is closed/failed.
    private var writeHandler: ((Data) throws -> Void)?
    private var fileHandle: FileHandle?

    private enum State { case open, finalized, failed }
    private var state: State = .open

    // MARK: - Init

    /// Opens (truncating) `url` and writes the placeholder header — RIFF or RF64
    /// per `projectedDataBytes` (eng E6: the projection comes from the pipeline's
    /// `duration × rate × channels × 3`; see `projectedDataBytes(durationSeconds:...)`).
    ///
    /// Throws `StemError.diskFull` / `.writeFailure` if the placeholder write
    /// fails; the half-written file is deleted before throwing.
    public convenience init(url: URL,
                            sampleRate: Int32 = 44_100,
                            channels: Int = 2,
                            projectedDataBytes: Int64 = 0) throws {
        try self.init(url: url,
                      sampleRate: sampleRate,
                      channels: channels,
                      projectedDataBytes: projectedDataBytes,
                      writeHandler: nil)
    }

    /// Designated init; `writeHandler` replaces the FileHandle write for tests.
    init(url: URL,
         sampleRate: Int32 = 44_100,
         channels: Int = 2,
         projectedDataBytes: Int64 = 0,
         writeHandler: ((Data) throws -> Void)?) throws {
        precondition(channels > 0, "WAVWriter needs at least one channel")
        precondition(sampleRate > 0, "WAVWriter needs a positive sample rate")
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels

        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw StemError.writeFailure("could not create \(url.lastPathComponent)")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw Self.mapWriteError(error)
        }
        self.fileHandle = handle
        self.writeHandler = writeHandler ?? { try handle.write(contentsOf: $0) }

        let rf64 = Self.usesRF64(projectedDataBytes: projectedDataBytes)
        self._isRF64 = rf64
        do {
            try performWrite(rf64
                             ? Self.rf64Header(sampleRate: sampleRate, channels: channels)
                             : Self.riffHeader(sampleRate: sampleRate, channels: channels))
        } catch {
            throw teardown(after: error)
        }
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Streaming append

    /// Appends interleaved frames: `samples.count` must be a multiple of
    /// `channels`. Each float is clamped to ±1.0 and rounded to nearest
    /// (ties away from zero) — clipping, dither-free (plan gain policy applies
    /// shared headroom upstream; see the type doc).
    ///
    /// On a write failure the partial file is DELETED and `StemError.diskFull`
    /// (ENOSPC) or `.writeFailure` (anything else) is thrown; the writer is
    /// poisoned and every later call throws.
    public func append(interleaved samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try append(interleaved: $0) }
    }

    /// Pointer-based append (see the Array overload). `buffer.count` scalars,
    /// interleaved, multiple of `channels`.
    public func append(interleaved buffer: UnsafeBufferPointer<Float>) throws {
        guard state == .open else {
            throw StemError.writeFailure(state == .finalized
                                         ? "append after finalize"
                                         : "writer failed; file was deleted")
        }
        let sampleCount = buffer.count
        guard sampleCount % channels == 0 else {
            throw StemError.writeFailure("interleaved append not frame-aligned: \(sampleCount) scalars for \(channels) channels")
        }
        guard sampleCount > 0 else { return }
        // Layout choice was fixed at open from the projection; a RIFF stream that
        // overflows the 32-bit size fields means the projection lied. Fail loudly
        // (with cleanup) rather than emitting a corrupt size field (eng E6).
        if !_isRF64,
           dataBytesWritten + Int64(sampleCount) * Int64(Self.bytesPerSample)
               > Int64(UInt32.max) - Int64(Self.riffHeaderSize - 8) {
            throw teardown(after: StemError.writeFailure("data exceeds RIFF 32-bit size fields; RF64 projection was required"))
        }

        var bytes = [UInt8](repeating: 0, count: sampleCount * Self.bytesPerSample)
        var p = 0
        for i in 0..<sampleCount {
            let v = UInt32(bitPattern: Self.quantize(buffer[i])) & 0x00FF_FFFF
            bytes[p] = UInt8(v & 0xFF)
            bytes[p + 1] = UInt8((v >> 8) & 0xFF)
            bytes[p + 2] = UInt8((v >> 16) & 0xFF)
            p += Self.bytesPerSample
        }
        do {
            try performWrite(Data(bytes))
        } catch {
            throw teardown(after: error)
        }
        dataBytesWritten += Int64(sampleCount) * Int64(Self.bytesPerSample)
        framesAppended += Int64(sampleCount / channels)
    }

    // MARK: - Finalize / teardown

    /// Backpatches the real sizes (RIFF offsets 4 + 40, or RF64 `ds64` fields)
    /// and closes the file. Idempotent: a second call on a finalized writer is a
    /// no-op. On a backpatch failure the partial file is deleted and the writer
    /// throws (eng E9: never leave an unbackpatched/garbage header behind).
    public func finalize() throws {
        guard state == .open else {
            if state == .finalized { return }
            throw StemError.writeFailure("finalize on failed writer")
        }
        let fileSize = Int64(usesRF64Layout ? Self.rf64HeaderSize : Self.riffHeaderSize) + dataBytesWritten
        do {
            if usesRF64Layout {
                try seekAndWrite(UInt64(fileSize - 8), at: 20)   // ds64.riffSize
                try seekAndWrite(UInt64(dataBytesWritten), at: 28)
                try seekAndWrite(UInt64(framesAppended), at: 36) // ds64.sampleCount
            } else {
                try seekAndWrite(UInt32(fileSize - 8), at: 4)
                try seekAndWrite(UInt32(dataBytesWritten), at: 40)
            }
            try fileHandle?.close()
        } catch {
            throw teardown(after: error)
        }
        fileHandle = nil
        writeHandler = nil
        state = .finalized
        isFinalized = true
    }

    /// Cancel/abort teardown (eng E1): close and DELETE the partial file.
    /// No-op if the writer never opened, already failed, or already finalized
    /// (deleting a finalized output is a caller bug and is refused).
    public func abortAndDelete() {
        guard state != .failed else { return }
        guard state != .finalized else { return }
        state = .failed
        try? fileHandle?.close()
        fileHandle = nil
        writeHandler = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Shared failure path: poison, close, DELETE the partial file, then map the
    /// error (`ENOSPC` → `.diskFull`, anything else → `.writeFailure`) — plan S2
    /// DiskFullError rescue + eng E9: no partial files survive a failed write.
    private func teardown(after error: Error) -> StemError {
        state = .failed
        try? fileHandle?.close()
        fileHandle = nil
        writeHandler = nil
        try? FileManager.default.removeItem(at: url)
        return Self.mapWriteError(error)
    }

    /// Layout chosen at open from the projected size (eng E6); fixed for the
    /// writer's lifetime — the pipeline must project correctly up front.
    private let _isRF64: Bool

    private var usesRF64Layout: Bool { _isRF64 }

    // MARK: - Physical writes

    private func performWrite(_ data: Data) throws {
        guard let handler = writeHandler else {
            throw StemError.writeFailure("writer closed")
        }
        try handler(data)
    }

    private func seekAndWrite(_ scalar: UInt32, at offset: UInt64) throws {
        var d = Data()
        d.appendLE32(scalar)
        try seekAndWrite(d, at: offset)
    }

    private func seekAndWrite(_ scalar: UInt64, at offset: UInt64) throws {
        var d = Data()
        d.appendLE64(scalar)
        try seekAndWrite(d, at: offset)
    }

    private func seekAndWrite(_ data: Data, at offset: UInt64) throws {
        guard let handle = fileHandle else {
            throw StemError.writeFailure("writer closed")
        }
        try handle.seek(toOffset: offset)
        try performWrite(data)
    }

    // MARK: - Error mapping (frozen StemError surface)

    private static func mapWriteError(_ error: Error) -> StemError {
        if let posix = error as? POSIXError, posix.code == .ENOSPC { return .diskFull }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return .diskFull }
        return .writeFailure(String(describing: error))
    }

    // MARK: - Quantization (clipping + dither-free rounding)

    /// Clamp to ±1.0 then round-to-nearest (ties away from zero) on the
    /// symmetric ±0x7FFFFF scale. Non-finite → 0 (silence).
    private static func quantize(_ sample: Float) -> Int32 {
        guard sample.isFinite else { return 0 }
        let clamped = Swift.min(1.0, Swift.max(-1.0, sample))
        return Int32((clamped * fullScale).rounded())
    }

    // MARK: - Header builders

    /// Canonical 44-byte PCM RIFF header with placeholder (zero) sizes.
    private static func riffHeader(sampleRate: Int32, channels: Int) -> Data {
        var d = Data(capacity: riffHeaderSize)
        d.append("RIFF".data(using: .ascii)!)                 // 0
        d.appendLE32(0)                                       // 4  placeholder file-8
        d.append("WAVE".data(using: .ascii)!)                 // 8
        d.append("fmt ".data(using: .ascii)!)                 // 12
        d.appendLE32(16)                                      // 16 fmt chunk size
        d.appendLE16(pcmFormatTag)                            // 20
        d.appendLE16(UInt16(channels))                        // 22
        d.appendLE32(UInt32(bitPattern: sampleRate))          // 24
        d.appendLE32(UInt32(sampleRate) * UInt32(channels) * 3) // 28 byte rate
        d.appendLE16(UInt16(channels * bytesPerSample))       // 32 block align
        d.appendLE16(24)                                      // 34 bits per sample
        d.append("data".data(using: .ascii)!)                 // 36
        d.appendLE32(0)                                       // 40 placeholder data size
        precondition(d.count == riffHeaderSize)
        return d
    }

    /// 80-byte RF64 (EBU Tech 3306) header: RF64 magic, 0xFFFFFFFF chunk size,
    /// ds64 chunk (placeholder riffSize/dataSize/sampleCount, empty table),
    /// fmt chunk, data chunk header with 0xFFFFFFFF.
    private static func rf64Header(sampleRate: Int32, channels: Int) -> Data {
        var d = Data(capacity: rf64HeaderSize)
        d.append("RF64".data(using: .ascii)!)                 // 0
        d.appendLE32(notARealSize)                            // 4
        d.append("WAVE".data(using: .ascii)!)                 // 8
        d.append("ds64".data(using: .ascii)!)                 // 12
        d.appendLE32(UInt32(ds64PayloadSize))                 // 16 ds64 size
        d.appendLE64(0)                                       // 20 riffSize (placeholder)
        d.appendLE64(0)                                       // 28 dataSize (placeholder)
        d.appendLE64(0)                                       // 36 sampleCount (placeholder)
        d.appendLE32(0)                                       // 44 table length (no table)
        d.append("fmt ".data(using: .ascii)!)                 // 48
        d.appendLE32(16)                                      // 52
        d.appendLE16(pcmFormatTag)                            // 56
        d.appendLE16(UInt16(channels))                        // 58
        d.appendLE32(UInt32(bitPattern: sampleRate))          // 60
        d.appendLE32(UInt32(sampleRate) * UInt32(channels) * 3) // 64
        d.appendLE16(UInt16(channels * bytesPerSample))       // 68
        d.appendLE16(24)                                      // 70
        d.append("data".data(using: .ascii)!)                 // 72
        d.appendLE32(notARealSize)                            // 76
        precondition(d.count == rf64HeaderSize)
        return d
    }

    // MARK: - Projections (disk preflight math, eng E5 / plan disk obligation)

    /// Data-chunk bytes one stem of `durationSeconds` needs:
    /// `duration × rate × channels × 3`.
    public static func projectedDataBytes(durationSeconds: Double,
                                          sampleRate: Int32 = 44_100,
                                          channels: Int = 2) -> Int64 {
        Int64((durationSeconds * Double(sampleRate) * Double(channels) * Double(bytesPerSample)).rounded())
    }

    /// The disk preflight formula (verification bar, eng E5):
    /// `required = duration × rate × channels × 3 bytes × stems + tmp copy projection`.
    /// The plan's ×1.2 margin, same-session split-dir accumulation and 1 GB
    /// headroom are applied by `preflightRequiredBytes`, not here.
    public static func requiredDiskBytes(durationSeconds: Double,
                                         sampleRate: Int32 = 44_100,
                                         channels: Int = 2,
                                         stemCount: Int = 2,
                                         tmpCopyBytes: Int64 = 0) -> Int64 {
        projectedDataBytes(durationSeconds: durationSeconds, sampleRate: sampleRate, channels: channels)
            * Int64(stemCount) + tmpCopyBytes
    }

    /// Preflight gate bytes per the plan obligation: stem bytes ×1.2 margin, plus
    /// the tmp source-copy projection and accumulated same-session split dirs
    /// (eng E5, un-margined projections), plus the 1 GB headroom.
    public static func preflightRequiredBytes(durationSeconds: Double,
                                              sampleRate: Int32 = 44_100,
                                              channels: Int = 2,
                                              stemCount: Int = 2,
                                              tmpCopyBytes: Int64 = 0,
                                              sameSessionSplitDirBytes: Int64 = 0,
                                              margin: Double = 1.2,
                                              headroomBytes: Int64 = 1_073_741_824) -> Int64 {
        Int64((Double(projectedDataBytes(durationSeconds: durationSeconds,
                                         sampleRate: sampleRate,
                                         channels: channels) * Int64(stemCount)) * margin).rounded())
            + tmpCopyBytes + sameSessionSplitDirBytes + headroomBytes
    }

    /// RF64 decision (eng E6): RIFF's 32-bit chunk size cannot address data
    /// beyond `UInt32.max - 36` bytes (36 = file bytes outside the RIFF size
    /// field in the canonical header) — beyond that, emit RF64.
    public static func usesRF64(projectedDataBytes: Int64) -> Bool {
        projectedDataBytes > Int64(UInt32.max) - Int64(riffHeaderSize - 8)
    }

    // MARK: - Header validation + rescue (eng E9)

    /// Outcome of validating a file that claims to be one of this writer's WAVs.
    public enum WAVValidation: Equatable {
        /// A fully valid, backpatched WAV whose declared sizes match the file.
        case finalized(dataBytes: Int64)
        /// Garbage, truncated, or interrupted before/during backpatch.
        case invalid(reason: String)
    }

    /// Validates the on-disk header: magic + layout + BOTH size fields must match
    /// the actual file length. An interrupted write (placeholder sizes never
    /// backpatched, or a partially-backpatched header) does not match and is
    /// `invalid` — that is exactly what the rescue path deletes (eng E9).
    public static func validateHeader(at url: URL) -> WAVValidation {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .invalid(reason: "unreadable")
        }
        defer { try? handle.close() }
        guard let headData = try? handle.read(upToCount: rf64HeaderSize), headData.count >= 12 else {
            return .invalid(reason: "shorter than 12 bytes")
        }
        let fileSize: Int64
        do { fileSize = Int64(try handle.seekToEnd()) } catch {
            return .invalid(reason: "size unreadable")
        }
        let b = [UInt8](headData)
        let magic = String(decoding: b[0..<4], as: UTF8.self)

        switch magic {
        case "RIFF":
            return validateRIFF(b: b, fileSize: fileSize)
        case "RF64":
            return validateRF64(b: b, fileSize: fileSize)
        default:
            return .invalid(reason: "bad magic \(magic)")
        }
    }

    private static func validateRIFF(b: [UInt8], fileSize: Int64) -> WAVValidation {
        guard fileSize >= Int64(riffHeaderSize) else { return .invalid(reason: "truncated before RIFF header end") }
        guard String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { return .invalid(reason: "missing WAVE") }
        guard String(decoding: b[12..<16], as: UTF8.self) == "fmt " else { return .invalid(reason: "missing fmt") }
        guard le16(b, 20) == pcmFormatTag else { return .invalid(reason: "not PCM") }
        let channels = Int(le16(b, 22))
        guard channels > 0 else { return .invalid(reason: "zero channels") }
        guard le16(b, 34) == 24 else { return .invalid(reason: "not 24-bit") }
        let sampleRate = Int(le32(b, 24))
        guard sampleRate > 0 else { return .invalid(reason: "zero sample rate") }
        guard le32(b, 28) == UInt32(sampleRate * channels * bytesPerSample) else { return .invalid(reason: "byte rate mismatch") }
        guard Int(le32(b, 16)) == 16 else { return .invalid(reason: "fmt size not 16") }
        guard String(decoding: b[36..<40], as: UTF8.self) == "data" else { return .invalid(reason: "missing data chunk") }
        let declaredData = Int64(le32(b, 40))
        let declaredRiff = Int64(le32(b, 4))
        guard declaredRiff == fileSize - 8 else { return .invalid(reason: "RIFF size \(declaredRiff) ≠ file-8 (\(fileSize - 8)) — interrupted backpatch") }
        guard declaredData == fileSize - Int64(riffHeaderSize) else { return .invalid(reason: "data size \(declaredData) ≠ file-44 (\(fileSize - Int64(riffHeaderSize))) — interrupted backpatch") }
        return .finalized(dataBytes: declaredData)
    }

    private static func validateRF64(b: [UInt8], fileSize: Int64) -> WAVValidation {
        guard fileSize >= Int64(rf64HeaderSize) else { return .invalid(reason: "truncated before RF64 header end") }
        guard String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { return .invalid(reason: "missing WAVE") }
        guard String(decoding: b[12..<16], as: UTF8.self) == "ds64" else { return .invalid(reason: "missing ds64") }
        guard Int(le32(b, 16)) == ds64PayloadSize else { return .invalid(reason: "ds64 size not 28") }
        guard le32(b, 44) == 0 else { return .invalid(reason: "unexpected ds64 table") }
        guard String(decoding: b[48..<52], as: UTF8.self) == "fmt " else { return .invalid(reason: "missing fmt") }
        guard le16(b, 56) == pcmFormatTag else { return .invalid(reason: "not PCM") }
        guard le16(b, 70) == 24 else { return .invalid(reason: "not 24-bit") }
        guard String(decoding: b[72..<76], as: UTF8.self) == "data" else { return .invalid(reason: "missing data chunk") }
        guard le32(b, 76) == notARealSize else { return .invalid(reason: "data size field not 0xFFFFFFFF") }
        let declaredData = Int64(le64(b, 28))
        let declaredRiff = Int64(le64(b, 20))
        guard declaredRiff == fileSize - 8 else { return .invalid(reason: "ds64.riffSize \(declaredRiff) ≠ file-8 (\(fileSize - 8)) — interrupted backpatch") }
        guard declaredData == fileSize - Int64(rf64HeaderSize) else { return .invalid(reason: "ds64.dataSize \(declaredData) ≠ file-80 (\(fileSize - Int64(rf64HeaderSize))) — interrupted backpatch") }
        return .finalized(dataBytes: declaredData)
    }

    /// Crash/interrupt rescue (eng E9): validate the header; DELETE the file
    /// unless it is a fully valid, backpatched WAV. Returns `true` iff a file
    /// was deleted; `false` for a valid file (kept) or no file at all.
    @discardableResult
    public static func rescuePartial(at url: URL) -> Bool {
        guard (try? checkResourceIsReachable(url)) == true else { return false }
        if case .finalized = validateHeader(at: url) { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    private static func checkResourceIsReachable(_ url: URL) throws -> Bool {
        try url.checkResourceIsReachable()
    }
}

// MARK: - Little-endian Data helpers

private extension Data {
    mutating func appendLE16(_ v: UInt16) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE32(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE64(_ v: UInt64) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: - Little-endian readers for validation

private func le16(_ b: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(b[offset]) | (UInt16(b[offset + 1]) << 8)
}

private func le32(_ b: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(le16(b, offset)) | (UInt32(le16(b, offset + 2)) << 16)
}

private func le64(_ b: [UInt8], _ offset: Int) -> UInt64 {
    UInt64(le32(b, offset)) | (UInt64(le32(b, offset + 4)) << 32)
}
