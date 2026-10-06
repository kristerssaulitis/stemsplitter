import AVFoundation

/// Sample-aligned multi-stem playback and offline export over one graph shape,
/// so what you hear is what you export:
///
///     per stem: Player → Mixer(volume) ─┐
///                                       Bus → TimePitch(pitch, rate) → main mixer
public final class StemMixer {
    public let names: [String]
    public let duration: Double

    private let engine = AVAudioEngine()
    private let files: [AVAudioFile]
    private let format: AVAudioFormat
    private var players: [AVAudioPlayerNode] = []
    private var mixers: [AVAudioMixerNode] = []
    private let bus = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var startTime: Double = 0
    public private(set) var isPlaying = false

    public init(tracks: [(name: String, url: URL)]) throws {
        names = tracks.map(\.name)
        files = try tracks.map { try AVAudioFile(forReading: $0.url) }
        guard let first = files.first else { throw CocoaError(.fileReadNoSuchFile) }
        format = first.processingFormat
        duration = Double(first.length) / format.sampleRate

        engine.attach(bus)
        engine.attach(timePitch)
        for _ in files {
            let p = AVAudioPlayerNode(), m = AVAudioMixerNode()
            engine.attach(p)
            engine.attach(m)
            engine.connect(p, to: m, format: format)
            engine.connect(m, to: bus, format: format)
            players.append(p)
            mixers.append(m)
        }
        engine.connect(bus, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    /// Per-stem gains (index-aligned with `names`), pitch in semitones, rate as a speed factor.
    public func apply(gains: [Float], pitch: Double, rate: Double) {
        let rateChanged = Float(rate) != timePitch.rate
        for (m, g) in zip(mixers, gains) { m.outputVolume = g }
        timePitch.pitch = Float(pitch * 100)
        timePitch.rate = Float(rate)
        timePitch.bypass = pitch == 0 && rate == 1
        if rateChanged && isPlaying { play(from: position) }
    }

    /// Seconds into the source (tempo-independent).
    public var position: Double {
        guard isPlaying, let p = players.first, let nodeTime = p.lastRenderTime,
              let t = p.playerTime(forNodeTime: nodeTime) else { return startTime }
        return min(startTime + Double(t.sampleTime) / t.sampleRate, duration)
    }

    public func play(from seconds: Double) {
        stopPlayers()
        let from = max(0, min(seconds, duration))
        startTime = from
        let a = AVAudioFramePosition(from * format.sampleRate)
        for (p, f) in zip(players, files) where f.length > a {
            p.scheduleSegment(f, startingFrame: a, frameCount: AVAudioFrameCount(f.length - a), at: nil)
        }
        #if os(iOS)
        // .playback ignores the ring/silent switch; the default .soloAmbient is muted by it on device.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
        if !engine.isRunning {
            engine.prepare()
            guard (try? engine.start()) != nil else { return }
        }
        // One shared start time keeps stems phase-aligned.
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        players.forEach { $0.play(at: when) }
        isPlaying = true
    }

    public func pause() {
        let t = position
        stopPlayers()
        startTime = t
    }

    public func seek(to seconds: Double) {
        if isPlaying { play(from: seconds) } else { startTime = max(0, min(seconds, duration)) }
    }

    private func stopPlayers() {
        players.forEach { $0.stop() }
        isPlaying = false
    }

    // MARK: Export

    public enum FileKind: Sendable { case wav, m4a }

    /// Renders the whole mix with these settings into `url` (WAV 24-bit or AAC .m4a).
    /// Uses its own engine, so playback can continue meanwhile.
    public static func render(
        tracks: [(name: String, url: URL)], gains: [Float], pitch: Double, rate: Double,
        kind: FileKind, to url: URL, progress: (Double) -> Void = { _ in }
    ) throws {
        let mixer = try StemMixer(tracks: tracks)
        mixer.apply(gains: gains, pitch: pitch, rate: rate)
        let engine = mixer.engine
        try engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 4096)
        defer { engine.stop(); engine.disableManualRenderingMode() }
        for (p, f) in zip(mixer.players, mixer.files) {
            p.scheduleSegment(f, startingFrame: 0, frameCount: AVAudioFrameCount(f.length), at: nil)
        }
        try engine.start()
        mixer.players.forEach { $0.play() }

        let sr = mixer.format.sampleRate
        let settings: [String: Any] = switch kind {
        case .wav: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .m4a: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 256_000]
        }
        try? FileManager.default.removeItem(at: url)
        do {
            let out = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            let total = AVAudioFramePosition(mixer.duration / rate * sr)
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                          frameCapacity: engine.manualRenderingMaximumFrameCount)!
            while engine.manualRenderingSampleTime < total {
                try Task.checkCancellation()
                let want = AVAudioFrameCount(min(Int64(buffer.frameCapacity), total - engine.manualRenderingSampleTime))
                switch try engine.renderOffline(want, to: buffer) {
                case .success: try out.write(from: buffer)
                case .error: throw CocoaError(.fileWriteUnknown)
                default: break
                }
                progress(Double(engine.manualRenderingSampleTime) / Double(total))
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Source video's picture (passthrough, no re-encode) with `audio` as its sound track.
    public static func replaceAudio(video: URL, audio: URL, to url: URL) async throws {
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        guard let vt = try await v.loadTracks(withMediaType: .video).first else {
            throw StemError.generic("source has no video track")
        }
        guard let at = try await a.loadTracks(withMediaType: .audio).first else {
            throw StemError.generic("rendered mix has no audio")
        }
        let len = CMTimeMinimum(try await a.load(.duration), try await v.load(.duration))
        let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: len), of: vt, at: .zero)
        cv.preferredTransform = try await vt.load(.preferredTransform)
        let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: len), of: at, at: .zero)

        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw StemError.generic("no export session")
        }
        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
