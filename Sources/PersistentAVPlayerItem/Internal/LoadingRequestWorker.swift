// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// Serves one loading request from AVFoundation.
///
/// The requested byte range is walked from its start. Bytes already on disk are
/// read in small chunks. For each gap, the worker attaches to a `SharedDownload`
/// already fetching those bytes (for another player of the same URL, say) or
/// starts a new one. The download, not the worker, writes the bytes to disk.
///
/// Confined to `IO.queue`.
final class LoadingRequestWorker: SharedDownloadSubscriber, @unchecked Sendable {
    let request: ResourceLoadingRequest

    /// Called when the loading request failed with a network or server error.
    var onError: ((Error) -> Void)?
    /// Called once, when the request has finished or was cancelled.
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

    private var download: SharedDownload?
    private var offsetAtSubscribe: Int64 = 0

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
        self.memoryBufferLimit = memoryBufferLimit
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
                attachOrStartDownload(from: 0, to: 2)
            } else {
                finishRequest(error: nil)
            }
            return
        }
        currentOffset = range.offset
        updateEndOffset()
        advance()
    }

    /// AVFoundation cancelled the request, or the owning player item went away.
    /// Never calls back into the loading request.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(IO.queue))
        isRequestFinished = true
        requestEnded()
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
            attachOrStartDownload(from: currentOffset, to: endOffset)
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

        // Fetch the gap up to the next cached range, the next download already
        // under way, or the end of the request, whichever comes first.
        let fetchEnd = [
            endOffset,
            file.ranges.nextLowerBound(after: currentOffset),
            file.nextDownloadStart(after: currentOffset),
        ].compactMap { $0 }.min()
        attachOrStartDownload(from: currentOffset, to: fetchEnd)
    }

    /// Subscribes to a download already fetching bytes from `start`, or starts one.
    private func attachOrStartDownload(from start: Int64, to end: Int64?) {
        if let download = file.joinableDownload(at: start) {
            subscribe(to: download)
            return
        }
        let download = file.startDownload(
            fetcher: fetcher,
            remoteURL: remoteURL,
            from: start,
            to: end,
            memoryBufferLimit: memoryBufferLimit
        )
        subscribe(to: download)
        download.start()
    }

    private func subscribe(to download: SharedDownload) {
        self.download = download
        offsetAtSubscribe = currentOffset
        // May call back right away with the response and buffered bytes.
        download.add(self)
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
        requestEnded()
    }

    private func requestEnded() {
        if let download {
            self.download = nil
            download.remove(self)
        }
        guard !isDone else { return }
        isDone = true
        onDone?(self)
    }

    // MARK: SharedDownloadSubscriber

    func downloadDidReceiveResponse(_ download: SharedDownload) {
        guard download === self.download, !isRequestFinished else { return }
        if needsContentInformation {
            fillContentInformation()
            needsContentInformation = false
        }
        guard request.requestedDataRange != nil else {
            finishRequest(error: nil)
            return
        }
        updateEndOffset()
        if let endOffset, currentOffset >= endOffset {
            finishRequest(error: nil)
        }
    }

    func download(_ download: SharedDownload, didReceive data: Data, at chunkStart: Int64) {
        guard download === self.download, !isRequestFinished else { return }
        let chunkEnd = chunkStart + Int64(data.count)
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

    func download(_ download: SharedDownload, didCompleteWithError error: Error?) {
        guard download === self.download else { return }
        self.download = nil
        if isRequestFinished { return }

        if let error {
            finishRequest(error: error)
        } else if endOffset == nil {
            // Length unknown: the server sent everything it has.
            finishRequest(error: nil)
        } else if currentOffset == offsetAtSubscribe {
            finishRequest(error: PersistentAVPlayerItemError.incompleteResponse)
        } else {
            // The download's bytes are on disk now; continue from there.
            advance()
        }
    }
}
