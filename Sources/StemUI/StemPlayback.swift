import SwiftUI
import AVFoundation
import StemCore

// MARK: - Formatting

public func formatClock(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - StemWaveform

/// Mirrored peak bars; the played part is bright, the rest dim.
struct StemWaveform: View {
    let peaks: [Float]
    let color: Color
    let progress: Double
    let audible: Bool

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty, size.width > 0 else { return }
            let step: CGFloat = 3
            let cols = max(1, Int(size.width / step))
            let per = Double(peaks.count) / Double(cols)
            let mid = size.height / 2
            let playedX = size.width * progress
            var played = Path(), rest = Path()
            for c in 0..<cols {
                let a = Int(Double(c) * per), b = max(a + 1, Int(Double(c + 1) * per))
                var m: Float = 0
                for i in a..<min(b, peaks.count) { m = max(m, peaks[i]) }
                // sqrt lifts quiet passages so every lane reads.
                let h = max(1, CGFloat(sqrt(min(1, m))) * mid * 0.95)
                let rect = CGRect(x: CGFloat(c) * step, y: mid - h, width: 2, height: h * 2)
                if rect.midX <= playedX { played.addRect(rect) } else { rest.addRect(rect) }
            }
            let alpha = audible ? 1.0 : 0.3
            ctx.fill(played, with: .color(color.opacity(alpha)))
            ctx.fill(rest, with: .color(color.opacity(alpha * 0.4)))
        }
        .accessibilityHidden(true)
    }
}

/// Max of `peaks` into `count` buckets (overview waveform for the scrubber).
func downsample(_ peaks: [Float], to count: Int) -> [Float] {
    guard count > 0, !peaks.isEmpty else { return [] }
    var out = [Float](repeating: 0, count: count)
    for (i, p) in peaks.enumerated() {
        let b = min(i * count / peaks.count, count - 1)
        out[b] = max(out[b], p)
    }
    return out
}

// MARK: - ProgressRing

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

// MARK: - SyncedVideo

/// Muted picture of the source video, slaved to the stem mixer's clock.
/// ponytail: drift-correcting seek (> 0.15 s), not a shared clock; fine for a preview.
@MainActor
final class VideoSync: ObservableObject {
    let player: AVPlayer

    init(url: URL) {
        player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    func update(position: Double, playing: Bool, rate: Double) {
        let t = player.currentTime().seconds
        if !t.isFinite || abs(t - position) > 0.15 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        let wanted = playing ? Float(rate) : 0
        if player.rate != wanted { player.rate = wanted }
    }
}

#if os(iOS)
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}
}
#else
struct VideoSurface: View {
    let player: AVPlayer
    var body: some View { Color.black }
}
#endif
