import Foundation

@available(macOS 15, *)
extension AgentXrayPanel {

    // MARK: - Per-entry expansion toggle

    /// Identifies the expansion key the user toggled.
    public enum ExpansionToggle: Equatable, Sendable {
        /// Top-level entry header (one entry per agent turn / user prompt).
        case entry(id: String)
        /// Agent turn's thinking sub-entry (derived id).
        case thinking(parentEntryID: String)
        /// Tool sub-entry inside an agent turn (mirrored JSONL id).
        case tool(toolID: String)

        /// Lookup key into `currentExpanded`. Thinking is the one
        /// derived sub-id; all others are direct JSONL ids.
        public var key: String {
            switch self {
            case .entry(let id), .tool(let id):
                return id
            case .thinking(let parent):
                return EntryID.derived(parent: parent, kind: "thinking").stableString
            }
        }
    }

    /// Flip the entry's set membership in `currentExpanded`.
    ///
    /// Note: when the user manually collapses a branch via its header
    /// chevron, the branch's sub-entries stay in `currentExpanded` as
    /// inert state — they're not visually rendered (their parent is
    /// folded), but their membership persists so re-opening the
    /// branch restores them. The pill enabledness check (`canCollapse`)
    /// ignores inert sub-entries by intersecting against
    /// `topLevelEntryIDs`.
    public func toggleExpansion(_ toggle: ExpansionToggle) {
        let key = toggle.key
        if !currentExpanded.insert(key).inserted {
            currentExpanded.remove(key)
        }
    }

    // MARK: - Bulk action

    /// Trigger a stepped collapse-all signal.
    public func collapseAll() { applyBulkAction(.collapse) }

    /// Trigger a stepped expand-all signal.
    public func expandAll() { applyBulkAction(.expand) }

    /// True iff a `.collapse` click would change the *visible* state.
    /// Sub-entries under a folded branch aren't rendered, so dropping
    /// them produces no visible change — those ids in
    /// `currentExpanded` are inert state. Test on intersection with
    /// `topLevelEntryIDs` instead of `currentExpanded.isEmpty` so the
    /// pill disables correctly when only inert sub-entries remain.
    public var canCollapse: Bool {
        !currentExpanded.intersection(currentEntryCollection().topLevelEntryIDs).isEmpty
    }

    /// True iff an `.expand` click would change `currentExpanded`.
    public var canExpand: Bool {
        currentExpanded.count < currentEntryCollection().allEntryIDs.count
    }

    /// Apply a bulk-action click. Computes the next expanded set via
    /// `nextExpanded(after:given:in:)` and writes it back if it
    /// differs from the current set.
    func applyBulkAction(_ direction: BulkDirection) {
        let entries = currentEntryCollection()
        let next = nextExpanded(
            after: direction,
            given: currentExpanded,
            in: entries
        )
        guard next != currentExpanded else { return }
        let nextLayoutRevision = direction == .collapse
            ? bulkState.layoutRevision &+ 1
            : bulkState.layoutRevision
        bulkState = BulkExpansionState(
            tick: bulkState.tick &+ 1,
            lastDirection: direction,
            layoutRevision: nextLayoutRevision
        )
        currentExpanded = next
    }

    // MARK: - Auto-expand on new items

    /// Lazily recompute the entry collection from the current
    /// `stream.entries`. Cleared on every stream tick / session
    /// change / `.free → .snap` mode flip.
    func currentEntryCollection() -> EntryCollection {
        if let cached = cachedEntryCollection { return cached }
        let collection = EntryCollection(of: stream.entries)
        cachedEntryCollection = collection
        return collection
    }

    /// Walk `stream.entries` for any id new since the last call. For
    /// each new id, materialise the entry's default expansion in
    /// `currentExpanded`:
    ///   - Branches (AgentEntry) are always inserted (default-expanded).
    ///   - Leaves are inserted only when the auto-expand pill is on
    ///     (post-attach forward-only).
    func autoExpandNewEntries() {
        let entries = currentEntryCollection()
        let isActive = shouldAutoExpandNewItems
        for entry in stream.entries {
            let id = entry.id.stableString
            if observedEntryIDs.insert(id).inserted {
                if entries.branchEntryIDs.contains(id) {
                    currentExpanded.insert(id)
                    if case .agent = entry, isActive {
                        currentExpanded.insert(
                            EntryID.derived(parent: id, kind: "thinking").stableString
                        )
                    }
                } else if isActive {
                    currentExpanded.insert(id)
                }
            }
            if case .agent(let turn) = entry {
                for sub in turn.subEntries {
                    if case .tool(let tool) = sub {
                        let toolID = tool.id.stableString
                        if observedEntryIDs.insert(toolID).inserted && isActive {
                            currentExpanded.insert(toolID)
                        }
                    }
                }
            }
        }
    }
}
