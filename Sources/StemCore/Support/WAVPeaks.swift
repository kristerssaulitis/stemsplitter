import AVFoundation

/// Waveform peaks for stored sessions. The pipeline computes peaks in memory
/// while writing; a history replay only has the WAV files on disk, so opening
/// one from history re-derives peaks here (one sequential decode, off-main).
public enum WAVPeaks {

    /// Max-|sample| peaks at `perSecond` bins per second (values 0...1), maxed
    /// across channels to match the pipeline's `PeakAccumulator` view of a stem.
    /// A partial trailing bin is kept. Throws on unreadable/undecodable files —
    /// callers fall back to empty peaks (flat lanes, playback still works).
    public static func load(from url: URL, perSecond: Int = StemTrack.peaksPerSecond) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard perSecond > 0, format.sampleRate >= Double(perSecond) else { return [] }
        let framesPerBin = Int(format.sampleRate) / perSecond
        let channelCount = max(1, Int(format.channelCount))

        // Decode in multi-bin chunks so whole-file buffers never materialize.
        let binsPerChunk = 512
        let framesPerChunk = framesPerBin * binsPerChunk
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerChunk)) else {
            return []
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(Int(file.length) / framesPerBin + 1)
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            let data = UnsafeBufferPointer(start: channels, count: channelCount)
            var bin: Float = 0
            for frame in 0..<frames {
                var sample: Float = 0
                for channel in data { sample = max(sample, abs(channel[frame])) }
                bin = max(bin, sample)
                if (frame + 1) % framesPerBin == 0 {
                    peaks.append(min(bin, 1))
                    bin = 0
                }
            }
            if frames < framesPerChunk { // short read = EOF
                if frames % framesPerBin != 0 { peaks.append(min(bin, 1)) }
                break
            }
        }
        return peaks
    }
}
