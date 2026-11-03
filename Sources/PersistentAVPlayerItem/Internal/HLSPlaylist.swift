// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// Reads and rewrites the URIs of an HLS playlist (RFC 8216).
struct HLSPlaylist {
    enum Kind: Equatable {
        /// A variant stream of a multivariant playlist (`EXT-X-STREAM-INF`).
        case variant
        /// An I-frame-only variant (`EXT-X-I-FRAME-STREAM-INF`).
        case iFrameVariant
        /// An alternative rendition (`EXT-X-MEDIA`) or a rendition report.
        case rendition
        /// Media data: a segment, partial segment or initialization section.
        case segment
        /// Anything else with a URI, such as keys. Never cached.
        case other

        var isPlaylist: Bool {
            self == .variant || self == .iFrameVariant || self == .rendition
        }
    }

    struct Reference: Equatable {
        var url: URL
        var kind: Kind
        /// The `EXT-X-BYTERANGE` or `BYTERANGE` of a segment, if any.
        var byteRange: Range<Int64>?
        /// For a variant, the `AUDIO` group it plays; for an audio rendition, its `GROUP-ID`.
        var audioGroup: String?
    }

    enum Rewrite {
        /// Keep the reference, made absolute.
        case keep
        /// Point the reference at another URL.
        case replace(URL)
        /// Remove the reference and, for a variant stream, its `EXT-X-STREAM-INF` line.
        case drop
    }

    let text: String
    /// The URL relative URIs resolve against: the playlist's URL after redirects.
    let baseURL: URL

    init?(data: Data, baseURL: URL) {
        guard let text = String(data: data, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return nil }
        self.text = text
        self.baseURL = baseURL
    }

    /// A multivariant ("master") playlist, which lists other playlists.
    var isMultivariant: Bool {
        text.contains("#EXT-X-STREAM-INF") || text.contains("#EXT-X-I-FRAME-STREAM-INF")
    }

    /// Whether the playlist will never change: a multivariant playlist, or a
    /// media playlist that has ended (VOD). Live playlists aren't cached.
    var isFinal: Bool {
        isMultivariant || text.contains("#EXT-X-ENDLIST") || text.contains("#EXT-X-PLAYLIST-TYPE:VOD")
    }

    /// Every URI in the playlist, resolved, in order.
    var references: [Reference] {
        var references: [Reference] = []
        _ = rewritten { reference in
            references.append(reference)
            return .keep
        }
        return references
    }

    /// The playlist with every URI made absolute and passed through `transform`.
    /// Variant streams for which `listFirst` returns `true` are moved ahead of
    /// the others, since players usually start with the first one listed.
    func rewritten(listFirst: (Reference) -> Bool = { _ in false }, _ transform: (Reference) -> Rewrite) -> String {
        let isMultivariant = isMultivariant
        var lines: [String] = []
        // Variant streams (`EXT-X-STREAM-INF` plus URI), reinserted in order at
        // the position of the first one.
        var variantBlocks: [(listFirst: Bool, lines: [String])] = []
        var variantsIndex: Int?
        // The `EXT-X-STREAM-INF` line waiting for its URI line.
        var pendingStreamInfo: String?
        // `EXT-X-BYTERANGE` of the next segment.
        var pendingByteRange: (length: Int64, offset: Int64?)?
        var nextByteRangeOffset: [URL: Int64] = [:]

        // `\r\n` is a single `Character`, so split on any newline.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                lines.append(line)
                continue
            }

