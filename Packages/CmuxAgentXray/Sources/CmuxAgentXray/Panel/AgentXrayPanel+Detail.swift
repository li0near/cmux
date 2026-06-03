import Foundation

@available(macOS 15, *)
extension AgentXrayPanel {

    /// Called when an `EntryView` row triggers `↗ Open detail` because
    /// the requested expandable section exceeded the inline cap. Looks
    /// up the source entry in the live transcript, resolves it into a
    /// `DetailContent` via `DetailContent.resolve(...)`, and routes
    /// through `host.openDetailTab(...)`.
    ///
    /// No-op in `.detail` mode (frozen panels don't host a live stream).
    public func openDetail(request: DetailRequest) {
        guard case .live = mode else { return }
        let entryID = request.sourceEntryID
        guard let entry = stream.entries.first(where: { $0.id.stableString == entryID }) else {
            return
        }
        guard let content = DetailContent.resolve(request: request, entry: entry) else {
            return
        }
        _ = host.openDetailTab(content: content, fromPanelID: id)
    }
}
