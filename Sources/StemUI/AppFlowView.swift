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

    public init(engine: any StemEngineProtocol, makeAudio: @escaping @MainActor () -> any AudioControlling) {
        _model = StateObject(wrappedValue: AppFlowModel(engine: engine, makeAudio: makeAudio))
    }

    public var body: some View {
        ZStack {
            Color.ssGround.ignoresSafeArea()
            content
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
            PickerHero(
                showsExportFirstNotice: model.showsExportFirstNotice,
                pickerDisabled: false,
                selection: $pickerItem
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
            // Success haptic when the split lands (CEO-2).
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        #endif
        if route == .picker {
            pickerItem = nil
        }
    }

    // MARK: PhotosPicker import glue (app-layer tmp copy, eng E5)

    private func importPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let imported = await VideoImporter.importVideo(item) else {
            return // importer surfaced nothing usable; picker stays available
        }
        thumbnail = imported.thumbnail
        model.pick(imported.video)
    }
}

// MARK: - Picker hero (F1: empty state)

/// Wordmark top; centered 170pt picker button; privacy sub-copy. No device
/// hedge line in v1 (2026-10-01 addendum).
struct PickerHero: View {

    let showsExportFirstNotice: Bool
    let pickerDisabled: Bool
    @Binding var selection: PhotosPickerItem?

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.unit4) {
            Text("StemSplitter")
                .font(.largeTitle.bold())
                .foregroundStyle(Color.ssTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, DesignSystem.Spacing.unit5)

            Spacer()

            PhotosPicker(selection: $selection, matching: .videos) {
                VStack(spacing: DesignSystem.Spacing.unit2) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 44))
                    Text("Pick a video")
                        .font(.title3.weight(.semibold))
                    Text("from your library")
                        .font(.subheadline)
                        .foregroundStyle(Color.ssTextSecondary)
                }
                .foregroundStyle(Color.ssTextPrimary)
                .frame(width: 170, height: 170)
                .background(Circle().fill(Color.ssAccent.opacity(0.14)))
                .overlay(Circle().strokeBorder(Color.ssAccent, lineWidth: 1.5))
            }
            .disabled(pickerDisabled)
            .accessibilityLabel("Pick a video from your library")

            Text("Nothing uploads. Nothing leaves your phone.")
                .font(.footnote)
                .foregroundStyle(Color.ssTextSecondary)

            if showsExportFirstNotice {
                Text("Export first — splits don't persist.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.ssAccent)
                    .padding(.vertical, DesignSystem.Spacing.unit)
                    .padding(.horizontal, DesignSystem.Spacing.unit2)
                    .background(
                        Capsule().fill(Color.ssAccent.opacity(0.14))
                    )
                    .accessibilityLabel("Export first. Splits don't persist.")
            }

            Spacer()
        }
        .padding(.horizontal, DesignSystem.Spacing.unit5)
        .padding(.bottom, DesignSystem.Spacing.unit4)
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
        let title = metadata.first { $0.commonKey == .commonKeyTitle }?.stringValue
            ?? url.deletingPathExtension().lastPathComponent

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
