// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// The on-disk store used by `PersistentAVPlayerItem`.
///
/// Each remote URL is stored as a sparse data file plus a small JSON file that
/// records which byte ranges have been downloaded, so partially played media
/// resumes from disk and only the missing bytes are fetched. An HLS stream is
/// stored as one such entry per playlist and per segment.
public final class MediaCache: @unchecked Sendable {
    /// The cache used by `PersistentAVPlayerItem` unless another one is passed in.
    public static let shared = MediaCache()

    /// `Documents/PersistentAVPlayerItem`.
    public static var defaultDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("PersistentAVPlayerItem", isDirectory: true)
    }

    /// Which variants of a cached HLS stream are offered to the player.
    public enum HLSVariantPolicy: Sendable {
        /// While online, every variant is offered, cached ones first: playback
        /// starts from disk, and the player may switch to a better variant,
        /// which is then cached too. Offline, only cached variants are offered.
        case upgradeWhenOnline
        /// Once a variant is fully cached, only cached variants are offered,
        /// online or not, so a cached stream never uses the network.
        case preferCached
    }

    public struct Status: Equatable, Sendable {
        /// Bytes of the resource stored on disk.
        public var cachedBytes: Int64
        /// Size of the resource, once known.
        public var totalBytes: Int64?
        /// Whether the whole resource is on disk.
        public var isComplete: Bool

        public var fractionCached: Double {
            guard let totalBytes, totalBytes > 0 else { return 0 }
            return Double(cachedBytes) / Double(totalBytes)
        }
    }

    public let directory: URL
    /// Maximum bytes each stream holds in memory before writing them to disk.
    public let memoryBufferLimit: Int
    /// When set, least recently used entries are deleted once the cache grows past
    /// this size. Entries in use by a player item are never deleted.
    public let maxDiskSize: Int64?
    public let hlsVariantPolicy: HLSVariantPolicy

    let fetcher: RemoteFetcher
    /// Open cache files by key. Confined to `IO.queue`.
    private var openFiles: [String: CacheFile] = [:]
    /// Created on first use by an HLS item. Confined to `IO.queue`.
    private var hlsServer: HLSProxyServer?

    /// - Parameters:
    ///   - directory: Where cached media is stored. Created on first write and
    ///     excluded from iCloud backup.
    ///   - memoryBufferLimit: Bytes each stream buffers in RAM before writing to disk.
    ///   - maxDiskSize: Optional size limit for the whole cache, in bytes.
    ///   - hlsVariantPolicy: Whether a cached HLS stream may switch to variants
    ///     that aren't cached yet.
    ///   - sessionConfiguration: Base configuration for downloads, e.g. to add
    ///     `httpAdditionalHeaders`. Its `urlCache` is disabled.
    public init(
        directory: URL = MediaCache.defaultDirectory,
        memoryBufferLimit: Int = 256 * 1024,
        maxDiskSize: Int64? = nil,
        hlsVariantPolicy: HLSVariantPolicy = .upgradeWhenOnline,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.directory = directory
        self.memoryBufferLimit = memoryBufferLimit
        self.maxDiskSize = maxDiskSize
        self.hlsVariantPolicy = hlsVariantPolicy
        self.fetcher = RemoteFetcher(configuration: sessionConfiguration)
    }

    deinit {
        fetcher.invalidate()
        if let hlsServer {
            IO.queue.async { hlsServer.stop() }
        }
    }

    // MARK: Public API

    /// Whether the whole resource at `url` is stored on disk. For an HLS stream,
    /// whether at least one variant (with its audio) can play without network.
    public func isCached(_ url: URL) -> Bool {
        status(for: url).isComplete
    }

    /// For an HLS stream, `cachedBytes` counts all of its playlists and segments
    /// on disk, and `totalBytes` is only known once the stream is complete.
    public func status(for url: URL) -> Status {
        IO.sync {
            guard let metadata = metadata(for: url) else {
                return Status(cachedBytes: 0, totalBytes: nil, isComplete: false)
            }
            if metadata.isHLSPlaylist {
                return hlsStatus(for: url)
            }
            let cached = metadata.ranges.byteCount
            let isComplete = metadata.contentLength.map { $0 > 0 && metadata.ranges.contains(0..<$0) } ?? false
            return Status(cachedBytes: cached, totalBytes: metadata.contentLength, isComplete: isComplete)
        }
    }

    /// The local file for `url`, only once it is completely downloaded. Always
    /// `nil` for HLS streams, which are stored as many files.
    public func cachedFileURL(for url: URL) -> URL? {
        IO.sync {
            guard let metadata = metadata(for: url), metadata.isComplete, !metadata.isHLSPlaylist else { return nil }
            return directory.appendingPathComponent(metadata.fileName, isDirectory: false)
        }
    }

    /// Bytes used on disk by the cache.
    public var totalSize: Int64 {
        IO.sync {
            entries().reduce(0) { $0 + $1.size }
        }
    }

    /// Deletes the cached data for `url`, including every playlist and segment
    /// of an HLS stream. Data in use by a player item is truncated instead, and
    /// the item keeps streaming from the network.
    public func remove(_ url: URL) {
        IO.sync {
            for url in [url] + hlsDescendants(of: url) {
                removeEntry(for: url)
            }
        }
    }

    /// Deletes all cached data. Data in use by a player item is truncated instead.
    public func clearAll() {
        IO.sync {
            var keep = Set<String>()
            for file in openFiles.values {
                file.reset()
                keep.insert(file.dataURL.lastPathComponent)
                keep.insert(file.metadataURL.lastPathComponent)
            }
            let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in contents where !keep.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Internal (IO.queue)

    func openFile(for url: URL, fileExtension: String?) -> CacheFile {
        dispatchPrecondition(condition: .onQueue(IO.queue))
        let key = url.cacheKey
        let file = openFiles[key] ?? CacheFile(
            key: key,
            remoteURL: url,
            directory: directory,
            fileExtension: fileExtension ?? "mp4",
            fileExtensionIsReliable: fileExtension != nil
        )
        openFiles[key] = file
        file.openCount += 1
        file.touch()
        return file
    }

    /// The HLS server, started if needed. Must not be called on `IO.queue`.
    func hlsProxyServer() -> HLSProxyServer {
        IO.sync {
            if let hlsServer { return hlsServer }
            let server = HLSProxyServer(cache: self)
            hlsServer = server
            return server
        }
    }

    func releaseFile(_ file: CacheFile) {
        dispatchPrecondition(condition: .onQueue(IO.queue))
        file.openCount -= 1
        guard file.openCount <= 0 else { return }
        file.cancelDownloads()
        file.saveMetadata()
        file.close()
        openFiles[file.key] = nil
        enforceSizeLimit()
    }

    func enforceSizeLimit() {
        dispatchPrecondition(condition: .onQueue(IO.queue))
        guard let maxDiskSize else { return }
        var entries = entries()
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxDiskSize else { return }
        // Read access dates only now: an HLS stream adds an entry per segment.
        for index in entries.indices {
            entries[index].lastAccess = CacheFile.loadMetadata(key: entries[index].key, directory: directory)?.lastAccess ?? .distantPast
        }
        entries.sort { $0.lastAccess < $1.lastAccess }
        for entry in entries where total > maxDiskSize && openFiles[entry.key] == nil {
            deleteEntry(key: entry.key)
            total -= entry.size
        }
    }

    // MARK: Private

    private struct Entry {
        var key: String
        var size: Int64
        var lastAccess: Date
    }

    /// The metadata of the entry for `url`, from the open file or from disk.
    func metadata(for url: URL) -> CacheFile.Metadata? {
        dispatchPrecondition(condition: .onQueue(IO.queue))
        let key = url.cacheKey
        if let file = openFiles[key] { return file.metadata }
        guard let metadata = CacheFile.loadMetadata(key: key, directory: directory),
              metadata.remoteURL == url else { return nil }
        return metadata
    }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var entries: [String: Entry] = [:]
        for url in contents {
            let key = url.deletingPathExtension().lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            entries[key, default: Entry(key: key, size: 0, lastAccess: .distantPast)].size += size
        }
        return Array(entries.values)
    }

    private func removeEntry(for url: URL) {
        let key = url.cacheKey
        if let file = openFiles[key] {
            file.reset()
        } else {
            deleteEntry(key: key)
        }
    }

    private func deleteEntry(key: String) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.deletingPathExtension().lastPathComponent == key {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
