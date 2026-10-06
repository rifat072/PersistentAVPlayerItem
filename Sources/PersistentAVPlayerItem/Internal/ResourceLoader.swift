// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import AVFoundation

/// The `AVAssetResourceLoaderDelegate` of one player item. Runs on `IO.queue`.
final class ResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case progress(cachedBytes: Int64, totalBytes: Int64)
        case completed
        case failed(Error)
    }

    /// Minimum interval between two progress events, to keep main-thread work low
    /// when many items download at once.
    static let progressInterval: TimeInterval = 0.25

    private let remoteURL: URL
    private let file: CacheFile
    private let cache: MediaCache
    private let eventHandler: @Sendable (Event) -> Void

    private var workers: [LoadingRequestWorker] = []
    private var isInvalidated = false
    private var didReportCompletion: Bool
    private var lastProgressDate = Date.distantPast

    init(remoteURL: URL, file: CacheFile, cache: MediaCache, eventHandler: @escaping @Sendable (Event) -> Void) {
        self.remoteURL = remoteURL
        self.file = file
        self.cache = cache
        self.eventHandler = eventHandler
        self.didReportCompletion = file.isComplete
    }

    /// Cancels all work. Called when the player item is deallocated.
    func invalidate() {
        IO.queue.async { [self] in
            isInvalidated = true
            let workers = self.workers
            self.workers = []
            for worker in workers { worker.cancel(force: true) }
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !isInvalidated, loadingRequest.request.url?.remoteURLFromCustomScheme != nil else { return false }
        let worker = LoadingRequestWorker(
            request: loadingRequest,
            file: file,
            fetcher: cache.fetcher,
            remoteURL: remoteURL,
            memoryBufferLimit: cache.memoryBufferLimit
        )
        worker.onBytesCached = { [weak self] in self?.bytesCached() }
        worker.onError = { [weak self] error in self?.eventHandler(.failed(error)) }
        worker.onDone = { [weak self] worker in self?.workers.removeAll { $0 === worker } }
        workers.append(worker)
        worker.start()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        workers.first { $0.request === loadingRequest }?.cancel()
    }

    // MARK: Progress

    private func bytesCached() {
        let total = file.contentLength ?? 0
        if !didReportCompletion, file.isComplete {
            didReportCompletion = true
            file.saveMetadata()
            eventHandler(.progress(cachedBytes: total, totalBytes: total))
            eventHandler(.completed)
            cache.enforceSizeLimit()
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastProgressDate) >= ResourceLoader.progressInterval else { return }
        lastProgressDate = now
        eventHandler(.progress(cachedBytes: file.cachedByteCount, totalBytes: total))
    }
}
