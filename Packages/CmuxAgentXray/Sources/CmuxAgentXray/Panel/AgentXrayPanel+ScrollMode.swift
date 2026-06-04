import Foundation

@available(macOS 15, *)
extension AgentXrayPanel {

    /// React to a `scrollMode` change. **Asymmetric** by design:
    ///
    /// - **`.free → .snap`**: full reset. Re-seed `currentExpanded` to
    ///   defaults (branches in, leaves out), drop the entry-collection
    ///   cache, bump `bulkState` (tick + `layoutRevision`), and re-
    ///   derive `entriesFilter`. `observedEntryIDs` is intentionally
    ///   preserved so the auto-expand pill stays forward-only across
    ///   mode flips (only entries that arrive *after* attach get
    ///   auto-expanded). The view's `.onChange(of: panel.entriesFilter)`
    ///   handler then scrolls the new content set to its tail boundary.
    /// - **`.snap → .free`**: preserve state. Just relax the filter to
    ///   `.all`. No state reset, no remount, no scroll.
    func applyModeFlip(from old: ScrollMode, to new: ScrollMode) {
        guard new != old else { return }
        switch new {
        case .snap:
            cachedEntryCollection = nil
            currentExpanded = currentEntryCollection().branchEntryIDs
            bulkState = BulkExpansionState(
                tick: bulkState.tick &+ 1,
                lastDirection: nil,
                layoutRevision: bulkState.layoutRevision &+ 1
            )
            recomputeEntriesFilter()
        case .free:
            if entriesFilter != .all {
                entriesFilter = .all
            }
        }
    }

    /// Notification entry point from the host's scrollbar observer.
    /// Filters by surface and bails outside `.snap` mode in O(1).
    /// Coalesces multiple events that arrive within one ~16ms display
    /// frame into a single trailing recompute.
    func queueScrollbarUpdate(surfaceID: UUID) {
        guard case .live = mode, scrollMode == .snap else { return }
        guard let pairedSurfaceID = pairedSurfaceUUID(),
              pairedSurfaceID == surfaceID else { return }
        guard !hasPendingScrollbarRecompute else { return }
        hasPendingScrollbarRecompute = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            guard let self else { return }
            self.hasPendingScrollbarRecompute = false
            self.recomputeEntriesFilter()
        }
    }

    /// Compute the entries filter from the host's scrollbar snapshot
    /// for the paired terminal and publish it. Equality short-circuit
    /// keeps redundant scroll events within the same turn from
    /// invalidating the parent view body.
    func recomputeEntriesFilter() {
        guard case .live = mode else { return }
        guard scrollMode == .snap else {
            if entriesFilter != .all { entriesFilter = .all }
            return
        }
        guard let pairedSurfaceID = pairedSurfaceUUID() else {
            if entriesFilter != .all { entriesFilter = .all }
            return
        }
        let scrollbar = host.scrollbarSnapshot(forSurfaceID: pairedSurfaceID)
        let computed = computeEntriesFilter(
            scrollbar: scrollbar,
            entries: stream.entries,
            anchors: turnAnchorStore.orderedAnchors
        )
        if computed != entriesFilter {
            entriesFilter = computed
        }
    }

    /// Set `streamingEntryID` to the trailing AgentEntry's id when that
    /// turn is still being written to (per `streamingFreshnessWindow`),
    /// nil otherwise. Schedules a one-shot recheck after the freshness
    /// window so the pulse settles even if no further entries land.
    func recomputeStreamingEntryID() {
        streamingFreshnessTimer?.invalidate()
        streamingFreshnessTimer = nil

        guard case .live = mode else {
            if streamingEntryID != nil { streamingEntryID = nil }
            return
        }
        let entries = stream.entries
        guard case let .agent(turn) = entries.last else {
            if streamingEntryID != nil { streamingEntryID = nil }
            return
        }
        // Codex rollouts have no per-line timestamps (`endTime == nil`).
        // Treat them as "fresh while at the tail" — the next non-agent
        // entry landing is what flips the pulse off in that case.
        let isFresh: Bool = {
            guard let endTime = turn.endTime else { return true }
            return Date().timeIntervalSince(endTime) < Self.streamingFreshnessWindow
        }()
        let agentID = turn.id.stableString
        if isFresh {
            if streamingEntryID != agentID {
                streamingEntryID = agentID
            }
            let interval = Self.streamingFreshnessWindow + 0.1
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recomputeStreamingEntryID()
                }
            }
            streamingFreshnessTimer = timer
        } else {
            if streamingEntryID != nil { streamingEntryID = nil }
        }
    }

    /// Resolve the paired terminal surface UUID from
    /// `resolvedSession.surfaceID` (string form). Returns nil if no
    /// session is attached or the id is malformed.
    private func pairedSurfaceUUID() -> UUID? {
        guard let surfaceIDString = resolvedSession?.surfaceID else { return nil }
        return UUID(uuidString: surfaceIDString)
    }
}
