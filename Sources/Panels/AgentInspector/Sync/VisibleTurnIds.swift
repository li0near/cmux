import Foundation

/// Pure value snapshot of the inputs that drive
/// `computeVisibleTurnFilter`. Decouples the algorithm from
/// `GhosttyScrollbar` so unit tests can drive it without spinning up
/// a terminal surface.
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

/// Three-way filter result for the visible-turn algorithm. The view
/// translates each case into a chunk-level predicate; no proportional
/// fallback or estimation is done at the algorithm level.
enum VisibleTurnFilter: Equatable {
    /// Show every chunk. Used when sync mode is off, when the stream
    /// is empty, or as a sentinel "free scroll" mode.
    case all
    /// Show only chunks belonging to a turn whose user-chunk id is in
    /// this set. Anchored region of the scrollback.
    case turns(Set<String>)
    /// Show only chunks whose containing turn has **no** anchor in
    /// `TurnAnchorStore`. Pre-inspector / resumed-painted region.
    /// User browses unanchored history independently of the terminal.
    case preAnchored
}

/// Compute the visible-turn filter from the paired terminal's
/// scrollbar state, the inspector's chunk list, and the recorded
/// turn anchors.
///
/// Decision tree (no proportional fallback):
///
/// 1. **Empty stream** → `.turns([])`.
/// 2. **At-bottom snap** (`viewportEnd ≥ total`) → `.turns([lastUserChunkId])`.
///    The user is explicitly looking at the latest content; show that
///    turn whether or not it's anchored.
/// 3. **Anchored fully-visible**: every anchor whose effective row
///    sits within `[viewportTop, viewportEnd]` → `.turns(matched)`.
/// 4. **Anchored "before"**: largest anchor with effective row ≤
///    `viewportTop` → `.turns([before.userChunkId])`. The user is
///    mid-AI-response; show the prompt that initiated it.
/// 5. **No anchor coverage** → `.preAnchored`. Free-scroll the
///    pre-inspector zone.
///
/// **Resize compensation.** Each anchor stores
/// `terminalRowAtSubmit` and `totalAtCapture`. On terminal resize,
/// scrollback rewraps and `total` changes. We scale the stored row
/// by `currentTotal / totalAtCapture` before comparing against the
/// viewport. Approximate (rewrap is non-uniform) but bounded.
/// Anchors recorded with `totalAtCapture == 0` (synthetic /
/// test-only) are treated as unscaled.
///
/// Returns `.all` when scrollbar is nil or chunks is empty (the empty
/// case is treated as "nothing to filter").
func computeVisibleTurnFilter(
    scrollbar: VisibleTurnScrollSnapshot?,
    chunks: [AgentChunk],
    anchors: [TurnAnchor]
) -> VisibleTurnFilter {
    guard let scrollbar, !chunks.isEmpty else { return .turns([]) }

    let viewportEnd = scrollbar.offset &+ scrollbar.len
    let isAtBottom = scrollbar.total == 0 || viewportEnd >= scrollbar.total
    if isAtBottom {
        if let lastUser = chunks.lastUserChunkId { return .turns([lastUser]) }
        if let last = chunks.last { return .turns([last.id]) }
        return .turns([])
    }

    if !anchors.isEmpty {
        let viewportTop = scrollbar.offset
        let viewportBot = viewportEnd
        // Project each anchor's row through the resize-scaling rule.
        let scaled: [(anchor: TurnAnchor, row: UInt64)] = anchors.map {
            (anchor: $0, row: scaledRow($0, currentTotal: scrollbar.total))
        }
        let fullyVisible = scaled.filter { $0.row >= viewportTop && $0.row <= viewportBot }
        if !fullyVisible.isEmpty {
            return .turns(Set(fullyVisible.map { $0.anchor.userChunkId }))
        }
        // No prompt fully visible — try "before" rule.
        let before = scaled
            .filter { $0.row <= viewportTop }
            .max(by: { $0.row < $1.row })
        if let before {
            return .turns([before.anchor.userChunkId])
        }
        // Viewport is above all anchored rows → pre-inspector zone.
    }

    return .preAnchored
}

