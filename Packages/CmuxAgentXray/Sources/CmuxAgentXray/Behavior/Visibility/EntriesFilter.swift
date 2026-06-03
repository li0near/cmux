import Foundation

/// Three-way filter result for the visible-entries algorithm. The
/// view translates each case into an entry-level predicate; no
/// proportional fallback or estimation is done at the algorithm level.
public enum EntriesFilter: Equatable, Sendable {
    /// Show every entry. Used when sync mode is off, when the stream
    /// is empty, or as a sentinel "free scroll" mode.
    case all
    /// Show only entries belonging to a turn whose user-entry id is
    /// in this set. Anchored region of the scrollback.
    case turns(Set<String>)
    /// Show only entries whose containing turn has **no** anchor in
    /// `TurnAnchorStore`. Pre-panel / resumed-painted region.
    case preAnchored
}

private let beforeTurnBoundaryPrefix = "__cmux_agentxray_before_turn__"
private let tailBoundaryPrefix = "__cmux_agentxray_tail__"

/// Id of the divider in the gap immediately before turn X starts.
public func beforeTurnBoundaryID(_ userEntryID: String) -> String {
    "\(beforeTurnBoundaryPrefix):\(userEntryID)"
}

public func isBeforeTurnBoundaryID(_ id: String) -> Bool {
    id.hasPrefix("\(beforeTurnBoundaryPrefix):")
}

/// Id of the trailing divider at the very bottom of the rendered
/// entry list. Filter-dependent so the OLD id is removed from the
/// layout on every filter swap.
public func tailBoundaryID(for filter: EntriesFilter) -> String {
    switch filter {
    case .all:
        return "\(tailBoundaryPrefix):all"
    case .turns(let ids):
        return "\(tailBoundaryPrefix):turns:\(ids.sorted().joined(separator: ","))"
    case .preAnchored:
        return "\(tailBoundaryPrefix):preAnchored"
    }
}

public func isTailBoundaryID(_ id: String) -> Bool {
    id.hasPrefix("\(tailBoundaryPrefix):")
}

/// Number of rows of slack at the bottom of the scrollback that
/// still count as "at bottom." Empirically tuned — see canonical
/// notes referenced from the plan §10.
private let atBottomToleranceRows: UInt64 = 3

/// Compute the visible-entries filter from the paired terminal's
/// scrollbar state, the panel's entry list, and the recorded turn
/// anchors.
///
/// **ALGORITHM IS EMPIRICALLY TUNED. DO NOT MODIFY** the band
/// constants (`atBottomToleranceRows`, the `2 * len` stay-band), the
/// scaling formula in `scaledRow`, or the decision-tree shape below
/// without an explicit user ask. Refactoring (rename, extract
/// helpers, relocate callers) is allowed; semantic changes are not.
public func computeEntriesFilter(
    scrollbar: ScrollbarSnapshot?,
    entries: [Entry],
    anchors: [TurnAnchor]
) -> EntriesFilter {
    guard !entries.isEmpty else { return .turns([]) }

    let latestUserID = entries.lastUserEntryID ?? entries.last!.id.stableString

    guard let scrollbar else {
        return .turns([latestUserID])
    }

    let latestPromptRow: UInt64 = {
        if let anchor = anchors.last(where: { $0.userEntryID == latestUserID }) {
            return scaledRow(anchor, currentTotal: scrollbar.total)
        }
        let bandRows = scrollbar.len &* 2
        return scrollbar.total > bandRows ? scrollbar.total - bandRows : 0
    }()

    let isInLatestStayBand = scrollbar.total == 0
        || scrollbar.offset &+ atBottomToleranceRows >= latestPromptRow
    if isInLatestStayBand {
        return .turns([latestUserID])
    }

    if !anchors.isEmpty {
        let viewportTop = scrollbar.offset
        let viewportBot = scrollbar.offset &+ scrollbar.len
        let scaled: [(anchor: TurnAnchor, row: UInt64)] = anchors.map {
            (anchor: $0, row: scaledRow($0, currentTotal: scrollbar.total))
        }
        let fullyVisible = scaled.filter { $0.row >= viewportTop && $0.row <= viewportBot }
        if !fullyVisible.isEmpty {
            return .turns(Set(fullyVisible.map { $0.anchor.userEntryID }))
        }
        let before = scaled
            .filter { $0.row <= viewportTop }
            .max(by: { $0.row < $1.row })
        if let before {
            return .turns([before.anchor.userEntryID])
        }
    }

    return .preAnchored
}

