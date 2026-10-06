// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation
import UniformTypeIdentifiers

enum MediaType {
    static let fallbackTypeIdentifier = UTType.mpeg4Movie.identifier

    /// The Uniform Type Identifier AVFoundation expects in
    /// `AVAssetResourceLoadingContentInformationRequest.contentType`.
    ///
    /// Servers often send `application/octet-stream`, which maps to `public.data`
    /// and makes playback fail (notably on the Simulator), so only audiovisual
    /// types are accepted from the MIME type before falling back to the extension.
    static func typeIdentifier(mimeType: String?, fileExtension: String?) -> String {
        if let mimeType = normalizedMIMEType(mimeType),
           let type = UTType(mimeType: mimeType),
           type.conforms(to: .audiovisualContent) {
            return type.identifier
        }
        if let fileExtension, !fileExtension.isEmpty,
           let type = UTType(filenameExtension: fileExtension),
           type.conforms(to: .audiovisualContent) {
            return type.identifier
        }
        return fallbackTypeIdentifier
    }

    static func normalizedMIMEType(_ mimeType: String?) -> String? {
        guard let base = mimeType?.split(separator: ";").first else { return nil }
        let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A parsed `Content-Range: bytes <start>-<end>/<total>` header.
struct ContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64?

    init?(_ header: String?) {
        guard let header else { return nil }
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              start <= end else { return nil }
        self.start = start
        self.end = end
        self.total = Int64(rangeAndTotal[1].trimmingCharacters(in: .whitespaces))
    }
}
