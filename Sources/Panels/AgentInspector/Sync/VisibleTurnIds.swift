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

/// Number of rows of slack at the bottom of the scrollback that
/// still count as "at bottom." Small scroll movements (mouse-wheel
/// ticks, overscroll bounce, sub-row reports during a drag gesture)
/// can leave the terminal a few rows shy of `total` while the user
/// considers themselves at the bottom. Without this tolerance the
/// filter flaps between `.turns([latest])` and `.preAnchored` for
/// the same gesture, especially in resumed sessions where the
/// `.preAnchored` zone covers the entire transcript and any flap
/// rebuilds the LazyVStack with a very different content count.
private let atBottomToleranceRows: UInt64 = 3

/// Compute the visible-turn filter from the paired terminal's
/// scrollbar state, the inspector's chunk list, and the recorded
/// turn anchors.
///
/// Decision tree (no proportional fallback):
///
/// 1. **Empty stream** → `.turns([])`.
/// 2. **No scrollbar yet** (cold attach / tab-switch / resume before
///    Ghostty's first scrollbar tick): treat as at-bottom — return
///    the latest user chunk's turn so the inspector shows live tail
///    instead of an empty placeholder.
/// 3. **Latest-turn stay band**: viewport top has not moved above the
///    latest user prompt's row → `.turns([lastUserChunkId])`. The
///    band is anchored exactly when a `claude_anchor` record exists
///    for the latest user chunk; otherwise approximated as
///    `2 * len` rows from the bottom of scrollback. This widens the
///    previous narrow at-bottom check so common scroll gestures
///    don't flap the filter into `.preAnchored` and back, which
///    forces a dramatic LazyVStack content-set swap and a visible
///    flash.
/// 4. **Anchored fully-visible**: every anchor whose effective row
///    sits within `[viewportTop, viewportEnd]` → `.turns(matched)`.
/// 5. **Anchored "before"**: largest anchor with effective row ≤
///    `viewportTop` → `.turns([before.userChunkId])`. The user is
///    mid-AI-response; show the prompt that initiated it.
/// 6. **No anchor coverage** → `.preAnchored`. Free-scroll the
///    pre-inspector / resumed-history zone.
///
/// **Resize compensation.** Each anchor stores
/// `terminalRowAtSubmit` and `totalAtCapture`. On terminal resize,
/// scrollback rewraps and `total` changes. We scale the stored row
/// by `currentTotal / totalAtCapture` before comparing against the
/// viewport. Approximate (rewrap is non-uniform) but bounded.
/// Anchors recorded with `totalAtCapture == 0` (synthetic /
/// test-only) are treated as unscaled.
func computeVisibleTurnFilter(
    scrollbar: VisibleTurnScrollSnapshot?,
    chunks: [AgentChunk],
    anchors: [TurnAnchor]
) -> VisibleTurnFilter {
    guard !chunks.isEmpty else { return .turns([]) }

    let latestUserId = chunks.lastUserChunkId ?? chunks.last!.id

    // Cold-attach guard: no scrollbar tick has been published for
    // this surface yet. Treat as at-bottom so the inspector shows
    // the live tail rather than an empty pane.
    guard let scrollbar else {
        return .turns([latestUserId])
    }

    // "Stay on latest turn" zone. The viewport remains on
    // `.turns([latestUserId])` while its top edge has not moved above
    // the latest user prompt's row in scrollback. Two estimation modes:
    //
    //   - Latest user chunk has an anchor: use the scaled anchor row
    //     exactly. This is the live-prompt path.
    //   - No anchor (resumed / pre-inspector latest turn): approximate
    //     the latest prompt's row as `2 * len` rows from the bottom of
    //     scrollback — i.e., assume the latest turn occupies up to two
    //     viewport-heights of scrollback. Gives a meaningful buffer
    //     past the narrow at-bottom tolerance before transitioning
    //     into the history zone.
    //
    // Without this widened band, exiting at-bottom by a single row
    // immediately swaps the rendered chunk set from `.turns([latest])`
    // (small) to `.preAnchored` (large), producing a visible content
    // flash even when the viewport's actually-visible chunks barely
    // change across the boundary.
    let latestPromptRow: UInt64 = {
        if let anchor = anchors.last(where: { $0.userChunkId == latestUserId }) {
            return scaledRow(anchor, currentTotal: scrollbar.total)
        }
        let bandRows = scrollbar.len &* 2
        return scrollbar.total > bandRows ? scrollbar.total - bandRows : 0
    }()

    let isInLatestStayBand = scrollbar.total == 0
        || scrollbar.offset &+ atBottomToleranceRows >= latestPromptRow
    if isInLatestStayBand {
        return .turns([latestUserId])
    }

    if !anchors.isEmpty {
        let viewportTop = scrollbar.offset
        let viewportBot = scrollbar.offset &+ scrollbar.len
        let scaled: [(anchor: TurnAnchor, row: UInt64)] = anchors.map {
            (anchor: $0, row: scaledRow($0, currentTotal: scrollbar.total))
        }
        let fullyVisible = scaled.filter { $0.row >= viewportTop && $0.row <= viewportBot }
        if !fullyVisible.isEmpty {
            return .turns(Set(fullyVisible.map { $0.anchor.userChunkId }))
        }
        let before = scaled
            .filter { $0.row <= viewportTop }
            .max(by: { $0.row < $1.row })
        if let before {
            return .turns([before.anchor.userChunkId])
        }
        // Viewport is above all anchored rows → fall through to
        // .preAnchored (free-scroll history zone).
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

/// Decide the chunk-id the inspector should scroll to (with
/// `anchor=.bottom`) on a filter transition.
///
/// - `.all` / `.turns(_)` → the LazyVStack container's own id (its
///   bottom edge = bottom of the rendered set).
/// - `.preAnchored` with the latest user chunk still rendered (i.e.,
///   the latest user is unanchored): the chunk immediately preceding
///   the latest user prompt. This puts pre-last-turn content at the
///   bottom of the inspector — the user lands on history, the
///   latest turn is scrollable down, older history scrollable up.
///   Without this, scrolling to `chunkListId` lands on the latest
///   turn (since `.preAnchored` includes it), which is the same
///   content the user just scrolled away from in the terminal.
/// - `.preAnchored` with the latest user chunk excluded (latest is
///   anchored): the rendered set's natural bottom IS already the
///   pre-last-turn boundary, so the container id suffices.
///
/// Targeting a specific chunk-id (rather than the container id) is
/// also more deterministic in the presence of LazyVStack lazy row
/// materialization: scrolling to `chunkListId` with `anchor=.bottom`
/// lands at an *estimated* container bottom whose offset can vary
/// across calls; scrolling to a specific chunk forces materialization
/// of that exact row.
func inspectorScrollTarget(
    chunks: [AgentChunk],
    filter: VisibleTurnFilter,
    anchoredUserIds: Set<String>,
    chunkListId: String
) -> String {
    switch filter {
    case .all, .turns:
        return chunkListId
    case .preAnchored:
        guard let latestUserId = chunks.lastUserChunkId else {
            return chunkListId
        }
        guard !anchoredUserIds.contains(latestUserId) else {
            return chunkListId
        }
        var lastBefore: String?
        for chunk in chunks {
            if case .user(let u) = chunk, u.id == latestUserId {
                return lastBefore ?? chunkListId
            }
            lastBefore = chunk.id
        }
        return chunkListId
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
    // FIFO contract: per-session `claude_anchor` socket events arrive
    // in submit order because `prompt-submit` claude-hook fires
    // synchronously per prompt and the socket router serializes
    // commands per-surface. The Nth queued payload corresponds to the
    // Nth not-yet-anchored user chunk in the stream (in chunk order).
    // If you change the hook firing order or add concurrent submits
    // per session, this assumption breaks — switch to keying anchors
    // by user-chunk id at that point.
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
