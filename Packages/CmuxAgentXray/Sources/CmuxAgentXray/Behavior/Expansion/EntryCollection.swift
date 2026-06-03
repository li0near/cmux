import Foundation

/// Direction of a bulk-action click on the panel's status-bar pills.
public enum BulkDirection: Equatable, Sendable {
    case collapse, expand
}

/// The visible inspector entries partitioned by structural role,
/// derived from the entry tree once and cached on the panel until
/// the stream's entry set changes.
///
/// Three Sets:
///   - `branchEntryIDs`     — entries that default-expand at boot
///                            (every `Entry.agent`).
///                            `branchEntryIDs ⊆ topLevelEntryIDs`.
///   - `topLevelEntryIDs`   — entries rendered as direct children of
///                            the panel root: every top-level entry
///                            (branches plus user / system / compact
///                            / synthesized leaves). Excludes
///                            sub-entries.
///   - `allEntryIDs`        — every classified entry id (top-level
///                            entries plus sub-entries that
///                            participate in expansion: agent turns'
///                            thinking + tools).
///
/// `topLevelEntryIDs` exists so the status bar's pill enabledness
/// can ask "is any *visible* entry expanded?" — without it, inert
/// sub-entry state (a tool the user opened, but whose parent branch
/// is now folded) keeps the collapse pill clickable while clicks
/// have no visible effect. Sub-entries under a collapsed branch
/// aren't rendered, so dropping them produces no visible change.
///
/// Leaves (non-branch top-level entries + sub-entries) are reachable
/// as `allEntryIDs.subtracting(branchEntryIDs)` — kept implicit to
/// avoid carrying a redundant set. AssistantText is intentionally
/// not classified.
public struct EntryCollection: Equatable, Sendable {
    public let branchEntryIDs:   Set<String>
    public let topLevelEntryIDs: Set<String>
    public let allEntryIDs:      Set<String>

    public init(
        branchEntryIDs: Set<String> = [],
        topLevelEntryIDs: Set<String> = [],
        allEntryIDs: Set<String> = []
    ) {
        self.branchEntryIDs = branchEntryIDs
        self.topLevelEntryIDs = topLevelEntryIDs
        self.allEntryIDs = allEntryIDs
    }

    /// Walks `entries` once, classifying every visible entry id.
    public init(of entries: [Entry]) {
        var branches = Set<String>()
        var topLevel = Set<String>()
        var all      = Set<String>()
        for entry in entries {
            let id = entry.id.stableString
            topLevel.insert(id)
            all.insert(id)
            switch entry {
            case .agent(let turn):
                branches.insert(id)
                for sub in turn.subEntries {
                    switch sub {
                    case .thinking(let t): all.insert(t.id.stableString)
                    case .tool(let t):     all.insert(t.id.stableString)
                    // assistantText is intentionally not classified;
                    // it's a header-only link, not an expandable row.
                    case .assistantText:   break
                    }
                }
            case .user, .system, .compact, .synthesized:
                break
            }
        }
        self.branchEntryIDs = branches
        self.topLevelEntryIDs = topLevel
        self.allEntryIDs = all
    }
}

// MARK: - Bulk action algorithm

/// Pure decision: given the current expanded set and the entry
/// collection, what's the next expanded set after a click in
/// `direction`?
///
/// Two-case state machine. Same-direction fiddles persist;
/// opposing-direction fiddles get reverted on the next click.
///
///   - **Collapse click.** Intersect with `branchEntryIDs`. If
///     smaller than `current` (leaves were expanded), return it —
///     closes the leaves, keeps user-collapsed branches absent. Else
///     return `[]` (advance to fullyCollapsed).
///   - **Expand click.** Union with `branchEntryIDs`. If larger
///     than `current` (branches were missing), return it — opens
///     the branches, preserves user-opened leaves. Else return
///     `allEntryIDs` (advance to fullyExpanded).
///
/// At terminals (`current` already empty for `.collapse`, already
/// `allEntryIDs` for `.expand`) returns `current` unchanged.
public func nextExpanded(
    after direction: BulkDirection,
    given current: Set<String>,
    in entries: EntryCollection
) -> Set<String> {
    switch direction {
    case .collapse:
        let branchesOnly = current.intersection(entries.branchEntryIDs)
        return branchesOnly.count < current.count ? branchesOnly : []
    case .expand:
        let withBranches = current.union(entries.branchEntryIDs)
        return withBranches.count > current.count ? withBranches : entries.allEntryIDs
    }
}
