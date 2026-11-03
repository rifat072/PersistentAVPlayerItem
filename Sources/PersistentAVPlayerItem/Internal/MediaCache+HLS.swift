// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

extension CacheFile.Metadata {
    var isHLSPlaylist: Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }
}

/// HLS streams in the cache. A stream is stored as ordinary entries: one per
/// playlist (only once it's final, i.e. multivariant or VOD) and one per segment.
///
/// All methods run on `IO.queue`.
extension MediaCache {
    /// The playlist at `url`, if a final copy of it is cached.
    func cachedPlaylist(for url: URL) -> HLSPlaylist? {
        guard let metadata = metadata(for: url), metadata.isComplete, metadata.isHLSPlaylist,
              let data = try? Data(contentsOf: directory.appendingPathComponent(metadata.fileName, isDirectory: false))
        else { return nil }
        return HLSPlaylist(data: data, baseURL: metadata.resolvedURL ?? url)
    }

    func storePlaylist(_ data: Data, for url: URL, resolvedURL: URL, mimeType: String?) {
        let file = openFile(for: url, fileExtension: "m3u8")
        try? file.replaceContents(with: data, mimeType: mimeType, resolvedURL: resolvedURL)
        releaseFile(file)
    }

    /// Whether the bytes of a segment reference are on disk, and how many there are.
    func cacheState(of segment: HLSPlaylist.Reference) -> (isCached: Bool, byteCount: Int64) {
        guard let metadata = metadata(for: segment.url) else { return (false, 0) }
        if let range = segment.byteRange {
            return (metadata.ranges.contains(range), Int64(range.count))
        }
        return (metadata.isComplete, metadata.contentLength ?? 0)
    }

    /// Whether the stream at `url` can play from disk.
    func isHLSComplete(_ url: URL) -> Bool {
        guard let playlist = cachedPlaylist(for: url) else { return false }
        if playlist.isMultivariant {
            return playableVariants(of: playlist).contains { $0.kind == .variant }
        }
        return isMediaPlaylistComplete(url)
    }

    /// The variants of a multivariant playlist that can play from disk: the
    /// media playlist and all its segments are cached, and so is a rendition
    /// of its audio group, if it has one with a URI.
    func playableVariants(of playlist: HLSPlaylist) -> [HLSPlaylist.Reference] {
        var memo: [URL: Bool] = [:]
        func isComplete(_ url: URL) -> Bool {
            if let known = memo[url] { return known }
            let result = isMediaPlaylistComplete(url)
            memo[url] = result
            return result
        }
        let references = playlist.references
        let audioRenditions = references.filter { $0.kind == .rendition && $0.audioGroup != nil }
        let groupsWithURI = Set(audioRenditions.compactMap(\.audioGroup))
        let completeGroups = Set(audioRenditions.filter { isComplete($0.url) }.compactMap(\.audioGroup))
        return references.filter { reference in
            guard reference.kind == .variant || reference.kind == .iFrameVariant, isComplete(reference.url) else { return false }
            guard let group = reference.audioGroup, groupsWithURI.contains(group) else { return true }
            return completeGroups.contains(group)
        }
    }

    func hlsStatus(for url: URL) -> Status {
        var cachedBytes: Int64 = 0
        for url in [url] + hlsDescendants(of: url) {
            cachedBytes += metadata(for: url)?.ranges.byteCount ?? 0
        }
        let isComplete = isHLSComplete(url)
        return Status(cachedBytes: cachedBytes, totalBytes: isComplete ? cachedBytes : nil, isComplete: isComplete)
    }

    /// The URLs of every cached playlist and segment reachable from the playlist
    /// at `url`, without `url` itself. Empty if `url` isn't a cached playlist.
    func hlsDescendants(of url: URL) -> [URL] {
        var seen: Set<URL> = [url]
        var result: [URL] = []
        var pending = [url]
        while let playlistURL = pending.popLast() {
            guard let playlist = cachedPlaylist(for: playlistURL) else { continue }
            for reference in playlist.references where reference.kind != .other && !seen.contains(reference.url) {
                seen.insert(reference.url)
                guard metadata(for: reference.url) != nil else { continue }
                result.append(reference.url)
                if reference.kind.isPlaylist { pending.append(reference.url) }
            }
        }
        return result
    }

    private func isMediaPlaylistComplete(_ url: URL) -> Bool {
        guard let playlist = cachedPlaylist(for: url), !playlist.isMultivariant, playlist.isFinal else { return false }
        return playlist.references.allSatisfy { $0.kind != .segment || cacheState(of: $0).isCached }
    }
}
