import SwiftUI
import StemLink

// MARK: - LinkDownloadModel
//
// iOS port of stemsplitter-mac's AppModel download queue: paste a Spotify or
// YouTube link, the native StemLink fetcher pulls the audio (no spotdl
// subprocess on iOS), and finished tracks split through the normal flow.

@MainActor
public final class LinkDownloadModel: ObservableObject {

    public struct Job: Identifiable {
        public enum State: Equatable {
            case waiting
            case resolving
            case downloading(fraction: Double?, bytesDone: Int64, bytesTotal: Int64?)
            case ready
            case failed(String)
            case cancelled

            public var isSettled: Bool {
                switch self {
                case .ready, .failed, .cancelled: return true
                default: return false
                }
            }
        }

        public let id = UUID()
        public let ref: TrackRef
        public var state: State = .waiting
        public var audio: FetchedAudio?

        public init(ref: TrackRef) {
            self.ref = ref
        }
    }

    public enum Phase: Equatable {
        case idle
        case resolving
        case listing
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var jobs: [Job] = []
    @Published public var linkText = ""
    @Published public private(set) var showsInvalidNotice = false
    @Published public private(set) var showsDuplicateNotice = false
    @Published public private(set) var resolveError: String?

    /// Called when a downloaded track should enter the split flow. The model
    /// auto-fires it for single-track links; collections split per row.
    public var onSplit: ((FetchedAudio) -> Void)?

    public let fetcher = AudioFetcher()

    private var downloadTask: Task<Void, Never>?
    private var activeJobID: UUID?
    private var pendingLink: MusicLink?
    private var armsAutoSplit = false

    public init() {}

    /// Session storage for fetched audio (tmp — like splits, downloads don't persist).
    static var downloadsURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StemLinkDownloads", isDirectory: true)
    }

    public var canSubmit: Bool { MusicLink.parse(linkText) != nil }

    // MARK: Submission

    public func submit() {
        guard let link = MusicLink.parse(linkText) else {
            showsInvalidNotice = true
            return
        }
        if jobs.contains(where: { $0.state == .waiting || $0.state == .resolving }) || activeJobID != nil {
            // One link at a time on iOS (mac enqueues; the single-flow app queues nothing).
            showsDuplicateNotice = true
            return
        }
        showsInvalidNotice = false
        showsDuplicateNotice = false
        resolveError = nil
        pendingLink = link
        phase = .resolving
        linkText = ""
        Task { await resolvePending() }
    }

    private func resolvePending() async {
        guard let link = pendingLink else { return }
        pendingLink = nil
        do {
            let resolved = try await fetcher.resolve(link)
            switch resolved {
            case .track(let ref):
                armsAutoSplit = true
                jobs = [Job(ref: ref)]
            case .collection(_, let tracks):
                armsAutoSplit = false
                jobs = tracks.map(Job.init(ref:))
            }
            phase = .listing
            pump()
        } catch is CancellationError {
            phase = .idle
        } catch let error as FetchError {
            phase = .idle
            resolveError = error.errorDescription
        } catch {
            phase = .idle
            resolveError = error.localizedDescription
        }
    }

    // MARK: Row actions

    public func splitJob(_ job: Job) {
        guard let audio = job.audio else { return }
        onSplit?(audio)
    }

    public func cancelJob(_ job: Job) {
        if job.id == activeJobID {
            downloadTask?.cancel()
        } else if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index].state = .cancelled
        }
    }

    public func retryJob(_ job: Job) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        guard jobs[index].state.isSettled else { return }
        jobs[index].state = .waiting
        pump()
    }

    public func removeJob(_ job: Job) {
        if job.id == activeJobID { downloadTask?.cancel() }
        jobs.removeAll { $0.id == job.id }
        if jobs.isEmpty && phase == .listing {
            phase = .idle
        }
    }

    public func reset() {
        downloadTask?.cancel()
        downloadTask = nil
        activeJobID = nil
        pendingLink = nil
        jobs = []
        phase = .idle
        resolveError = nil
        showsInvalidNotice = false
        showsDuplicateNotice = false
    }

    // MARK: Serial download pump (mac's pumpDownloads, struct-jobs flavor)

    private func pump() {
        guard activeJobID == nil, let index = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        let id = jobs[index].id
        activeJobID = id
        downloadTask = Task { await run(jobID: id) }
    }

    private func run(jobID: UUID) async {
        defer {
            activeJobID = nil
            downloadTask = nil
            pump()
        }
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let ref = jobs[index].ref
        jobs[index].state = .resolving
        do {
            let audio = try await fetcher.download(ref, toDirectory: Self.downloadsURL) {
                [weak self] fraction, done, total in
                Task { @MainActor in
                    self?.updateJob(jobID) { job in
                        if !job.state.isSettled {
                            job.state = .downloading(fraction: fraction, bytesDone: done, bytesTotal: total)
                        }
                    }
                }
            }
            updateJob(jobID) { job in
                job.state = .ready
                job.audio = audio
            }
            if armsAutoSplit {
                armsAutoSplit = false
                jobs.removeAll { $0.id == jobID }
                if jobs.isEmpty { phase = .idle }
                onSplit?(audio)
            }
        } catch is CancellationError {
            updateJob(jobID) { $0.state = .cancelled }
        } catch let error as FetchError {
            updateJob(jobID) { $0.state = .failed(error.errorDescription ?? "Download failed.") }
        } catch {
            updateJob(jobID) { $0.state = .failed(error.localizedDescription) }
        }
    }

    private func updateJob(_ id: UUID, _ mutate: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    /// Called by the sheet as the user types; clears the inline notices.
    func linkTextDidChange() {
        showsInvalidNotice = false
        showsDuplicateNotice = false
    }
}

