import Foundation

/// Shared plumbing for YouTube's innertube JSON API (POST, JSON in/out).
enum Innertube {

    static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15"

    static func post<T>(
        body: [String: Any],
        to url: URL,
        userAgent: String,
        headers: [String: String] = [:],
        parse: (Data) -> T
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw FetchError.cancelled
        } catch {
            throw FetchError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetchError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return parse(data)
    }
}

/// One downloadable audio format from a player response.
public struct AudioStreamFormat: Equatable, Sendable {
    public let url: URL
    public let mimeType: String   // e.g. "audio/mp4; codecs=\"mp4a.40.2\""
    public let bitrate: Int
    public let contentLength: Int64?

    public var isAAC: Bool { mimeType.hasPrefix("audio/mp4") }
}

public struct YouTubeVideoInfo: Equatable, Sendable {
    public let title: String
    public let duration: TimeInterval
}

/// Direct stream extraction via the innertube player endpoint. The iOS client
/// returns signed, decipher-free `audio/mp4` URLs; clients change often, so two
/// are tried and the failure reason from the last one is surfaced.
public enum YouTubePlayer {

    struct Client: Sendable {
        let name: String
        let version: String
        let userAgent: String
        let headers: [String: String]
        let deviceMake: String?
        let deviceModel: String?
        let osName: String?
        let osVersion: String?
    }

    /// Player clients, best first. The IOS entry mirrors what yt-dlp ships
    /// (2025); a stale clientVersion is what turns OK responses into
    /// FAILED_PRECONDITION, so bump both fields together when downloads break.
    static let clients: [Client] = [
        Client(
            name: "IOS", version: "20.10.4",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)",
            headers: ["X-YouTube-Client-Name": "5", "X-YouTube-Client-Version": "20.10.4"],
            deviceMake: "Apple", deviceModel: "iPhone16,2",
            osName: "iPhone", osVersion: "18.3.2.22D82"),
        Client(
            name: "TVHTML5", version: "7.20250312.16.00",
            userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
            headers: [:],
            deviceMake: nil, deviceModel: nil, osName: nil, osVersion: nil),
    ]

    static let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!

    /// Fetches video info + the best AAC stream for a video.
    /// - Returns: video metadata and the highest-bitrate direct `audio/mp4` URL
    ///   (AVFoundation reads AAC-in-MP4; WebM/Opus formats are skipped).
    public static func bestAACStream(videoID: String) async throws -> (YouTubeVideoInfo, AudioStreamFormat) {
        var lastReason = "unknown error"
        for client in clients {
            var clientContext: [String: Any] = [
                "clientName": client.name,
                "clientVersion": client.version,
                "hl": "en",
                "gl": "US",
            ]
            if let deviceMake = client.deviceMake { clientContext["deviceMake"] = deviceMake }
            if let deviceModel = client.deviceModel { clientContext["deviceModel"] = deviceModel }
            if let osName = client.osName { clientContext["osName"] = osName }
            if let osVersion = client.osVersion { clientContext["osVersion"] = osVersion }
            let body: [String: Any] = [
                "context": ["client": clientContext],
                "videoId": videoID,
                "contentCheckOk": true,
                "racyCheckOk": true,
            ]
            let result: YouTubePlayerParser.PlayerResult = try await Innertube.post(
                body: body, to: endpoint, userAgent: client.userAgent,
                headers: client.headers, parse: YouTubePlayerParser.parse)
            if result.status == "OK", let info = result.videoInfo {
                if let stream = bestAAC(in: result.formats) {
                    return (info, stream)
                }
                lastReason = "no audio stream in response"
                continue
            }
            lastReason = result.reason ?? "status \(result.status ?? "unknown")"
        }
        throw FetchError.videoUnavailable(lastReason)
    }

    static func bestAAC(in formats: [AudioStreamFormat]) -> AudioStreamFormat? {
        formats.filter { $0.isAAC }.max { $0.bitrate < $1.bitrate }
    }
}

// MARK: - Parser (pure, offline-testable)

public enum YouTubePlayerParser {

    public struct PlayerResult: Sendable {
        public var status: String?
        public var reason: String?
        public var videoInfo: YouTubeVideoInfo?
        public var formats: [AudioStreamFormat] = []
    }

    public static func parse(_ data: Data) -> PlayerResult {
        var result = PlayerResult()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return result
        }
        let playability = root["playabilityStatus"] as? [String: Any]
        result.status = playability?["status"] as? String
        result.reason = playability?["reason"] as? String

        if let details = root["videoDetails"] as? [String: Any] {
            let title = details["title"] as? String ?? ""
            let seconds = (details["lengthSeconds"] as? NSString)?.doubleValue ?? 0
            result.videoInfo = YouTubeVideoInfo(title: title, duration: seconds)
        }

        let streaming = root["streamingData"] as? [String: Any]
        let formats = streaming?["adaptiveFormats"] as? [Any] ?? []
        result.formats = formats.compactMap(format)
        return result
    }

    static func format(_ any: Any) -> AudioStreamFormat? {
        guard let f = any as? [String: Any], let urlString = f["url"] as? String,
              let url = URL(string: urlString) else { return nil }
        let mime = f["mimeType"] as? String ?? ""
        let bitrate = (f["bitrate"] as? NSNumber)?.intValue ?? 0
        // contentLength arrives as a JSON string in player responses.
        let length = (f["contentLength"] as? String).flatMap(Int64.init)
            ?? (f["contentLength"] as? NSNumber)?.int64Value
        return AudioStreamFormat(url: url, mimeType: mime, bitrate: bitrate, contentLength: length)
    }
}
