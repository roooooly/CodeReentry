import Foundation

/// Bounded-memory JSONL reader.
///
/// Session logs can be hundreds of megabytes (or more). Reading them through
/// `Data(contentsOf:) -> String -> [String]` keeps several full-file copies in
/// memory at once. This reader keeps at most one chunk plus one line resident,
/// skips pathological oversized lines, and supports bounded head/tail scans.
public enum JSONLStreamReader {
    public static let defaultChunkSize = 256 * 1_024
    public static let defaultMaximumLineBytes = 8 * 1_024 * 1_024

    public struct ReadResult: Sendable, Equatable {
        public let bytesRead: UInt64
        public let reachedEndOfFile: Bool
        public let skippedOversizedLines: Int

        public init(bytesRead: UInt64, reachedEndOfFile: Bool, skippedOversizedLines: Int) {
            self.bytesRead = bytesRead
            self.reachedEndOfFile = reachedEndOfFile
            self.skippedOversizedLines = skippedOversizedLines
        }
    }

    /// Iterates over non-empty JSONL lines without loading the whole file.
    /// Return `false` from `body` to stop early.
    @discardableResult
    public static func forEachLine(
        at url: URL,
        startingAtOffset requestedOffset: UInt64 = 0,
        byteLimit: UInt64? = nil,
        chunkSize: Int = defaultChunkSize,
        maximumLineBytes: Int = defaultMaximumLineBytes,
        includeEmptyLines: Bool = false,
        _ body: (Data) throws -> Bool
    ) throws -> ReadResult {
        precondition(chunkSize > 0)
        precondition(maximumLineBytes > 0)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = min(requestedOffset, fileSize)
        try handle.seek(toOffset: startOffset)

        var buffer = Data()
        buffer.reserveCapacity(min(chunkSize * 2, maximumLineBytes + chunkSize))
        // A non-zero offset can point into the middle of a JSON line. Discard
        // that partial line before yielding any data.
        var discardingPartialLine = startOffset > 0
        var bytesRead: UInt64 = 0
        var skippedOversizedLines = 0
        var stoppedByConsumer = false

        scanLoop: while true {
            if Task.isCancelled { throw CancellationError() }
            if let byteLimit, bytesRead >= byteLimit { break }

            let remaining = byteLimit.map { Int(min(UInt64(chunkSize), $0 - bytesRead)) } ?? chunkSize
            guard remaining > 0,
                  let chunk = try handle.read(upToCount: remaining),
                  !chunk.isEmpty else {
                break
            }
            bytesRead += UInt64(chunk.count)

            var incoming = chunk
            if discardingPartialLine {
                guard let newline = incoming.firstIndex(of: 0x0A) else { continue }
                let next = incoming.index(after: newline)
                incoming = next < incoming.endIndex ? Data(incoming[next...]) : Data()
                discardingPartialLine = false
            }
            if incoming.isEmpty { continue }
            buffer.append(incoming)

            var lineStart = buffer.startIndex
            while lineStart < buffer.endIndex,
                  let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                var lineEnd = newline
                if lineEnd > lineStart {
                    let previous = buffer.index(before: lineEnd)
                    if buffer[previous] == 0x0D { lineEnd = previous }
                }
                let lineLength = buffer.distance(from: lineStart, to: lineEnd)
                if lineLength > maximumLineBytes {
                    skippedOversizedLines += 1
                } else if lineLength > 0 || includeEmptyLines {
                    let line = Data(buffer[lineStart..<lineEnd])
                    let shouldContinue = try autoreleasepool { try body(line) }
                    if !shouldContinue {
                        stoppedByConsumer = true
                        break scanLoop
                    }
                }
                lineStart = buffer.index(after: newline)
            }

            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
            // A single unbroken line must not defeat the memory bound.
            if buffer.count > maximumLineBytes {
                buffer.removeAll(keepingCapacity: false)
                discardingPartialLine = true
                skippedOversizedLines += 1
            }
        }

        let physicallyReachedEndOfFile = startOffset + bytesRead >= fileSize
        if !stoppedByConsumer,
           physicallyReachedEndOfFile,
           !discardingPartialLine,
           !buffer.isEmpty {
            if buffer.count > maximumLineBytes {
                skippedOversizedLines += 1
            } else {
                let shouldContinue = try autoreleasepool { try body(buffer) }
                if !shouldContinue { stoppedByConsumer = true }
            }
        }

        return ReadResult(
            bytesRead: bytesRead,
            reachedEndOfFile: !stoppedByConsumer && physicallyReachedEndOfFile,
            skippedOversizedLines: skippedOversizedLines
        )
    }

    /// Returns a safe starting offset for a tail scan of at most `maximumBytes`.
    public static func tailOffset(for url: URL, maximumBytes: UInt64) -> UInt64 {
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return UInt64(max(0, size - Int(min(maximumBytes, UInt64(Int.max)))))
    }

    /// Normalizes aliases such as `/var` and `/private/var` so persisted paths
    /// and fresh directory enumeration compare consistently.
    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
