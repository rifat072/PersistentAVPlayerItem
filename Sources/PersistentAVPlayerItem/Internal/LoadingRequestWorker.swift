// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// Serves one loading request from AVFoundation.
///
/// The requested byte range is walked from its start. Bytes already on disk are
/// read in small chunks; each gap is fetched with an HTTP `Range` request. Bytes
/// from the network are handed to AVFoundation immediately and collected in a
/// small buffer, which is written to the cache file whenever it reaches
/// `memoryBufferLimit`. RAM use per stream therefore stays at about one buffer.
///
/// Confined to `IO.queue`.
final class LoadingRequestWorker: RemoteDataTaskHandler, @unchecked Sendable {
    let request: ResourceLoadingRequest

    /// Called after buffered bytes were written to the cache file.
    var onBytesCached: (() -> Void)?
    /// Called when the loading request failed with a network or server error.
    var onError: ((Error) -> Void)?
    /// Called once, when the request has ended and no download is running any more.
    var onDone: ((LoadingRequestWorker) -> Void)?

    private let file: CacheFile
    private let fetcher: RemoteFetcher
    private let remoteURL: URL
    private let memoryBufferLimit: Int
    private let readChunkSize: Int

    private var needsContentInformation = false
    /// Next byte to hand to AVFoundation.
    private var currentOffset: Int64 = 0
    /// Exclusive end of the requested range; `nil` while the resource length is unknown.
    private var endOffset: Int64?
    private var isRequestFinished = false
    private var isDone = false

    private var task: URLSessionTask?
    private var taskStartOffset: Int64 = 0
    private var offsetAtTaskStart: Int64 = 0
    /// Resource offset of the next byte the current task will receive.
    private var networkOffset: Int64 = 0
    private var serverIgnoresRange = false
    /// Keeps downloading after the request ended, to fill the cache from a server
    /// that ignores `Range` and so can only ever send the whole file.
    private var isFillingWholeFile = false

    private var writeBuffer = Data()
    private var writeBufferOffset: Int64 = 0

    init(
        request: ResourceLoadingRequest,
        file: CacheFile,
        fetcher: RemoteFetcher,
        remoteURL: URL,
        memoryBufferLimit: Int,
        readChunkSize: Int = 256 * 1024
    ) {
        self.request = request
        self.file = file
        self.fetcher = fetcher
        self.remoteURL = remoteURL
        self.memoryBufferLimit = max(memoryBufferLimit, 16 * 1024)
        self.readChunkSize = max(readChunkSize, 16 * 1024)
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(IO.queue))
        needsContentInformation = request.wantsContentInformation
        if needsContentInformation, file.contentLength != nil {
            fillContentInformation()
            needsContentInformation = false
        }

