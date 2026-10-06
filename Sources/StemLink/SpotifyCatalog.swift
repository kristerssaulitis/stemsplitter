import Foundation

/// Spotify catalog metadata without an API account: the public embed page
/// (`open.spotify.com/embed/<type>/<id>`) ships a `__NEXT_DATA__` JSON blob with
/// the track name/artists/duration, or a full `trackList` for albums/playlists.
public struct SpotifyCatalog: Sendable {

    public init() {}

    /// Resolves a Spotify link to a single track or a named collection.
    public func resolve(_ link: MusicLink) async throws -> ResolvedLink {
        guard let path = link.spotifyPath else { throw FetchError.invalidLink }
        var request = URLRequest(url: URL(string: "https://open.spotify.com/embed/\(path)")!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if error is CancellationError { throw FetchError.cancelled }
            throw FetchError.spotifyUnavailable
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.spotifyUnavailable
        }
        let entity = SpotifyEmbedParser.parse(String(decoding: data, as: UTF8.self))
        guard let entity else { throw FetchError.spotifyUnavailable }

        switch entity {
        case .track(let ref):
            return .track(ref)
        case .collection(let name, let tracks):
            guard !tracks.isEmpty else { throw FetchError.spotifyUnavailable }
            return .collection(name: name, tracks: tracks)
        }
    }

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15"
}

// MARK: - Parser (pure, offline-testable)

public enum SpotifyEmbedParser {

    public enum Entity: Equatable, Sendable {
        case track(TrackRef)
        case collection(name: String, tracks: [TrackRef])
    }

    /// Extracts the embed entity from the page HTML. Returns nil when the page
    /// has no `__NEXT_DATA__` blob or its shape changed.
    public static func parse(_ html: String) -> Entity? {
        guard let json = nextDataJSON(html), let root = try? JSONSerialization.jsonObject(with: json),
              let props = dig(root, "props"), let pageProps = dig(props, "pageProps"),
              let state = dig(pageProps, "state"), let data = dig(state, "data"),
              let entity = dig(data, "entity") else { return nil }
        return parseEntity(entity)
    }

    static func nextDataJSON(_ html: String) -> Data? {
        guard let open = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else {
            return nil
        }
        return String(html[open.upperBound..<close.lowerBound]).data(using: .utf8)
    }

    private static func parseEntity(_ entity: Any) -> Entity? {
        guard let dict = entity as? [String: Any] else { return nil }
        let name = dict["name"] as? String ?? dict["title"] as? String ?? ""
        guard !name.isEmpty else { return nil }
        let type = dict["type"] as? String

        if type == "track" {
            let artists = ((dict["artists"] as? [Any])?.compactMap { ($0 as? [String: Any])?["name"] as? String }) ?? []
            let durationMs = (dict["duration"] as? NSNumber)?.doubleValue
            let id = refID(dict["uri"] as? String) ?? (dict["id"] as? String) ?? ""
            guard !id.isEmpty else { return nil }
            let ref = TrackRef(
                id: id, source: .spotify,
                artist: artists.first, title: name,
                duration: durationMs.map { $0 / 1000 })
            return .track(ref)
        }

        // Album/playlist: trackList[] with uri/title/subtitle(=artist)/duration(ms).
        guard let list = dict["trackList"] as? [Any], !list.isEmpty else { return nil }
        let tracks = list.compactMap { item -> TrackRef? in
            guard let t = item as? [String: Any],
                  let title = t["title"] as? String,
                  let id = refID(t["uri"] as? String) else { return nil }
            return TrackRef(
                id: id, source: .spotify,
                artist: t["subtitle"] as? String,
                title: title,
                duration: ((t["duration"] as? NSNumber)?.doubleValue).map { $0 / 1000 })
        }
        guard !tracks.isEmpty else { return nil }
        return .collection(name: name, tracks: tracks)
    }

    /// "spotify:track:<id>" → "<id>".
    private static func refID(_ uri: String?) -> String? {
        guard let uri, uri.hasPrefix("spotify:track:") else { return nil }
        let id = String(uri.dropFirst("spotify:track:".count))
        return id.isEmpty ? nil : id
    }

    static func dig(_ any: Any, _ key: String) -> Any? {
        (any as? [String: Any])?[key]
    }
}
