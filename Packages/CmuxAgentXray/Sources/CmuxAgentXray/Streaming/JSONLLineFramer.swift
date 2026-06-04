import Foundation

/// Stateful line framer for JSONL byte streams. Owns the carry buffer
/// across chunk boundaries (a) for line splits — a chunk read may end
/// mid-line, and (b) for UTF-8 codepoint splits — a chunk read may end
/// mid-codepoint, and naïvely calling `String(data:encoding:.utf8)`
/// would return `nil` and silently drop bytes.
///
/// The carry is a byte-level `Data`, not `String`, so a multi-byte
/// codepoint that straddles a chunk boundary stays intact across the
/// drain → next-drain boundary instead of being dropped.
///
/// Used by both `JSONLTail` (local file fd) and `RemoteJSONLStream`
/// (SSH-piped `tail -F` stdout).
///
/// Not `Sendable`; callers serialize access (queue isolation in
/// `JSONLTail`, single-task ownership in `RemoteJSONLStream`).
final class JSONLLineFramer {
    private var carry: Data

    init() {
        self.carry = Data()
    }

    /// Reset accumulated carry (e.g. after a stream restart).
    func reset() {
        carry.removeAll(keepingCapacity: true)
    }

    /// Ingest a byte chunk; return any complete lines produced.
    /// Trailing bytes that don't form a complete line, or that end
    /// mid-codepoint, stay in the carry for the next call.
    func ingest(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        var combined = carry
        combined.append(chunk)

        // 1) Trim trailing partial UTF-8 codepoint bytes into the
        //    next-iteration carry.
        let (decodable, trailingPartial) = Self.splitAtUTF8Boundary(combined)
        guard let text = String(data: decodable, encoding: .utf8) else {
            // Decoded segment is still invalid UTF-8 (not a boundary
            // issue — actually corrupt). Drop the chunk to avoid an
            // infinite carry. Producers writing to JSONL should never
            // emit non-UTF-8 bytes.
            carry = trailingPartial
            return []
        }

        // 2) Split into complete lines; any tail without a trailing
        //    newline becomes the line-level carry.
        var emitted: [String] = []
        var working = text
        while let nlIdx = working.firstIndex(of: "\n") {
            let line = String(working[..<nlIdx])
            working = String(working[working.index(after: nlIdx)...])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                emitted.append(trimmed)
            }
        }

        // The line-level remainder is the still-incomplete-line bytes
        // (partial line, no trailing \n). We need to keep them as
        // bytes so the byte-level carry covers the next chunk too.
        let lineRemainderData = working.data(using: .utf8) ?? Data()
        carry = lineRemainderData + trailingPartial

        return emitted
    }

    // MARK: - UTF-8 boundary detection

    /// Split a buffer at the last valid UTF-8 codepoint boundary.
    /// Returns `(decodableHead, partialTail)` where `partialTail` is
    /// at most 3 bytes (a leading byte for a 2/3/4-byte sequence with
    /// fewer continuation bytes than required).
    ///
    /// UTF-8 byte taxonomy (first byte):
    ///   - `0xxxxxxx` — 1-byte sequence (ASCII)
    ///   - `110xxxxx` — leading byte of 2-byte sequence
    ///   - `1110xxxx` — leading byte of 3-byte sequence
    ///   - `11110xxx` — leading byte of 4-byte sequence
    ///   - `10xxxxxx` — continuation byte (always preceded by a
    ///     leading byte within 1–3 positions)
    ///
    /// Algorithm: scan back from the end of the buffer up to 3 bytes,
    /// looking for a leading byte. If we find one and the remaining
    /// bytes don't satisfy the sequence's length, split there.
    static func splitAtUTF8Boundary(_ data: Data) -> (decodable: Data, partial: Data) {
        let count = data.count
        guard count > 0 else { return (data, Data()) }

        // Walk back at most 3 bytes (max UTF-8 leading byte position).
        for backOffset in 1...min(3, count) {
            let i = count - backOffset
            let byte = data[data.startIndex.advanced(by: i)]

            if byte < 0x80 {
                // ASCII — codepoint complete; everything up to count.
                if backOffset == 1 {
                    return (data, Data())
                }
                // ASCII byte is N steps back, but bytes past it are
                // either continuation bytes belonging to an earlier
                // leading byte (impossible if we got here without
                // hitting one) or invalid bytes. Treat as decodable —
                // the String(data:) call will surface real corruption.
                return (data, Data())
            }

            if byte & 0b1100_0000 == 0b1000_0000 {
                // Continuation byte. Need to keep walking back to
                // find its leading byte.
                continue
            }

            // Leading byte found at offset `i` (backOffset positions
            // from end). Determine expected sequence length.
            let expectedLen: Int
            if      byte & 0b1110_0000 == 0b1100_0000 { expectedLen = 2 }
            else if byte & 0b1111_0000 == 0b1110_0000 { expectedLen = 3 }
            else if byte & 0b1111_1000 == 0b1111_0000 { expectedLen = 4 }
            else {
                // Invalid leading byte (e.g. starts with 11111xxx).
                // Treat as boundary — let String(data:) surface the
                // corruption. Don't carry forward indefinitely.
                return (data, Data())
            }

            let actualLen = backOffset
            if actualLen >= expectedLen {
                // Sequence is complete; nothing to carry.
                return (data, Data())
            }
            // Sequence is incomplete — split before the leading byte.
            let head = data.prefix(i)
            let tail = data.suffix(from: data.startIndex.advanced(by: i))
            return (Data(head), Data(tail))
        }

        // Walked back 3 bytes and saw only continuation bytes. The
        // sequence has to start at or before count-4. If a 4-byte
        // sequence's leading byte is at count-4, we'd have hit it on
        // backOffset=4 (loop bound). For pragmatic safety, treat as
        // already-decodable — corrupt streams self-correct on the
        // next chunk.
        return (data, Data())
    }
}