        guard let range = request.requestedDataRange else {
            // Content information only.
            if needsContentInformation {
                startNetworkTask(from: 0, to: 2)
            } else {
                finishRequest(error: nil)
            }
            return
        }
        currentOffset = range.offset
        updateEndOffset()
        advance()
    }

    /// AVFoundation cancelled the request, or the owning player item went away
    /// (`force`). Never calls back into the loading request.
    func cancel(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(IO.queue))
        isRequestFinished = true
        requestEnded(force: force)
    }

    // MARK: Serving

    private func advance() {
        guard !isRequestFinished else { return }
        if request.isCancelled {
            cancel()
            return
        }
        if let endOffset, currentOffset >= endOffset {
            finishRequest(error: nil)
            return
        }
        if needsContentInformation {
            startNetworkTask(from: currentOffset, to: endOffset)
            return
        }

        let cachedCount = file.ranges.contiguousByteCount(from: currentOffset)
        if cachedCount > 0 {
            var length = min(cachedCount, Int64(readChunkSize))
            if let endOffset { length = min(length, endOffset - currentOffset) }
            do {
                let data = try file.read(at: currentOffset, length: Int(length))
                request.deliver(data)
                currentOffset += Int64(data.count)
            } catch {
                // The data file is unusable; drop it and fetch from the network instead.
                file.reset()
            }
            // One chunk per queue hop, so a cancellation can get in between.
            IO.queue.async { [weak self] in self?.advance() }
            return
        }

        // Fetch the gap up to the next cached range (or the end of the request).
        let fetchEnd = [endOffset, file.ranges.nextLowerBound(after: currentOffset)].compactMap { $0 }.min()
        startNetworkTask(from: currentOffset, to: fetchEnd)
    }

    private func updateEndOffset() {
        guard let range = request.requestedDataRange else { return }
        var end: Int64? = range.requestsAllDataToEndOfResource ? nil : range.offset + range.length
        if let length = file.contentLength {
            end = min(end ?? length, length)
        }
        endOffset = end
    }

    private func fillContentInformation() {
        request.setContentInformation(
            contentType: MediaType.typeIdentifier(mimeType: file.mimeType, fileExtension: file.fileExtension),
            contentLength: file.contentLength,
            isByteRangeAccessSupported: file.contentLength != nil
        )
    }

    private func finishRequest(error: Error?) {
        guard !isRequestFinished else { return }
        isRequestFinished = true
        if !request.isCancelled {
            request.finish(error: error)
        }
        if let error { onError?(error) }
        requestEnded(force: error != nil)
    }

    private func requestEnded(force: Bool) {
        if task != nil {
            if !force && (isFillingWholeFile || claimWholeFileDownload()) { return }
            stopNetworkTask()
        }
        markDone()
    }

    private func claimWholeFileDownload() -> Bool {
        guard serverIgnoresRange, !file.isFullDownloadInProgress else { return false }
        file.isFullDownloadInProgress = true
        isFillingWholeFile = true
        return true
    }

    private func markDone() {
        guard !isDone else { return }
        isDone = true
        flushWriteBuffer()
        file.saveMetadata()
        onDone?(self)
    }

    // MARK: Network

    /// Requests `[start, end)`, or everything from `start` when `end` is `nil`.
    private func startNetworkTask(from start: Int64, to end: Int64?) {
        var urlRequest = URLRequest(url: remoteURL)
        let rangeEnd = end.map { String($0 - 1) } ?? ""
        urlRequest.setValue("bytes=\(start)-\(rangeEnd)", forHTTPHeaderField: "Range")
        taskStartOffset = start
        offsetAtTaskStart = currentOffset
        networkOffset = start
        task = fetcher.startTask(with: urlRequest, handler: self)
    }

    private func stopNetworkTask() {
        let task = self.task
        self.task = nil
        task?.cancel()
        flushWriteBuffer()
        if isFillingWholeFile {
            isFillingWholeFile = false
            file.isFullDownloadInProgress = false
        }
    }

    func remoteTask(_ task: URLSessionTask, didReceive response: URLResponse) -> Bool {
        guard task === self.task else { return false }
        guard let response = response as? HTTPURLResponse else {
            finishRequest(error: PersistentAVPlayerItemError.invalidResponse)
            return false
        }

        switch response.statusCode {
        case 206:
            guard let contentRange = ContentRange(response.value(forHTTPHeaderField: "Content-Range")),
                  contentRange.start == taskStartOffset else {
                finishRequest(error: PersistentAVPlayerItemError.invalidResponse)
                return false
            }
            serverIgnoresRange = false
            file.updateContentInfo(contentLength: contentRange.total, mimeType: response.mimeType)
        case 200:
            // The server ignored `Range` and sends the whole file from byte 0.
            serverIgnoresRange = true
            networkOffset = 0
            let length = response.expectedContentLength
            file.updateContentInfo(contentLength: length >= 0 ? length : nil, mimeType: response.mimeType)
        default:
            finishRequest(error: PersistentAVPlayerItemError.unexpectedStatusCode(response.statusCode))
            return false
        }

        if needsContentInformation {
            fillContentInformation()
            needsContentInformation = false
        }
        guard request.requestedDataRange != nil else {
            finishRequest(error: nil)
            // Still running only if it became the whole-file download.
            return self.task != nil
        }
        updateEndOffset()
        if let endOffset, currentOffset >= endOffset {
            finishRequest(error: nil)
            return self.task != nil
        }
        return true
    }

    func remoteTask(_ task: URLSessionTask, didReceive data: Data) {
        guard task === self.task else { return }
        let chunkStart = networkOffset
        let chunkEnd = chunkStart + Int64(data.count)
        networkOffset = chunkEnd
        appendToWriteBuffer(data, at: chunkStart)

        guard !isRequestFinished else { return }
        if chunkStart <= currentOffset, currentOffset < chunkEnd, !request.isCancelled {
            let deliverEnd = min(chunkEnd, endOffset ?? chunkEnd)
            if deliverEnd > currentOffset {
                let lower = data.startIndex + Int(currentOffset - chunkStart)
                let upper = data.startIndex + Int(deliverEnd - chunkStart)
                request.deliver(data.subdata(in: lower..<upper))
                currentOffset = deliverEnd
            }
        }
        if let endOffset, currentOffset >= endOffset {
            finishRequest(error: nil)
        }
    }

    func remoteTask(_ task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        self.task = nil
        flushWriteBuffer()
        if isFillingWholeFile {
            isFillingWholeFile = false
            file.isFullDownloadInProgress = false
        }

        if isRequestFinished {
            markDone()
        } else if let error {
            finishRequest(error: error)
        } else if endOffset == nil {
            // Length unknown: the server sent everything it has.
            finishRequest(error: nil)
        } else if currentOffset == offsetAtTaskStart {
            finishRequest(error: PersistentAVPlayerItemError.incompleteResponse)
        } else {
            advance()
        }
    }

    // MARK: Write buffer

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
        onBytesCached?()
    }
}
