import Foundation

@available(macOS 15, *)
extension AgentXrayPanel {

    /// Called whenever the host reports the focused session changed.
    /// Resets per-session state and (re-)attaches the stream.
    func handleSessionChange(_ session: ResolvedAgentSession?) {
        resolvedSession = session
        // A session change always concludes any in-flight remote attach
        // (success or detach via "Change"); clear the spinner.
        remoteAttachInFlight = false
        host.updateTitle(panelID: id, title: displayTitle)
        stream.attach(session: session)
        // New session → drop precomputed entry fields; ids may collide
        // by chance and stale content would be served.
        computedCache.reset()
        // New session → reset bulk-expansion state to defaults. The
        // persistent `expansionMode` pill state is preserved — only
        // the user's pill click changes it. Bump `layoutRevision` so
        // the LazyVStack drops the previous session's stale lazy-row
        // geometry.
        cachedEntryCollection = nil
        currentExpanded.removeAll(keepingCapacity: false)
        bulkState = BulkExpansionState(
            tick: bulkState.tick &+ 1,
            lastDirection: nil,
            layoutRevision: bulkState.layoutRevision &+ 1
        )
        // Eagerly seed observedEntryIDs + currentExpanded from the
        // entries already loaded on attach. The auto-expand pill is
        // forward-only: pre-attach entries count as "already there"
        // so the pill never reaches them on the next stream tick.
        // Branches still default-expanded structurally; sub-entries
        // (text + tool) stay collapsed.
        observedEntryIDs.removeAll(keepingCapacity: false)
        let entries = currentEntryCollection()
        for entry in stream.entries {
            observedEntryIDs.insert(entry.id.stableString)
            if case .agent(let turn) = entry {
                for sub in turn.subEntries {
                    observedEntryIDs.insert(sub.id.stableString)
                }
            }
        }
        currentExpanded.formUnion(entries.branchEntryIDs)
        // Re-scope the anchor store on session change. New session ⇒
        // drop anchors from the previous turn timeline.
        if let session,
           let workspaceUUID = UUID(uuidString: session.workspaceID),
           let surfaceUUID = UUID(uuidString: session.surfaceID) {
            turnAnchorStore.setSurface(workspaceID: workspaceUUID, surfaceID: surfaceUUID)
        } else {
            turnAnchorStore.setSurface(workspaceID: nil, surfaceID: nil)
        }
        drainPendingClaudeAnchors()
        pairTurnAnchorsToAgentEntries()
        // Recompute the visible-entry filter SYNCHRONOUSLY against the
        // new session's entries. Without this, the first re-render
        // after the session swap uses the stale filter from the
        // previous session — typically `.turns([oldUserId])` whose id
        // does not exist in the new entry set, producing an empty
        // visible-entry list and a "Waiting for transcript" flash.
        recomputeEntriesFilter()
        recomputeStreamingEntryID()

        // Re-subscribe the stream observation — every session-change
        // resets the stream, and we want a fresh observation per
        // attach so cancelled tasks get GC'd promptly.
        startStreamObservation()
    }

    /// Title shown in the host's tab bar. Computed from current state.
    /// In `.detail` mode the static content title wins.
    public var displayTitle: String {
        switch mode {
        case .live:
            if let session = resolvedSession {
                return String(
                    localized: "agentXray.title.attached",
                    defaultValue: "Inspector — \(session.sessionID.prefix(8))",
                    bundle: .module
                )
            }
            return String(
                localized: "agentXray.title",
                defaultValue: "Agent X-ray",
                bundle: .module
            )
        case .detail(let content):
            return content.title
        }
    }

    /// SF Symbol identifier the host can use for the tab icon.
    public var displayIconSymbol: String {
        switch mode {
        case .live:   return "chart.bar.doc.horizontal"
        case .detail: return "doc.text"
        }
    }

    /// Subscribe to `stream` change notifications. The Observation
    /// framework's `withObservationTracking` only fires once per
    /// invocation; we re-arm the tracking inside the continuation so
    /// every subsequent change re-runs the recompute pipeline.
    private func startStreamObservation() {
        streamObservationTask?.cancel()
        streamObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, self != nil {
                let didFire = await Self.awaitNextStreamChange { [weak self] in
                    _ = self?.stream.entries
                    _ = self?.stream.lineCount
                }
                guard didFire, let self else { return }
                // Hop one runloop turn so the observed mutation has
                // fully landed before downstream recomputes read it.
                await Task.yield()
                self.handleStreamTick()
            }
        }
    }

    /// Wraps `withObservationTracking` in an async continuation so the
    /// stream-observation Task can `await` the next change. Returns
    /// `true` on the first observed read after a tracked mutation.
    private static func awaitNextStreamChange(
        _ access: @escaping @MainActor () -> Void
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            withObservationTracking {
                access()
            } onChange: {
                continuation.resume(returning: true)
            }
        }
    }

    /// Triggered after every observed `stream.entries` mutation. Drops
    /// the cached entry collection, drains queued claude anchors,
    /// pairs new agent turns to their user-entry anchors, refreshes
    /// the entries filter, materialises auto-expand on new ids, and
    /// re-evaluates the streaming-pulse id.
    func handleStreamTick() {
        cachedEntryCollection = nil
        drainPendingClaudeAnchors()
        pairTurnAnchorsToAgentEntries()
        recomputeEntriesFilter()
        autoExpandNewEntries()
        recomputeStreamingEntryID()
    }
}
