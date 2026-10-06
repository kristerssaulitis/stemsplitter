import Foundation

// MARK: - Shared fetch model (Spotify metadata in, YouTube audio out)

/// One fetchable track, whatever the source. `source` decides the route:
/// Spotify refs are matched on YouTube Music by search, YouTube refs go to the
/// player endpoint directly with `id` as the video id.
public struct TrackRef: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable { case spotify, youtube }

    public let id: String
    public let source: Source
    public let artist: String?
    public let title: String
    /// Seconds, when the source metadata carries it (Spotify embed does; the
    /// YouTube player response overrides it later).
    public let duration: TimeInterval?

    public init(id: String, source: Source, artist: String?, title: String, duration: TimeInterval?) {
        self.id = id
        self.source = source
        self.artist = artist
        self.title = title
        self.duration = duration
    }

    /// "Artist - Title" as shown everywhere; falls back to the bare title.
    public var displayName: String {
        guard let artist, !artist.isEmpty else { return title }
        return "\(artist) - \(title)"
    }

    /// YouTube Music search phrase (spotDL's "artist title" convention).
    public var searchQuery: String {
        guard let artist, !artist.isEmpty else { return title }
        return "\(artist) \(title)"
    }
}

/// What a link resolved to: one track/video, or a named collection of tracks.
public enum ResolvedLink: Equatable, Sendable {
    case track(TrackRef)
    case collection(name: String, tracks: [TrackRef])
}

/// A downloaded, split-ready audio file.
public struct FetchedAudio: Equatable, Sendable {
    public let fileURL: URL
    public let displayName: String
    public let duration: TimeInterval
    public let fileSizeBytes: Int64

    public init(fileURL: URL, displayName: String, duration: TimeInterval, fileSizeBytes: Int64) {
        self.fileURL = fileURL
        self.displayName = displayName
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
    }
}

// MARK: - Errors

public enum FetchError: LocalizedError, Equatable {
    case cancelled
    case invalidLink
    case spotifyUnavailable
    case unsupportedPlaylist
    case noMatch(String)            // YouTube Music had no song for the query
    case videoUnavailable(String)   // player refusal (bot check, removed, private…)
    case noAudioStream              // no direct AAC stream in the player response
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return nil
        case .invalidLink: return "That doesn't look like a Spotify or YouTube link."
        case .spotifyUnavailable: return "Spotify metadata isn't reachable right now. Try again."
        case .unsupportedPlaylist: return "That YouTube playlist couldn't be read. Try the individual video."
        case .noMatch(let name): return "No YouTube match found for “\(name)”."
        case .videoUnavailable(let reason): return "Video unavailable: \(reason)"
        case .noAudioStream: return "No downloadable audio stream for that track."
        case .network(let message): return message
        }
    }
}
