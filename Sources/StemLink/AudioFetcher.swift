import Foundation

/// The native replacement for stemsplitter-mac's spotdl subprocess:
/// resolve a link to track metadata (Spotify embed / YouTube player), match on
/// YouTube Music, and stream the AAC audio to a local .m4a file. Foundation-only.
public struct AudioFetcher: Sendable {

    public init() {}

    // MARK: Resolve (link → track refs, no audio yet)

    public func resolve(_ link: MusicLink) async throws -> ResolvedLink {
        switch link {
        case .spotifyTrack, .spotifyAlbum, .spotifyPlaylist:
            return try await SpotifyCatalog().resolve(link)

        case .youtube:
            guard let (id, _) = link.youtubeID else { throw FetchError.invalidLink }
            let (info, _) = try await YouTubePlayer.bestAACStream(videoID: id)
            let ref = TrackRef(id: id, source: .youtube, artist: nil, title: info.title, duration: info.duration)
            return .track(ref)

        case .youtubePlaylist(let playlistID):
            let items = try await YouTubePlaylist.items(playlistID: playlistID)
            guard !items.isEmpty else { throw FetchError.unsupportedPlaylist }
            let name = items.first?.playlistTitle ?? "YouTube playlist"
            return .collection(name: name.isEmpty ? "YouTube playlist" : name, tracks: items.map(\.ref))
        }
    }

    // MARK: Download (track ref → local .m4a)

    /// Progress callback: fraction (nil when total is unknown), bytes done, bytes total.
    public typealias Progress = @Sendable (_ fraction: Double?, _ bytesDone: Int64, _ bytesTotal: Int64?) -> Void

    public func download(_ ref: TrackRef, toDirectory directory: URL, progress: Progress? = nil) async throws -> FetchedAudio {
        let videoID: String
        switch ref.source {
        case .youtube:
            videoID = ref.id
        case .spotify:
            let songs = try await YouTubeMusic.searchSongs(ref.searchQuery)
            guard let first = songs.first else { throw FetchError.noMatch(ref.displayName) }
            videoID = first.videoID
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = Self.uniqueFileURL(name: ref.displayName, in: directory)

        do {
            // Stream edges intermittently 403 fresh URLs (IP-reputation throttling);
            // a new player call mints new URLs, so retry whole-fetch, not the GET.
            var info: YouTubeVideoInfo?
            var lastReason = "no audio stream"
            var delivered = false
            for attempt in 0..<3 {
                if attempt > 0 {
                    try await Task.sleep(for: .seconds(attempt == 1 ? 2 : 6))
                }
                let (video, stream) = try await YouTubePlayer.bestAACStream(videoID: videoID)
                info = video
                progress?(stream.contentLength.map { _ in 0.0 }, 0, stream.contentLength)
                do {
                    try await streamToFile(stream, to: fileURL, progress: progress)
                    let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                    if let total = stream.contentLength, size < total {
                        lastReason = "truncated stream (\(size)/\(total))"
                        try? FileManager.default.removeItem(at: fileURL)
                        continue
                    }
                    delivered = true
                    break
                } catch let error as StreamFailure {
                    lastReason = error.reason
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            guard delivered, let video = info else {
                throw FetchError.noAudioStream
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            return FetchedAudio(
                fileURL: fileURL,
                displayName: ref.displayName,
                duration: video.duration > 0 ? video.duration : (ref.duration ?? 0),
                fileSizeBytes: size)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: fileURL)
            throw FetchError.cancelled
        } catch let error as FetchError {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw FetchError.network(error.localizedDescription)
        }
    }

    /// Internal marker: the stream GET itself failed (bad status / empty body),
    /// worth retrying with a fresh URL — distinct from transport errors.
    private struct StreamFailure: Error {
        let reason: String
    }

    /// Streams the URL into `to`, buffer-writing and reporting progress.
    /// googlevideo 403s plain GETs — the Range header is mandatory. Mid-stream
    /// drops resume from the written offset (same URL stays valid for hours).
    private func streamToFile(_ stream: AudioStreamFormat, to fileURL: URL, progress: Progress?) async throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        let total = stream.contentLength
        var written: Int64 = 0
        var buffer: [UInt8] = []
        buffer.reserveCapacity(256 * 1024)

        func flush() throws {
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress?(total.map { Double(written) / Double($0) }, written, total)
            }
        }

        for attempt in 0..<3 {
            var request = URLRequest(url: stream.url)
            request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // A 200 after a resume would replay bytes we already have.
            guard (200..<300).contains(status), !(attempt > 0 && status == 200) else {
                throw StreamFailure(reason: "stream returned HTTP \(status) at offset \(written)")
            }
            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    buffer.append(byte)
                    if buffer.count >= 256 * 1024 {
                        try flush()
                    }
                }
                try flush()
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == 2 { throw StreamFailure(reason: error.localizedDescription) }
                try? flush()
                try await Task.sleep(for: .seconds(1))
            }
        }
        if written == 0 {
            // A 206 with an empty body reads as success to URLSession; the
            // caller checks the file and retries with a fresh URL when starved.
            throw StreamFailure(reason: "stream returned no bytes")
        }
    }

    // MARK: Filenames

    /// "AC/DC: Back In Black" → "AC-DC - Back In Black" (path-safe, display-honest).
    public static func sanitizedFileName(_ displayName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = displayName.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Track" : String(cleaned.prefix(120))
    }

    static func uniqueFileURL(name: String, in directory: URL) -> URL {
        let base = sanitizedFileName(name)
        var candidate = directory.appendingPathComponent("\(base).m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(n)).m4a")
            n += 1
        }
        return candidate
    }
}

