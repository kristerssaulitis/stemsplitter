import SwiftUI
import StemCore

// MARK: - ResultView

/// The mixer: video preview, quick presets, one lane per stem (tap icon = mute,
/// S = solo, drag = seek), transport with pitch/speed, and a Share menu that
/// renders exactly what you hear.
public struct ResultView: View {

    @ObservedObject var model: ResultModel
    let onNewSplit: () -> Void

    @StateObject private var video: VideoSync
    @State private var shareRequest: ShareRequest?
    @State private var confirmLeave = false
    @State private var toastDismissTask: Task<Void, Never>?

    init(model: ResultModel, onNewSplit: @escaping () -> Void) {
        self.model = model
        self.onNewSplit = onNewSplit
        _video = StateObject(wrappedValue: VideoSync(url: model.sourceURL))
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.isPlaying)) { _ in
            let position = model.position
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 14) {
                        if model.hasVideo {
                            VideoSurface(player: video.player)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .frame(maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
                                .onTapGesture { model.togglePlay() }
                        }
                        presets
                        lanes(position: position)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.unit2)
                    .padding(.bottom, DesignSystem.Spacing.unit2)
                }
                .scrollBounceBehavior(.basedOnSize)
                transport(position: position)
            }
            .onChange(of: position) { _, p in
                model.tick()
                if model.hasVideo { video.update(position: p, playing: model.isPlaying, rate: model.rate) }
            }
        }
        .onChange(of: model.isPlaying) { _, playing in
            if model.hasVideo { video.update(position: model.position, playing: playing, rate: model.rate) }
        }
        .onDisappear { model.stop() }
        .overlay { if let kind = model.exporting { exportOverlay(kind) } }
        .overlay(alignment: .bottom) { if model.exportToastVisible { exportToast } }
        .sheet(item: $shareRequest) { request in
            ShareExportView(items: request.items) { model.exportFinished() }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Start a new split?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("New Split", role: .destructive, action: onNewSplit)
        } message: {
            Text("Export anything you want to keep first — this split won't be saved.")
        }
        .onChange(of: model.exportToastVisible) { _, visible in
            guard visible else { return }
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            toastDismissTask?.cancel()
            toastDismissTask = Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                model.dismissExportToast()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { confirmLeave = true } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.ssSurface))
            }
            .accessibilityLabel("New split")

            VStack(spacing: 1) {
                Text(model.title)
                    .font(.headline)
                    .foregroundStyle(Color.ssTextPrimary)
                    .lineLimit(1)
                Text("\(formatClock(model.duration)) · split in \(Int(model.splitSeconds.rounded()))s")
                    .font(.caption)
                    .foregroundStyle(Color.ssTextSecondary)
            }
            .frame(maxWidth: .infinity)

            shareMenu
        }
        .foregroundStyle(Color.ssTextPrimary)
        .padding(.horizontal, DesignSystem.Spacing.unit2)
        .padding(.vertical, 8)
    }

    private var shareMenu: some View {
        Menu {
            Section("What you hear") {
                Button { share(.mix) } label: {
                    Label("Export Mix (WAV)", systemImage: "waveform")
                }
                if model.hasVideo {
                    Button { share(.video) } label: {
                        Label("Export Video with Mix", systemImage: "film")
                    }
                }
            }
            Section("Stems") {
                Button { share(.stems) } label: {
                    Label("All Stems", systemImage: "square.stack.3d.up")
                }
                ForEach(model.tracks.map(\.name) + (model.outputs.stems.contains { $0.name == "instrumental" } ? ["instrumental"] : []), id: \.self) { name in
                    Button { share(.stem(name)) } label: {
                        Label(StemStyle.title(name), systemImage: StemStyle.icon(name))
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.ssAccent))
                .foregroundStyle(Color.ssGround)
        }
        .accessibilityLabel("Share or export")
    }

    private func share(_ kind: ResultModel.ExportKind) {
        Task {
            let urls = await model.export(kind)
            if !urls.isEmpty { shareRequest = ShareRequest(items: urls) }
        }
    }

    // MARK: Presets

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availablePresets) { preset in
                    let active = model.activePreset == preset
                    Button { withAnimation(.easeOut(duration: 0.15)) { model.apply(preset) } } label: {
                        Text(preset.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(active ? Color.ssAccent : Color.ssSurface))
                            .foregroundStyle(active ? Color.ssGround : Color.ssTextPrimary)
                    }
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
    }

    private var availablePresets: [ResultModel.Preset] {
        let names = Set(model.tracks.map(\.name))
        return ResultModel.Preset.allCases.filter { p in
            switch p {
            case .noDrums, .drumsOnly: names.contains("drums")
            default: true
            }
        }
    }

    // MARK: Lanes

    private func lanes(position: Double) -> some View {
        let progress = model.duration > 0 ? position / model.duration : 0
        return VStack(spacing: 8) {
            ForEach(model.tracks) { track in
                StemLane(
                    track: track,
                    progress: progress,
                    audible: model.isAudible(track.name),
                    muted: model.muted.contains(track.name),
                    soloed: model.soloed.contains(track.name),
                    onMute: { model.toggleMute(track.name) },
                    onSolo: { model.toggleSolo(track.name) },
                    onSeek: { model.seek(toFraction: $0) }
                )
            }
        }
    }

    // MARK: Transport

    private func transport(position: Double) -> some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { model.duration > 0 ? position / model.duration : 0 },
                    set: { model.seek(toFraction: $0) }),
                in: 0...1
            )
            .accessibilityLabel("Playback position")
            .accessibilityValue(formatClock(position))

            HStack {
                Text(formatClock(position))
                Spacer()
                Text("-" + formatClock(max(0, model.duration - position)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.ssTextSecondary)
            .padding(.top, -6)

            HStack {
                pitchMenu
                Spacer()
                Button { model.skip(-10) } label: {
                    Image(systemName: "gobackward.10").font(.title2)
                }
                .accessibilityLabel("Back 10 seconds")
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color.ssTextPrimary))
                        .foregroundStyle(Color.ssGround)
                }
                .padding(.horizontal, 18)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                Button { model.skip(10) } label: {
                    Image(systemName: "goforward.10").font(.title2)
                }
                .accessibilityLabel("Forward 10 seconds")
                Spacer()
                speedMenu
            }
            .foregroundStyle(Color.ssTextPrimary)
        }
        .padding(.horizontal, DesignSystem.Spacing.unit2)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.white.opacity(0.04).ignoresSafeArea(edges: .bottom))
    }

    private var pitchMenu: some View {
        Menu {
            Picker("Pitch", selection: $model.pitch) {
                ForEach((-6...6).reversed(), id: \.self) { st in
                    Text(st == 0 ? "Original key" : String(format: abs(st) == 1 ? "%+d semitone" : "%+d semitones", st)).tag(st)
                }
            }
        } label: {
            TransportChip(icon: "tuningfork", text: model.pitch == 0 ? "Key" : String(format: "%+d", model.pitch),
                          active: model.pitch != 0)
        }
        .accessibilityLabel("Pitch")
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: $model.rate) {
                ForEach([1.5, 1.25, 1.1, 1.0, 0.9, 0.75, 0.5], id: \.self) { r in
                    Text(r == 1 ? "Normal speed" : "\(Int(r * 100))%").tag(r)
                }
            }
        } label: {
            TransportChip(icon: "speedometer", text: model.rate == 1 ? "1×" : "\(Int(model.rate * 100))%",
                          active: model.rate != 1)
        }
        .accessibilityLabel("Speed")
    }

    // MARK: Export feedback

    private func exportOverlay(_ kind: ResultModel.ExportKind) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: model.exportProgress)
                    .tint(.ssAccent)
                    .frame(width: 200)
                Text(exportTitle(kind))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ssTextPrimary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignSystem.Radius.sheet))
        }
    }

    private func exportTitle(_ kind: ResultModel.ExportKind) -> String {
        switch kind {
        case .mix: "Rendering mix…"
        case .video: "Making video…"
        case .stems, .stem: "Preparing stems…"
        }
    }

    private var exportToast: some View {
        Label("Exported", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.ssTextPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 150)
            .transition(.opacity)
    }
}

