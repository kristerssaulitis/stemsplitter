import SwiftUI
import StemCore

// MARK: - ProcessingView

/// Processing screen (design F2/F7/F11/F3): thumbnail + title + duration, the
/// progressive waveform fill as chunks complete (Reduce Motion → static bar),
/// ring + percent + ETA ("initial estimate" label while the figure is the
/// pre-start estimate), Cancel with the >30 s confirmation, and the failure
/// state routing every non-enumerated error to "Split failed — try again".
public struct ProcessingView: View {

    @ObservedObject var model: ProcessingModel
    let thumbnail: Image?
    let onAbandon: () -> Void
    let onTryAgain: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        VStack(spacing: DesignSystem.Spacing.unit3) {
            Spacer(minLength: DesignSystem.Spacing.unit2)

            Artwork(thumbnail: thumbnail)
                .frame(maxWidth: 320)

            VStack(spacing: 4) {
                Text(model.video.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.ssTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(formatClock(model.video.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.ssTextSecondary)
            }

            if let failure = model.failure {
                failureState(failure)
            } else {
                progressState
            }

            Spacer()

            if model.failure == nil {
                Button("Cancel") { model.requestCancel() }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Cancel this split")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.unit3)
        .padding(.bottom, DesignSystem.Spacing.unit2)
        .overlay(alignment: .center) {
            if model.phase == .downloading {
                iCloudDownloadModal(
                    videoTitle: model.video.title,
                    phase: model.phase,
                    progress: model.progress,
                    eta: model.eta,
                    totalBytes: model.video.fileSizeBytes,
                    onCancel: { model.requestCancel() }
                )
                .padding(DesignSystem.Spacing.unit5)
            }
        }
        .alert(
            "Cancel this split?",
            isPresented: Binding(
                get: { model.showsCancelConfirmation },
                set: { shown in if !shown { model.keepGoing() } }
            )
        ) {
            Button("Cancel Split", role: .destructive) { model.confirmCancel() }
            Button("Keep Going", role: .cancel) { model.keepGoing() }
        } message: {
            Text("Progress will be lost.")
        }
    }

    // MARK: Progress (F2/F7)

    private static let stems = ["vocals", "drums", "bass", "other"]

    @ViewBuilder
    private var progressState: some View {
        VStack(spacing: DesignSystem.Spacing.unit2) {
            // Each stem lane fills with the shared progress — the four outputs being made.
            VStack(spacing: 8) {
                ForEach(Self.stems, id: \.self) { stem in
                    HStack(spacing: 10) {
                        Image(systemName: StemStyle.icon(stem))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StemStyle.color(stem))
                            .frame(width: 22)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule().fill(StemStyle.color(stem))
                                    .frame(width: max(6, geo.size.width * model.progress))
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: model.progress)
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
            .padding(DesignSystem.Spacing.unit2)
            .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.card).fill(Color.ssSurface))
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline) {
                Text("\(Int((model.progress * 100).rounded()))%")
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.ssTextPrimary)
                    .contentTransition(.numericText())
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(phaseLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.ssTextPrimary)
                    if let eta = model.eta, model.phase == .splitting {
                        Text(eta.isInitial ? "about \(formatRemaining(eta.seconds))" : "\(formatRemaining(eta.seconds)) left")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Color.ssTextSecondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Split progress \(Int((model.progress * 100).rounded())) percent")
        }
    }

    private func formatRemaining(_ seconds: Double) -> String {
        seconds < 60 ? "\(max(1, Int(seconds.rounded())))s" : formatClock(seconds)
    }

    private var phaseLabel: String {
        switch model.phase {
        case .downloading: "Downloading from iCloud"
        case .decoding: "Reading audio…"
        case .splitting: "Separating stems…"
        case nil: "Starting…"
        }
    }

    // MARK: Failure (F3 generic / F5 corrupt / S2 named)

    @ViewBuilder
    private func failureState(_ failure: StemError) -> some View {
        VStack(spacing: DesignSystem.Spacing.unit3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(failure.userMessage ?? "Split failed — try again")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ssTextPrimary)
                .multilineTextAlignment(.center)

            Button("Try again") { onTryAgain() }
                .buttonStyle(PrimaryButtonStyle())
            .accessibilityLabel("Try the split again")

            Button {
                onAbandon()
            } label: {
                Text("Pick another video")
                    .font(.subheadline)
                    .foregroundStyle(Color.ssTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }
}

/// 16:9 thumbnail, or a waveform tile for audio-only sources.
struct Artwork: View {
    let thumbnail: Image?

    var body: some View {
        Color.ssSurface
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    thumbnail.resizable().scaledToFill()
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(Color.ssAccent)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
            .accessibilityHidden(true)
    }
}
