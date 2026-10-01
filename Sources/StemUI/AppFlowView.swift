import SwiftUI
import PhotosUI
import AVFoundation
import StemCore

// MARK: - AppFlowView

/// The single-flow UI (plan: picker → pre-flight → processing → result).
/// Thin over `AppFlowModel`: routing, iOS-only device affordances (idle timer,
/// landing haptic), and the F9a/F12 flow-level notices.
public struct AppFlowView: View {

    @StateObject private var model: AppFlowModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var thumbnail: Image?
    @State private var importingFile = false
    @State private var importing = false

    public init(engine: any StemEngineProtocol) {
        _model = StateObject(wrappedValue: AppFlowModel(engine: engine))
    }

    public var body: some View {
        ZStack {
            Color.ssGround.ignoresSafeArea()
            content
            if importing {
                Color.black.opacity(0.4).ignoresSafeArea()
                ProgressView("Preparing…")
                    .tint(.ssAccent)
                    .foregroundStyle(Color.ssTextPrimary)
                    .padding(DesignSystem.Spacing.unit3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignSystem.Radius.card))
            }
        }
        .preferredColorScheme(.dark)
        .tint(.ssAccent)
        .animation(.easeInOut(duration: 0.25), value: model.route)
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.audio, .movie]) { result in
            guard case .success(let url) = result else { return }
            Task { await importFile(url) }
        }
        .alert(
            "Split interrupted",
            isPresented: Binding(
                get: { model.startAgain != nil },
                set: { _ in }
            ),
            presenting: model.startAgain
        ) { state in
            Button("Start again") { model.startAgainConfirmed() }
            Button("Discard", role: .destructive) { model.startAgainDiscarded() }
        } message: { state in
            Text("\(state.videoTitle) didn't finish splitting.")
        }
        .onChange(of: model.route) { _, route in
            handleRouteChange(route)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.route {
        case .picker:
            HomeView(
                showsExportFirstNotice: model.showsExportFirstNotice,
                selection: $pickerItem,
                onImportFile: { importingFile = true }
            )
            .onChange(of: pickerItem) { _, item in
                Task { await importPicked(item) }
            }
        case .preflight:
            if let preflight = model.preflight {
                PreflightView(
                    model: preflight,
                    thumbnail: thumbnail,
                    onCancel: { model.cancelPreflight() },
                    onProceed: { model.proceedFromPreflight() }
                )
                .transition(.opacity)
            }
        case .processing:
            if let processing = model.processing {
                ProcessingView(
                    model: processing,
                    thumbnail: thumbnail,
                    onAbandon: { model.abandonSplit() },
                    onTryAgain: { model.tryAgain() }
                )
                .transition(.opacity)
            }
        case .result:
            if let result = model.result {
                ResultView(model: result, onNewSplit: { model.newSplit() })
                    .transition(.opacity)
            }
        }
    }

    private func handleRouteChange(_ route: FlowRoute) {
        #if os(iOS)
        // Foreground-only processing (plan constraint): keep the display awake
        // for the whole split; device auto-lock must not interrupt long splits.
        UIApplication.shared.isIdleTimerDisabled = (route == .processing)
        if route == .result {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        #endif
        if route == .picker {
            pickerItem = nil
        }
    }

    // MARK: Import glue (app-layer tmp copy, eng E5)

    private func importPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        importing = true
        defer { importing = false }
        guard let imported = await VideoImporter.importVideo(item) else { return }
        thumbnail = imported.thumbnail
        model.pick(imported.video)
    }

    private func importFile(_ url: URL) async {
        importing = true
        defer { importing = false }
        guard let imported = await VideoImporter.importFile(url) else { return }
        thumbnail = imported.thumbnail
        model.pick(imported.video)
    }
}

// MARK: - Home (F1: empty state)

struct HomeView: View {

