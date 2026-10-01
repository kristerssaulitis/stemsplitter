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
        VStack(spacing: DesignSystem.Spacing.unit4) {
            VideoSummaryCard(
                title: model.video.title,
                duration: model.video.duration,
                thumbnail: thumbnail
            )
            .padding(.top, DesignSystem.Spacing.unit5)

            Spacer()

            if let failure = model.failure {
                failureState(failure)
            } else {
                progressState
            }

            Spacer()

            if model.failure == nil {
                Button {
                    model.requestCancel()
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                            .fill(Color.ssTextSecondary.opacity(0.16)))
                        .foregroundStyle(Color.ssTextPrimary)
                }
                .accessibilityLabel("Cancel this split")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.unit5)
        .padding(.bottom, DesignSystem.Spacing.unit4)
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

    @ViewBuilder
    private var progressState: some View {
        VStack(spacing: DesignSystem.Spacing.unit4) {
            // The one authored motion moment: waveform bars landing as chunks
            // complete. Reduce Motion swaps it for a static progress bar.
            if reduceMotion {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.unit) {
                    ProgressView(value: model.progress)
                        .tint(Color.ssAccent)
                    Text("Splitting…")
                        .font(.caption)
                        .foregroundStyle(Color.ssTextSecondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                WaveformView(peaks: model.peaks, fill: 1)
                    .frame(height: 96)
            }

            HStack(spacing: DesignSystem.Spacing.unit4) {
                ProgressRing(progress: model.progress)
                    .frame(width: 88, height: 88)
                    .overlay {
                        Text("\(Int((model.progress * 100).rounded()))%")
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.ssTextPrimary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Split progress")
                    .accessibilityValue("\(Int((model.progress * 100).rounded())) percent")

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.unit) {
                    if let eta = model.eta {
                        Text("ETA \(formatClock(eta.seconds))")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Color.ssTextPrimary)
                        if eta.isInitial {
                            Text("initial estimate")
                                .font(.caption)
                                .foregroundStyle(Color.ssTextSecondary)
                        }
                    } else {
                        Text("Estimating…")
                            .font(.headline)
                            .foregroundStyle(Color.ssTextSecondary)
                    }
                    Text(phaseLabel)
                        .font(.caption)
                        .foregroundStyle(Color.ssTextSecondary)
                }
            }
        }
    }

    private var phaseLabel: String {
        switch model.phase {
        case .downloading: "Downloading from iCloud"
        case .decoding: "Reading audio"
        case .splitting: "Splitting audio"
        case nil: "Starting…"
        }
    }

    // MARK: Failure (F3 generic / F5 corrupt / S2 named)

    @ViewBuilder
    private func failureState(_ failure: StemError) -> some View {
        VStack(spacing: DesignSystem.Spacing.unit3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Color.ssAccent)
            Text(failure.userMessage ?? "Split failed — try again")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ssTextPrimary)
                .multilineTextAlignment(.center)

            Button {
                onTryAgain()
            } label: {
                Text("Try again")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                        .fill(Color.ssAccent))
                    .foregroundStyle(Color.ssGround)
            }
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
