import SwiftUI
import AVFoundation
import Combine
import StemCore

// MARK: - AVStemPlayer (real AudioControlling)

/// AVPlayer-backed transport for the result screen. Playback session policy
/// (plan obligation): category `.playback`; an interruption (call/Siri) pauses
/// and resumes when it ends. iOS-only session/observation is `#if os(iOS)`
/// so the package keeps building on macOS.
final class AVStemPlayer: NSObject, AudioControlling {

    private let player = AVPlayer()
    private var loadedDuration: TimeInterval = 0

    /// Sync duration read; `load(.duration)` is async-only on this deployment
    /// target, and the transport only needs the figure at load time.
    private static func syncDuration(of asset: AVAsset) -> TimeInterval {
        let seconds = asset.duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    override init() {
        super.init()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        #endif
    }

    deinit {
        #if os(iOS)
        NotificationCenter.default.removeObserver(self)
        #endif
    }

    var position: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    var duration: TimeInterval { loadedDuration }

    var isPlaying: Bool { player.timeControlStatus == .playing }

    func load(_ url: URL, at position: TimeInterval, play: Bool) {
        let asset = AVURLAsset(url: url)
        loadedDuration = Self.syncDuration(of: asset)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        seek(to: position)
        if play {
            player.play()
        }
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func seek(to time: TimeInterval) {
        player.seek(
            to: CMTime(seconds: max(0, time), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    #if os(iOS)
    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }
        switch type {
        case .began:
            player.pause()
        case .ended:
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                player.play()
            }
        @unknown default:
            break
        }
    }
    #endif
}

// MARK: - Formatting

/// mm:ss clock used by transport + ETA labels.
public func formatClock(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - WaveformView

/// Waveform bars rendered from streamed per-chunk peaks. In processing the fill
/// grows as chunks complete (the one authored motion moment, F7); on the result
/// screen the filled fraction tracks playback and the gesture scrubs (F10).
/// Reduce Motion swaps the processing usage for a static bar (token block rule).
struct WaveformView: View {

    /// Per-chunk peaks, 0...1.
    let peaks: [Float]

    /// Filled fraction 0...1 (accent up to here, muted after).
    var fill: Double = 1

    /// Enables tap+drag scrubbing (result screen).
    var interactive: Bool = false

    var onScrub: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let barCount = min(max(Int(geo.size.width / 5), 12), 96)
            let bars = Self.buckets(from: peaks, count: barCount)
            let filledCount = Int((Double(barCount) * min(max(fill, 0), 1)).rounded())
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(index < filledCount ? Color.ssAccent : Color.ssTextSecondary.opacity(0.22))
                        .frame(width: 3, height: max(6, CGFloat(bars[index]) * geo.size.height))
                        .frame(maxHeight: geo.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                interactive && geo.size.width > 0
                    ? DragGesture(minimumDistance: 0).onChanged { value in
                        onScrub?(value.location.x / geo.size.width)
                    }
                    : nil
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waveform")
        .accessibilityValue(interactive ? "Playback position" : "Progress")
        .accessibilityAdjustableAction { direction in
            guard interactive else { return }
            let step = 0.05
            switch direction {
            case .increment: onScrub?(min(fill + step, 1))
            case .decrement: onScrub?(max(fill - step, 0))
            @unknown default: break
            }
        }
    }

    /// Downsamples per-chunk peaks into `count` buckets (max of each bucket).
    static func buckets(from peaks: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !peaks.isEmpty else { return [Float](repeating: 0.12, count: count) }
        if peaks.count <= count {
            return peaks + [Float](repeating: 0.12, count: count - peaks.count)
        }
        var buckets = [Float](repeating: 0, count: count)
        for (index, peak) in peaks.enumerated() {
            let bucket = min(index * count / peaks.count, count - 1)
            buckets[bucket] = max(buckets[bucket], peak)
        }
        return buckets
    }
}

// MARK: - ProgressRing (F2)

/// Matte progress ring — accent stroke on a muted track, no glow, no gradient.
struct ProgressRing: View {

    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.ssTextSecondary.opacity(0.22), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(Color.ssAccent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - TransportControls (F10 shared transport)

/// Shared playback transport: play/pause + position clock. Position lives in
/// the player, so it survives selector switches by construction.
struct TransportControls: View {

    @ObservedObject var model: ResultModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(spacing: DesignSystem.Spacing.unit3) {
                Text(formatClock(model.position))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.ssTextSecondary)
                    .frame(minWidth: 44, alignment: .leading)

                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(Color.ssGround)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.ssAccent))
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                Text(formatClock(model.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.ssTextSecondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .tint(Color.ssAccent)
        }
    }
}
