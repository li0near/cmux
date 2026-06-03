import Foundation

/// Queued `claude_anchor` record plus the user entries that were
/// already in the stream when the record arrived.
struct PendingClaudeAnchor: Equatable {
    let payload: ClaudeAnchorPayload
    let knownUserEntryIDsAtReceipt: Set<String>
    let allowsFutureFallback: Bool

    init(
        payload: ClaudeAnchorPayload,
        knownUserEntryIDsAtReceipt: Set<String>,
        allowsFutureFallback: Bool = true
    ) {
        self.payload = payload
        self.knownUserEntryIDsAtReceipt = knownUserEntryIDsAtReceipt
        self.allowsFutureFallback = allowsFutureFallback
    }
}

/// Pairing result: a queued `claude_anchor` payload paired to a
/// user-entry id.
public struct ClaudeAnchorPairing: Equatable, Sendable {
    public let userEntryID: String
    public let payload: ClaudeAnchorPayload

    public init(userEntryID: String, payload: ClaudeAnchorPayload) {
        self.userEntryID = userEntryID
        self.payload = payload
    }
}

/// Pair queued `claude_anchor` records with newly-arrived user
/// entries in the stream. Returns the anchors to record and the
/// residual queue.
///
/// A queued payload is consumed when either:
/// - its `turnID`, when present, exactly matches a not-yet-anchored
///   user entry id or prompt id,
/// - its submitted prompt text exactly matches one future user
///   entry, or
/// - exactly one future user entry exists and fallback is allowed.
///
/// The fallback never searches historical entries. Ambiguity leaves
/// the anchor queued rather than guessing.
///
/// Pure value function for testability; the panel calls
/// `pairClaudeAnchorsToUserEntries` and applies each result via
/// `TurnAnchorStore.recordTurnStart(...)`.
public func pairClaudeAnchorsToUserEntries(
    entries: [Entry],
    queue: [ClaudeAnchorPayload],
    isAnchored: (String) -> Bool
) -> (pairings: [ClaudeAnchorPairing], remainingQueue: [ClaudeAnchorPayload]) {
    let pendingQueue = queue.map {
        PendingClaudeAnchor(payload: $0, knownUserEntryIDsAtReceipt: [])
    }
    let result = pairClaudeAnchorsToUserEntries(
        entries: entries,
        queue: pendingQueue,
        isAnchored: isAnchored
    )
    return (result.pairings, result.remainingQueue.map(\.payload))
}

/// Internal variant that takes pre-known-id sets per pending anchor.
/// Used by the panel's hot-path code that records the known set at
/// receive-time so the anchor pairs only against *future* entries.
func pairClaudeAnchorsToUserEntries(
    entries: [Entry],
    queue: [PendingClaudeAnchor],
    isAnchored: (String) -> Bool
) -> (pairings: [ClaudeAnchorPairing], remainingQueue: [PendingClaudeAnchor]) {
    var pairings: [ClaudeAnchorPairing] = []
    var remainingQueue: [PendingClaudeAnchor] = []
    var pairedUserIDs: Set<String> = []
    let users = entries.compactMap { entry -> UserEntry? in
        guard case .user(let user) = entry else { return nil }
        return user
    }

    for pending in queue {
        if let turnID = pending.payload.turnID {
            if let exact = users.first(where: { user in
                let id = user.id.stableString
                return (id == turnID || user.promptId == turnID)
                    && !isAnchored(id)
                    && !pairedUserIDs.contains(id)
            }) {
                let id = exact.id.stableString
                pairedUserIDs.insert(id)
                pairings.append(ClaudeAnchorPairing(userEntryID: id, payload: pending.payload))
                continue
            }
        }

        guard pending.allowsFutureFallback else {
            remainingQueue.append(pending)
            continue
        }

        let futureUsers = users.filter { user in
            let id = user.id.stableString
            return !pending.knownUserEntryIDsAtReceipt.contains(id)
                && !isAnchored(id)
                && !pairedUserIDs.contains(id)
        }
        if let submitted = normalizedPromptText(pending.payload.submittedPromptText) {
            let matches = futureUsers.filter {
                normalizedPromptText($0.body.textContent) == submitted
            }
            if matches.count == 1, let match = matches.first {
                let id = match.id.stableString
                pairedUserIDs.insert(id)
                pairings.append(ClaudeAnchorPairing(userEntryID: id, payload: pending.payload))
                continue
            }
            if matches.count > 1 {
                remainingQueue.append(pending)
                continue
            }
        }

        guard futureUsers.count == 1, let fallback = futureUsers.first else {
            remainingQueue.append(pending)
            continue
        }
        let id = fallback.id.stableString
        pairedUserIDs.insert(id)
        pairings.append(ClaudeAnchorPairing(userEntryID: id, payload: pending.payload))
    }
    return (pairings, remainingQueue)
}

private func normalizedPromptText(_ text: String?) -> String? {
    guard let text else { return nil }
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}
