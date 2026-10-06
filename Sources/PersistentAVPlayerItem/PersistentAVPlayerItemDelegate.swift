// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// Caching events of a `PersistentAVPlayerItem`, delivered on the main thread.
/// All methods are optional.
@MainActor
public protocol PersistentAVPlayerItemDelegate: AnyObject {
    /// More of the resource was written to disk. Throttled to a few calls per second.
    func playerItem(_ playerItem: PersistentAVPlayerItem, didCacheBytes cachedBytes: Int64, outOf totalBytes: Int64)

    /// The whole resource is now on disk. Later items for the same URL play from the local file.
    func playerItemDidFinishCaching(_ playerItem: PersistentAVPlayerItem)

    /// Loading data for the item failed with a network or server error.
    func playerItem(_ playerItem: PersistentAVPlayerItem, didFailWithError error: Error)
}

public extension PersistentAVPlayerItemDelegate {
    func playerItem(_ playerItem: PersistentAVPlayerItem, didCacheBytes cachedBytes: Int64, outOf totalBytes: Int64) {}
    func playerItemDidFinishCaching(_ playerItem: PersistentAVPlayerItem) {}
    func playerItem(_ playerItem: PersistentAVPlayerItem, didFailWithError error: Error) {}
}
