import Foundation

/// One split session's output directory (`Caches/Splits/<uuid>/`, plan output
/// lifecycle): playable on the result screen for the session, purged on next
/// launch; Share / Save to Files is the persistence path.
public struct SplitSession: Equatable, Sendable {

    /// Session identifier; the directory name under the store's base directory.
    public let id: UUID

    /// `Caches/Splits/<id>/` — vocals.wav + instrumental.wav live here.
    public let directory: URL

    /// File URL where the vocals stem WAV is (or will be) written.
    public let vocalsURL: URL

    /// File URL where the instrumental stem WAV is (or will be) written.
    public let instrumentalURL: URL

    /// `true` while the `.inprogress` marker exists — the session has not
    /// completed (or was interrupted: an orphan). Orphans are purged by
    /// `purgeOrphans()` / `purgeOnLaunch()`.
    public let isInProgress: Bool
}

/// Lifecycle for per-session split output directories (plan T6; output lifecycle,
/// orphan cleanup, eng E9 dir-level hygiene).
///
/// Decisions encoded here, all from the approved plan:
/// - Sessions live under `<base>/<uuid>/` where `base` is `Caches/Splits`
///   (injectable for tests — plan verification bar: "session dir create/list
///   under Caches/Splits/<uuid> with .inprogress marker").
/// - A session starts with a `.inprogress` marker file; completing removes it.
///   A dir still carrying the marker after the app died is an orphan.
/// - `purgeOnLaunch()` wipes ALL session dirs: split output "purged on next
///   launch; cold relaunch lands on the empty picker state".
/// - `purgeOrphans()` wipes only dead (marker-carrying) sessions — the
///   "Start again purges it before restarting" flow keeps completed output.
/// - Listing validates: a completed dir whose WAV files carry garbage headers
///   (eng E9: interrupted writes leave garbage headers) is deleted, never
///   surfaced. Header-level backpatch rescue itself lives in WAVWriter (T5);
///   the store is the dir-level net.
///
/// All filesystem state is rooted at the injected `baseDirectory`; nothing here
/// touches the real caches directory unless given it.
public final class SplitStore: Sendable {

    /// Root of all session dirs (e.g. `.../Caches/Splits`). Injectable for tests.
    public let baseDirectory: URL

    /// Marker file naming an unfinished session. Deliberately dot-prefixed so it
    /// never collides with output files and hides from user-facing file pickers.
    public static let markerFileName = ".inprogress"

    /// Output file names inside a session dir (contract `SplitOutputs`).
    public static let vocalsFileName = "vocals.wav"
    public static let instrumentalFileName = "instrumental.wav"

    /// The one failure this store raises: the named session does not exist.
    public enum SplitStoreError: Error, Equatable, Sendable {
        case sessionNotFound
    }

