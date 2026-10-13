// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import XCTest
@testable import PersistentAVPlayerItem

/// Several players of the same URL must share downloads instead of fetching
/// the same bytes more than once.
final class SharedDownloadTests: XCTestCase {
    private let body = XCTestCase.randomData(count: 300_000)

    private func register(gate: StubServer.Gate? = nil) -> URL {
        StubServer.shared.register(.init(data: body, mimeType: "video/mp4", supportsRange: true, gate: gate))
    }

    func testConcurrentRequestsForSameRangeShareOneDownload() {
        let cache = makeTestCache()
        let url = register()
        let first = MockLoadingRequest(offset: 0, length: 300_000)
        let second = MockLoadingRequest(offset: 0, length: 300_000)
        let third = MockLoadingRequest(offset: 50_000, length: 100_000)
        wait(for: [
            start(first, url: url, cache: cache),
            start(second, url: url, cache: cache),
            start(third, url: url, cache: cache),
        ], timeout: 10)

        XCTAssertEqual(first.receivedData, body)
        XCTAssertEqual(second.receivedData, body)
        XCTAssertEqual(third.receivedData, body.subdata(in: 50_000..<150_000))
        XCTAssertEqual(second.contentLength, 300_000)
        XCTAssertEqual(third.contentType, "public.mpeg-4")
        XCTAssertEqual(StubServer.shared.requests(for: url), ["bytes=0-299999"])
        XCTAssertTrue(cache.isCached(url))
    }

    func testLateSubscriberCatchesUpFromBuffer() {
        // The buffer is larger than what arrives before the pause, so nothing is on disk yet.
        assertLateSubscriberJoins(memoryBufferLimit: 1 << 20)
    }

    func testLateSubscriberReadsFlushedBytesThenJoins() {
        // Most bytes before the pause are flushed to disk; the rest are in the buffer.
        assertLateSubscriberJoins(memoryBufferLimit: 16 * 1024)
    }

    private func assertLateSubscriberJoins(memoryBufferLimit: Int, file: StaticString = #filePath, line: UInt = #line) {
        let cache = makeTestCache(memoryBufferLimit: memoryBufferLimit)
        let gate = StubServer.Gate(afterBytes: 100_000)
        let url = register(gate: gate)
        let player = keepOpen(url, in: cache)
        defer { player.close() }

        let early = MockLoadingRequest(offset: 0, length: 300_000)
        let earlyDone = start(early, url: url, cache: cache)
        waitUntil { player.file.activeDownloads.first?.networkOffset == 100_000 }

        let late = MockLoadingRequest(offset: 40_000, length: 200_000)
        let lateDone = start(late, url: url, cache: cache)
        // Let the late request attach before the download continues.
        IO.sync {}
        gate.open()
        wait(for: [earlyDone, lateDone], timeout: 10)

        XCTAssertEqual(early.receivedData, body, file: file, line: line)
        XCTAssertEqual(late.receivedData, body.subdata(in: 40_000..<240_000), file: file, line: line)
        XCTAssertEqual(late.contentLength, 300_000, file: file, line: line)
        XCTAssertEqual(StubServer.shared.requests(for: url), ["bytes=0-299999"], file: file, line: line)
    }

    func testNewDownloadStopsWhereAnotherIsUnderWay() {
        let cache = makeTestCache(memoryBufferLimit: 1 << 20)
        let gate = StubServer.Gate(afterBytes: 8 * 1024)
        let url = register(gate: gate)
        let player = keepOpen(url, in: cache)
        defer { player.close() }

        let middle = MockLoadingRequest(offset: 100_000, length: 100_000)
        let middleDone = start(middle, url: url, cache: cache)
        waitUntil { player.file.activeDownloads.first?.networkOffset == 108_192 }

        let whole = MockLoadingRequest(offset: 0, length: 0, toEnd: true)
        let wholeDone = start(whole, url: url, cache: cache)
        // The whole-file request fetches up to the middle download, then joins it.
        waitUntil { player.file.ranges.contains(0..<100_000) }
        gate.open()
        wait(for: [middleDone, wholeDone], timeout: 10)

        XCTAssertEqual(middle.receivedData, body.subdata(in: 100_000..<200_000))
        XCTAssertEqual(whole.receivedData, body)
        XCTAssertEqual(StubServer.shared.requests(for: url), [
            "bytes=100000-199999",
            "bytes=0-99999",
            "bytes=200000-299999",
        ])
    }

    func testCancellingOneSubscriberKeepsDownloadForOthers() {
        let cache = makeTestCache()
        let gate = StubServer.Gate(afterBytes: 100_000)
        let url = register(gate: gate)
        let player = keepOpen(url, in: cache)
        defer { player.close() }

        let cancelled = MockLoadingRequest(offset: 0, length: 300_000)
        let kept = MockLoadingRequest(offset: 0, length: 300_000)
        let cancelledWorker = WorkerHolder()
        let cancelledDone = start(cancelled, url: url, cache: cache, holder: cancelledWorker)
        let keptDone = start(kept, url: url, cache: cache)
        waitUntil { player.file.activeDownloads.first?.networkOffset == 100_000 }

        IO.sync {
            cancelled.isCancelled = true
            cancelledWorker.worker?.cancel()
        }
        gate.open()
        wait(for: [cancelledDone, keptDone], timeout: 10)

        XCTAssertEqual(cancelled.finishCount, 0)
        XCTAssertEqual(kept.finishCount, 1)
        XCTAssertEqual(kept.receivedData, body)
        XCTAssertEqual(StubServer.shared.requests(for: url), ["bytes=0-299999"])
    }

    func testLastSubscriberLeavingCancelsDownload() {
        let cache = makeTestCache()
        let url = register()
        let player = keepOpen(url, in: cache)
        defer { player.close() }

        run(MockLoadingRequest(offset: 0, length: 300_000), url: url, cache: cache, cancelImmediately: true)
        XCTAssertTrue(IO.sync { player.file.activeDownloads.isEmpty })
    }

    func testObserversSeeBytesFromAnyDownload() {
        let cache = makeTestCache()
        let url = register()
        let player = keepOpen(url, in: cache)
        defer { player.close() }

        let observerID = ObjectIdentifier(self)
        nonisolated(unsafe) var notifications = 0
        IO.sync { player.file.addObserver(observerID) { notifications += 1 } }
        run(MockLoadingRequest(offset: 0, length: 300_000), url: url, cache: cache)

        XCTAssertGreaterThan(IO.sync { notifications }, 0)
        XCTAssertTrue(IO.sync { player.file.isComplete })
        IO.sync { player.file.removeObserver(observerID) }
    }
}
