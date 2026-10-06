import Foundation

/// YouTube Music song lookup via the innertube API (the same backend the YT Music
/// web player uses), restricted to the "Songs" shelf so the first hit is the
/// official track — spotDL's matching behavior.
public struct YTMSong: Equatable, Sendable {
    public let videoID: String
    public let title: String
    public let artist: String?

    public init(videoID: String, title: String, artist: String?) {
        self.videoID = videoID
        self.title = title
        self.artist = artist
    }
}

public enum YouTubeMusic {

    /// Stable innertube param that filters search results to the Songs shelf.
    public static let songsFilterParams = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
    static let clientVersion = "1.20240401.01.00"
    static let endpoint = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!

    /// Ordered song results for a query; first element is the match spotDL would take.
    public static func searchSongs(_ query: String) async throws -> [YTMSong] {
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB_REMIX",
                "clientVersion": clientVersion,
                "hl": "en",
                "gl": "US",
            ]],
            "query": query,
            "params": songsFilterParams,
        ]
        return try await Innertube.post(
            body: body, to: endpoint, userAgent: Innertube.browserUserAgent,
            parse: YouTubeMusicSearchParser.parse)
    }
}

// MARK: - Parser (pure, offline-testable)

public enum YouTubeMusicSearchParser {

    /// Walks the (deeply nested, undocumented) response collecting song rows in order.
    public static func parse(_ data: Data) -> [YTMSong] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var items: [Any] = []
        collect(key: "musicResponsiveListItemRenderer", in: root, into: &items)
        return items.compactMap(song)
    }

    static func song(_ item: Any) -> YTMSong? {
        guard let dict = item as? [String: Any] else { return nil }
        let videoID = ((dict["playlistItemData"] as? [String: Any])?["videoId"] as? String)
            ?? firstWatchID(dict)
        guard let videoID, !videoID.isEmpty else { return nil }
        let columns = (dict["flexColumns"] as? [Any]) ?? []
        let title = columnText(columns, 0, joinAll: true)
        guard !title.isEmpty else { return nil }
        let subtitleRuns = columnRuns(columns, 1)
        let artist = subtitleRuns.first
        return YTMSong(videoID: videoID, title: title, artist: artist)
    }

    /// Fallback id source: the title run's watchEndpoint.
    private static func firstWatchID(_ dict: [String: Any]) -> String? {
        var endpoints: [Any] = []
        collect(key: "watchEndpoint", in: dict, into: &endpoints)
        return endpoints.compactMap { ($0 as? [String: Any])?["videoId"] as? String }.first
    }

    static func columnRuns(_ columns: [Any], _ index: Int) -> [String] {
        guard index < columns.count,
              let cell = (columns[index] as? [String: Any])?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let text = cell["text"] as? [String: Any] else { return [] }
        if let runs = text["runs"] as? [Any] {
            return runs.compactMap { ($0 as? [String: Any])?["text"] as? String }
        }
        if let simple = text["simpleText"] as? String { return [simple] }
        return []
    }

    static func columnText(_ columns: [Any], _ index: Int, joinAll: Bool) -> String {
        let runs = columnRuns(columns, index)
        if joinAll { return runs.joined() }
        return runs.first ?? ""
    }

    /// Depth-first collection of every value stored under `key`.
    static func collect(key: String, in node: Any, into out: inout [Any]) {
        if let dict = node as? [String: Any] {
            for (k, v) in dict {
                if k == key { out.append(v) }
                collect(key: key, in: v, into: &out)
            }
        } else if let array = node as? [Any] {
            for v in array { collect(key: key, in: v, into: &out) }
        }
    }
}
