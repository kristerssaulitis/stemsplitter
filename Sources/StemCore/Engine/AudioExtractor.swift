import AVFoundation
import CoreMedia
import Foundation

/// Pre-flight description of a media container's audio (plan "pre-flight" step:
/// iCloud modal / disk check / long-video confirm run before any split starts).
public struct AudioProbe: Equatable, Sendable {

    /// Container duration in seconds (audio track duration where a track exists).
    public var duration: TimeInterval

    /// Whether the container carries an audio track at all.
    public var hasAudio: Bool

    /// Codec FourCC as a short string (e.g. "aac", "alac"); `nil` when `hasAudio`
    /// is `false`.
    public var codec: String?

    /// Source sample rate in Hz as stored in the stream (pre-conversion; e.g.
    /// 48000 for a 48 kHz source). `nil` when `hasAudio` is `false`.
    public var sampleRate: Double?

    public init(duration: TimeInterval, hasAudio: Bool, codec: String?, sampleRate: Double?) {
        self.duration = duration
        self.hasAudio = hasAudio
        self.codec = codec
        self.sampleRate = sampleRate
    }
}

/// One buffer of decoded, converted audio pulled out of `AudioExtractor`.
///
/// The extractor's channel policy (plan pipeline: decode → resample → chunk) is
/// fixed: interleaved stereo Float32 at 44.1 kHz. A chunk is a buffer unit for
/// the streaming pipeline, not the model chunk grid — the Chunker slices these
/// into model chunks with overlap.
public struct AudioChunk: Equatable, Sendable {

    /// Interleaved samples, left/right pairs: `[L0, R0, L1, R1, …]`.
    public var interleavedSamples: [Float]

    /// Output sample rate (always 44.1 kHz under the plan's channel policy).
    public var sampleRate: Double

    /// Output channel count (always 2).
    public var channels: Int

    /// Stereo frames in this chunk (`interleavedSamples.count / channels`).
    public var frameCount: Int {
        channels > 0 ? interleavedSamples.count / channels : 0
    }

    public init(interleavedSamples: [Float], sampleRate: Double, channels: Int) {
        self.interleavedSamples = interleavedSamples
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// AVAssetReader audio-only decode stage (plan Approach B, Engine layer).
///
/// Decodes the audio track of a local media file to **interleaved stereo
/// Float32 at 44.1 kHz** through an explicit `AVAudioConverter` stage (mono
/// sources are upmixed dual-mono; other sample rates are resampled), and
/// streams the result as a pull-based `AsyncSequence` so the pipeline draws
/// bounded buffers only — no whole-file float buffers (plan memory invariant).
///
/// Error mapping is the plan Review Section 2 rows 1-5, via the frozen
/// `StemError` contract:
/// - No audio track, or an audio path that decodes to zero samples
///   (S2 rows 1, Chunker empty path) → `.noAudio`
/// - Undecodable codec: reader produces no samples and fails (S2 row 2,
///   "same copy") → `.undecodable(.codec)`
/// - Decode/resample-stage failure once samples were flowing (S2 row 5
///   `DecodeFailure`) → `.undecodable(.resample)`
/// - Container that AVFoundation cannot open as media (truncated moov, design
///   fix F5) → `.corruptAsset`
/// - Caller-contract violation (source file absent — the app layer guarantees a
///   security-scoped local copy per `StemEngineProtocol`) → `.generic`
///
/// S2 rows 3-4 (iCloud offline / download stalled) are surfaced by the app
/// layer's picker/download stage before a local URL exists; by the frozen
/// `StemEngineProtocol` contract this component only ever receives local file
/// URLs and cannot observe those states.
public struct AudioExtractor: Sendable {

    /// Sample rate the extractor converts every source to (plan channel policy).
    public let outputSampleRate: Double

    /// Upper bound on stereo frames per emitted `AudioChunk`.
    public let chunkFrames: Int

    /// - Parameters:
    ///   - outputSampleRate: Target rate, default 44.1 kHz (plan channel policy).
    ///   - chunkFrames: Buffer granularity in stereo frames, default 1 second.
    public init(outputSampleRate: Double = 44_100, chunkFrames: Int = 44_100) {
        self.outputSampleRate = outputSampleRate
        self.chunkFrames = chunkFrames
    }

    /// Cheap pre-flight read: duration / hasAudio / codec / source sample rate,
    /// no decode. Throws `.corruptAsset` when AVFoundation cannot open the
    /// container as media, `.generic` when the file is absent.
    public func probe(at url: URL) async throws -> AudioProbe {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StemError.generic("AudioExtractor.probe: source file missing at \(url.path)")
        }
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let audioTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch is CancellationError {
            throw StemError.cancelled
        } catch {
            // AVFoundation can't open this as media (e.g. truncated moov atom).
            throw StemError.corruptAsset
        }
        guard let track = audioTracks.first else {
            return AudioProbe(duration: duration.seconds, hasAudio: false, codec: nil, sampleRate: nil)
        }
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let asbd = descriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0).map { $0.pointee }
        }
        let codec = asbd.map { Self.fourCCString($0.mFormatID) }
        let sampleRate = asbd?.mSampleRate
        return AudioProbe(
            duration: duration.seconds, hasAudio: true, codec: codec, sampleRate: sampleRate)
    }

    /// Pull-based decode stream: each `next()` yields up to `chunkFrames`
    /// stereo frames. A source with no audio throws `.noAudio` on the first
    /// pull; a corrupt container throws `.corruptAsset`; an undecodable codec
    /// throws `.undecodable(.codec)`. Task cancellation surfaces as
    /// `.cancelled` (plan row 14 pipeline contract).
    public func chunks(from url: URL) -> AudioChunkSequence {
        AudioChunkSequence(extractor: self, url: url)
    }

    /// `'aac '` → `"aac"`.
    static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        let raw = String(decoding: bytes, as: UTF8.self)
        return raw.trimmingCharacters(in: .whitespaces)
    }
}

