// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import AVFoundation

/// An `AVPlayerItem` that saves remote media to disk while it streams, and plays
/// from disk next time.
///
/// - A fully cached URL plays straight from the local file, without network access.
/// - Otherwise, AVFoundation's byte-range requests go through a resource loader.
///   Cached bytes are read from disk and only the missing ranges are downloaded.
///   Downloaded bytes are buffered in RAM only up to `MediaCache.memoryBufferLimit`
///   (256 KB by default) before being written to disk.
/// - HLS playlists (`.m3u8`) and non-HTTP URLs are played without caching.
///
/// ```swift
/// let item = PersistentAVPlayerItem(url: url)
/// let player = AVPlayer(playerItem: item)
/// player.play()
/// ```
open class PersistentAVPlayerItem: AVPlayerItem {
    /// The URL the item was created with.
    public let url: URL

    /// The cache the item reads from and writes to.
    public let cache: MediaCache

    /// `true` when the whole resource was already on disk when the item was created.
    public let isPlayingFromCache: Bool

    /// Receives caching progress, completion and errors on the main thread.
    public weak var delegate: (any PersistentAVPlayerItemDelegate)?

    private let customFileExtension: String?
    private let resourceLoaderDelegate: ResourceLoader?
    private let lease: CacheLease?

    /// Creates an item that caches `url` in `cache`.
    ///
    /// - Parameters:
    ///   - url: Remote URL of a progressive media file (MP4, MOV, M4A, MP3, …).
    ///   - cache: Where the media is stored. Defaults to `MediaCache.shared`.
    ///   - customFileExtension: The file's extension, for URLs whose path has none
    ///     (for example `"mp4"`). Used to name the cached file.
    ///   - automaticallyLoadedAssetKeys: Passed through to `AVPlayerItem`.
    public init(
        url: URL,
        cache: MediaCache = .shared,
        customFileExtension: String? = nil,
        automaticallyLoadedAssetKeys: [String]? = nil
    ) {
        self.url = url
        self.cache = cache
        self.customFileExtension = customFileExtension

        guard url.isCacheableRemoteMedia, let customSchemeURL = url.customSchemeURL else {
            isPlayingFromCache = false
            resourceLoaderDelegate = nil
            lease = nil
            super.init(asset: AVURLAsset(url: url), automaticallyLoadedAssetKeys: automaticallyLoadedAssetKeys)
            return
        }

        let fileExtension = customFileExtension ?? (url.pathExtension.isEmpty ? nil : url.pathExtension)
        let file = IO.sync { cache.openFile(for: url, fileExtension: fileExtension) }
        let (isComplete, extensionIsReliable, dataURL) = IO.sync {
            (file.isComplete, file.metadata.fileExtensionIsReliable, file.dataURL)
        }
        lease = CacheLease(cache: cache, file: file)
        isPlayingFromCache = isComplete

        let asset: AVURLAsset
        if isComplete && extensionIsReliable {
            // AVFoundation identifies local files by extension, so the file can be
            // used directly only when the extension is known to be right.
            asset = AVURLAsset(url: dataURL)
            resourceLoaderDelegate = nil
        } else {
            asset = AVURLAsset(url: customSchemeURL)
            let box = ItemBox()
            let loader = ResourceLoader(remoteURL: url, file: file, cache: cache) { event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { box.item?.handle(event) }
                }
            }
            asset.resourceLoader.setDelegate(loader, queue: IO.queue)
            resourceLoaderDelegate = loader
            super.init(asset: asset, automaticallyLoadedAssetKeys: automaticallyLoadedAssetKeys)
            box.item = self
            return
        }
        super.init(asset: asset, automaticallyLoadedAssetKeys: automaticallyLoadedAssetKeys)
    }

    /// Copies get their own resource loader, so they keep caching. `AVPlayerLooper`
    /// relies on this. Without the override, `AVPlayerItem` would call an
    /// initializer this class doesn't implement.
    open override func copy(with zone: NSZone? = nil) -> Any {
        let makeCopy = { [url, cache, customFileExtension, automaticallyLoadedAssetKeys] in
            MainActor.assumeIsolated {
                PersistentAVPlayerItem(
                    url: url,
                    cache: cache,
                    customFileExtension: customFileExtension,
                    automaticallyLoadedAssetKeys: automaticallyLoadedAssetKeys
                )
            }
        }
        return Thread.isMainThread ? makeCopy() : DispatchQueue.main.sync(execute: makeCopy)
    }

    deinit {
        resourceLoaderDelegate?.invalidate()
    }

    private func handle(_ event: ResourceLoader.Event) {
        switch event {
        case let .progress(cachedBytes, totalBytes):
            delegate?.playerItem(self, didCacheBytes: cachedBytes, outOf: totalBytes)
        case .completed:
            delegate?.playerItemDidFinishCaching(self)
        case let .failed(error):
            delegate?.playerItem(self, didFailWithError: error)
        }
    }
}

/// Weak reference used to route loader events to the item on the main thread.
/// Only read and written on the main thread.
private final class ItemBox: @unchecked Sendable {
    weak var item: PersistentAVPlayerItem?
}

/// Keeps a cache file open, and so safe from eviction, while an item exists.
private final class CacheLease: @unchecked Sendable {
    private let cache: MediaCache
    private let file: CacheFile

    init(cache: MediaCache, file: CacheFile) {
        self.cache = cache
        self.file = file
    }

    deinit {
        IO.queue.async { [cache, file] in cache.releaseFile(file) }
    }
}
