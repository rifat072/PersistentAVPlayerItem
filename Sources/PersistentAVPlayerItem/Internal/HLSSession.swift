// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// The HLS server's view of one player item: which segments its player has
/// asked for, so caching progress and completion can be reported to it.
///
/// Progress covers the segments of every VOD media playlist the player has
/// loaded. Since segment sizes are only known once downloaded, `totalBytes` is
/// extrapolated from the segments cached so far until the last one is on disk.
///
/// Confined to `IO.queue`, except `invalidate()`.
final class HLSSession: @unchecked Sendable {
    let id: Int
    /// Whether the stream could play from disk when the item was created.
    let isComplete: Bool

    private weak var server: HLSProxyServer?
    private weak var cache: MediaCache?
    private let eventHandler: @Sendable (ResourceLoader.Event) -> Void

    private struct SegmentKey: Hashable {
        var url: URL
        var byteRange: Range<Int64>?
    }

    private var segments: [SegmentKey: (isCached: Bool, byteCount: Int64)] = [:]
    private var keysByURL: [URL: [SegmentKey]] = [:]
    private var didReportCompletion: Bool
    private var lastProgressDate = Date.distantPast

    init(id: Int, server: HLSProxyServer, cache: MediaCache, isComplete: Bool, eventHandler: @escaping @Sendable (ResourceLoader.Event) -> Void) {
        self.id = id
        self.server = server
        self.cache = cache
        self.isComplete = isComplete
        self.eventHandler = eventHandler
        self.didReportCompletion = isComplete
    }

    /// Ends the session and closes its connections. Called when the item is deallocated.
    func invalidate() {
        IO.queue.async { [server, id] in server?.removeSession(id) }
    }

    /// Adds the segments of a media playlist the player loaded.
    func track(_ references: [HLSPlaylist.Reference]) {
        guard let cache else { return }
        for reference in references {
            let key = SegmentKey(url: reference.url, byteRange: reference.byteRange)
            guard segments[key] == nil else { continue }
            segments[key] = cache.cacheState(of: reference)
            keysByURL[reference.url, default: []].append(key)
        }
        reportProgress()
    }

    /// Bytes of the segment at `url` may have been cached.
    func segmentUpdated(_ url: URL) {
        guard let cache, let keys = keysByURL[url] else { return }
        for key in keys {
            segments[key] = cache.cacheState(of: HLSPlaylist.Reference(url: key.url, kind: .segment, byteRange: key.byteRange))
        }
        reportProgress()
    }

    func report(_ error: Error) {
        eventHandler(.failed(error))
    }

    private func reportProgress() {
        let cached = segments.values.filter(\.isCached)
        guard !cached.isEmpty else { return }
        let cachedBytes = cached.reduce(0) { $0 + $1.byteCount }
        if cached.count == segments.count {
            guard !didReportCompletion else { return }
            didReportCompletion = true
            eventHandler(.progress(cachedBytes: cachedBytes, totalBytes: cachedBytes))
            eventHandler(.completed)
            cache?.enforceSizeLimit()
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastProgressDate) >= ResourceLoader.progressInterval else { return }
        lastProgressDate = now
        let estimatedTotal = cachedBytes * Int64(segments.count) / Int64(cached.count)
        eventHandler(.progress(cachedBytes: cachedBytes, totalBytes: estimatedTotal))
    }
}
