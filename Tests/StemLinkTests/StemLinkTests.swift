import XCTest
@testable import StemLink

final class StemLinkTests: XCTestCase {

    // MARK: MusicLink (ported from stemsplitter-mac)

    func testSpotifyTrackStripsQueryParamsAndWhitespace() throws {
        let link = try XCTUnwrap(MusicLink.parse("  https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=abc123&context=xyz  "))
        XCTAssertEqual(link, .spotifyTrack("4cOdK2wGLETKBW3PvgPWqT"))
        XCTAssertEqual(link.spotifyPath, "track/4cOdK2wGLETKBW3PvgPWqT")
    }

    func testSpotifyAlbumAndPlaylist() throws {
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://open.spotify.com/album/1DFixLWuPkv3KT3TnV35m3")), .spotifyAlbum("1DFixLWuPkv3KT3TnV35m3"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=1")), .spotifyPlaylist("37i9dQZF1DXcBWIGoYBM5M"))
    }

    func testSpotifyURIForm() throws {
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("spotify:track:4cOdK2wGLETKBW3PvgPWqT")), .spotifyTrack("4cOdK2wGLETKBW3PvgPWqT"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("SPOTIFY:PLAYLIST:37i9dQZF1DXcBWIGoYBM5M")), .spotifyPlaylist("37i9dQZF1DXcBWIGoYBM5M"))
    }

    func testYouTubeWatchShortsPlaylist() throws {
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")), .youtube("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://music.youtube.com/watch?v=dQw4w9WgXcQ")), .youtube("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://youtu.be/dQw4w9WgXcQ?si=x")), .youtube("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://www.youtube.com/shorts/abc123_-")), .youtube("https://www.youtube.com/watch?v=abc123_-"))
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://www.youtube.com/playlist?list=PL123_-")), .youtubePlaylist("PL123_-"))
    }

    func testRejectsNonMusicLinks() {
        XCTAssertNil(MusicLink.parse(""))
        XCTAssertNil(MusicLink.parse("   "))
        XCTAssertNil(MusicLink.parse("https://google.com"))
        XCTAssertNil(MusicLink.parse("https://open.spotify.com/track/"))  // no id
        XCTAssertNil(MusicLink.parse("https://open.spotify.com/genre/discover-page"))
        XCTAssertNil(MusicLink.parse("spotify:episode:5pd1mU0zU8eYz0WfW1z1z1z"))
        XCTAssertNil(MusicLink.parse("https://www.youtube.com/watch"))  // no v param
        XCTAssertNil(MusicLink.parse("not a link"))
    }

    func testYouTubeIDExtraction() throws {
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://youtu.be/abc_-1"))?.youtubeID?.id, "abc_-1")
        XCTAssertTrue(try XCTUnwrap(MusicLink.parse("https://www.youtube.com/playlist?list=PL42"))!.youtubeID!.isPlaylist)
        XCTAssertEqual(try XCTUnwrap(MusicLink.parse("https://www.youtube.com/playlist?list=PL42"))!.youtubeID!.id, "PL42")
    }

    // MARK: Spotify embed parser

    func testSpotifyEmbedTrackEntity() throws {
        let html = nextData("""
        {"props":{"pageProps":{"state":{"data":{"entity":{
            "type":"track","name":"Never Gonna Give You Up","uri":"spotify:track:4PTG3Z6ehGkBFwjybzWkR8",
            "artists":[{"name":"Rick Astley","uri":"spotify:artist:0gxy"}],
            "duration":213573,"isPlayable":true}}}}}}
        """)
        guard case .track(let ref)? = SpotifyEmbedParser.parse(html) else { return XCTFail() }
        XCTAssertEqual(ref.id, "4PTG3Z6ehGkBFwjybzWkR8")
        XCTAssertEqual(ref.artist, "Rick Astley")
        XCTAssertEqual(ref.title, "Never Gonna Give You Up")
        XCTAssertEqual(try XCTUnwrap(ref.duration), 213.573, accuracy: 0.001)
        XCTAssertEqual(ref.displayName, "Rick Astley - Never Gonna Give You Up")
        XCTAssertEqual(ref.searchQuery, "Rick Astley Never Gonna Give You Up")
    }

    func testSpotifyEmbedPlaylistTrackList() throws {
        let html = nextData("""
        {"props":{"pageProps":{"state":{"data":{"entity":{
            "type":"playlist","name":"Today's Top Hits",
            "trackList":[
                {"uri":"spotify:track:11hc","title":"Patient Zero","subtitle":"Taylor Swift","duration":225868},
                {"uri":"spotify:track:abcd","title":"Second","subtitle":"Other Artist","duration":200000}]}}}}}}
        """)
        guard case .collection(let name, let tracks)? = SpotifyEmbedParser.parse(html) else { return XCTFail() }
        XCTAssertEqual(name, "Today's Top Hits")
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].artist, "Taylor Swift")
        XCTAssertEqual(try XCTUnwrap(tracks[0].duration), 225.868, accuracy: 0.001)
    }

    func testSpotifyEmbedGarbageReturnsNil() {
        XCTAssertNil(SpotifyEmbedParser.parse("<html><body>consent wall</body></html>"))
        XCTAssertNil(SpotifyEmbedParser.parse(""))
    }

    // MARK: YouTube Music search parser

    func testSearchParserPicksRunsAndIds() throws {
        let data = Data(searchResponseJSON.utf8)
        let songs = YouTubeMusicSearchParser.parse(data)
        XCTAssertEqual(songs.count, 2)
        XCTAssertEqual(songs[0].videoID, "lYBUbBu4W08")
        XCTAssertEqual(songs[0].title, "Never Gonna Give You Up")
        XCTAssertEqual(songs[0].artist, "Rick Astley")
        XCTAssertEqual(songs[1].videoID, "DPpWrwz3Iao")
        XCTAssertEqual(songs[1].artist, "Jerry Butler")
    }

    // MARK: Player parser

    func testPlayerParserSelectsHighestBitrateAAC() throws {
        let result = YouTubePlayerParser.parse(Data(playerResponseJSON.utf8))
        XCTAssertEqual(result.status, "OK")
        XCTAssertEqual(result.videoInfo?.title, "Never Gonna Give You Up")
        XCTAssertEqual(result.videoInfo?.duration, 214)
        let best = try XCTUnwrap(YouTubePlayer.bestAAC(in: result.formats))
        XCTAssertEqual(best.url.absoluteString, "https://gvideo.test/140")
        XCTAssertEqual(best.contentLength, 3459077)  // string-typed in real payloads
        XCTAssertEqual(result.formats.count, 4)  // parser keeps everything; bestAAC filters
    }

    func testPlayerParserSurfacesRefusal() {
        let result = YouTubePlayerParser.parse(Data(#"""
        {"playabilityStatus": {"status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"}}
        """#.utf8))
        XCTAssertEqual(result.status, "LOGIN_REQUIRED")
        XCTAssertEqual(result.reason, "Sign in to confirm you're not a bot")
        XCTAssertTrue(result.formats.isEmpty)
    }

    // MARK: YT playlist parser

    func testPlaylistParserReadsPanelItems() throws {
        let items = YouTubePlaylist.parse(Data(playlistResponseJSON.utf8))
        XCTAssertEqual(items.count, 2)
        guard items.count == 2 else { return }
        guard items.count == 2 else { return }
        XCTAssertEqual(items[0].ref.id, "fOT0BUpITw8")
        XCTAssertEqual(items[0].ref.artist, "Peso Pluma")
        XCTAssertEqual(try XCTUnwrap(items[0].ref.duration), 235, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(items[1].ref.duration), 3730, accuracy: 0.001)
    }

    func testClockSeconds() {
        XCTAssertEqual(YouTubePlaylist.clockSeconds("3:55"), 235)
        XCTAssertEqual(YouTubePlaylist.clockSeconds("1:02:10"), 3730)
        XCTAssertNil(YouTubePlaylist.clockSeconds("LIVE"))
        XCTAssertNil(YouTubePlaylist.clockSeconds(nil))
    }

    // MARK: Filenames

    func testSanitizedFileNameStripsPathCharacters() {
        XCTAssertEqual(AudioFetcher.sanitizedFileName("AC/DC: Back In Black"), "AC-DC- Back In Black")
        XCTAssertEqual(AudioFetcher.sanitizedFileName("   "), "Track")
        XCTAssertEqual(AudioFetcher.sanitizedFileName("Norman Fucking Rockwell!"), "Norman Fucking Rockwell!")
    }

    // MARK: helpers

    private func nextData(_ json: String) -> String {
        "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>"
    }
}

private let searchResponseJSON = """
{
 "contents": {
  "tabbedSearchResultsRenderer": {
   "tabs": [
    {
     "tabRenderer": {
      "content": {
       "sectionListRenderer": {
        "contents": [
         {
          "musicShelfRenderer": {
           "contents": [
            {
             "musicResponsiveListItemRenderer": {
              "playlistItemData": {
               "videoId": "lYBUbBu4W08"
              },
              "flexColumns": [
               {
                "musicResponsiveListItemFlexColumnRenderer": {
                 "text": {
                  "runs": [
                   {
                    "text": "Never Gonna Give You Up"
                   }
                  ]
                 }
                }
               },
               {
                "musicResponsiveListItemFlexColumnRenderer": {
                 "text": {
                  "runs": [
                   {
                    "text": "Rick Astley"
                   },
                   {
                    "text": " bullet "
                   },
                   {
                    "text": "Whenever You Need Somebody"
                   },
                   {
                    "text": " bullet "
                   },
                   {
                    "text": "3:34"
                   }
                  ]
                 }
                }
               }
              ]
             }
            },
            {
             "musicResponsiveListItemRenderer": {
              "playlistItemData": {
               "videoId": "DPpWrwz3Iao"
              },
              "flexColumns": [
               {
                "musicResponsiveListItemFlexColumnRenderer": {
                 "text": {
                  "runs": [
                   {
                    "text": "Never Give You Up"
                   }
                  ]
                 }
                }
               },
               {
                "musicResponsiveListItemFlexColumnRenderer": {
                 "text": {
                  "simpleText": "Jerry Butler"
                 }
                }
               }
              ]
             }
            }
           ]
          }
         }
        ]
       }
      }
     }
    }
   ]
  }
 }
}
"""

private let playerResponseJSON = """
{
 "playabilityStatus": {
  "status": "OK"
 },
 "videoDetails": {
  "title": "Never Gonna Give You Up",
  "lengthSeconds": "214"
 },
 "streamingData": {
  "adaptiveFormats": [
   {
    "itag": 251,
    "mimeType": "audio/webm; codecs=\\"opus\\"",
    "bitrate": 135138,
    "url": "https://gvideo.test/251",
    "contentLength": "3445462"
   },
   {
    "itag": 140,
    "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"",
    "bitrate": 131115,
    "url": "https://gvideo.test/140",
    "contentLength": "3459077"
   },
   {
    "itag": 139,
    "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"",
    "bitrate": 50546,
    "url": "https://gvideo.test/139",
    "contentLength": "1304649"
   },
   {
    "itag": 18,
    "mimeType": "video/mp4; codecs=\\"avc1\\"",
    "bitrate": 500000,
    "url": "https://gvideo.test/18",
    "contentLength": "9000000"
   }
  ]
 }
}
"""

private let playlistResponseJSON = """
{
 "contents": {
  "twoColumnBrowseResultsRenderer": {
   "tabs": [
    {
     "tabRenderer": {
      "content": {
       "sectionListRenderer": {
        "contents": [
         {
          "itemSectionRenderer": {
           "contents": [
            {
             "playlistVideoListRenderer": {
              "contents": [
               {
                "playlistPanelVideoRenderer": {
                 "videoId": "fOT0BUpITw8",
                 "title": {
                  "simpleText": "BELLAKEO (Video Oficial) - Peso Pluma, Anitta"
                 },
                 "longBylineText": {
                  "runs": [
                   {
                    "text": "Peso Pluma"
                   }
                  ]
                 },
                 "lengthText": {
                  "simpleText": "3:55"
                 }
                }
               },
               {
                "playlistPanelVideoRenderer": {
                 "videoId": "NFvDHYMzj9U",
                 "title": {
                  "simpleText": "Second Song"
                 },
                 "longBylineText": {
                  "runs": [
                   {
                    "text": "Other Band"
                   }
                  ]
                 },
                 "lengthText": {
                  "simpleText": "1:02:10"
                 }
                }
               }
              ]
             }
            }
           ]
          }
         }
        ]
       }
      }
     }
    }
   ]
  }
 }
}
"""
