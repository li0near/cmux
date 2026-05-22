import Foundation

/// Pure value snapshot of the inputs that drive
/// `computeVisibleTurnIds`. Decouples the algorithm from
/// `GhosttyScrollbar` so unit tests can drive it without spinning up a
/// terminal surface.
struct VisibleTurnScrollSnapshot: Equatable {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(total: UInt64, offset: UInt64, len: UInt64) {
        self.total = total
        self.offset = offset
        self.len = len
    }

    init(_ scrollbar: GhosttyScrollbar) {
        self.total = scrollbar.total
        self.offset = scrollbar.offset
        self.len = scrollbar.len
    }
}

/// Compute the set of user-chunk ids whose **turn** is currently visible
/// in the paired terminal viewport.
///
/// A "turn" is a user prompt + everything between it and the next user
/// prompt (assistant chunks, tool calls, system messages, compact
/// markers). The inspector view filters its row list to chunks whose
/// owning turn appears in this set.
///
/// Three regimes, evaluated in order:
///
/// 1. **At-bottom snap.** Terminal viewport reaches the tail of its
///    scrollback. Returns the latest user chunk's id (live tail). When
///    the stream has no user chunks at all, returns the latest chunk's
///    id so the panel still has something to show.
///
/// 2. **Anchored.** At least one `TurnAnchor` is recorded.
///    - If at least one user prompt is **fully visible**
///      (`terminalRowAtSubmit` ∈ `[viewportTop, viewportBottom]`), the
///      visible set is the union of all such fully-visible prompts.
///    - Otherwise, the visible set is the prompt **before** the visible
///      region (largest `terminalRowAtSubmit ≤ viewportTop`). User-rule:
///      "the user always sees what prompt initiated what's on screen."
///    - If the viewport is above the first anchor, falls through to
///      regime 3.
///
/// 3. **Proportional fallback.** No anchor matches (fresh session, or
///    pre-inspector-open turns). Pick the user chunk at the **floored**
///    proportional position in the chunk list:
///    `idx = floor(lastIndex * fraction)`. Floor (not round) guarantees
///    we land at-or-before the visible region. The post-compaction
///    restriction from v1 is dropped — always show *some* turn.
///
/// Returns an empty set when scrollbar is nil or chunks is empty.
func computeVisibleTurnIds(
    scrollbar: VisibleTurnScrollSnapshot?,
    chunks: [AgentChunk],
    anchors: [TurnAnchor]
) -> Set<String> {
    guard let scrollbar, !chunks.isEmpty else { return [] }

    let viewportEnd = scrollbar.offset &+ scrollbar.len
    let isAtBottom = scrollbar.total == 0 || viewportEnd >= scrollbar.total
    if isAtBottom {
        if let lastUser = chunks.lastUserChunkId { return [lastUser] }
        if let last = chunks.last { return [last.id] }
        return []
    }

    if !anchors.isEmpty {
        let viewportTop = scrollbar.offset
        let viewportBot = viewportEnd
        let fullyVisible = anchors.filter {
            $0.terminalRowAtSubmit >= viewportTop && $0.terminalRowAtSubmit <= viewportBot
        }
        if !fullyVisible.isEmpty {
            return Set(fullyVisible.map(\.userChunkId))
        }
        // No prompt fully visible — anchor on the prompt before the visible region.
        let before = anchors
            .filter { $0.terminalRowAtSubmit <= viewportTop }
            .max(by: { $0.terminalRowAtSubmit < $1.terminalRowAtSubmit })
        if let before {
            return [before.userChunkId]
        }
        // Viewport is above the first anchor — fall through to proportional.
    }

    // Regime 3: proportional fallback. Always show *some* turn.
    let userIds = chunks.userChunkIdsInOrder()
    let pool = userIds.isEmpty ? chunks.map(\.id) : userIds
    guard !pool.isEmpty else { return [] }
    let scrollableRows: UInt64 = scrollbar.total > scrollbar.len
        ? scrollbar.total - scrollbar.len
        : 0
    let fraction: Double = scrollableRows == 0
        ? 0
        : min(1.0, Double(scrollbar.offset) / Double(scrollableRows))
    let lastIndex = pool.count - 1
    // Floor (not round) — always land at-or-before the visible region.
    let idx = min(lastIndex, max(0, Int(Double(lastIndex) * fraction)))
    return [pool[idx]]
}

extension Array where Element == AgentChunk {
    /// Id of the most recent `UserChunk` in insertion order, or nil if the
    /// list contains no user chunks.
    var lastUserChunkId: String? {
        for chunk in reversed() {
            if case .user(let u) = chunk { return u.id }
        }
        return nil
    }

    /// Ids of every `UserChunk` in insertion order.
    func userChunkIdsInOrder() -> [String] {
        compactMap { chunk -> String? in
            if case .user(let u) = chunk { return u.id }
            return nil
        }
    }
}

/// Project the ordered chunk list down to the chunks that belong to one of
/// the visible turns in `visibleIds`. A chunk belongs to a visible turn
/// when:
///   - it is the user chunk whose id is in `visibleIds`, OR
///   - it follows that user chunk and precedes the next user chunk
///     (tool calls / system / compact / AI between user prompts).
///
/// When `visibleIds` references a non-user chunk id (proportional
/// fallback over a user-less stream), only that single chunk is included.
func chunksInVisibleTurns(
    chunks: [AgentChunk],
    visibleIds: Set<String>
) -> [AgentChunk] {
    if visibleIds.isEmpty { return [] }
    var result: [AgentChunk] = []
    var includeFlag = false
    var sawAnyUser = false
    for chunk in chunks {
        if case .user(let u) = chunk {
            sawAnyUser = true
            includeFlag = visibleIds.contains(u.id)
        }
        if includeFlag {
            result.append(chunk)
        } else if !sawAnyUser && visibleIds.contains(chunk.id) {
            // Pre-first-user chunk targeted by proportional fallback over a user-less stream.
            result.append(chunk)
        }
    }
    return result
}
