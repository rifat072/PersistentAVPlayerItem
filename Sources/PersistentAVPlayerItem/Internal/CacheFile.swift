// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// One cached resource: a sparse data file written at byte offsets, plus a JSON
/// sidecar recording which byte ranges of it are valid.
///
/// Confined to `IO.queue`. Several player items for the same URL share one instance.
final class CacheFile: @unchecked Sendable {
    struct Metadata: Codable, Equatable {
        var remoteURL: URL
        var fileName: String
        /// `true` when the extension came from the URL or the caller, so the data
        /// file can be handed to AVFoundation directly once complete.
        var fileExtensionIsReliable: Bool
        var contentLength: Int64?
        var mimeType: String?
        var ranges: ByteRangeSet
        var lastAccess: Date
        /// For an HLS playlist, its URL after redirects, which relative URIs
        /// in it resolve against.
        var resolvedURL: URL?

        var isComplete: Bool {
            guard let contentLength, contentLength > 0 else { return false }
            return ranges.contains(0..<contentLength)
        }
    }

    /// Metadata is persisted after at least this many new bytes, and whenever a
    /// worker finishes. Losing it on a crash only means re-downloading those bytes.
    static let metadataSaveThreshold = 1 << 20

    let key: String
    let directory: URL
    private(set) var metadata: Metadata

    /// Number of player items currently using this file. Open files are never evicted.
    var openCount = 0
    /// Downloads in flight for this file. Loading requests attach to these before
    /// starting their own, so each byte range is fetched once.
    var activeDownloads: [SharedDownload] = []
    /// The download that keeps filling the file, without subscribers, from a server
    /// that ignores `Range`. At most one per file.
    var fillDownload: SharedDownload?

    private var handle: FileHandle?
    private var unsavedByteCount = 0
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    init(key: String, remoteURL: URL, directory: URL, fileExtension: String, fileExtensionIsReliable: Bool) {
        self.key = key
        self.directory = directory
        if let stored = CacheFile.loadMetadata(key: key, directory: directory), stored.remoteURL == remoteURL {
            metadata = stored
            validateDataFile()
        } else {
            metadata = Metadata(
                remoteURL: remoteURL,
                fileName: "\(key).\(fileExtension)",
                fileExtensionIsReliable: fileExtensionIsReliable,
                contentLength: nil,
                mimeType: nil,
                ranges: ByteRangeSet(),
                lastAccess: Date()
            )
        }
    }

