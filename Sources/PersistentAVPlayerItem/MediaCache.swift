// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// The on-disk store used by `PersistentAVPlayerItem`.
///
/// Each remote URL is stored as a sparse data file plus a small JSON file that
/// records which byte ranges have been downloaded, so partially played media
/// resumes from disk and only the missing bytes are fetched.
public final class MediaCache: @unchecked Sendable {
    /// The cache used by `PersistentAVPlayerItem` unless another one is passed in.
    public static let shared = MediaCache()

    /// `Documents/PersistentAVPlayerItem`.
    public static var defaultDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("PersistentAVPlayerItem", isDirectory: true)
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

    let fetcher: RemoteFetcher
    /// Open cache files by key. Confined to `IO.queue`.
    private var openFiles: [String: CacheFile] = [:]

    /// - Parameters:
    ///   - directory: Where cached media is stored. Excluded from iCloud backup.
    ///   - memoryBufferLimit: Bytes each stream buffers in RAM before writing to disk.
    ///   - maxDiskSize: Optional size limit for the whole cache, in bytes.
    ///   - sessionConfiguration: Base configuration for downloads, e.g. to add
    ///     `httpAdditionalHeaders`. Its `urlCache` is disabled.
    public init(
        directory: URL = MediaCache.defaultDirectory,
        memoryBufferLimit: Int = 256 * 1024,
        maxDiskSize: Int64? = nil,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.directory = directory
        self.memoryBufferLimit = memoryBufferLimit
        self.maxDiskSize = maxDiskSize
        self.fetcher = RemoteFetcher(configuration: sessionConfiguration)
        MediaCache.prepareDirectory(directory)
    }

    deinit {
        fetcher.invalidate()
    }

    // MARK: Public API

    /// Whether the whole resource at `url` is stored on disk.
    public func isCached(_ url: URL) -> Bool {
        status(for: url).isComplete
    }

    public func status(for url: URL) -> Status {
        IO.sync {
            guard let metadata = metadata(for: url) else {
                return Status(cachedBytes: 0, totalBytes: nil, isComplete: false)
            }
            let cached = metadata.ranges.byteCount
            let isComplete = metadata.contentLength.map { $0 > 0 && metadata.ranges.contains(0..<$0) } ?? false
            return Status(cachedBytes: cached, totalBytes: metadata.contentLength, isComplete: isComplete)
        }
    }

    /// The local file for `url`, only once it is completely downloaded.
    public func cachedFileURL(for url: URL) -> URL? {
        IO.sync {
            guard let metadata = metadata(for: url),
                  let length = metadata.contentLength, length > 0,
                  metadata.ranges.contains(0..<length) else { return nil }
            return directory.appendingPathComponent(metadata.fileName, isDirectory: false)
        }
    }

    /// Bytes used on disk by the cache.
    public var totalSize: Int64 {
        IO.sync {
            entries().reduce(0) { $0 + $1.size }
        }
    }

    /// Deletes the cached data for `url`. Data in use by a player item is
    /// truncated instead, and the item keeps streaming from the network.
    public func remove(_ url: URL) {
        IO.sync {
            let key = url.cacheKey
            if let file = openFiles[key] {
                file.reset()
            } else {
                deleteEntry(key: key)
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

    func releaseFile(_ file: CacheFile) {
        dispatchPrecondition(condition: .onQueue(IO.queue))
        file.openCount -= 1
        guard file.openCount <= 0 else { return }
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

    private func metadata(for url: URL) -> CacheFile.Metadata? {
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
            var entry = entries[key] ?? Entry(key: key, size: 0, lastAccess: .distantPast)
            entry.size += size
            if url.pathExtension == "json", let metadata = CacheFile.loadMetadata(key: key, directory: directory) {
                entry.lastAccess = metadata.lastAccess
            }
            entries[key] = entry
        }
        return Array(entries.values)
    }

    private func deleteEntry(key: String) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.deletingPathExtension().lastPathComponent == key {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func prepareDirectory(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }
}