/// `AsyncSequence` handle for `AudioExtractor.chunks(from:)`. The value is a
/// lightweight configuration; state lives in the iterator, which is created
/// and consumed on the caller's task (pull-based — no producer task, no
/// unbounded buffering).
public struct AudioChunkSequence: AsyncSequence {
    public typealias Element = AudioChunk

    let extractor: AudioExtractor
    let url: URL

    public func makeAsyncIterator() -> AudioChunkIterator {
        AudioChunkIterator(extractor: extractor, url: url)
    }
}

/// Pull-based decode iterator: one `AVAssetReader` + one `AVAudioConverter`,
/// both created lazily on first `next()` and confined to the consuming task.
public final class AudioChunkIterator: AsyncIteratorProtocol {

    private enum State {
        case notStarted
        case running(Running)
        case finished
    }

    /// Everything the converter loop needs once the reader is live.
    private final class Running {
        let reader: AVAssetReader
        let trackOutput: AVAssetReaderTrackOutput
        let converter: AVAudioConverter
        let outputFormat: AVAudioFormat
        /// First sample pulled during setup, fed to the converter first.
        var pendingSample: CMSampleBuffer?
        var producedAnySamples = false
        var sawReaderFailure = false

        init(
            reader: AVAssetReader, trackOutput: AVAssetReaderTrackOutput,
            converter: AVAudioConverter, outputFormat: AVAudioFormat
        ) {
            self.reader = reader
            self.trackOutput = trackOutput
            self.converter = converter
            self.outputFormat = outputFormat
        }
    }

    private let outputSampleRate: Double
    private let chunkFrames: Int
    private let url: URL
    private var state: State = .notStarted

    init(extractor: AudioExtractor, url: URL) {
        self.outputSampleRate = extractor.outputSampleRate
        self.chunkFrames = extractor.chunkFrames
        self.url = url
    }

    deinit {
        if case .running(let running) = state {
            running.reader.cancelReading()
        }
    }

