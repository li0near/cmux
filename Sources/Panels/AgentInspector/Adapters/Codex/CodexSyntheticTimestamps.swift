import Foundation

/// Codex rollout JSONL files don't carry per-line timestamps. To still let
/// the inspector order chunks reasonably, we synthesise a monotonic timestamp
/// for each line by linearly interpolating between the file's mtime
/// (treated as "now") and a heuristic earliest timestamp.
///
/// This is a soft anchor: useful for ordering and "follow tail" semantics,
/// but Phase 3 should treat sync points anchored on Codex synthetic
/// timestamps as approximate. Document on the first decision-log entry.
struct CodexSyntheticTimestamps {
    let baseStart: Date
    let baseEnd: Date
    let totalLines: Int

    func stamp(for lineIndex: Int) -> Date {
        guard totalLines > 0 else { return baseStart }
        let fraction = Double(lineIndex) / Double(max(totalLines, 1))
        let span = baseEnd.timeIntervalSince(baseStart)
        return baseStart.addingTimeInterval(span * fraction)
    }

    /// Construct from a file's mtime. We default `baseStart` to one hour
    /// before mtime — sessions that span days will be visually compressed,
    /// but order is preserved which is the only thing the renderer needs.
    static func forFile(at path: String, fallbackSpanSeconds: TimeInterval = 60 * 60) -> CodexSyntheticTimestamps {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
        let lineCount = countLines(at: path)
        return CodexSyntheticTimestamps(
            baseStart: mtime.addingTimeInterval(-fallbackSpanSeconds),
            baseEnd: mtime,
            totalLines: lineCount
        )
    }

    private static func countLines(at path: String) -> Int {
        // Cheap approximation — counting bytes-with-newlines avoids loading
        // the whole file. For tail-follow we can recompute as new lines come
        // in; for the initial render this is good enough.
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return 1
        }
        defer { try? handle.close() }
        var count = 0
        let chunkSize = 256 * 1024
        while true {
            let data: Data
            if #available(macOS 10.15.4, *) {
                data = (try? handle.read(upToCount: chunkSize)) ?? Data()
            } else {
                data = handle.readData(ofLength: chunkSize)
            }
            if data.isEmpty { break }
            count += data.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) }
        }
        return max(count, 1)
    }
}
