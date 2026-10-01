import SwiftUI
import StemCore

// MARK: - PreflightView

/// Pre-flight step (design F4): thumbnail + title + duration, the inline
/// probe + disk check, the long-video confirm sheet (estimate > 3 min), and
/// the iCloud download modal (shown during the split stream's
/// `.phase(.downloading)`, with size + expected time, eng E7).
public struct PreflightView: View {

    @ObservedObject var model: PreflightModel
    let thumbnail: Image?
    let onCancel: () -> Void
    let onProceed: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.unit4) {
            Text("Ready to split")
                .font(.title.bold())
                .foregroundStyle(Color.ssTextPrimary)
                .padding(.top, DesignSystem.Spacing.unit5)

            VideoSummaryCard(
                title: model.video.title,
                duration: model.video.duration,
                thumbnail: thumbnail
            )

            probeArea

            if model.lowPowerAdjusted {
                Label("Low Power Mode is on — this may take longer than estimated.",
                      systemImage: "battery.25")
                    .font(.footnote)
                    .foregroundStyle(Color.ssTextSecondary)
            }

            if case .blocked = model.probe {
                Button {
                    onCancel()
                } label: {
                    Text("Pick another video")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                            .fill(Color.ssAccent))
                        .foregroundStyle(Color.ssGround)
                }
            }

            Spacer()
        }
        .padding(.horizontal, DesignSystem.Spacing.unit5)
        .task {
            // Inline probe + disk check are instant (F4); auto-proceed when
            // allowed (short videos start straight away; the long-video sheet
            // fires inside proceedFromPreflight when the estimate > 3 min).
            await model.check()
            onProceed()
        }
        .confirmationDialog(
            "About ~\(estimatedMinutes) min to process.",
            isPresented: Binding(
                get: { model.showsLongVideoConfirm },
                set: { shown in if !shown { model.declineLongVideo() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Continue") {
                model.confirmLongVideo()
                onProceed()
            }
            Button("Cancel", role: .cancel) {
                model.declineLongVideo()
            }
        } message: {
            Text("This video is long. Continue?")
        }
    }

    private var estimatedMinutes: Int {
        max(1, Int((model.estimate.seconds / 60).rounded()))
    }

    @ViewBuilder
    private var probeArea: some View {
        switch model.probe {
        case .checking:
            HStack(spacing: DesignSystem.Spacing.unit2) {
                ProgressView()
                    .tint(Color.ssAccent)
                Text("Checking this video…")
                    .font(.subheadline)
                    .foregroundStyle(Color.ssTextSecondary)
            }
            .padding(.vertical, DesignSystem.Spacing.unit2)
        case .allowed:
            Label("Video checked — audio found and there's room for the split.",
                  systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(Color.ssAccent)
        case .blocked(let error):
            Label {
                Text(error.userMessage ?? "This video can't be processed")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.subheadline)
            .foregroundStyle(Color.ssTextPrimary)
        }
    }
}

// MARK: - VideoSummaryCard (F1/F2 shared video header facts)

struct VideoSummaryCard: View {

    let title: String
    let duration: TimeInterval
    let thumbnail: Image?

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.unit2) {
            Group {
                if let thumbnail {
                    thumbnail
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                            .fill(Color.ssTextSecondary.opacity(0.22))
                        Image(systemName: "video")
                            .foregroundStyle(Color.ssTextSecondary)
                    }
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.unit) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.ssTextPrimary)
                    .lineLimit(1)
                Text(formatClock(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.ssTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.unit2)
        .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
            .fill(Color.ssTextSecondary.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(formatClock(duration))")
    }
}

// MARK: - iCloudDownloadModal (F4 / E7)

/// Modal shown over processing while the engine streams the iCloud download:
/// progress, size (when known), expected time, Cancel.
public struct iCloudDownloadModal: View {

    let videoTitle: String
    let phase: PipelinePhase?
    let progress: Double
    let eta: ETAEstimate?
    let totalBytes: Int64?
    let onCancel: () -> Void

    public var body: some View {
        VStack(spacing: DesignSystem.Spacing.unit3) {
            ProgressRing(progress: progress)
                .frame(width: 64, height: 64)
                .overlay {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.ssTextPrimary)
                }

            Text("Downloading from iCloud")
                .font(.headline)
                .foregroundStyle(Color.ssTextPrimary)

            Text(videoTitle)
                .font(.subheadline)
                .foregroundStyle(Color.ssTextSecondary)
                .lineLimit(1)

            Text(downloadDetailLine)
                .font(.caption)
                .foregroundStyle(Color.ssTextSecondary)

            Button {
                onCancel()
            } label: {
                Text("Cancel")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                        .fill(Color.ssAccent))
                    .foregroundStyle(Color.ssGround)
            }
            .accessibilityLabel("Cancel download")
        }
        .padding(DesignSystem.Spacing.unit4)
        .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.sheet)
            .fill(Color.ssGround))
        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.sheet)
            .strokeBorder(Color.ssTextSecondary.opacity(0.3), lineWidth: 1))
        .interactiveDismissDisabled()
    }

    /// Size + expected time (E7). Either half is dropped when unknown.
    private var downloadDetailLine: String {
        var parts: [String] = []
        if let totalBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
        }
        if let eta {
            parts.append("about \(formatClock(eta.seconds))")
        }
        return parts.isEmpty ? "Preparing download…" : parts.joined(separator: " · ")
    }
}