    let showsExportFirstNotice: Bool
    @Binding var selection: PhotosPickerItem?
    let onImportFile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.ssAccent)
                Text("StemSplitter")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.ssTextPrimary)
                Spacer()
            }
            .padding(.top, DesignSystem.Spacing.unit2)

            Spacer()

            StemStack()
                .padding(.bottom, DesignSystem.Spacing.unit4)

            Text("Split any video\ninto stems")
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.ssTextPrimary)
            Text("Vocals, drums, bass and the rest — separated on your phone in seconds.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.ssTextSecondary)
                .padding(.top, DesignSystem.Spacing.unit)
                .padding(.horizontal, DesignSystem.Spacing.unit2)

            if showsExportFirstNotice {
                Label("Export what you need — splits clear when the app restarts.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.ssAccent)
                    .padding(.vertical, DesignSystem.Spacing.unit)
                    .padding(.horizontal, DesignSystem.Spacing.unit2)
                    .background(Capsule().fill(Color.ssAccent.opacity(0.12)))
                    .padding(.top, DesignSystem.Spacing.unit3)
            }

            Spacer()

            VStack(spacing: 12) {
                PhotosPicker(selection: $selection, matching: .videos) {
                    Label("Choose Video", systemImage: "play.rectangle.on.rectangle")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Choose a video from your library")

                Button(action: onImportFile) {
                    Label("Import Audio File", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())

                Label("Runs on this iPhone. Nothing is uploaded.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.ssTextSecondary)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.unit3)
        .padding(.bottom, DesignSystem.Spacing.unit2)
    }
}

/// Four stem lanes as the hero graphic: the product in one picture.
private struct StemStack: View {
    private let stems = ["vocals", "drums", "bass", "other"]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(stems.enumerated()), id: \.offset) { index, stem in
                HStack(spacing: 10) {
                    Image(systemName: StemStyle.icon(stem))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(StemStyle.color(stem).opacity(0.18)))
                        .foregroundStyle(StemStyle.color(stem))
                    DecorativeWave(seed: index, color: StemStyle.color(stem))
                        .frame(height: 26)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 300)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.ssSurface))
        .accessibilityHidden(true)
    }
}

private struct DecorativeWave: View {
    let seed: Int
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let bars = Int(size.width / 4)
            var path = Path()
            for i in 0..<bars {
                let x = Double(i)
                let v = abs(sin(x * 0.37 + Double(seed) * 1.7) * cos(x * 0.11 + Double(seed)))
                let h = max(2, v * size.height)
                path.addRoundedRect(in: CGRect(x: CGFloat(i) * 4, y: (size.height - h) / 2, width: 2, height: h),
                                    cornerSize: CGSize(width: 1, height: 1))
            }
            ctx.fill(path, with: .color(color.opacity(0.85)))
        }
    }
}

// MARK: - VideoImporter (PhotosPicker → PickedVideo + thumbnail)

enum VideoImporter {

    /// Transferable that receives a copy of the picked movie file (eng E5 tmp
    /// projection; the whole video is copied to tmp before splitting).
    private struct ImportedMovie: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .movie) { movie in
                SentTransferredFile(movie.url)
            } importing: { received in
                let originalExtension = URL(fileURLWithPath: received.file.lastPathComponent).pathExtension
                let target = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(originalExtension.isEmpty ? "mov" : originalExtension)
                try? FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: received.file, to: target)
                return ImportedMovie(url: target)
            }
        }
    }

    struct Imported {
        var video: PickedVideo
        var thumbnail: Image?
    }

    static func importVideo(_ item: PhotosPickerItem) async -> Imported? {
        guard let movie = try? await item.loadTransferable(type: ImportedMovie.self) else {
            return nil
        }
        let url = movie.url
        let asset = AVURLAsset(url: url)

        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let metadata = (try? await asset.load(.metadata)) ?? []
        // Picked movies arrive as UUID-named tmp files: name them by date instead.
        var title = metadata.first { $0.commonKey == .commonKeyTitle }?.stringValue ?? ""
        if title.isEmpty {
            let created = try? await asset.load(.creationDate)?.load(.dateValue)
            title = "Video · " + (created ?? Date()).formatted(date: .abbreviated, time: .shortened)
        }

        var size: Int64?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            size = attrs[.size] as? Int64
        }

        return Imported(
            video: PickedVideo(
                id: item.itemIdentifier ?? UUID().uuidString,
                title: title.isEmpty ? "Selected video" : title,
                duration: max(0, duration),
                localURL: url,
                fileSizeBytes: size,
                isCloudBacked: false // the transferable copy already materialized the file
            ),
            thumbnail: makeThumbnail(asset: asset)
        )
    }

    /// Files app import: copy out of the security scope into tmp, like the picker path.
    static func importFile(_ url: URL) async -> Imported? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            return nil
        }
        let asset = AVURLAsset(url: target)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? nil
        return Imported(
            video: PickedVideo(
                id: target.path,
                title: url.deletingPathExtension().lastPathComponent,
                duration: max(0, duration.isFinite ? duration : 0),
                localURL: target,
                fileSizeBytes: size,
                isCloudBacked: false),
            thumbnail: makeThumbnail(asset: asset))
    }

    private static func makeThumbnail(asset: AVAsset) -> Image? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        guard
            let cgImage = try? generator.copyCGImage(
                at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        else { return nil }
        #if os(iOS)
        return Image(uiImage: UIImage(cgImage: cgImage))
        #else
        return Image(nsImage: NSImage(cgImage: cgImage, size: .zero))
        #endif
    }
}
