public import Foundation

/// Workspace + surface scoped store of turn anchors keyed by
/// user-entry id.
///
/// Lifetime matches the panel: anchors are session-local and not
/// persisted to disk. On focus change, the store is replaced
/// wholesale via `setSurface(workspaceID:surfaceID:)` to keep stale
/// anchors from another session out of view.
///
/// `@MainActor`-isolated, plain (non-`@Published` / non-`@Observable`)
/// state. Consumers that need to react to inserts subscribe via
/// `onAnchorRecorded` or watch the panel's transcript stream.
@MainActor
@available(macOS 15, *)
public final class TurnAnchorStore {
    public private(set) var workspaceID: UUID?
    public private(set) var surfaceID: UUID?

    /// Anchors keyed by user-entry id (string form of `EntryID.stableString`).
    public private(set) var anchors: [String: TurnAnchor] = [:]
    private var insertionOrder: [String] = []

    public init() {}

    /// Re-scope the store to a different (workspace, surface) pair.
    /// Drops all existing anchors. Called from the focus observer on
    /// session change.
    public func setSurface(workspaceID: UUID?, surfaceID: UUID?) {
        if self.workspaceID == workspaceID && self.surfaceID == surfaceID {
            return
        }
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        anchors.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
    }

    /// Record the anchor for a freshly-observed user prompt.
    /// Idempotent: re-discovery of the same entry does not shift the
    /// anchor.
    ///
    /// `totalAtCapture` is the `ScrollbarSnapshot.total` at the moment
    /// `terminalRow` was read; the visible-entries filter uses it to
    /// scale the row on terminal resize. Pass `0` for synthetic /
    /// test-only anchors that should not be scaled.
    public func recordTurnStart(
        userEntryID: String,
        terminalRow: UInt64,
        totalAtCapture: UInt64 = 0,
        at date: Date = Date()
    ) {
        if anchors[userEntryID] != nil { return }
        let anchor = TurnAnchor(
            userEntryID: userEntryID,
            agentTurnID: nil,
            terminalRowAtSubmit: terminalRow,
            totalAtCapture: totalAtCapture,
            capturedAt: date
        )
        anchors[userEntryID] = anchor
        insertionOrder.append(userEntryID)
    }

    /// Pair an agent turn id with the most recent user entry's
    /// turn anchor. No-op if the user entry has no anchor or already
    /// has an agent pairing.
    public func pairAgentTurn(userEntryID: String, agentTurnID: String) {
        guard var existing = anchors[userEntryID], existing.agentTurnID == nil else { return }
        existing.agentTurnID = agentTurnID
        anchors[userEntryID] = existing
    }

    /// Look up an anchor by either the user-entry id or the
    /// agent-turn id.
    public func anchor(forEntryID entryID: String) -> TurnAnchor? {
        if let direct = anchors[entryID] { return direct }
        return anchors.values.first(where: { $0.agentTurnID == entryID })
    }

    /// Find the anchor whose `terminalRowAtSubmit` is the largest
    /// value `<= row`. That's the turn currently visible at the given
    /// row. Returns nil if `row` is before the first recorded turn.
    public func anchorContaining(row: UInt64) -> TurnAnchor? {
        insertionOrder
            .compactMap { anchors[$0] }
            .filter { $0.terminalRowAtSubmit <= row }
            .max(by: { $0.terminalRowAtSubmit < $1.terminalRowAtSubmit })
    }

    /// Anchors in insertion order — the natural turn order.
    public var orderedAnchors: [TurnAnchor] {
        insertionOrder.compactMap { anchors[$0] }
    }
}
