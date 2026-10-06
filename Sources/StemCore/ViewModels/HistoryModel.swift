import Foundation

// MARK: - HistoryModel

/// The user's saved splits: completed `SplitStore` sessions as a browsable,
/// deletable list. Entries survive relaunch (the store lives in Application
/// Support); a delete removes the session dir and its stems for good.
@MainActor
public final class HistoryModel: ObservableObject {

    /// One history row. `splitSeconds` is the original split time (0 = unknown,
    /// e.g. sessions from before metadata existed).
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let date: Date
        public let splitSeconds: TimeInterval
    }

    @Published public private(set) var entries: [Entry] = []

    /// Total size of the history on disk (all session dirs), for the footer.
    @Published public private(set) var storageBytes: Int64 = 0

    /// The store this model reads/writes. Exposed for completion-time metadata
    /// writes from the flow model.
    public let store: SplitStore

    public init(store: SplitStore = SplitStore(baseDirectory: SplitStore.defaultBaseDirectory())) {
        self.store = store
    }

    // MARK: List

    /// Refresh from disk: completed sessions, newest first. In-progress sessions
    /// (an active split) never appear. The store's listing validation also runs
    /// here, so garbage-header leftovers are cleaned as a side effect.
    public func reload() {
        entries = store.listSessions()
            .filter { $0.isInProgress == false }
            .map { session in
                let metadata = store.readMetadata(for: session.id)
                let attributes = try? FileManager.default.attributesOfItem(atPath: session.directory.path)
                let date = metadata?.date ?? (attributes?[.creationDate] as? Date) ?? Date()
                return Entry(
                    id: session.id,
                    title: metadata?.title ?? "Split",
                    date: date,
                    splitSeconds: metadata?.splitSeconds ?? 0)
            }
            .sorted { $0.date > $1.date }
        storageBytes = Self.directorySize(at: store.baseDirectory)
    }

    // MARK: Delete

    /// Delete one entry: removes the session dir and every stem in it.
    /// Idempotent; the list updates in place.
    public func delete(_ entry: Entry) {
        store.purgeSession(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        storageBytes = Self.directorySize(at: store.baseDirectory)
    }

    // MARK: Record (completion-time)

    /// Write display metadata for a freshly completed split and refresh.
    /// Best-effort, like all store writes.
    public func recordCompletion(id: UUID, title: String, splitSeconds: TimeInterval) {
        store.writeMetadata(SplitMetadata(title: title, date: Date(), splitSeconds: splitSeconds), for: id)
        reload()
    }

    // MARK: Open (history replay)

    /// Build the mixer model for a stored session: stem WAVs re-read from the
    /// session dir, waveform peaks decoded once per stem off-main. `nil` when
    /// the session vanished or its WAVs are gone — callers should `reload()`.
    public func makeResult(for entry: Entry) async -> ResultModel? {
        let directory = store.baseDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return nil }
        let wavs = files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard
            let vocals = wavs.first(where: { $0.lastPathComponent == SplitStore.vocalsFileName }),
            let instrumental = wavs.first(where: { $0.lastPathComponent == SplitStore.instrumentalFileName })
        else { return nil }

        var stems: [StemTrack] = []
        for url in wavs {
            let name = url.deletingPathExtension().lastPathComponent
            let peaks = (try? WAVPeaks.load(from: url)) ?? []
            stems.append(StemTrack(name: name, url: url, peaks: peaks))
        }
        let outputs = SplitOutputs(vocalsURL: vocals, instrumentalURL: instrumental, stems: stems)
        // No source video survives for history items: the mixer opens audio-only
        // (video export + preview hide themselves via hasVideo == false).
        return ResultModel(
            title: entry.title,
            sourceURL: vocals,
            outputs: outputs,
            splitSeconds: entry.splitSeconds,
            resultDate: entry.date)
    }

    // MARK: Private

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
