// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation
import XCTest
@testable import PersistentAVPlayerItem

/// In-memory HTTP server for `StubURLProtocol`.
final class StubServer: @unchecked Sendable {
    struct Resource {
        var data: Data
        var mimeType: String
        var supportsRange: Bool
    }

    static let shared = StubServer()
    static let host = "stub.test"

    private let lock = NSLock()
    private var resources: [URL: Resource] = [:]
    private var requestedRanges: [URL: [String]] = [:]

    func register(_ resource: Resource, name: String = "\(UUID().uuidString).mp4") -> URL {
        let url = URL(string: "https://\(StubServer.host)/\(name)")!
        lock.withLock { resources[url] = resource }
        return url
    }

    func resource(for url: URL) -> Resource? {
        lock.withLock { resources[url] }
    }

    func logRequest(_ url: URL, range: String?) {
        lock.withLock { requestedRanges[url, default: []].append(range ?? "none") }
    }

    func requests(for url: URL) -> [String] {
        lock.withLock { requestedRanges[url] ?? [] }
    }
}

final class StubURLProtocol: URLProtocol {
    static let chunkSize = 8 * 1024

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == StubServer.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let resource = StubServer.shared.resource(for: url) else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        StubServer.shared.logRequest(url, range: rangeHeader)

        let total = resource.data.count
        var body = resource.data
        var headers = ["Content-Type": resource.mimeType]
        var status = 200
        if resource.supportsRange, let (start, end) = Self.parse(rangeHeader, total: total) {
            status = 206
            body = resource.data.subdata(in: start..<(end + 1))
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        }
        headers["Content-Length"] = String(body.count)

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < body.count {
            let end = min(offset + Self.chunkSize, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parse(_ header: String?, total: Int) -> (Int, Int)? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]) else { return nil }
        let end = Int(bounds[1]).map { min($0, total - 1) } ?? total - 1
        return start <= end ? (start, end) : nil
    }
}

/// Records what the worker does with a loading request.
final class MockLoadingRequest: ResourceLoadingRequest, @unchecked Sendable {
    let wantsContentInformation: Bool
    let requestedDataRange: RequestedDataRange?
    var isCancelled = false

    private(set) var contentType: String?
    private(set) var contentLength: Int64?
    private(set) var isByteRangeAccessSupported: Bool?
    private(set) var receivedData = Data()
    private(set) var finishCount = 0
    private(set) var finishError: Error?

    init(wantsContentInformation: Bool = true, offset: Int64, length: Int64, toEnd: Bool = false) {
        self.wantsContentInformation = wantsContentInformation
        self.requestedDataRange = RequestedDataRange(offset: offset, length: length, requestsAllDataToEndOfResource: toEnd)
    }

    init(contentInformationOnly: Void) {
        wantsContentInformation = true
        requestedDataRange = nil
    }

    func setContentInformation(contentType: String, contentLength: Int64?, isByteRangeAccessSupported: Bool) {
        self.contentType = contentType
        self.contentLength = contentLength
        self.isByteRangeAccessSupported = isByteRangeAccessSupported
    }

    func deliver(_ data: Data) {
        XCTAssertEqual(finishCount, 0, "Data delivered after finishing")
        receivedData.append(data)
    }

    func finish(error: Error?) {
        finishCount += 1
        finishError = error
    }
}

/// Keeps a worker alive until it reports done.
final class WorkerHolder: @unchecked Sendable {
    var worker: LoadingRequestWorker?
}

extension XCTestCase {
    func makeTestCache(memoryBufferLimit: Int = 16 * 1024, directory: URL? = nil) -> MediaCache {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentAVPlayerItemTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MediaCache(directory: directory, memoryBufferLimit: memoryBufferLimit, sessionConfiguration: configuration)
    }

    static func randomData(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    /// Runs one worker for `request` to completion.
    func run(
        _ request: MockLoadingRequest,
        url: URL,
        cache: MediaCache,
        cancelImmediately: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let done = expectation(description: "worker done")
        let holder = WorkerHolder()
        IO.queue.async {
            let cacheFile = cache.openFile(for: url, fileExtension: "mp4")
            let worker = LoadingRequestWorker(
                request: request,
                file: cacheFile,
                fetcher: cache.fetcher,
                remoteURL: url,
                memoryBufferLimit: cache.memoryBufferLimit,
                readChunkSize: 16 * 1024
            )
            holder.worker = worker
            worker.onDone = { _ in
                cache.releaseFile(cacheFile)
                holder.worker = nil
                done.fulfill()
            }
            worker.start()
            if cancelImmediately {
                request.isCancelled = true
                worker.cancel()
            }
        }
        wait(for: [done], timeout: 10)
    }
}
