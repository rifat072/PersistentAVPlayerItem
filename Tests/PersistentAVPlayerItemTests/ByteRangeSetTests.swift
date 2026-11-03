// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import XCTest
@testable import PersistentAVPlayerItem

final class ByteRangeSetTests: XCTestCase {
    func testInsertMergesOverlappingAndAdjacentRanges() {
        var set = ByteRangeSet()
        set.insert(10..<20)
        set.insert(30..<40)
        XCTAssertEqual(set.ranges, [10..<20, 30..<40])

        set.insert(20..<25) // adjacent to the first
        XCTAssertEqual(set.ranges, [10..<25, 30..<40])

        set.insert(0..<5)
        XCTAssertEqual(set.ranges, [0..<5, 10..<25, 30..<40])

        set.insert(3..<35) // bridges everything
        XCTAssertEqual(set.ranges, [0..<40])
        XCTAssertEqual(set.byteCount, 40)
    }

    func testInsertIgnoresEmptyRange() {
        var set = ByteRangeSet([5..<10])
        set.insert(7..<7)
        XCTAssertEqual(set.ranges, [5..<10])
    }

    func testContains() {
        let set = ByteRangeSet([0..<10, 20..<30])
        XCTAssertTrue(set.contains(0..<10))
        XCTAssertTrue(set.contains(22..<25))
        XCTAssertFalse(set.contains(5..<25))
        XCTAssertFalse(set.contains(30..<31))
        XCTAssertTrue(set.contains(50..<50))
    }

    func testContiguousByteCountAndNextLowerBound() {
        let set = ByteRangeSet([0..<10, 20..<30])
        XCTAssertEqual(set.contiguousByteCount(from: 0), 10)
        XCTAssertEqual(set.contiguousByteCount(from: 25), 5)
        XCTAssertEqual(set.contiguousByteCount(from: 10), 0)
        XCTAssertEqual(set.nextLowerBound(after: 10), 20)
        XCTAssertEqual(set.nextLowerBound(after: 0), 20)
        XCTAssertNil(set.nextLowerBound(after: 20))
    }

    func testMissingRanges() {
        let set = ByteRangeSet([10..<20, 30..<40])
        XCTAssertEqual(set.missingRanges(in: 0..<50), [0..<10, 20..<30, 40..<50])
        XCTAssertEqual(set.missingRanges(in: 12..<35), [20..<30])
        XCTAssertEqual(set.missingRanges(in: 10..<20), [])
        XCTAssertEqual(ByteRangeSet().missingRanges(in: 0..<5), [0..<5])
    }

    func testCodableRoundTrip() throws {
        let set = ByteRangeSet([0..<10, 20..<30])
        let data = try JSONEncoder().encode(set)
        XCTAssertEqual(String(data: data, encoding: .utf8), "[[0,10],[20,30]]")
        XCTAssertEqual(try JSONDecoder().decode(ByteRangeSet.self, from: data), set)
    }
}

final class ParsingTests: XCTestCase {
    func testContentRange() {
        XCTAssertEqual(ContentRange("bytes 0-1/1234"), ContentRange("bytes 0-1/1234"))
        let range = ContentRange("bytes 100-199/1000")
        XCTAssertEqual(range?.start, 100)
        XCTAssertEqual(range?.end, 199)
        XCTAssertEqual(range?.total, 1000)
        XCTAssertNil(ContentRange("bytes 0-1/*")?.total)
        XCTAssertNil(ContentRange("bytes */1000"))
        XCTAssertNil(ContentRange(nil))
    }

    func testTypeIdentifier() {
        XCTAssertEqual(MediaType.typeIdentifier(mimeType: "video/mp4", fileExtension: nil), "public.mpeg-4")
        XCTAssertEqual(MediaType.typeIdentifier(mimeType: "audio/mpeg", fileExtension: nil), "public.mp3")
        XCTAssertEqual(MediaType.typeIdentifier(mimeType: "video/quicktime; charset=binary", fileExtension: nil), "com.apple.quicktime-movie")
        XCTAssertEqual(MediaType.typeIdentifier(mimeType: "application/octet-stream", fileExtension: "mp3"), "public.mp3")
        XCTAssertEqual(MediaType.typeIdentifier(mimeType: nil, fileExtension: nil), "public.mpeg-4")
    }

    func testCustomSchemeRoundTrip() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/videos/clip.mp4?token=abc"))
        let custom = try XCTUnwrap(url.customSchemeURL)
        XCTAssertEqual(custom.scheme, "pavpi-https")
        XCTAssertEqual(custom.pathExtension, "mp4")
        XCTAssertEqual(custom.remoteURLFromCustomScheme, url)
        XCTAssertNil(url.remoteURLFromCustomScheme)
    }

    func testCacheability() throws {
        let mp4 = try XCTUnwrap(URL(string: "https://example.com/a.mp4"))
        let hls = try XCTUnwrap(URL(string: "https://example.com/a.M3U8"))
        XCTAssertTrue(mp4.isRemoteHTTP)
        XCTAssertFalse(mp4.isHLSPlaylist)
        XCTAssertTrue(hls.isRemoteHTTP)
        XCTAssertTrue(hls.isHLSPlaylist)
        XCTAssertFalse(URL(fileURLWithPath: "/tmp/a.mp4").isRemoteHTTP)
    }
}