// MARK: - YouTube playlists (innertube "next")

public enum YouTubePlaylist {

    struct Item: Sendable {
        let ref: TrackRef
        let playlistTitle: String?
    }

    /// Ordered videos of a YouTube playlist. WEB client; parser is shape-tolerant.
    static func items(playlistID: String) async throws -> [Item] {
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB",
                "clientVersion": "2.20250312.04.00",
                "hl": "en",
                "gl": "US",
            ]],
            "playlistId": playlistID,
        ]
        let data: Data = try await Innertube.post(
            body: body, to: URL(string: "https://www.youtube.com/youtubei/v1/next?prettyPrint=false")!,
            userAgent: Innertube.browserUserAgent, headers: [:]) { $0 }
        return parse(data)
    }

    static func parse(_ data: Data) -> [Item] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var raw: [Any] = []
        YouTubeMusicSearchParser.collect(key: "playlistPanelVideoRenderer", in: root, into: &raw)

        // The playlist's own name rides above the panel.
        var headers: [Any] = []
        YouTubeMusicSearchParser.collect(key: "playlistHeaderRenderer", in: root, into: &headers)
        let playlistName = headers.compactMap { header -> String? in
            guard let dict = header as? [String: Any], let title = dict["title"] as? [String: Any] else { return nil }
            if let simple = title["simpleText"] as? String { return simple }
            let runs = title["runs"] as? [Any] ?? []
            return runs.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
        }.first

        return raw.compactMap { any -> Item? in
            guard let dict = any as? [String: Any], let videoID = dict["videoId"] as? String else { return nil }
            let titleDict = dict["title"] as? [String: Any]
            let title = (titleDict?["simpleText"] as? String)
                ?? ((titleDict?["runs"] as? [Any])?.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined() ?? "")
            let artist = ((dict["longBylineText"] as? [String: Any])?["runs"] as? [Any])?
                .compactMap { ($0 as? [String: Any])?["text"] as? String }.first
            let length = (dict["lengthText"] as? [String: Any])?["simpleText"] as? String
            return Item(
                ref: TrackRef(id: videoID, source: .youtube, artist: artist, title: title, duration: Self.clockSeconds(length)),
                playlistTitle: playlistName)
        }
    }

    /// "3:55" / "1:02:10" → seconds; nil for malformed or live entries.
    static func clockSeconds(_ clock: String?) -> TimeInterval? {
        guard let clock else { return nil }
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 >= 0 }) else { return nil }
        var seconds = 0.0
        for part in parts { seconds = seconds * 60 + part }
        return seconds
    }
}
