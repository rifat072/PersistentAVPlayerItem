// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import AVFoundation
import XCTest
@testable import PersistentAVPlayerItem

@MainActor
final class PersistentAVPlayerItemTests: XCTestCase {
    func testUncachedItemUsesResourceLoader() throws {
        let cache = makeTestCache()
        let url = StubServer.shared.register(.init(data: Data(count: 10), mimeType: "video/mp4", supportsRange: true))
        let item = PersistentAVPlayerItem(url: url, cache: cache)

        let assetURL = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
        XCTAssertEqual(assetURL.scheme, "pavpi-https")
        XCTAssertFalse(item.isPlayingFromCache)
        XCTAssertNotNil((item.asset as? AVURLAsset)?.resourceLoader.delegate)
    }

    func testPlainURLInitializerUsesResourceLoader() throws {
        // Guards against resolving to the inherited `AVPlayerItem.init(url:)`, which
        // would silently bypass the cache.
        let directoryExisted = FileManager.default.fileExists(atPath: MediaCache.defaultDirectory.path)
        addTeardownBlock {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: MediaCache.defaultDirectory.path)
            if !directoryExisted, contents?.isEmpty == true {
                try? FileManager.default.removeItem(at: MediaCache.defaultDirectory)
            }
        }
        let url = try XCTUnwrap(URL(string: "https://\(StubServer.host)/\(UUID().uuidString).mp4"))
        let item = PersistentAVPlayerItem(url: url)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url.scheme, "pavpi-https")
        XCTAssertTrue(item.cache === MediaCache.shared)
    }

    func testCopyKeepsCaching() throws {
        let cache = makeTestCache()
        let url = StubServer.shared.register(.init(data: Data(count: 10), mimeType: "video/mp4", supportsRange: true))
        let item = PersistentAVPlayerItem(url: url, cache: cache)

        let copy = try XCTUnwrap(item.copy() as? PersistentAVPlayerItem)
        XCTAssertFalse(copy === item)
        XCTAssertEqual(copy.url, url)
        XCTAssertTrue(copy.cache === cache)
        XCTAssertEqual((copy.asset as? AVURLAsset)?.url.scheme, "pavpi-https")
        XCTAssertNotNil((copy.asset as? AVURLAsset)?.resourceLoader.delegate)
    }

    func testCachedItemPlaysLocalFile() throws {
        let cache = makeTestCache()
        let body = XCTestCase.randomData(count: 50_000)
        let url = StubServer.shared.register(.init(data: body, mimeType: "video/mp4", supportsRange: true))
        run(MockLoadingRequest(offset: 0, length: 50_000), url: url, cache: cache)

        let item = PersistentAVPlayerItem(url: url, cache: cache)
        let assetURL = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
        XCTAssertTrue(assetURL.isFileURL)
        XCTAssertEqual(assetURL, cache.cachedFileURL(for: url))
        XCTAssertTrue(item.isPlayingFromCache)
    }

    func testCachedItemWithGuessedExtensionStillUsesLoader() throws {
        let cache = makeTestCache()
        let body = XCTestCase.randomData(count: 20_000)
        let url = StubServer.shared.register(.init(data: body, mimeType: "audio/mpeg", supportsRange: true), name: UUID().uuidString)
        _ = PersistentAVPlayerItem(url: url, cache: cache) // records that the extension is a guess
        run(MockLoadingRequest(offset: 0, length: 20_000), url: url, cache: cache)

        let item = PersistentAVPlayerItem(url: url, cache: cache)
        XCTAssertTrue(item.isPlayingFromCache)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url.scheme, "pavpi-https")
    }

    func testHLSAndFileURLsPassThrough() throws {
        let hls = try XCTUnwrap(URL(string: "https://example.com/stream/master.m3u8"))
        let hlsItem = PersistentAVPlayerItem(url: hls, cache: makeTestCache())
        XCTAssertEqual((hlsItem.asset as? AVURLAsset)?.url, hls)

        let file = URL(fileURLWithPath: "/tmp/clip.mp4")
        let fileItem = PersistentAVPlayerItem(url: file, cache: makeTestCache())
        XCTAssertEqual((fileItem.asset as? AVURLAsset)?.url, file)
    }
}
