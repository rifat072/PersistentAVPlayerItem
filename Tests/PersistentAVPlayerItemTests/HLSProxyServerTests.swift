// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import XCTest
@testable import PersistentAVPlayerItem

/// Drives the HLS server over real loopback HTTP, as AVPlayer would, against
/// stub origin resources.
final class HLSProxyServerTests: XCTestCase {
    private struct Stream {
        var master: URL
        var low: URL
        var high: URL
        var segments: [URL]
        var segmentData: [Data]
    }

    /// A VOD stream with two variants; the low one has three TS segments.
    private func registerStream(live: Bool = false) -> Stream {
        let directory = "hls-\(UUID().uuidString)"
        let segmentData = (0..<3).map { XCTestCase.randomData(count: 20_000 + $0 * 1000) }
        let segments = segmentData.enumerated().map { index, data in
            StubServer.shared.register(.init(data: data, mimeType: "video/mp2t", supportsRange: true), name: "\(directory)/low/seg\(index).ts")
        }
        let media = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        seg0.ts
        #EXTINF:4.0,
        seg1.ts
        #EXTINF:4.0,
        seg2.ts
        \(live ? "" : "#EXT-X-ENDLIST")
        """
        let low = StubServer.shared.register(.init(data: Data(media.utf8), mimeType: "application/vnd.apple.mpegurl", supportsRange: false), name: "\(directory)/low/index.m3u8")
        let highMedia = "#EXTM3U\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n"
        let high = StubServer.shared.register(.init(data: Data(highMedia.utf8), mimeType: "application/vnd.apple.mpegurl", supportsRange: false), name: "\(directory)/high/index.m3u8")
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000
        high/index.m3u8
        """
        let masterURL = StubServer.shared.register(.init(data: Data(master.utf8), mimeType: "application/vnd.apple.mpegurl", supportsRange: false), name: "\(directory)/master.m3u8")
        return Stream(master: masterURL, low: low, high: high, segments: segments, segmentData: segmentData)
    }

    private let client: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private func get(_ url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        let (data, response) = try await client.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func uriLines(_ data: Data) throws -> [URL] {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { URL(string: String($0)) }
    }

    private func makeSession(_ cache: MediaCache, url: URL) async throws -> (HLSSession, URL) {
        let result = await Task.detached { cache.hlsProxyServer().makeSession(for: url) { _ in } }.value
        let session = try XCTUnwrap(result)
        addTeardownBlock { session.session.invalidate() }
        return session
    }

    func testStreamsAndCachesVOD() async throws {
        let cache = makeTestCache()
        let stream = registerStream()
        let (_, masterURL) = try await makeSession(cache, url: stream.master)

        let (masterData, masterResponse) = try await get(masterURL)
        XCTAssertEqual(masterResponse.statusCode, 200)
        XCTAssertEqual(masterResponse.value(forHTTPHeaderField: "Content-Type"), "application/vnd.apple.mpegurl")
        let variants = try uriLines(masterData)
        XCTAssertEqual(variants.count, 2)
        XCTAssertTrue(variants.allSatisfy { $0.host == "127.0.0.1" })

        let (mediaData, _) = try await get(variants[0])
        let segmentURLs = try uriLines(mediaData)
        XCTAssertEqual(segmentURLs.count, 3)
        XCTAssertTrue(segmentURLs.allSatisfy { $0.host == "127.0.0.1" })
        XCTAssertFalse(cache.isCached(stream.master))

        // A byte range, then each whole segment.
        let (part, partResponse) = try await get(segmentURLs[1], range: "bytes=100-199")
        XCTAssertEqual(partResponse.statusCode, 206)
        XCTAssertEqual(partResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 100-199/21000")
        XCTAssertEqual(part, stream.segmentData[1].subdata(in: 100..<200))
        for (url, expected) in zip(segmentURLs, stream.segmentData) {
            let (data, response) = try await get(url)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "video/mp2t")
            XCTAssertEqual(data, expected)
        }

        waitUntil { cache.isHLSComplete(stream.master) }
        XCTAssertTrue(cache.isCached(stream.master))
        let status = cache.status(for: stream.master)
        XCTAssertGreaterThanOrEqual(status.cachedBytes, Int64(stream.segmentData.reduce(0) { $0 + $1.count }))
        XCTAssertEqual(status.totalBytes, status.cachedBytes)
        XCTAssertNil(cache.cachedFileURL(for: stream.master))
    }

    func testCompleteStreamPlaysFromDiskWithOnlyCachedVariants() async throws {
        let cache = makeTestCache()
        let stream = registerStream()
        let (_, masterURL) = try await makeSession(cache, url: stream.master)
        let variants = try uriLines(try await get(masterURL).0)
        for url in try uriLines(try await get(variants[0]).0) {
            _ = try await get(url)
        }
        waitUntil { cache.isHLSComplete(stream.master) }

        let requestsBefore = ([stream.master, stream.low] + stream.segments).map { StubServer.shared.requests(for: $0).count }
        let (session, secondURL) = try await makeSession(cache, url: stream.master)
        XCTAssertTrue(session.isComplete)
        let offlineVariants = try uriLines(try await get(secondURL).0)
        // Only the fully cached low variant is offered.
        XCTAssertEqual(offlineVariants.count, 1)
        let segmentURLs = try uriLines(try await get(offlineVariants[0]).0)
        for (url, expected) in zip(segmentURLs, stream.segmentData) {
            let (data, _) = try await get(url)
            XCTAssertEqual(data, expected)
        }
        let requestsAfter = ([stream.master, stream.low] + stream.segments).map { StubServer.shared.requests(for: $0).count }
        XCTAssertEqual(requestsAfter, requestsBefore, "A cached stream must not touch the network")
    }

    func testLiveSegmentsArePassedThrough() async throws {
        let cache = makeTestCache()
        let stream = registerStream(live: true)
        let (_, masterURL) = try await makeSession(cache, url: stream.master)
        let variants = try uriLines(try await get(masterURL).0)
        let segmentURLs = try uriLines(try await get(variants[0]).0)
        XCTAssertEqual(segmentURLs, stream.segments)

        // Live media playlists are fetched every time, never cached.
        _ = try await get(variants[0])
        XCTAssertEqual(StubServer.shared.requests(for: stream.low).count, 2)
        XCTAssertNil(IO.sync { cache.cachedPlaylist(for: stream.low) })
    }

    func testRemoveDeletesWholeStream() async throws {
        let cache = makeTestCache()
        let stream = registerStream()
        let (_, masterURL) = try await makeSession(cache, url: stream.master)
        let variants = try uriLines(try await get(masterURL).0)
        for url in try uriLines(try await get(variants[0]).0) {
            _ = try await get(url)
        }
        waitUntil { cache.isHLSComplete(stream.master) }

        cache.remove(stream.master)
        XCTAssertEqual(cache.status(for: stream.master).cachedBytes, 0)
        XCTAssertEqual(cache.status(for: stream.segments[0]).cachedBytes, 0)
        XCTAssertEqual(cache.totalSize, 0)
    }

    func testUpstreamErrorIsForwarded() async throws {
        let cache = makeTestCache()
        let missing = try XCTUnwrap(URL(string: "https://\(StubServer.host)/\(UUID().uuidString)/master.m3u8"))
        let (_, masterURL) = try await makeSession(cache, url: missing)
        let (_, response) = try await get(masterURL)
        XCTAssertEqual(response.statusCode, 404)
    }
}
