import AppKit
import Foundation

@available(macOS 15, *)
extension AgentXrayPanel {

    /// Called when an `EntryView` row triggers `↗ Open detail` because
    /// the requested expandable section exceeded the inline cap. Looks
    /// up the source entry in the live transcript (walking both
    /// top-level entries and each agent turn's sub-entries) and routes
    /// the resolved `DetailContent` through `host.openDetailTab(...)`.
    ///
    /// **Cmd-click** (modifier read at click time via
    /// `NSApp.currentEvent`) flips focus-on-open off so users can
    /// queue multiple detail tabs without losing AgentX-ray context.
    /// Default click activates the new panel.
    ///
    /// No-op in `.detail` mode (frozen panels don't host a live stream).
    public func openDetail(request: DetailRequest) {
        guard case .live = mode else { return }
        let cmdHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        let activate = !cmdHeld
        let targetID = request.sourceEntryID

        // Walk the transcript: a sub-entry's id never collides with a
        // top-level entry id (sub-entries use derived ids like
        // "d:text-0:<line-uuid>" / "d:thinking-0:<line-uuid>"; tool
        // sub-entries use the raw `tool_use_id`), so the first match
        // wins.
        var matchedEntry: Entry?
        for entry in stream.entries {
            if entry.id.stableString == targetID {
                matchedEntry = entry
                break
            }
            if case .agent(let turn) = entry,
               turn.subEntries.contains(where: { $0.id.stableString == targetID }) {
                matchedEntry = entry
                break
            }
        }
        guard let entry = matchedEntry else { return }
        guard let content = DetailContent.resolve(request: request, entry: entry) else {
            return
        }
        _ = host.openDetailTab(content: content, fromPanelID: id, activate: activate)
    }
}
