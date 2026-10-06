// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import AVFoundation
import Combine
import PersistentAVPlayerItem

/// One muted, looping player and its cache state.
@MainActor
final class TileModel: ObservableObject, PersistentAVPlayerItemDelegate {
    enum CacheState: Equatable {
        /// Fully on disk when the tile was created; no network used.
        case fromDisk
        /// Streaming; this fraction of the file is on disk.
        case streaming(Double)
        /// Finished downloading while playing; the next item plays from disk.
        case saved
        case failed
    }

    @Published private(set) var cacheState: CacheState
    let player: AVPlayer
    private var cancellables = Set<AnyCancellable>()

    init(video: SampleVideo) {
        let item = PersistentAVPlayerItem(url: video.url)
        // A short forward buffer keeps memory low with many players on screen.
        item.preferredForwardBufferDuration = 4

        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false

        if item.isPlayingFromCache {
            cacheState = .fromDisk
        } else {
            cacheState = .streaming(MediaCache.shared.status(for: video.url).fractionCached)
        }
        item.delegate = self

        // Loop by seeking back. AVPlayerLooper copies items, which would detach
        // the copies from the resource loader.
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.player.seek(to: .zero)
                self?.player.play()
            }
            .store(in: &cancellables)

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                if status == .failed { self?.cacheState = .failed }
            }
            .store(in: &cancellables)
    }

    func play() { player.play() }
    func pause() { player.pause() }

    // MARK: PersistentAVPlayerItemDelegate

    func playerItem(_ playerItem: PersistentAVPlayerItem, didCacheBytes cachedBytes: Int64, outOf totalBytes: Int64) {
        guard case .streaming = cacheState, totalBytes > 0 else { return }
        cacheState = .streaming(Double(cachedBytes) / Double(totalBytes))
    }

    func playerItemDidFinishCaching(_ playerItem: PersistentAVPlayerItem) {
        cacheState = .saved
    }

    func playerItem(_ playerItem: PersistentAVPlayerItem, didFailWithError error: Error) {
        print("[\(playerItem.url.lastPathComponent)] caching error: \(error.localizedDescription)")
    }
}
