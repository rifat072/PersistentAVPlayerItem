# PersistentAVPlayerItem

An `AVPlayerItem` subclass that saves remote audio and video to disk **while it streams**, then plays the local copy next time. It is built for screens that play many videos at once, such as feeds and landing pages with 10–15 muted tiles.

```swift
import PersistentAVPlayerItem

let item = PersistentAVPlayerItem(url: videoURL)
let player = AVPlayer(playerItem: item)
player.isMuted = true
player.play()
```

There's nothing else to set up. What happens depends on how much of the file is already on disk:

| State of the cache | What happens |
| --- | --- |
| Nothing cached | AVPlayer's byte-range requests are fetched over HTTP and written to disk as they arrive. |
| Partly cached | Cached ranges are read from disk; only the missing ranges are downloaded. |
| Fully cached | The item plays the local file directly, with no network access. |

## Features

- **HLS too.** `.m3u8` streams are cached playlist by playlist and segment by segment. See [HLS streams](#hls-streams).
- **Low memory use.** Each stream holds at most `memoryBufferLimit` bytes (256 KB by default) in RAM, then writes them to a sparse file on disk. Memory use doesn't grow with file size or with the number of bytes downloaded.
- **Range-aware.** It honors `requestedOffset`, `requestedLength` and `requestsAllDataToEndOfResource`, serves concurrent and out-of-order requests (such as the tail read for an MP4's `moov` atom), and supports seeking into parts that aren't downloaded yet without waiting for earlier bytes.
- **One download per URL.** Players showing the same URL share in-flight downloads. A player that needs bytes another one is already fetching attaches to that download, catching up from its buffer, instead of opening a second connection. Progress and completion are reported to every item using the URL.
- **Works on the Simulator.** Content information is filled in properly: a UTI derived from the MIME type or file extension, the total length from `Content-Range`, and byte-range support. Every loading request gets an answer, including requests that only ask for content information.
- **Servers that ignore `Range`.** If a server replies `200` with the whole file, the bytes before the requested offset are skipped for playback but still written to the cache.
- **Persistent.** Files live in `Documents/PersistentAVPlayerItem/`, which is excluded from iCloud backup. A JSON file next to each media file records which byte ranges are valid, so caching resumes across launches.
- **Concurrency-safe.** All caching state is confined to one serial queue. The package builds in Swift 6 language mode.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/rifat072/PersistentAVPlayerItem.git", from: "1.0.0"),
],
targets: [
    .target(name: "App", dependencies: ["PersistentAVPlayerItem"]),
]
```

Or in Xcode: **File → Add Package Dependencies…**

Requires iOS 15, macOS 12, tvOS 15 or visionOS 1, and Swift 6.

## Usage

### Progress and completion

```swift
final class TileModel: PersistentAVPlayerItemDelegate {
    func playerItem(_ item: PersistentAVPlayerItem, didCacheBytes cached: Int64, outOf total: Int64) { }
    func playerItemDidFinishCaching(_ item: PersistentAVPlayerItem) { }
    func playerItem(_ item: PersistentAVPlayerItem, didFailWithError error: Error) { }
}

item.delegate = model          // called on the main thread; every method is optional
item.isPlayingFromCache        // true if the whole file was on disk when the item was created
```

### URLs without a file extension

```swift
PersistentAVPlayerItem(url: url, customFileExtension: "mp4")
```

Without an extension, playback still works because the type comes from the server's MIME type. The extension is only used to name the cached file so it can be played directly once complete.

### HLS streams

```swift
let item = PersistentAVPlayerItem(url: URL(string: "https://example.com/stream/master.m3u8")!)
```

`AVAssetResourceLoader` can't serve HLS media segments, so HLS items play through a small HTTP server on `127.0.0.1`, started when the first HLS item is created. It rewrites each playlist so variant playlists and segments come back to it, and serves segments the same way as progressive files: from disk where cached, otherwise downloaded once (shared between players) and written to disk.

- **VOD streams** (multivariant playlists, and media playlists with `#EXT-X-ENDLIST`) are cached. Every segment of a media playlist, including `EXT-X-MAP` init sections and `EXT-X-BYTERANGE` ranges, is a separate cache entry.
- **Replay from disk.** Once every segment of a variant (and of its audio rendition) is on disk, the stream counts as cached: `isPlayingFromCache` is `true` and `MediaCache.isCached(_:)` returns `true`. The server lists cached variants first, so playback starts from disk.
- **Upgrading quality.** With the default `hlsVariantPolicy: .upgradeWhenOnline`, the uncached variants are still offered while the device is online. If the player switches to a better one, it's cached too. Offline, only cached variants are offered, so playback doesn't stall on a variant that needs the network. Pass `.preferCached` to `MediaCache(…)` to offer only cached variants even when online, so a cached stream never uses the network.
- **Live streams** play normally, and their segments aren't cached.
- **Keys** (`EXT-X-KEY`) are never cached, so AES-128 streams still fetch their keys from the network. FairPlay works as it would without this library.
- **Progress** counts the segments of the media playlists the player has loaded. Segment sizes are only known once downloaded, so `totalBytes` is an estimate until the last one is cached.
- For a URL that doesn't end in `.m3u8`, pass `customFileExtension: "m3u8"`.
- On macOS, a sandboxed app needs the `com.apple.security.network.server` entitlement for the local server. If the server can't start, the stream plays uncached.

### Managing the cache

```swift
let cache = MediaCache.shared

cache.isCached(url)              // whole file on disk?
cache.status(for: url)           // cachedBytes, totalBytes, isComplete, fractionCached
cache.cachedFileURL(for: url)    // local file, once complete
cache.totalSize                  // bytes on disk
cache.remove(url)                // for HLS, every playlist and segment of the stream
cache.clearAll()
```

You can also create a custom cache, for example with a size limit, extra headers or a different directory:

```swift
let configuration = URLSessionConfiguration.default
configuration.httpAdditionalHeaders = ["Authorization": "Bearer …"]

let cache = MediaCache(
    directory: MediaCache.defaultDirectory,
    memoryBufferLimit: 256 * 1024,
    maxDiskSize: 500 * 1024 * 1024,      // evicts least recently used entries
    hlsVariantPolicy: .upgradeWhenOnline,
    sessionConfiguration: configuration
)
let item = PersistentAVPlayerItem(url: url, cache: cache)
```

Entries in use by a live player item are never evicted. `remove` and `clearAll` truncate them instead, and those items continue streaming from the network.

## Playing many videos at once

The library keeps its own memory small. Most of the remaining memory goes to AVFoundation's buffers and the video decoders, so:

- **Limit the forward buffer:** `item.preferredForwardBufferDuration = 4`.
- **Pause tiles that are off screen** (`onDisappear`), and release players you no longer show.
- **Use `AVPlayerLayer`** instead of SwiftUI's `VideoPlayer`, which adds playback controls to every tile.
- **Mute and use the `.ambient` audio session category** so background videos don't interrupt the user's music.
- **To loop**, observe `AVPlayerItem.didPlayToEndTimeNotification` and seek to zero. `AVPlayerLooper` also works: copies of a `PersistentAVPlayerItem` keep caching and share downloads with the original.

## Demo

`Example/PersistentAVPlayerItemDemo.xcodeproj` is a SwiftUI app that plays 9–17 muted, looping videos in a grid, including two HLS streams. Each tile's badge shows its cache state:

| Badge | Meaning |
| --- | --- |
| **NET n%** | Streaming; n% of the file (or of the HLS segments loaded) is saved so far. |
| **SAVED** | Fully downloaded while playing. |
| **DISK** | Played from the local file with no network. |

Tap ↻ to recreate the players and watch cached videos switch to **DISK**. The **⋯** menu changes the number of tiles and clears the cache.

## Limitations

- Progressive files and VOD HLS streams are cached. Live HLS, MPEG-DASH and non-HTTP URLs play normally without caching.
- Media is cached only as far as AVPlayer requests it. A video is fully cached once it has been played (or buffered) to the end.
- If the remote file's length changes, its cached bytes are discarded and fetched again.

## Tests

```sh
swift test
```

The unit tests drive the range and caching logic against a stub HTTP server, both with and without `Range` support, and drive the HLS server over real loopback HTTP.

## License

MIT. See [LICENSE](LICENSE).
