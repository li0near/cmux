import Foundation

/// Per-turn anchor record used by the inspector's scroll-sync.
///
/// One anchor pairs a user-prompt chunk with the paired terminal's
/// scrollback row count at submission time. The "end" of a turn is
/// implicit — it's the next anchor's `terminalRowAtSubmit` (or the live
/// `total` if this is the latest turn). That's enough for the proportional
/// within-turn mapping the inspector uses.
struct TurnAnchor: Equatable, Sendable {
    /// User-prompt chunk id (turn start) — matches `UserChunk.id` and the
    /// `id` of the corresponding `ChunkRowSnapshot`.
    let userChunkId: String
    /// AI chunk id paired with this user prompt. Nil while the assistant
    /// response hasn't started streaming yet. Updated once the trailing
    /// AIChunk first becomes visible in the stream.
    var aiChunkId: String?
    /// Terminal `total` scrollback rows at user-prompt observation time.
    /// Read from `ScrollbarStateCache.latest(for:)` when the user chunk
    /// first appears in the stream, OR delivered exactly via the
    /// `claude_anchor` socket command when the inspector + cmux are
    /// running together.
    let terminalRowAtSubmit: UInt64
    /// `scrollbar.total` snapshot at capture time. Used by
    /// `computeVisibleTurnFilter` to scale `terminalRowAtSubmit` on
    /// terminal resize / rewrap. `0` means "treat as unscaled" (used
    /// for synthetic / test-only anchors).
    let totalAtCapture: UInt64
    /// Wallclock at which the anchor was captured. Useful for debugging
    /// stale-cache races.
    let capturedAt: Date
}

/// Workspace + surface scoped store of turn anchors keyed by user-chunk id.
///
/// Lifetime matches the inspector panel: anchors are session-local and not
/// persisted to disk. On focus change, the store is replaced wholesale via
/// `setSurface(workspaceId:surfaceId:)` to keep stale anchors from another
/// session out of view.
///
/// `@MainActor`-isolated, plain (non-`@Published`) state. Consumers that
/// need to react to inserts can subscribe via `onAnchorRecorded` or watch
/// the underlying `panel.stream.objectWillChange` instead.
@MainActor
final class TurnAnchorStore {
    private(set) var workspaceId: UUID?
    private(set) var surfaceId: UUID?

    /// Anchors keyed by user-chunk id.
    private(set) var anchors: [String: TurnAnchor] = [:]
    /// Insertion order — preserved for `anchorContaining(row:)` and tests.
    private var insertionOrder: [String] = []

    /// Re-scope the store to a different (workspace, surface) pair. Drops
    /// all existing anchors. Called from the focus observer on session
    /// change.
    func setSurface(workspaceId: UUID?, surfaceId: UUID?) {
        if self.workspaceId == workspaceId && self.surfaceId == surfaceId {
            return
        }
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        anchors.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
    }

    /// Record the anchor for a freshly-observed user prompt. Idempotent:
    /// re-discovery of the same chunk does not shift the anchor.
    ///
    /// `totalAtCapture` is the `scrollbar.total` snapshot at the moment
    /// `terminalRow` was read; the visible-turn algorithm uses it to
    /// scale the row on terminal resize. Pass `0` for synthetic /
    /// test-only anchors that should not be scaled.
    func recordTurnStart(
        userChunkId: String,
        terminalRow: UInt64,
        totalAtCapture: UInt64 = 0,
        at date: Date = Date()
    ) {
        if anchors[userChunkId] != nil { return }
        let anchor = TurnAnchor(
            userChunkId: userChunkId,
            aiChunkId: nil,
            terminalRowAtSubmit: terminalRow,
            totalAtCapture: totalAtCapture,
            capturedAt: date
        )
        anchors[userChunkId] = anchor
        insertionOrder.append(userChunkId)
    }

    /// Pair an AI chunk id with the most recent (or specified) user chunk's
    /// turn anchor. No-op if the user chunk has no anchor or already has
    /// an AI pairing.
    func pairAIChunk(userChunkId: String, aiChunkId: String) {
        guard var existing = anchors[userChunkId], existing.aiChunkId == nil else { return }
        existing.aiChunkId = aiChunkId
        anchors[userChunkId] = existing
    }

    /// Look up an anchor by either the user-chunk id or the AI-chunk id.
    func anchor(forChunkId chunkId: String) -> TurnAnchor? {
        if let direct = anchors[chunkId] { return direct }
        return anchors.values.first(where: { $0.aiChunkId == chunkId })
    }

    /// Find the anchor whose `terminalRowAtSubmit` is the largest value
    /// `<= row`. That's the turn currently visible at the given row.
    /// Returns nil if `row` is before the first recorded turn.
    func anchorContaining(row: UInt64) -> TurnAnchor? {
        var best: TurnAnchor?
        for id in insertionOrder {
            guard let a = anchors[id] else { continue }
            if a.terminalRowAtSubmit <= row {
                if best == nil || a.terminalRowAtSubmit > best!.terminalRowAtSubmit {
                    best = a
                }
            }
        }
        return best
    }

    /// Anchors in insertion order — the natural turn order.
    var orderedAnchors: [TurnAnchor] {
        insertionOrder.compactMap { anchors[$0] }
    }
}