/// Scale an anchor's `terminalRowAtSubmit` for the current scrollback
/// `total`. Compensates for terminal resize/rewrap.
private func scaledRow(_ anchor: TurnAnchor, currentTotal: UInt64) -> UInt64 {
    if anchor.totalAtCapture == 0 { return anchor.terminalRowAtSubmit }
    if currentTotal == anchor.totalAtCapture { return anchor.terminalRowAtSubmit }
    // Multiply first to keep precision in integer arithmetic.
    let scaled = (anchor.terminalRowAtSubmit &* currentTotal) / anchor.totalAtCapture
    return scaled
}

extension Array where Element == AgentChunk {
    /// Id of the most recent `UserChunk` in insertion order, or nil
    /// if the list contains no user chunks.
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

/// Project the ordered chunk list down to the chunks that should be
/// rendered under a given `VisibleTurnFilter` and per-chunk anchor
/// status (`isAnchored`).
///
/// - `.all` → every chunk.
/// - `.turns(set)` → chunks whose containing turn's user-chunk-id is
///   in `set`. A chunk's "containing turn" is the most recent
///   user-chunk preceding or equal to it. Chunks before the first
///   user prompt are included only when their own id appears in
///   `set` (rare — proportional fallback over a user-less stream).
/// - `.preAnchored` → chunks whose containing turn's user-chunk-id
///   is NOT in `anchoredUserIds`.
func chunksForFilter(
    chunks: [AgentChunk],
    filter: VisibleTurnFilter,
    anchoredUserIds: Set<String>
) -> [AgentChunk] {
    switch filter {
    case .all:
        return chunks
    case .turns(let visibleIds):
        return chunksMatchingTurnPredicate(chunks: chunks) { userId in
            userId.map { visibleIds.contains($0) } ?? false
        } orphanInclude: { chunk in
            visibleIds.contains(chunk.id)
        }
    case .preAnchored:
        return chunksMatchingTurnPredicate(chunks: chunks) { userId in
            guard let userId else { return false }
            return !anchoredUserIds.contains(userId)
        } orphanInclude: { _ in
            // Chunks with no preceding user prompt are inherently
            // "unanchored" — include them in the pre-anchored zone.
            true
        }
    }
}

/// FIFO-pair queued `claude_anchor` records with newly-arrived user
/// chunks in the stream. Returns the anchors to record (in
/// insertion order) and the residual queue.
///
/// A queued payload is consumed only when a not-yet-anchored user
/// chunk exists at or after the current FIFO position. Pre-inspector
/// user chunks (those that arrived before any payload was queued)
/// stay unanchored — the caller skips over them.
///
/// Pure value function for testability; the panel calls
/// `pairClaudeAnchorsToUserChunks` and applies each result via
/// `TurnAnchorStore.recordTurnStart(...)`.
struct ClaudeAnchorPairing: Equatable {
    let userChunkId: String
    let payload: ClaudeAnchorPayload
}

/// Walk the chunk list once; for each chunk, decide inclusion based
/// on the most recent preceding user-chunk-id (or nil if none yet).
/// `orphanInclude` decides chunks that come before any user prompt.
private func chunksMatchingTurnPredicate(
    chunks: [AgentChunk],
    predicate: (String?) -> Bool,
    orphanInclude: (AgentChunk) -> Bool
) -> [AgentChunk] {
    var result: [AgentChunk] = []
    var currentUserId: String?
    for chunk in chunks {
        if case .user(let u) = chunk {
            currentUserId = u.id
        }
        if currentUserId == nil {
            if orphanInclude(chunk) { result.append(chunk) }
        } else if predicate(currentUserId) {
            result.append(chunk)
        }
    }
    return result
}

func pairClaudeAnchorsToUserChunks(
    chunks: [AgentChunk],
    queue: [ClaudeAnchorPayload],
    isAnchored: (String) -> Bool
) -> (pairings: [ClaudeAnchorPairing], remainingQueue: [ClaudeAnchorPayload]) {
    var queue = queue
    var pairings: [ClaudeAnchorPairing] = []
    for chunk in chunks {
        guard case .user(let user) = chunk else { continue }
        if isAnchored(user.id) { continue }
        guard !queue.isEmpty else { break }
        let head = queue.removeFirst()
        pairings.append(ClaudeAnchorPairing(userChunkId: user.id, payload: head))
    }
    return (pairings, queue)
}
