// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// The single serial queue that owns all mutable caching state.
///
/// The resource loader delegate, the `URLSession` delegate and every cache file
/// mutation run on this queue, so internal types need no locks. Types marked
/// `@unchecked Sendable` in this module rely on that confinement.
enum IO {
    private static let queueKey = DispatchSpecificKey<Bool>()

    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "PersistentAVPlayerItem.io", qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: true)
        return queue
    }()

    static var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == true
    }

    /// Runs `work` on the IO queue, inline if already on it.
    static func sync<T>(_ work: () throws -> T) rethrows -> T {
        if isOnQueue { return try work() }
        return try queue.sync(execute: work)
    }
}
