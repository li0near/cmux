import Foundation

@available(macOS 15, *)
extension AgentXrayPanel {

    /// Handler for `claude_anchor` payloads delivered by the host.
    /// Queues records by session id so anchors submitted while the
    /// panel is attached elsewhere can still be consumed when that
    /// session becomes active.
    func handleClaudeAnchorPayload(_ payload: ClaudeAnchorPayload) {
        guard case .live = mode else { return }
        let isCurrentSession = resolvedSession?.sessionID == payload.sessionID
        let knownIDs: Set<String> = isCurrentSession
            ? Set(stream.entries.userEntryIDsInOrder())
            : []
        pendingClaudeAnchorsBySessionID[payload.sessionID, default: []].append(
            PendingClaudeAnchor(
                payload: payload,
                knownUserEntryIDsAtReceipt: knownIDs,
                allowsFutureFallback: isCurrentSession
            )
        )
        guard isCurrentSession else { return }
        // The user entry for this prompt may already be in the stream
        // (rare: hook fires after JSONL flush + tail debounce). Try
        // draining immediately so the anchor is recorded without
        // waiting for the next stream tick.
        drainPendingClaudeAnchors()
        recomputeEntriesFilter()
    }

    /// Drain queued `claude_anchor` records by pairing each one with
    /// a matching live user entry. Pure pairing function does the
    /// work; we apply each result via `TurnAnchorStore.recordTurnStart`.
    func drainPendingClaudeAnchors() {
        guard case .live = mode,
              let sessionID = resolvedSession?.sessionID,
              let queue = pendingClaudeAnchorsBySessionID[sessionID],
              !queue.isEmpty else { return }
        let entries = stream.entries
        guard !entries.isEmpty else { return }
        let result = pairClaudeAnchorsToUserEntries(
            entries: entries,
            queue: queue,
            isAnchored: { [turnAnchorStore] id in
                turnAnchorStore.anchor(forEntryID: id) != nil
            }
        )
        for pairing in result.pairings {
            turnAnchorStore.recordTurnStart(
                userEntryID: pairing.userEntryID,
                terminalRow: pairing.payload.terminalRowAtSubmit,
                totalAtCapture: pairing.payload.totalAtCapture,
                at: pairing.payload.capturedAt
            )
        }
        if result.remainingQueue.isEmpty {
            pendingClaudeAnchorsBySessionID.removeValue(forKey: sessionID)
        } else {
            pendingClaudeAnchorsBySessionID[sessionID] = result.remainingQueue
        }
    }

    /// Walk the entries once to pair every recorded user-entry anchor
    /// with its first following AgentTurn. Idempotent.
    func pairTurnAnchorsToAgentTurns() {
        guard case .live = mode else { return }
        let entries = stream.entries
        guard !entries.isEmpty else { return }
        var lastUnpairedUserID: String? = {
            for anchor in turnAnchorStore.orderedAnchors.reversed() {
                if anchor.agentTurnID == nil { return anchor.userEntryID }
            }
            return nil
        }()
        for entry in entries {
            switch entry {
            case .user(let user):
                if turnAnchorStore.anchor(forEntryID: user.id.stableString) != nil {
                    lastUnpairedUserID = user.id.stableString
                }
            case .agent(let turn):
                if let userID = lastUnpairedUserID {
                    turnAnchorStore.pairAgentTurn(
                        userEntryID: userID,
                        agentTurnID: turn.id.stableString
                    )
                    lastUnpairedUserID = nil
                }
            case .system, .compact, .synthesized:
                break
            }
        }
    }
}
