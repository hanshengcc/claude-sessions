import Foundation

/// Bounded log of a terminal's raw output, addressed by absolute byte offsets,
/// plus the pty size history needed to replay it faithfully. Thread-safe.
public final class OutputBuffer: @unchecked Sendable {
    public struct Size: Equatable, Sendable {
        public let cols: Int
        public let rows: Int
        public init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
        }
    }

    /// One replay step: switch to `size`, then feed `bytes`.
    public struct Segment: Equatable, Sendable {
        public let size: Size
        public let bytes: [UInt8]
    }

    public struct Snapshot: Equatable, Sendable {
        /// True when the client's offset was too old (or absent): it must reset and replay.
        public let isFullReplay: Bool
        public let segments: [Segment]
        /// Absolute offset just past the returned bytes.
        public let end: UInt64
    }

    private let capacity: Int
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var startOffset: UInt64 = 0
    private var sizes: [(offset: UInt64, size: Size)]

    public init(capacity: Int, initialSize: Size = Size(cols: 80, rows: 24)) {
        self.capacity = capacity
        sizes = [(0, initialSize)]
    }

    public var endOffset: UInt64 { lock.withLock { startOffset + UInt64(bytes.count) } }
    public var currentSize: Size { lock.withLock { sizes[sizes.count - 1].size } }

    /// Returns the end offset after appending.
    @discardableResult
    public func append<C: Collection>(_ chunk: C) -> UInt64 where C.Element == UInt8 {
        lock.withLock {
            bytes.append(contentsOf: chunk)
            trimLocked()
            return startOffset + UInt64(bytes.count)
        }
    }

    public func recordResize(_ size: Size) {
        lock.withLock {
            guard sizes[sizes.count - 1].size != size else { return }
            let offset = startOffset + UInt64(bytes.count)
            if sizes[sizes.count - 1].offset == offset {
                sizes[sizes.count - 1] = (offset, size)
            } else {
                sizes.append((offset, size))
            }
        }
    }

    /// Bytes after `since`. Full replay starts at the first newline so the
    /// client never begins inside an escape sequence.
    public func snapshot(since: UInt64?) -> Snapshot {
        lock.withLock {
            let end = startOffset + UInt64(bytes.count)
            if let since, since >= startOffset, since <= end {
                return Snapshot(isFullReplay: false, segments: segmentsLocked(from: since, to: end), end: end)
            }
            var from = startOffset
            if startOffset > 0, let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
                from = startOffset + UInt64(newline + 1)
            }
            return Snapshot(isFullReplay: true, segments: segmentsLocked(from: from, to: end), end: end)
        }
    }

    private func segmentsLocked(from: UInt64, to end: UInt64) -> [Segment] {
        var result: [Segment] = []
        var cursor = from
        let startIndex = sizes.lastIndex { $0.offset <= from } ?? 0
        for index in startIndex..<sizes.count {
            let segmentEnd = index + 1 < sizes.count ? min(sizes[index + 1].offset, end) : end
            let size = sizes[index].size
            if segmentEnd > cursor || result.isEmpty || index > startIndex {
                let lower = Int(cursor - startOffset), upper = Int(max(segmentEnd, cursor) - startOffset)
                result.append(Segment(size: size, bytes: Array(bytes[lower..<upper])))
            }
            cursor = max(cursor, segmentEnd)
        }
        // Drop empty leading segments except the last size marker.
        return result.enumerated().filter { $0.element.bytes.count > 0 || $0.offset == result.count - 1 }.map(\.element)
    }

    private func trimLocked() {
        let overflow = bytes.count - capacity
        guard overflow > 0 else { return }
        bytes.removeFirst(overflow)
        startOffset += UInt64(overflow)
        // Keep the size in effect at the new start, drop older history.
        if let keep = sizes.lastIndex(where: { $0.offset <= startOffset }), keep > 0 {
            sizes.removeFirst(keep)
        }
    }
}
