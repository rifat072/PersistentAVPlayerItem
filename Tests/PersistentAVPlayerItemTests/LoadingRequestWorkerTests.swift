// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import XCTest
@testable import PersistentAVPlayerItem

final class LoadingRequestWorkerTests: XCTestCase {
    private let body = XCTestCase.randomData(count: 300_000)

    private func register(supportsRange: Bool = true, mimeType: String = "video/mp4") -> URL {
        StubServer.shared.register(.init(data: body, mimeType: mimeType, supportsRange: supportsRange))
    }

    func testServesRequestedRangeAndCachesIt() {
        let cache = makeTestCache()
        let url = register()
        let request = MockLoadingRequest(offset: 100_000, length: 50_000)
        run(request, url: url, cache: cache)

        XCTAssertEqual(request.finishCount, 1)
        XCTAssertNil(request.finishError)
        XCTAssertEqual(request.contentType, "public.mpeg-4")
        XCTAssertEqual(request.contentLength, 300_000)
        XCTAssertEqual(request.isByteRangeAccessSupported, true)
        XCTAssertEqual(request.receivedData, body.subdata(in: 100_000..<150_000))
        XCTAssertEqual(StubServer.shared.requests(for: url), ["bytes=100000-149999"])

        let status = cache.status(for: url)
        XCTAssertEqual(status.cachedBytes, 50_000)
        XCTAssertEqual(status.totalBytes, 300_000)
        XCTAssertFalse(status.isComplete)
    }

    func testRepeatedRequestIsServedFromDisk() {
        let cache = makeTestCache()
        let url = register()
        run(MockLoadingRequest(offset: 0, length: 120_000), url: url, cache: cache)

        let second = MockLoadingRequest(offset: 10_000, length: 100_000)
        run(second, url: url, cache: cache)

        XCTAssertEqual(second.receivedData, body.subdata(in: 10_000..<110_000))
        XCTAssertEqual(second.contentLength, 300_000)
        XCTAssertEqual(StubServer.shared.requests(for: url).count, 1, "Second request must not hit the network")
    }

    func testFetchesOnlyMissingRanges() {
        let cache = makeTestCache()
        let url = register()
        run(MockLoadingRequest(offset: 100_000, length: 100_000), url: url, cache: cache)

        let full = MockLoadingRequest(offset: 0, length: 0, toEnd: true)
        run(full, url: url, cache: cache)

        XCTAssertEqual(full.receivedData, body)
        XCTAssertEqual(StubServer.shared.requests(for: url), [
            "bytes=100000-199999",
            "bytes=0-99999",
            "bytes=200000-299999",
        ])
        XCTAssertTrue(cache.isCached(url))
        let fileURL = cache.cachedFileURL(for: url)
        XCTAssertEqual(fileURL.flatMap { try? Data(contentsOf: $0) }, body)
    }

    func testTailRequestBeforeHead() {
        // AVFoundation often reads the `moov` atom at the end of a file first.
        let cache = makeTestCache()
        let url = register()
        let tail = MockLoadingRequest(offset: 290_000, length: 10_000)
        run(tail, url: url, cache: cache)
        XCTAssertEqual(tail.receivedData, body.subdata(in: 290_000..<300_000))

        let head = MockLoadingRequest(offset: 0, length: 2)
        run(head, url: url, cache: cache)
        XCTAssertEqual(head.receivedData, body.prefix(2))
        XCTAssertEqual(head.contentLength, 300_000)
    }

    func testServerIgnoringRangeHeader() {
        let cache = makeTestCache()
        let url = register(supportsRange: false)
        let request = MockLoadingRequest(offset: 1_000, length: 4_000)
        run(request, url: url, cache: cache)

        XCTAssertEqual(request.finishCount, 1)
        XCTAssertEqual(request.receivedData, body.subdata(in: 1_000..<5_000))
        XCTAssertEqual(request.contentLength, 300_000)
        // The full response is kept downloading so the cache fills up.
        XCTAssertTrue(cache.isCached(url))
        XCTAssertEqual(cache.cachedFileURL(for: url).flatMap { try? Data(contentsOf: $0) }, body)
    }

