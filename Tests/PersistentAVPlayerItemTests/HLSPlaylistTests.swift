// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import XCTest
@testable import PersistentAVPlayerItem

final class HLSPlaylistTests: XCTestCase {
    private let base = URL(string: "https://cdn.test/videos/clip/master.m3u8")!

    private func playlist(_ text: String) throws -> HLSPlaylist {
        try XCTUnwrap(HLSPlaylist(data: Data(text.utf8), baseURL: base))
    }

    func testRejectsNonPlaylists() {
        XCTAssertNil(HLSPlaylist(data: Data("<html>".utf8), baseURL: base))
    }

    func testMultivariantReferences() throws {
        let playlist = try playlist("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",DEFAULT=YES,URI="audio/en.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aac",SUBTITLES="subs"
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="aac"
        https://other.test/high/index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="low/iframes.m3u8"
        #EXT-X-SESSION-KEY:METHOD=AES-128,URI="../keys/k1"
        """)
        XCTAssertTrue(playlist.isMultivariant)
        XCTAssertTrue(playlist.isFinal)
        XCTAssertEqual(playlist.references, [
            .init(url: URL(string: "https://cdn.test/videos/clip/audio/en.m3u8")!, kind: .rendition, audioGroup: "aac"),
            .init(url: URL(string: "https://cdn.test/videos/clip/subs/en.m3u8")!, kind: .rendition),
            .init(url: URL(string: "https://cdn.test/videos/clip/low/index.m3u8")!, kind: .variant, audioGroup: "aac"),
            .init(url: URL(string: "https://other.test/high/index.m3u8")!, kind: .variant, audioGroup: "aac"),
            .init(url: URL(string: "https://cdn.test/videos/clip/low/iframes.m3u8")!, kind: .iFrameVariant),
            .init(url: URL(string: "https://cdn.test/videos/keys/k1")!, kind: .other),
        ])
    }

    func testMediaPlaylistReferencesAndByteRanges() throws {
        let playlist = try playlist("""
        #EXTM3U\r
        #EXT-X-TARGETDURATION:6\r
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"\r
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.test/k"\r
        #EXTINF:6.0,\r
        #EXT-X-BYTERANGE:1000@720\r
        media.mp4\r
        #EXTINF:6.0,\r
        #EXT-X-BYTERANGE:500\r
        media.mp4\r
        #EXTINF:4.0,\r
        seg3.ts?token=abc\r
        #EXT-X-ENDLIST\r
        """)
        XCTAssertFalse(playlist.isMultivariant)
        XCTAssertTrue(playlist.isFinal)
        let media = URL(string: "https://cdn.test/videos/clip/media.mp4")!
        XCTAssertEqual(playlist.references, [
            .init(url: URL(string: "https://cdn.test/videos/clip/init.mp4")!, kind: .segment, byteRange: 0..<720),
            .init(url: URL(string: "https://keys.test/k")!, kind: .other),
            .init(url: media, kind: .segment, byteRange: 720..<1720),
            .init(url: media, kind: .segment, byteRange: 1720..<2220),
            .init(url: URL(string: "https://cdn.test/videos/clip/seg3.ts?token=abc")!, kind: .segment),
        ])
    }

    func testLivePlaylistIsNotFinal() throws {
        let playlist = try playlist("""
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:6.0,
        seg100.ts
        """)
        XCTAssertFalse(playlist.isFinal)
    }

    func testRewriteReplacesAndDrops() throws {
        let playlist = try playlist("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000
        high.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="iframes.m3u8"
        #EXT-X-SESSION-KEY:METHOD=AES-128,URI="key"
        """)
        let text = playlist.rewritten { reference in
            switch reference.url.lastPathComponent {
            case "low.m3u8": return .replace(URL(string: "http://127.0.0.1:1/low")!)
            case "high.m3u8", "iframes.m3u8": return .drop
            default: return .keep
            }
        }
        XCTAssertEqual(text, """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        http://127.0.0.1:1/low
        #EXT-X-SESSION-KEY:METHOD=AES-128,URI="https://cdn.test/videos/clip/key"
        """)
    }
}