// MARK: - LinkDownloadSheet

public struct LinkDownloadSheet: View {
    @ObservedObject public private(set) var model: LinkDownloadModel
    @Environment(\.dismiss) private var dismiss

    public init(model: LinkDownloadModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.unit3) {
                    Text("Spotify link (track, album, playlist) or YouTube video. The matching audio is fetched as AAC, then split on-device like any imported file.")
                        .font(.callout)
                        .foregroundStyle(Color.ssTextSecondary)

                    HStack(spacing: 8) {
                        TextField("Paste a Spotify or YouTube link", text: $model.linkText)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                        #endif
                            .onSubmit { model.submit() }
                            .onChange(of: model.linkText) { _, _ in
                                model.linkTextDidChange()
                            }
                        Button("Add", action: { model.submit() })
                            .disabled(!model.canSubmit)
                    }

                    if model.showsInvalidNotice {
                        Text("That doesn't look like a Spotify or YouTube link.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if model.showsDuplicateNotice {
                        Text("Already working on a link — one at a time for now.")
                            .font(.caption)
                            .foregroundStyle(Color.ssTextSecondary)
                    }
                    if let resolveError = model.resolveError {
                        Text(resolveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if model.phase == .resolving {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Reading link…")
                                .font(.callout)
                                .foregroundStyle(Color.ssTextSecondary)
                        }
                        .padding(.vertical, DesignSystem.Spacing.unit2)
                    }

                    if !model.jobs.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(model.jobs) { job in
                                DownloadRow(
                                    job: job,
                                    onSplit: { model.splitJob(job) },
                                    onCancel: { model.cancelJob(job) },
                                    onRetry: { model.retryJob(job) },
                                    onRemove: { model.removeJob(job) })
                            }
                        }
                    } else if model.phase == .idle {
                        Text("Tracks land here, download one by one, and then split like imported files.")
                            .font(.caption)
                            .foregroundStyle(Color.ssTextSecondary)
                    }

                    Text("Link lookups reach Spotify and YouTube. Audio is fetched to this iPhone and never uploaded; splitting stays fully on-device.")
                        .font(.caption2)
                        .foregroundStyle(Color.ssTextSecondary)
                }
                .padding(.horizontal, DesignSystem.Spacing.unit3)
                .padding(.vertical, DesignSystem.Spacing.unit3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.ssGround)
            .navigationTitle("Split from Link")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.ssAccent)
    }
}

// MARK: - DownloadRow

struct DownloadRow: View {
    let job: LinkDownloadModel.Job
    let onSplit: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.ref.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.ssTextPrimary)
                    .lineLimit(1)
                statusLine
            }
            Spacer()
            controls
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.ssSurface))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.ref.displayName), \(accessibilityStatus)")
    }

    private var iconName: String {
        switch job.state {
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle"
        default: return "arrow.down.circle"
        }
    }

    private var iconColor: Color {
        switch job.state {
        case .ready: return .ssAccent
        case .failed: return .red
        default: return .ssTextSecondary
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch job.state {
        case .waiting:
            Text("Waiting")
                .font(.caption)
                .foregroundStyle(Color.ssTextSecondary)
        case .resolving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Looking up…")
                    .font(.caption)
                    .foregroundStyle(Color.ssTextSecondary)
            }
        case .downloading(let fraction, let done, let total):
            VStack(alignment: .leading, spacing: 4) {
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(.ssAccent)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(statusText(done: done, total: total))
                    .font(.caption)
                    .foregroundStyle(Color.ssTextSecondary)
            }
        case .ready:
            Text("Ready to split")
                .font(.caption)
                .foregroundStyle(Color.ssAccent)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundStyle(Color.ssTextSecondary)
        }
    }

    private func statusText(done: Int64, total: Int64?) -> String {
        let doneText = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        if let total {
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(doneText) of \(totalText)"
        }
        return doneText
    }

    private var accessibilityStatus: String {
        switch job.state {
        case .waiting: return "waiting"
        case .resolving: return "looking up"
        case .downloading: return "downloading"
        case .ready: return "ready to split"
        case .failed(let message): return "failed, \(message)"
        case .cancelled: return "cancelled"
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch job.state {
        case .ready:
            Button("Split", action: onSplit)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.ssTextSecondary)
            .accessibilityLabel("Remove download")
        case .failed, .cancelled:
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Retry download")
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.ssTextSecondary)
            .accessibilityLabel("Remove download")
        default:
            Button(action: onCancel) {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel download")
        }
    }
}
