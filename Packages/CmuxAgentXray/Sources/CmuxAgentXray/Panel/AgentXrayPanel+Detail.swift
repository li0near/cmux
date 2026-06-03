import Foundation

@available(macOS 15, *)
extension AgentXrayPanel {

    /// Called when an `EntryView` row triggers `↗ Open detail` because
    /// the requested expandable section exceeded the inline cap. Looks
    /// up the source entry in the live transcript, asks the host to
    /// resolve it into a `DetailContent`, and routes through
    /// `host.openDetailTab(...)`.
    ///
    /// No-op in `.detail` mode (frozen panels don't host a live stream).
    public func openDetail(request: DetailRequest) {
        guard case .live = mode else { return }
        let entryID = request.sourceEntryID
        guard let entry = stream.entries.first(where: { $0.id.stableString == entryID }) else {
            return
        }
        guard let content = resolveDetailContent(request: request, entry: entry) else {
            return
        }
        _ = host.openDetailTab(content: content, fromPanelID: id)
    }

    /// Phase 10 fleshes out per-case resolution from `DetailRequest` to
    /// `DetailContent`. For Phase 8 we land a stub that returns nil for
    /// every case, keeping the wiring path testable end-to-end without
    /// pinning down the resolver shape early.
    private func resolveDetailContent(
        request: DetailRequest,
        entry: Entry
    ) -> DetailContent? {
        _ = (request, entry)
        return nil
    }
}
