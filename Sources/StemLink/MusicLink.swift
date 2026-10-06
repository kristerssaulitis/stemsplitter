import Foundation

/// A music link that can be fetched: a Spotify track/album/playlist or a YouTube video.
/// Ported from stemsplitter-mac's StemLink (identical grammar; iOS fetches natively).
public enum MusicLink: Equatable, Sendable {
    case spotifyTrack(String)
    case spotifyAlbum(String)
    case spotifyPlaylist(String)
    case youtube(String)  // normalized URL
    case youtubePlaylist(String)

    /// Spotify entity path for the embed endpoint (`open.spotify.com/embed/<path>`).
    public var spotifyPath: String? {
        switch self {
        case .spotifyTrack(let id): return "track/\(id)"
        case .spotifyAlbum(let id): return "album/\(id)"
        case .spotifyPlaylist(let id): return "playlist/\(id)"
        case .youtube, .youtubePlaylist: return nil
        }
    }

    /// YouTube video id for single videos, playlist id for playlists.
    public var youtubeID: (id: String, isPlaylist: Bool)? {
        switch self {
        case .spotifyTrack, .spotifyAlbum, .spotifyPlaylist:
            return nil
        case .youtube(let url):
            if let v = Self.queryItem("v", in: URL(string: url)?.query ?? "") { return (v, false) }
            return nil
        case .youtubePlaylist(let id):
            return (id, true)
        }
    }

    /// Parses messy pasted text: surrounding whitespace, tracking query params and both
    /// open.spotify.com paths and spotify: URIs are accepted; anything else is rejected.
    public static func parse(_ raw: String) -> MusicLink? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.lowercased().hasPrefix("spotify:") {
            let parts = text.split(separator: ":").map(String.init)
            guard parts.count >= 3 else { return nil }
            let id = parts.last!
            switch parts[1].lowercased() {
            case "track": return validID(id) ? .spotifyTrack(id) : nil
            case "album": return validID(id) ? .spotifyAlbum(id) : nil
            case "playlist": return validID(id) ? .spotifyPlaylist(id) : nil
            default: return nil
            }
        }

        guard let url = URL(string: text), let host = url.host?.lowercased() else { return nil }
        if host == "open.spotify.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count == 2 else { return nil }
            let id = parts[1]
            switch parts[0] {
            case "track": return validID(id) ? .spotifyTrack(id) : nil
            case "album": return validID(id) ? .spotifyAlbum(id) : nil
            case "playlist": return validID(id) ? .spotifyPlaylist(id) : nil
            default: return nil
            }
        }
        if host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return validID(id) ? .youtube("https://www.youtube.com/watch?v=\(id)") : nil
        }
        if host.hasSuffix("youtube.com") {
            if url.path == "/watch", let v = queryItem("v", in: url.query ?? ""), validID(v) {
                return .youtube("https://www.youtube.com/watch?v=\(v)")
            }
            if url.path == "/playlist", let list = queryItem("list", in: url.query ?? ""), validID(list) {
                return .youtubePlaylist(list)
            }
            if url.path.hasPrefix("/shorts/") {
                let id = String(url.path.dropFirst("/shorts/".count))
                if validID(id) { return .youtube("https://www.youtube.com/watch?v=\(id)") }
            }
            return nil
        }
        return nil
    }

    static func queryItem(_ key: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 && kv[0] == key { return String(kv[1]) }
        }
        return nil
    }

    /// Spotify ids are base62 (22 chars today); YouTube ids are base64-ish. Be liberal.
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}