    public func next() async throws -> AudioChunk? {
        switch state {
        case .finished:
            return nil
        case .running:
            break
        case .notStarted:
            try await startReading()
        }

        guard case .running(let running) = state else {
            return nil
        }

        // Sanity cap: `.haveData` with zero frames must not loop forever.
        var emptyConverts = 0
        while true {
            if Task.isCancelled {
                throw StemError.cancelled
            }
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: running.outputFormat, frameCapacity: AVAudioFrameCount(chunkFrames))
            guard let outBuffer else {
                throw StemError.undecodable(.resample)
            }
            var converterError: NSError?
            let status = running.converter.convert(
                to: outBuffer, error: &converterError,
                withInputFrom: { [weak self] _, inputStatus in
                    guard let buffer = self?.pullInputSample() else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return buffer
                })

            switch status {
            case .haveData:
                if outBuffer.frameLength == 0 {
                    emptyConverts += 1
                    if emptyConverts > 100 {
                        throw StemError.undecodable(.resample)
                    }
                    continue
                }
                running.producedAnySamples = true
                return chunk(from: outBuffer)
            case .endOfStream:
                state = .finished
                // A reader failure makes the input block return nil, which the
                // converter reports as end-of-stream — distinguish it here.
                if running.sawReaderFailure {
                    throw running.producedAnySamples
                        ? StemError.undecodable(.resample)  // S2 row 5 DecodeFailure
                        : StemError.undecodable(.codec)  // S2 row 2, same copy
                }
                if !running.producedAnySamples {
                    // S2 Chunker row: zero-length audio path → NoAudibleTrackError.
                    throw StemError.noAudio
                }
                return nil
            case .error:
                running.reader.cancelReading()
                throw StemError.undecodable(.resample)
            case .inputRanDry:
                emptyConverts += 1
                if emptyConverts > 100 {
                    throw StemError.undecodable(.resample)
                }
            @unknown default:
                throw StemError.undecodable(.resample)
            }
        }
    }

    // MARK: - Setup

    private func startReading() async throws {
        if Task.isCancelled {
            throw StemError.cancelled
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // The app layer guarantees a security-scoped local copy; absence is
            // a caller bug and routes to the sanctioned `.generic` sink.
            throw StemError.generic("AudioExtractor: source file missing at \(url.path)")
        }

        let asset = AVURLAsset(url: url)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch is CancellationError {
            throw StemError.cancelled
        } catch {
            // Container AVFoundation cannot open as media (truncated moov, …).
            throw StemError.corruptAsset
        }
        guard let track = audioTracks.first else {
            // S2 row 1: no audio track in the container.
            throw StemError.noAudio
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw StemError.corruptAsset
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                // Let the reader pick native interleaving; the format is read
                // back from the first sample buffer either way.
                AVLinearPCMIsNonInterleaved: false,
            ])
        guard reader.canAdd(output) else {
            throw StemError.corruptAsset
        }
        reader.add(output)
        guard reader.startReading() else {
            reader.cancelReading()
            throw StemError.corruptAsset
        }

        // Pull the first sample now: it pins the reader's actual output format
        // (channels, rate, interleaving) for the converter, and lets us tell
        // "codec undecodable" (reader failed, zero samples) from "empty audio
        // path" (clean EOF, zero samples) apart.
        guard let firstSample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                // S2 row 2: undecodable codec → same copy as no-audio.
                throw StemError.undecodable(.codec)
            }
            // Clean EOF on a track that exists: zero-length audio path.
            throw StemError.noAudio
        }
        guard let desc = CMSampleBufferGetFormatDescription(firstSample),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
        else {
            throw StemError.undecodable(.codec)
        }

        let outputFormat = try Self.stereoInterleavedFloat(sampleRate: outputSampleRate)
        guard let sourceFormat = Self.format(
            asbd: asbd, layoutTag: Self.layoutTag(forChannelCount: Int(asbd.mChannelsPerFrame))),
            let converter = AVAudioConverter(from: sourceFormat, to: outputFormat)
        else {
            throw StemError.undecodable(.resample)
        }

        let running = Running(
            reader: reader, trackOutput: output, converter: converter,
            outputFormat: outputFormat)
        running.pendingSample = firstSample
        state = .running(running)
    }

    // MARK: - Converter input

    /// Input block for `AVAudioConverter`: hands the stashed sample, then
    /// reader output, then `nil` at EOF. Reader failures are recorded here (the
    /// block cannot throw) and mapped when the converter reports end-of-stream.
    private func pullInputSample() -> AVAudioBuffer? {
        guard case .running(let running) = state else { return nil }
        if let pending = running.pendingSample {
            running.pendingSample = nil
            return audioBuffer(from: pending)
        }
        guard !running.sawReaderFailure else { return nil }
        guard let sample = running.trackOutput.copyNextSampleBuffer() else {
            if running.reader.status == .failed {
                running.sawReaderFailure = true
            }
            return nil
        }
        return audioBuffer(from: sample)
    }

    /// Copies a `CMSampleBuffer` into a retained `AVAudioPCMBuffer` matching
    /// the reader's actual (possibly interleaved or non-interleaved) layout.
    private func audioBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return nil }
        let asbd = asbdPtr.pointee
        let frameCount = Int(CMSampleBufferGetNumSamples(sample))
        guard frameCount > 0, let format = AVAudioFormat(streamDescription: asbdPtr),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }

        let channelCount = Int(asbd.mChannelsPerFrame)
        // Documented two-call pattern: query the required AudioBufferList size,
        // then fill the caller-allocated list.
        var neededSize = 0
        let queryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &neededSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard queryStatus == noErr, neededSize > 0 else {
            return nil
        }
        let listPointer = UnsafeMutableRawPointer.allocate(
            byteCount: neededSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            .assumingMemoryBound(to: AudioBufferList.self)
        memset(listPointer, 0, neededSize)
        defer { listPointer.deallocate() }
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: listPointer,
            bufferListSize: neededSize, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &retainedBlock)
        guard status == noErr else { return nil }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(listPointer)
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if isNonInterleaved {
            guard let planes = buffer.floatChannelData else { return nil }
            for channel in 0..<min(channelCount, Int(buffer.format.channelCount)) {
                let source = audioBuffers[channel]
                guard let sourceData = source.mData else { return nil }
                planes[channel].update(from: sourceData.assumingMemoryBound(to: Float.self),
                                       count: frameCount)
            }
        } else {
            guard let base = buffer.floatChannelData?[0],
                let sourceData = audioBuffers[0].mData
            else { return nil }
            let floatCount = frameCount * max(channelCount, 1)
            base.update(from: sourceData.assumingMemoryBound(to: Float.self), count: floatCount)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }

    // MARK: - Output

    private func chunk(from buffer: AVAudioPCMBuffer) -> AudioChunk {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var samples = [Float](repeating: 0, count: frameLength * channelCount)
        if let base = buffer.floatChannelData?[0] {
            samples.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.update(
                    from: base, count: frameLength * channelCount)
            }
        }
        return AudioChunk(
            interleavedSamples: samples, sampleRate: buffer.format.sampleRate,
            channels: channelCount)
    }

    // MARK: - Format helpers

    /// Interleaved Float32 stereo with a stereo channel layout, so the
    /// converter's mono→stereo upmix is layout-aware (dual mono).
    static func stereoInterleavedFloat(sampleRate: Double) throws -> AVAudioFormat {
        let asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0)
        guard let format = format(asbd: asbd, layoutTag: kAudioChannelLayoutTag_Stereo) else {
            throw StemError.undecodable(.resample)
        }
        return format
    }

    static func layoutTag(forChannelCount count: Int) -> AudioChannelLayoutTag {
        switch count {
        case 1: return kAudioChannelLayoutTag_Mono
        case 2: return kAudioChannelLayoutTag_Stereo
        default: return kAudioChannelLayoutTag_Unknown | AudioChannelLayoutTag(count)
        }
    }

    /// Builds an `AVAudioFormat` carrying both the ASBD and a channel layout
    /// via a `CMAudioFormatDescription` (needed for layout-aware upmixing).
    static func format(
        asbd: AudioStreamBasicDescription, layoutTag: AudioChannelLayoutTag
    ) -> AVAudioFormat? {
        var mutableASBD = asbd
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = layoutTag
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &mutableASBD,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description)
        guard status == noErr, let description else { return nil }
        return AVAudioFormat(cmAudioFormatDescription: description)
    }
}