// MARK: - StemLane

struct StemLane: View {
    let track: StemTrack
    let progress: Double
    let audible: Bool
    let muted: Bool
    let soloed: Bool
    let onMute: () -> Void
    let onSolo: () -> Void
    let onSeek: (Double) -> Void

    var body: some View {
        let color = StemStyle.color(track.name)
        HStack(spacing: 10) {
            Button(action: onMute) {
                Image(systemName: muted ? "speaker.slash.fill" : StemStyle.icon(track.name))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(color.opacity(audible ? 0.2 : 0.07)))
                    .foregroundStyle(audible ? color : Color.ssTextSecondary)
            }
            .accessibilityLabel(muted ? "Unmute \(StemStyle.title(track.name))" : "Mute \(StemStyle.title(track.name))")

            VStack(alignment: .leading, spacing: 2) {
                Text(StemStyle.title(track.name))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(audible ? Color.ssTextPrimary : Color.ssTextSecondary)
                GeometryReader { geo in
                    StemWaveform(peaks: track.peaks, color: color, progress: progress, audible: audible)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.ssTextPrimary)
                                .frame(width: 1.5)
                                .offset(x: geo.size.width * progress)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            onSeek(v.location.x / max(geo.size.width, 1))
                        })
                }
            }
            .frame(height: 50)

            Button(action: onSolo) {
                Text("S")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(soloed ? Color.yellow : Color.ssSurface))
                    .foregroundStyle(soloed ? Color.ssGround : Color.ssTextSecondary)
            }
            .accessibilityLabel(soloed ? "Unsolo \(StemStyle.title(track.name))" : "Solo \(StemStyle.title(track.name))")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.card).fill(Color.ssSurface))
    }
}

private struct TransportChip: View {
    let icon: String
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).monospacedDigit()
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Capsule().fill(active ? Color.ssAccent.opacity(0.2) : Color.ssSurface))
        .foregroundStyle(active ? Color.ssAccent : Color.ssTextPrimary)
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
