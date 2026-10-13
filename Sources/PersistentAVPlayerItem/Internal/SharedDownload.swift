// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// Receives the bytes of a `SharedDownload`. Called on `IO.queue`.
protocol SharedDownloadSubscriber: AnyObject {
    /// The response arrived; the cache file now knows the content length and type.
    func downloadDidReceiveResponse(_ download: SharedDownload)
    /// `data` holds the resource bytes starting at `offset`. It may begin before the
    /// subscriber's position (catch-up from the buffer when subscribing).
    func download(_ download: SharedDownload, didReceive data: Data, at offset: Int64)
    /// The download ended. Its bytes are on disk by now.
    func download(_ download: SharedDownload, didCompleteWithError error: Error?)
}

/// One HTTP range request for a cache file, shared by every loading request
/// that needs its bytes, so players showing the same URL download it once.
///
/// Received bytes go to all subscribers and into a small buffer, which is
/// written to the cache file whenever it reaches `memoryBufferLimit`. Bytes this
/// download has received are therefore always either on disk or in the buffer.
///
/// The download is cancelled when its last subscriber leaves, except when the
/// server ignores `Range`: then it keeps filling the file while the file is open,
/// since any new request would start again from byte 0.
///
/// Confined to `IO.queue`.
final class SharedDownload: RemoteDataTaskHandler, @unchecked Sendable {
    /// A subscriber may attach this far ahead of the download's position and wait,
    /// rather than opening another connection.
    static let joinDistance: Int64 = 256 * 1024

    private let file: CacheFile
    private let fetcher: RemoteFetcher
    private let remoteURL: URL
    private let memoryBufferLimit: Int

    /// First byte of the requested range (0 once the server answered with the whole file).
    private(set) var startOffset: Int64
    /// Exclusive end of the requested range; `nil` means to the end of the resource.
    private(set) var endOffset: Int64?
    /// Resource offset of the next byte to arrive.
    private(set) var networkOffset: Int64
    private(set) var hasResponse = false
    private(set) var serverIgnoresRange = false
    private(set) var isFinished = false

    private var task: URLSessionTask?
    private var subscribers: [SharedDownloadSubscriber] = []
    private var writeBuffer = Data()
    private var writeBufferOffset: Int64 = 0

    /// Downloads `[start, end)`, or everything from `start` when `end` is `nil`.
    init(file: CacheFile, fetcher: RemoteFetcher, remoteURL: URL, from start: Int64, to end: Int64?, memoryBufferLimit: Int) {
        self.file = file
        self.fetcher = fetcher
        self.remoteURL = remoteURL
        self.memoryBufferLimit = max(memoryBufferLimit, 16 * 1024)
        self.startOffset = start
        self.endOffset = end
        self.networkOffset = start
    }

    func start() {
        var request = URLRequest(url: remoteURL)
        let rangeEnd = endOffset.map { String($0 - 1) } ?? ""
        request.setValue("bytes=\(startOffset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        task = fetcher.startTask(with: request, handler: self)
    }

    /// Whether a subscriber positioned at `offset` can be served by this download:
    /// the bytes from `offset` are either in the buffer or still to come, close enough.
    func canServe(offset: Int64) -> Bool {
        guard !isFinished else { return false }
        if let endOffset, offset >= endOffset { return false }
        let earliestBufferedOffset = writeBuffer.isEmpty ? networkOffset : writeBufferOffset
        guard offset >= earliestBufferedOffset else { return false }
        return serverIgnoresRange || offset - networkOffset <= SharedDownload.joinDistance
    }

    /// Adds a subscriber and replays what it missed: the response, and the
    /// bytes still held in the buffer.
    func add(_ subscriber: SharedDownloadSubscriber) {
        subscribers.append(subscriber)
        guard hasResponse else { return }
        subscriber.downloadDidReceiveResponse(self)
        if !writeBuffer.isEmpty, subscribers.contains(where: { $0 === subscriber }) {
            subscriber.download(self, didReceive: writeBuffer, at: writeBufferOffset)
        }
    }

    func remove(_ subscriber: SharedDownloadSubscriber) {
        subscribers.removeAll { $0 === subscriber }
        guard subscribers.isEmpty, !isFinished else { return }
        if serverIgnoresRange, file.fillDownload == nil || file.fillDownload === self {
            file.fillDownload = self
        } else {
            cancel()
        }
    }

    /// Stops the download without notifying subscribers.
    func cancel() {
        guard !isFinished else { return }
        subscribers = []
        let task = self.task
        finish(error: nil)
        task?.cancel()
    }

    // MARK: RemoteDataTaskHandler

    func remoteTask(_ task: URLSessionTask, didReceive response: URLResponse) -> Bool {
        guard task === self.task else { return false }
        guard let response = response as? HTTPURLResponse else {
            finish(error: PersistentAVPlayerItemError.invalidResponse)
            return false
        }

        switch response.statusCode {
        case 206:
            guard let contentRange = ContentRange(response.value(forHTTPHeaderField: "Content-Range")),
                  contentRange.start == startOffset else {
                finish(error: PersistentAVPlayerItemError.invalidResponse)
                return false
            }
            file.updateContentInfo(contentLength: contentRange.total, mimeType: response.mimeType)
        case 200:
            // The server ignored `Range` and sends the whole file from byte 0.
            serverIgnoresRange = true
            startOffset = 0
            endOffset = nil
            networkOffset = 0
            let length = response.expectedContentLength
            file.updateContentInfo(contentLength: length >= 0 ? length : nil, mimeType: response.mimeType)
        default:
            finish(error: PersistentAVPlayerItemError.unexpectedStatusCode(response.statusCode))
            return false
        }

        hasResponse = true
        if let length = file.contentLength {
            endOffset = min(endOffset ?? length, length)
        }
        for subscriber in subscribers {
            subscriber.downloadDidReceiveResponse(self)
        }
        // Subscribers may have left (e.g. a content-information-only request).
        return self.task != nil
    }

    func remoteTask(_ task: URLSessionTask, didReceive data: Data) {
        guard task === self.task else { return }
        let chunkStart = networkOffset
        networkOffset += Int64(data.count)
        appendToWriteBuffer(data, at: chunkStart)
        for subscriber in subscribers {
            subscriber.download(self, didReceive: data, at: chunkStart)
        }
    }

    func remoteTask(_ task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        finish(error: error)
    }

    // MARK: Private

    private func finish(error: Error?) {
        guard !isFinished else { return }
        isFinished = true
        task = nil
        flushWriteBuffer()
        file.saveMetadata()
        file.activeDownloads.removeAll { $0 === self }
        if file.fillDownload === self {
            file.fillDownload = nil
        }
        let subscribers = self.subscribers
        self.subscribers = []
        for subscriber in subscribers {
            subscriber.download(self, didCompleteWithError: error)
        }
    }

    private func appendToWriteBuffer(_ data: Data, at offset: Int64) {
        if !writeBuffer.isEmpty, writeBufferOffset + Int64(writeBuffer.count) != offset {
            flushWriteBuffer()
        }
        if writeBuffer.isEmpty {
            writeBufferOffset = offset
        }
        writeBuffer.append(data)
        if writeBuffer.count >= memoryBufferLimit {
            flushWriteBuffer()
        }
    }

    private func flushWriteBuffer() {
        guard !writeBuffer.isEmpty else { return }
        // A failed write (e.g. disk full) only means these bytes aren't cached.
        try? file.write(writeBuffer, at: writeBufferOffset)
        writeBufferOffset += Int64(writeBuffer.count)
        writeBuffer.removeAll(keepingCapacity: true)
        file.notifyObservers()
    }
}