/// Scale an anchor's `terminalRowAtSubmit` for the current
/// scrollback `total`. **DO NOT MODIFY** without an explicit ask.
private func scaledRow(_ anchor: TurnAnchor, currentTotal: UInt64) -> UInt64 {
    if anchor.totalAtCapture == 0 { return anchor.terminalRowAtSubmit }
    if currentTotal == anchor.totalAtCapture { return anchor.terminalRowAtSubmit }
    let scaled = (anchor.terminalRowAtSubmit &* currentTotal) / anchor.totalAtCapture
    return scaled
}

extension Array where Element == Entry {
    /// Id of the most recent **authentic** `UserEntry` in insertion
    /// order, or nil if the list contains no authentic user entries.
    /// "Authentic" excludes `wasQueued` entries.
    public var lastUserEntryID: String? {
        for entry in reversed() {
            if case .user(let u) = entry, !u.wasQueued { return u.id.stableString }
        }
        return nil
    }

    /// Ids of every `UserEntry` in insertion order, including
    /// queued ones. Anchor pairing depends on this.
    public func userEntryIDsInOrder() -> [String] {
        compactMap { entry -> String? in
            if case .user(let u) = entry { return u.id.stableString }
            return nil
        }
    }
}

/// Project the ordered entry list down to the entries that should
/// be rendered under a given `EntriesFilter` and per-entry anchor
/// status.
public func entriesForFilter(
    entries: [Entry],
    filter: EntriesFilter,
    anchoredUserIDs: Set<String>
) -> [Entry] {
    switch filter {
    case .all:
        return entries
    case .turns(let visibleIDs):
        return entriesMatchingTurnPredicate(entries: entries) { userID in
            userID.map { visibleIDs.contains($0) } ?? false
        } orphanInclude: { entry in
            visibleIDs.contains(entry.id.stableString)
        }
    case .preAnchored:
        return entriesMatchingTurnPredicate(entries: entries) { userID in
            guard let userID else { return false }
            return !anchoredUserIDs.contains(userID)
        } orphanInclude: { _ in
            true
        }
    }
}

/// Decide the entry-id the panel should scroll to (with
/// `anchor=.bottom`) on a filter transition.
public func scrollTarget(
    entries: [Entry],
    filter: EntriesFilter,
    anchoredUserIDs: Set<String>
) -> String {
    switch filter {
    case .all, .turns:
        return tailBoundaryID(for: filter)
    case .preAnchored:
        guard let latestUserID = entries.lastUserEntryID else {
            return tailBoundaryID(for: filter)
        }
        guard !anchoredUserIDs.contains(latestUserID) else {
            return tailBoundaryID(for: filter)
        }
        for (index, entry) in entries.enumerated() {
            if case .user(let u) = entry, u.id.stableString == latestUserID {
                return index > 0 ? beforeTurnBoundaryID(latestUserID) : tailBoundaryID(for: filter)
            }
        }
        return tailBoundaryID(for: filter)
    }
}

/// Walk the entry list once; for each entry, decide inclusion based
/// on the most recent preceding user-entry-id (or nil if none yet).
/// `orphanInclude` decides entries that come before any user prompt.
///
/// **Queued-prompt continuity**: a `UserEntry` with `wasQueued ==
/// true` represents a prompt the user typed mid-turn. It is *not*
/// a fresh turn boundary, so `currentUserID` does not advance past
/// queued users — the queued prompt + the resulting agent response
/// continue to bucket under the *original* prompt's turn id.
private func entriesMatchingTurnPredicate(
    entries: [Entry],
    predicate: (String?) -> Bool,
    orphanInclude: (Entry) -> Bool
) -> [Entry] {
    var result: [Entry] = []
    var currentUserID: String?
    for entry in entries {
        if case .user(let u) = entry, !u.wasQueued {
            currentUserID = u.id.stableString
        }
        if currentUserID == nil {
            // Compact-boundary signals are unanchored to any user
            // turn — include them across all visibility modes.
            if case .compact = entry {
                result.append(entry)
            } else if orphanInclude(entry) {
                result.append(entry)
            }
        } else if predicate(currentUserID) {
            result.append(entry)
        } else if case .compact = entry {
            // Compact rows mid-stream also pass through under .turns mode.
            result.append(entry)
        }
    }
    return result
}
