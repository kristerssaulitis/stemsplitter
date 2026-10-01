import SwiftUI
import StemCore

// MARK: - ResultView

/// Result screen: title + "split in Xs", segmented Original / Vocals /
/// Instrumental selector over a shared position-preserving transport with
/// waveform scrub (F10), two stem cards with mini waveforms from streamed
/// peaks, Share stems (primary), long-press card → share that stem (CEO-3),
/// and "New split" with the F9a export-first notice handled by the flow.
public struct ResultView: View {

    @ObservedObject var model: ResultModel
    let onNewSplit: () -> Void

    @State private var shareRequest: ShareRequest?
    @State private var toastDismissTask: Task<Void, Never>?

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.unit3) {
            header
            sourceSelector
            waveformScrub
            TransportControls(model: model)
            stemCards
            shareButton
            newSplitButton
        }
        .padding(.horizontal, DesignSystem.Spacing.unit5)
        .padding(.top, DesignSystem.Spacing.unit4)
        .padding(.bottom, DesignSystem.Spacing.unit3)
        .overlay(alignment: .bottom) {
            if model.exportToastVisible {
                exportToast
            }
        }
        .sheet(item: $shareRequest) { request in
            ShareExportView(items: request.items) {
                model.exportFinished()
            }
        }
        .onChange(of: model.exportToastVisible) { _, visible in
            guard visible else { return }
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            // Brief confirmation toast (F6): auto-dismiss after ~2.5 s.
            toastDismissTask?.cancel()
            toastDismissTask = Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                model.dismissExportToast()
            }
        }
    }

    // MARK: Header ("title" + "split in Xs")

    private var header: some View {
        Text("Split in \(Int(model.splitSeconds.rounded()))s")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.ssTextPrimary)
            .padding(.top, DesignSystem.Spacing.unit2)
    }

    // MARK: Source selector (F10)

    private var sourceSelector: some View {
        Picker("Source", selection: Binding(
            get: { model.selected },
            set: { model.select($0) }
        )) {
            ForEach(ResultModel.Source.allCases) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .tint(Color.ssAccent)
        .accessibilityLabel("Source")
    }

    // MARK: Waveform scrub (F10 tap+drag; position preserved across switches)

    private var waveformScrub: some View {
        WaveformView(
            peaks: model.peaks,
            fill: model.duration > 0 ? model.position / model.duration : 0,
            interactive: true
        ) { fraction in
            model.scrub(toFraction: fraction)
        }
        .frame(height: 72)
        .padding(DesignSystem.Spacing.unit2)
        .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
            .fill(Color.ssTextSecondary.opacity(0.08)))
    }

    // MARK: Stem cards (mini waveforms from streamed peaks; long-press share)

    private var stemCards: some View {
        VStack(spacing: DesignSystem.Spacing.unit3) {
            stemCard(.vocals, title: "Vocals")
            stemCard(.instrumental, title: "Instrumental")
        }
    }

    private func stemCard(_ source: ResultModel.Source, title: String) -> some View {
        let payload = model.sharePayload(for: source)
        return VStack(spacing: DesignSystem.Spacing.unit2) {
            HStack(spacing: DesignSystem.Spacing.unit2) {
                WaveformView(peaks: model.peaks, fill: 1)
                    .frame(height: 32)
                    .frame(maxWidth: .infinity)

                Button {
                    model.playSource(source)
                } label: {
                    Image(systemName: cardPlayIcon(for: source))
                        .font(.title3)
                        .foregroundStyle(Color.ssAccent)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Play \(title)")
            }

            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.ssTextPrimary)
                Spacer()
                Text("WAV · 44.1 kHz · 24-bit")
                    .font(.caption)
                    .foregroundStyle(Color.ssTextSecondary)
            }
        }
        .padding(DesignSystem.Spacing.unit2)
        .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
            .fill(Color.ssTextSecondary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { model.playSource(source) }
        // CEO-3: long-press the card to share just that stem's WAV.
        .contextMenu {
            if !payload.isEmpty {
                Button {
                    shareRequest = ShareRequest(items: payload)
                } label: {
                    Label("Share \(title)", systemImage: "square.and.arrow.up")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) stem, WAV 44.1 kilohertz, 24-bit")
    }

    private func cardPlayIcon(for source: ResultModel.Source) -> String {
        (model.selected == source && model.isPlaying) ? "pause.circle" : "play.circle"
    }

    // MARK: Share stems (primary) + New split (F9a)

    private var shareButton: some View {
        Button {
            shareRequest = ShareRequest(items: model.shareStemsPayload)
        } label: {
            Label("Share stems", systemImage: "square.and.arrow.up")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.card)
                    .fill(Color.ssAccent))
                .foregroundStyle(Color.ssGround)
        }
        .accessibilityLabel("Share both stems")
    }

    private var newSplitButton: some View {
        Button(action: onNewSplit) {
            Text("New split")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .foregroundStyle(Color.ssTextSecondary)
        .accessibilityHint("Splits don't persist. Export first to keep the files.")
    }

    // MARK: Export toast (F6)

    private var exportToast: some View {
        Label("Export complete — your WAVs are shared.", systemImage: "checkmark.circle")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.ssTextPrimary)
            .padding(.horizontal, DesignSystem.Spacing.unit3)
            .padding(.vertical, DesignSystem.Spacing.unit2)
            .background(Capsule().fill(Color.ssTextSecondary.opacity(0.24)))
            .padding(.bottom, DesignSystem.Spacing.unit3)
            .transition(.opacity)
            .accessibilityLabel("Export complete")
    }
}

// MARK: - Share plumbing

/// Identifiable wrapper so `.sheet(item:)` can present a share request.
struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [URL]
}

/// Export surface with completion detection (F6 toast needs the completed
/// callback, which iOS 17 `ShareLink` lacks): UIActivityViewController on iOS,
/// a plain ShareLink on macOS (compile-only path; v1 is iPhone-only).
struct ShareExportView: View {

    let items: [URL]
    let onCompleted: () -> Void

    var body: some View {
        #if os(iOS)
        ShareSheet(items: items, onCompleted: onCompleted)
        #else
        VStack(spacing: DesignSystem.Spacing.unit3) {
            ShareLink(items: items) {
                Text("Share")
            }
            .font(.headline)
            Button("Done") { onCompleted() }
        }
        .padding(DesignSystem.Spacing.unit4)
        #endif
    }
}

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {

    let items: [URL]
    let onCompleted: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if completed {
                onCompleted()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