    static func metadataURL(key: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    static func loadMetadata(key: String, directory: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: metadataURL(key: key, directory: directory)) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    var dataURL: URL { directory.appendingPathComponent(metadata.fileName, isDirectory: false) }
    var metadataURL: URL { CacheFile.metadataURL(key: key, directory: directory) }
    var contentLength: Int64? { metadata.contentLength }
    var mimeType: String? { metadata.mimeType }
    var ranges: ByteRangeSet { metadata.ranges }
    var fileExtension: String { (metadata.fileName as NSString).pathExtension }
    var cachedByteCount: Int64 { metadata.ranges.byteCount }

    var isComplete: Bool { metadata.isComplete }

    /// Records the resource's length and MIME type. A changed length means the
    /// remote file changed, so the stale bytes are discarded.
    func updateContentInfo(contentLength: Int64?, mimeType: String?) {
        if let contentLength, let known = metadata.contentLength, known != contentLength {
            reset()
        }
        if let contentLength { metadata.contentLength = contentLength }
        if let mimeType = MediaType.normalizedMIMEType(mimeType) { metadata.mimeType = mimeType }
    }

    func write(_ data: Data, at offset: Int64) throws {
        var data = data
        if let length = metadata.contentLength {
            let available = length - offset
            guard available > 0 else { return }
            if Int64(data.count) > available { data = data.prefix(Int(available)) }
        }
        guard !data.isEmpty else { return }
        let handle = try openHandle()
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        metadata.ranges.insert(offset..<(offset + Int64(data.count)))
        unsavedByteCount += data.count
        if unsavedByteCount >= CacheFile.metadataSaveThreshold {
            saveMetadata()
        }
    }

    /// Replaces the whole resource, e.g. a playlist downloaded in one piece.
    func replaceContents(with data: Data, mimeType: String?, resolvedURL: URL?) throws {
        reset()
        updateContentInfo(contentLength: Int64(data.count), mimeType: mimeType)
        metadata.resolvedURL = resolvedURL
        try write(data, at: 0)
        saveMetadata()
    }

    func read(at offset: Int64, length: Int) throws -> Data {
        let handle = try openHandle()
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: dataURL])
        }
        return data
    }

    func touch() {
        metadata.lastAccess = Date()
    }

    // MARK: Shared downloads

    /// The in-flight download best placed to serve bytes from `offset`, if any.
    func joinableDownload(at offset: Int64) -> SharedDownload? {
        activeDownloads
            .filter { $0.canServe(offset: offset) }
            .min { abs($0.networkOffset - offset) < abs($1.networkOffset - offset) }
    }

    /// Start of the nearest in-flight download beginning after `offset`. A new
    /// download stops there instead of fetching the same bytes again.
    func nextDownloadStart(after offset: Int64) -> Int64? {
        activeDownloads
            .filter { !$0.isFinished && $0.startOffset > offset }
            .map(\.startOffset)
            .min()
    }

    func startDownload(fetcher: RemoteFetcher, remoteURL: URL, from start: Int64, to end: Int64?, memoryBufferLimit: Int) -> SharedDownload {
        let download = SharedDownload(file: self, fetcher: fetcher, remoteURL: remoteURL, from: start, to: end, memoryBufferLimit: memoryBufferLimit)
        activeDownloads.append(download)
        return download
    }

    func cancelDownloads() {
        for download in activeDownloads { download.cancel() }
        activeDownloads = []
        fillDownload = nil
    }

    // MARK: Observers

    /// `handler` is called on `IO.queue` whenever bytes were written to disk,
    /// whichever player's download wrote them.
    func addObserver(_ id: ObjectIdentifier, handler: @escaping () -> Void) {
        observers[id] = handler
    }

    func removeObserver(_ id: ObjectIdentifier) {
        observers[id] = nil
    }

    func notifyObservers() {
        for handler in observers.values { handler() }
    }

    // MARK: Persistence

    func saveMetadata() {
        unsavedByteCount = 0
        // Nothing worth remembering yet; don't leave empty entries on disk.
        guard metadata.contentLength != nil || !metadata.ranges.isEmpty else { return }
        do {
            try CacheFile.prepareDirectory(directory)
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            // Without metadata the bytes are simply fetched again next time.
        }
    }

    /// Creates the cache directory on first use and excludes it from iCloud backup.
    static func prepareDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    /// Drops all cached bytes but keeps the instance usable by active players.
    func reset() {
        metadata.ranges = ByteRangeSet()
        if let handle {
            try? handle.truncate(atOffset: 0)
        } else {
            try? FileManager.default.removeItem(at: dataURL)
        }
        saveMetadata()
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: dataURL.path) {
            try CacheFile.prepareDirectory(directory)
            guard fileManager.createFile(atPath: dataURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: dataURL])
            }
        }
        let handle = try FileHandle(forUpdating: dataURL)
        self.handle = handle
        return handle
    }

    /// Discards range metadata that the data file on disk can't back up, e.g.
    /// after the file was deleted or truncated outside this library.
    private func validateDataFile() {
        guard let lastByte = metadata.ranges.ranges.last?.upperBound else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: dataURL.path)[.size] as? NSNumber)?.int64Value
        if size == nil || size! < lastByte {
            metadata.ranges = ByteRangeSet()
            saveMetadata()
        }
    }
}