    /// - Parameter baseDirectory: the `Splits` directory that holds `<uuid>`
    ///   session dirs. Created on demand by `createSession()`.
    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Production location: `<caches>/Splits` (plan output lifecycle). Tests inject
    /// their own base directory instead of using this.
    public static func defaultBaseDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Splits", isDirectory: true)
    }

    /// Create a fresh session dir `<base>/<uuid>/` with the `.inprogress` marker
    /// and return it. The base directory is created on demand.
    public func createSession() throws -> SplitSession {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let directory = baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let marker = directory.appendingPathComponent(Self.markerFileName)
        if FileManager.default.fileExists(atPath: marker.path) == false {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
        return SplitSession(
            id: id,
            directory: directory,
            vocalsURL: directory.appendingPathComponent(Self.vocalsFileName),
            instrumentalURL: directory.appendingPathComponent(Self.instrumentalFileName),
            isInProgress: true
        )
    }

    /// Mark the session completed: removes the `.inprogress` marker so the dir
    /// survives `purgeOrphans()` and lists as finished output.
    public func markCompleted(_ session: SplitSession) throws {
        guard session.directory == sessionDirectory(for: session.id),
              FileManager.default.fileExists(atPath: session.directory.path) else {
            throw SplitStoreError.sessionNotFound
        }
        try FileManager.default.removeItem(at: session.directory.appendingPathComponent(Self.markerFileName))
    }

    /// All sessions, sorted by id for stable ordering. Side effect (deliberate,
    /// eng E9 dir-level hygiene): completed dirs containing garbage-header WAV
    /// files, and empty completed leftovers, are DELETED here — validated output
    /// only is ever surfaced. In-progress dirs are listed untouched (an active
    /// session may transiently have zero or partial files).
    ///
    /// A missing base directory lists as empty. Enumeration failures surface as
    /// empty rather than throwing: listing must never block the UI.
    public func listSessions() -> [SplitSession] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: baseDirectory.path) else {
            return []
        }
        var sessions: [SplitSession] = []
        for name in names.sorted() {
            guard let id = UUID(uuidString: name) else { continue }
            let directory = sessionDirectory(for: id)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let marker = directory.appendingPathComponent(Self.markerFileName)
            let inProgress = FileManager.default.fileExists(atPath: marker.path)

            if inProgress == false {
                let wavURLs = ((try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension.lowercased() == "wav" }
                let allValid = wavURLs.isEmpty == false
                    && wavURLs.allSatisfy(Self.hasValidWAVHeader)
                if allValid == false {
                    // Garbage-header outputs (eng E9) or an empty completed
                    // leftover: validated and deleted, never surfaced.
                    try? FileManager.default.removeItem(at: directory)
                    continue
                }
            }

            sessions.append(SplitSession(
                id: id,
                directory: directory,
                vocalsURL: directory.appendingPathComponent(Self.vocalsFileName),
                instrumentalURL: directory.appendingPathComponent(Self.instrumentalFileName),
                isInProgress: inProgress
            ))
        }
        return sessions
    }

    /// Plan output lifecycle: "purged on next launch". Deletes EVERY session dir
    /// under the base — completed and orphan alike. Idempotent; a missing base is
    /// a no-op. Best-effort: a dir that fails to delete never blocks launch.
    public func purgeOnLaunch() {
        for directory in existingSessionDirectories() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Orphan purge: deletes only sessions still carrying the `.inprogress`
    /// marker (dead sessions — the plan's "interrupted split leaves a partial
    /// Caches/Splits/<uuid>/ dir; 'Start again' purges it"). Completed output
    /// survives. Idempotent, best-effort.
    public func purgeOrphans() {
        for directory in existingSessionDirectories() {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(Self.markerFileName).path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Purge one named session ("Start again" purge before restarting). Idempotent.
    public func purgeSession(id: UUID) {
        try? FileManager.default.removeItem(at: sessionDirectory(for: id))
    }

    // MARK: - WAV header validation (eng E9 dir-level net)

    /// Minimal container sanity check for an output WAV: first 12 bytes must be
    /// a `RIFF····WAVE` (plain WAV) or `RF64····WAVE` (RF64, eng E6 >4 GB
    /// variant — per EBU Tech 3306 the form type stays "WAVE", the size field is
    /// 0xFFFFFFFF and real sizes live in the ds64 chunk) header. Anything else —
    /// wrong magic, truncated file, backpatched garbage — is invalid.
    public static func hasValidWAVHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else {
            return false
        }
        let magic = header.subdata(in: 0..<4)
        let form = header.subdata(in: 8..<12)
        return form == Data("WAVE".utf8)
            && (magic == Data("RIFF".utf8) || magic == Data("RF64".utf8))
    }

    // MARK: - Private

    private func sessionDirectory(for id: UUID) -> URL {
        baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func existingSessionDirectories() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: baseDirectory.path) else {
            return []
        }
        return names.compactMap { name in
            guard UUID(uuidString: name) != nil else { return nil }
            let directory = baseDirectory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return directory
        }
    }
}