    func testContentInformationOnlyRequest() {
        let cache = makeTestCache()
        let url = register(mimeType: "audio/mpeg")
        let request = MockLoadingRequest(contentInformationOnly: ())
        run(request, url: url, cache: cache)

        XCTAssertEqual(request.finishCount, 1)
        XCTAssertNil(request.finishError)
        XCTAssertEqual(request.contentType, "public.mp3")
        XCTAssertEqual(request.contentLength, 300_000)
        XCTAssertTrue(request.receivedData.isEmpty)
    }

    func testOctetStreamFallsBackToFileExtension() {
        let cache = makeTestCache()
        let url = register(mimeType: "application/octet-stream")
        let request = MockLoadingRequest(offset: 0, length: 2)
        run(request, url: url, cache: cache)
        XCTAssertEqual(request.contentType, "public.mpeg-4")
    }

    func testCancelledRequestIsNeverFinished() {
        let cache = makeTestCache()
        let url = register()
        let request = MockLoadingRequest(offset: 0, length: 300_000)
        run(request, url: url, cache: cache, cancelImmediately: true)
        XCTAssertEqual(request.finishCount, 0)
    }

    func testHTTPErrorFailsRequest() {
        let cache = makeTestCache()
        let url = URL(string: "https://\(StubServer.host)/missing.mp4")!
        let request = MockLoadingRequest(offset: 0, length: 100)
        run(request, url: url, cache: cache)
        XCTAssertEqual(request.finishCount, 1)
        XCTAssertEqual(request.finishError as? PersistentAVPlayerItemError, .unexpectedStatusCode(404))
    }

    func testCacheSurvivesNewCacheInstance() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentAVPlayerItemTests-\(UUID().uuidString)", isDirectory: true)
        let url = register()
        run(MockLoadingRequest(offset: 0, length: 300_000), url: url, cache: makeTestCache(directory: directory))

        let reopened = makeTestCache(directory: directory)
        XCTAssertTrue(reopened.isCached(url))
        let request = MockLoadingRequest(offset: 5, length: 10)
        run(request, url: url, cache: reopened)
        XCTAssertEqual(request.receivedData, body.subdata(in: 5..<15))
        XCTAssertEqual(StubServer.shared.requests(for: url).count, 1)
    }

    func testRemoveAndClearAll() {
        let cache = makeTestCache()
        let first = register()
        let second = register()
        run(MockLoadingRequest(offset: 0, length: 300_000), url: first, cache: cache)
        run(MockLoadingRequest(offset: 0, length: 300_000), url: second, cache: cache)
        XCTAssertGreaterThan(cache.totalSize, 0)

        cache.remove(first)
        XCTAssertFalse(cache.isCached(first))
        XCTAssertTrue(cache.isCached(second))

        cache.clearAll()
        XCTAssertFalse(cache.isCached(second))
        XCTAssertEqual(cache.totalSize, 0)
    }

    func testChangedContentLengthDiscardsStaleBytes() {
        let cache = makeTestCache()
        let url = register()
        run(MockLoadingRequest(offset: 0, length: 1_000), url: url, cache: cache)
        IO.sync {
            let file = cache.openFile(for: url, fileExtension: "mp4")
            XCTAssertEqual(file.cachedByteCount, 1_000)
            file.updateContentInfo(contentLength: 500_000, mimeType: "video/mp4")
            XCTAssertEqual(file.cachedByteCount, 0)
            cache.releaseFile(file)
        }
    }

    func testSizeLimitEvictsLeastRecentlyUsed() {
        let cache = MediaCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("PersistentAVPlayerItemTests-\(UUID().uuidString)"),
            maxDiskSize: 450_000,
            sessionConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StubURLProtocol.self]
                return configuration
            }()
        )
        addTeardownBlock { cache.clearAll() }
        let old = register()
        let new = register()
        run(MockLoadingRequest(offset: 0, length: 300_000), url: old, cache: cache)
        run(MockLoadingRequest(offset: 0, length: 300_000), url: new, cache: cache)

        XCTAssertFalse(cache.isCached(old))
        XCTAssertTrue(cache.isCached(new))
    }
}
