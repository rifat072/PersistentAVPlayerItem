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
        let url = try XCTUnwrap(URL(string: "https://\(StubServer.host)/\(UUID().uuidString).mp4"))
        var item: PersistentAVPlayerItem? = PersistentAVPlayerItem(url: url)
        XCTAssertEqual((item?.asset as? AVURLAsset)?.url.scheme, "pavpi-https")
        XCTAssertTrue(item?.cache === MediaCache.shared)

        // Nothing was downloaded, so nothing may be written to the default cache
        // (on macOS that's the user's Documents folder).
        item = nil
        IO.sync {}
        let metadataURL = CacheFile.metadataURL(key: url.cacheKey, directory: MediaCache.defaultDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
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
        // The item that streams the file opens it with a guessed extension.
        let streamingItem = PersistentAVPlayerItem(url: url, cache: cache)
        run(MockLoadingRequest(offset: 0, length: 20_000), url: url, cache: cache)

        let item = PersistentAVPlayerItem(url: url, cache: cache)
        withExtendedLifetime(streamingItem) {}
        XCTAssertTrue(item.isPlayingFromCache)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url.scheme, "pavpi-https")
    }

    func testHLSItemPlaysThroughLocalServer() throws {
        let hls = try XCTUnwrap(URL(string: "https://example.com/stream/master.m3u8"))
        let hlsItem = PersistentAVPlayerItem(url: hls, cache: makeTestCache())
        let assetURL = try XCTUnwrap((hlsItem.asset as? AVURLAsset)?.url)
        XCTAssertEqual(assetURL.scheme, "http")
        XCTAssertEqual(assetURL.host, "127.0.0.1")
        XCTAssertEqual(assetURL.lastPathComponent, "master.m3u8")
        XCTAssertFalse(hlsItem.isPlayingFromCache)

        let extensionless = try XCTUnwrap(URL(string: "https://example.com/stream/master"))
        let extensionlessItem = PersistentAVPlayerItem(url: extensionless, cache: makeTestCache(), customFileExtension: "m3u8")
        XCTAssertEqual((extensionlessItem.asset as? AVURLAsset)?.url.host, "127.0.0.1")
    }

    func testFileURLsPassThrough() throws {
        let file = URL(fileURLWithPath: "/tmp/clip.mp4")
        let fileItem = PersistentAVPlayerItem(url: file, cache: makeTestCache())
        XCTAssertEqual((fileItem.asset as? AVURLAsset)?.url, file)
    }
}
