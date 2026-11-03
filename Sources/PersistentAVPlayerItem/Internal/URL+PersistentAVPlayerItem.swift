// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import CryptoKit
import Foundation

extension URL {
    static let customSchemePrefix = "pavpi-"

    /// Whether the URL can be cached at all. Local files are played as-is.
    var isRemoteHTTP: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Whether the URL names an HLS playlist by its extension.
    var isHLSPlaylist: Bool {
        let ext = pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }

    /// The URL with its scheme replaced, so AVFoundation hands every request for
    /// it to the resource loader delegate. The path, and so its extension, is kept.
    var customSchemeURL: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let scheme = components.scheme else { return nil }
        components.scheme = URL.customSchemePrefix + scheme
        return components.url
    }

    /// The original URL for a URL produced by `customSchemeURL`.
    var remoteURLFromCustomScheme: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              scheme.hasPrefix(URL.customSchemePrefix) else { return nil }
        components.scheme = String(scheme.dropFirst(URL.customSchemePrefix.count))
        return components.url
    }

    /// Stable file-name-safe key for the cache entry of this URL.
    var cacheKey: String {
        SHA256.hash(data: Data(absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