            if trimmed.hasPrefix("#") {
                let tag = String(trimmed.prefix { $0 != ":" })
                if tag == "#EXT-X-STREAM-INF" {
                    pendingStreamInfo = line
                    continue
                }
                if tag == "#EXT-X-BYTERANGE" {
                    pendingByteRange = Self.parseByteRange(String(trimmed.dropFirst(tag.count + 1)))
                }
                guard let kind = Self.uriTags[tag],
                      let uri = Self.attribute("URI", in: trimmed),
                      let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
                    lines.append(line)
                    continue
                }
                var reference = Reference(url: url, kind: kind)
                if tag == "#EXT-X-MAP" || tag == "#EXT-X-PART" {
                    reference.byteRange = Self.attribute("BYTERANGE", in: trimmed)
                        .flatMap(Self.parseByteRange)
                        .flatMap { range in range.offset.map { $0..<($0 + range.length) } }
                } else if tag == "#EXT-X-MEDIA", Self.enumeratedAttribute("TYPE", in: trimmed) == "AUDIO" {
                    reference.audioGroup = Self.attribute("GROUP-ID", in: trimmed)
                }
                switch transform(reference) {
                case .keep:
                    lines.append(Self.replacingAttribute("URI", in: line, with: url.absoluteString))
                case let .replace(newURL):
                    lines.append(Self.replacingAttribute("URI", in: line, with: newURL.absoluteString))
                case .drop:
                    break
                }
                continue
            }

            // A URI line: a variant stream in a multivariant playlist, else a segment.
            let streamInfo = pendingStreamInfo
            pendingStreamInfo = nil
            guard let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
                lines.append(contentsOf: [streamInfo, line].compactMap { $0 })
                continue
            }
            var reference = Reference(url: url, kind: isMultivariant ? .variant : .segment)
            if let range = pendingByteRange {
                let offset = range.offset ?? nextByteRangeOffset[url] ?? 0
                reference.byteRange = offset..<(offset + range.length)
                nextByteRangeOffset[url] = offset + range.length
                pendingByteRange = nil
            }
            if let streamInfo {
                reference.audioGroup = Self.attribute("AUDIO", in: streamInfo)
            }
            let uri: String
            switch transform(reference) {
            case .keep: uri = url.absoluteString
            case let .replace(newURL): uri = newURL.absoluteString
            case .drop: continue
            }
            if let streamInfo, reference.kind == .variant {
                variantsIndex = variantsIndex ?? lines.count
                variantBlocks.append((listFirst(reference), [streamInfo, uri]))
            } else {
                lines.append(contentsOf: [streamInfo, uri].compactMap { $0 })
            }
        }
        if let variantsIndex {
            let ordered = variantBlocks.filter(\.listFirst) + variantBlocks.filter { !$0.listFirst }
            lines.insert(contentsOf: ordered.flatMap(\.lines), at: variantsIndex)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Parsing

    /// Tags with a `URI` attribute, and what the URI points at.
    private static let uriTags: [String: Kind] = [
        "#EXT-X-MEDIA": .rendition,
        "#EXT-X-I-FRAME-STREAM-INF": .iFrameVariant,
        "#EXT-X-RENDITION-REPORT": .rendition,
        "#EXT-X-MAP": .segment,
        "#EXT-X-PART": .segment,
        "#EXT-X-PRELOAD-HINT": .segment,
        "#EXT-X-KEY": .other,
        "#EXT-X-SESSION-KEY": .other,
        "#EXT-X-SESSION-DATA": .other,
    ]

    /// The value of a quoted attribute such as `URI="…"`.
    static func attribute(_ name: String, in line: String) -> String? {
        attributeValueRange(name, quoted: true, in: line).map { String(line[$0]) }
    }

    /// The value of an unquoted attribute such as `TYPE=AUDIO`.
    static func enumeratedAttribute(_ name: String, in line: String) -> String? {
        attributeValueRange(name, quoted: false, in: line).map { String(line[$0]) }
    }

    private static func attributeValueRange(_ name: String, quoted: Bool, in line: String) -> Range<String.Index>? {
        let prefix = quoted ? "\(name)=\"" : "\(name)="
        var searchStart = line.startIndex
        while let match = line.range(of: prefix, range: searchStart..<line.endIndex) {
            searchStart = match.upperBound
            // The name must start an attribute, not end another one (`XURI=`).
            guard match.lowerBound > line.startIndex,
                  [":", ","].contains(line[line.index(before: match.lowerBound)]) else { continue }
            let end = line[match.upperBound...].firstIndex(of: quoted ? "\"" : ",") ?? (quoted ? nil : line.endIndex)
            return end.map { match.upperBound..<$0 }
        }
        return nil
    }

    private static func replacingAttribute(_ name: String, in line: String, with value: String) -> String {
        guard let range = attributeValueRange(name, quoted: true, in: line) else { return line }
        var line = line
        line.replaceSubrange(range, with: value)
        return line
    }

    /// `<length>[@<offset>]`.
    private static func parseByteRange(_ value: String) -> (length: Int64, offset: Int64?)? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "@", maxSplits: 1)
        guard let first = parts.first, let length = Int64(first), length > 0 else { return nil }
        let offset = parts.count == 2 ? Int64(parts[1]) : nil
        return (length, offset)
    }
}
