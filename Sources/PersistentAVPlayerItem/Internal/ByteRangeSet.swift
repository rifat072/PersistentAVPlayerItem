// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// A sorted set of non-overlapping, non-adjacent byte ranges.
struct ByteRangeSet: Equatable, Sendable {
    private(set) var ranges: [Range<Int64>] = []

    init(_ ranges: [Range<Int64>] = []) {
        for range in ranges { insert(range) }
    }

    var isEmpty: Bool { ranges.isEmpty }

    /// Total number of bytes covered.
    var byteCount: Int64 {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Inserts `range`, merging it with any overlapping or adjacent ranges.
    mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var lower = range.lowerBound
        var upper = range.upperBound
        var result: [Range<Int64>] = []
        result.reserveCapacity(ranges.count + 1)
        var inserted = false
        for existing in ranges {
            if existing.upperBound < lower {
                result.append(existing)
            } else if existing.lowerBound > upper {
                if !inserted {
                    result.append(lower..<upper)
                    inserted = true
                }
                result.append(existing)
            } else {
                lower = min(lower, existing.lowerBound)
                upper = max(upper, existing.upperBound)
            }
        }
        if !inserted { result.append(lower..<upper) }
        ranges = result
    }

    /// Whether every byte of `range` is covered.
    func contains(_ range: Range<Int64>) -> Bool {
        guard !range.isEmpty else { return true }
        return ranges.contains { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound }
    }

    /// Number of covered bytes starting exactly at `offset` before the first gap.
    func contiguousByteCount(from offset: Int64) -> Int64 {
        guard let range = ranges.first(where: { $0.lowerBound <= offset && offset < $0.upperBound }) else { return 0 }
        return range.upperBound - offset
    }

    /// The start of the first covered range that begins after `offset`.
    func nextLowerBound(after offset: Int64) -> Int64? {
        ranges.first { $0.lowerBound > offset }?.lowerBound
    }

    /// The parts of `range` that are not covered.
    func missingRanges(in range: Range<Int64>) -> [Range<Int64>] {
        var missing: [Range<Int64>] = []
        var cursor = range.lowerBound
        for existing in ranges where existing.upperBound > cursor {
            if existing.lowerBound >= range.upperBound { break }
            if existing.lowerBound > cursor {
                missing.append(cursor..<existing.lowerBound)
            }
            cursor = max(cursor, existing.upperBound)
            if cursor >= range.upperBound { break }
        }
        if cursor < range.upperBound {
            missing.append(cursor..<range.upperBound)
        }
        return missing
    }
}

extension ByteRangeSet: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode([Range<Int64>].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ranges)
    }
}
