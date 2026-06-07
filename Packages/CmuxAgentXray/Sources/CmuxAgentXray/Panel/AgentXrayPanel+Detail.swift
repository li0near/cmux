import Foundation

@available(macOS 15, *)
extension AgentXrayPanel {

    /// Called when an `EntryView` row triggers `↗ Open detail` because
    /// the requested expandable section exceeded the inline cap. Looks
    /// up the source entry in the live transcript (walking both
    /// top-level entries and each agent turn's sub-entries).
    ///
    /// Image sections short-circuit through `host.openImageInPanel(...)`
    /// before the resolver runs — the host materializes base64 bytes
    /// to a temp file and opens a real cmux panel via the standard
    /// URL-click pipeline. Everything else flows through
    /// `DetailContent.resolve(...)` and `host.openDetailTab(...)`.
    ///
    /// No-op in `.detail` mode (frozen panels don't host a live stream).
    public func openDetail(request: DetailRequest) {
        guard case .live = mode else { return }
        let targetID = request.sourceEntryID

        // Walk the transcript: a sub-entry's id never collides with a
        // top-level entry id (sub-entries use derived ids like
        // "d:thinking-0:<parent>"), so the first match wins.
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

        // Image-section short-circuit. The clicked section is an
        // `.image(ImageSource)` — hand the bytes to the host's
        // image-open helper directly. No DetailContent flow.
        if case .bodySection(_, let sectionIndex) = request,
           case .image(let source) = imageSectionForRequest(
               targetID: targetID,
               sectionIndex: sectionIndex,
               entry: entry
           ) {
            host.openImageInPanel(
                source: source,
                sourceEntryID: targetID,
                sectionIndex: sectionIndex
            )
            return
        }

        guard let content = DetailContent.resolve(request: request, entry: entry) else {
            return
        }
        _ = host.openDetailTab(content: content, fromPanelID: id)
    }

    /// Returns the `.image(...)` section at the requested index if the
    /// click target's body has one, else nil. `targetID` may identify
    /// either the top-level entry itself (e.g. `UserEntry`) or one of
    /// an agent turn's sub-entries (e.g. a `ToolEntry` returning a
    /// screenshot).
    private func imageSectionForRequest(
        targetID: String,
        sectionIndex: Int,
        entry: Entry
    ) -> Section? {
        // Top-level entry hit (e.g. UserEntry whose body has
        // `.image(...)` from a paste).
        if entry.id.stableString == targetID {
            switch entry {
            case .user(let user):
                return user.body.sections.indices.contains(sectionIndex)
                    ? user.body.sections[sectionIndex]
                    : nil
            default:
                return nil
            }
        }
        // Sub-entry hit — the target id matches a child of an agent
        // turn (e.g. a `ToolEntry` whose body carries the image).
        if case .agent(let turn) = entry {
            for sub in turn.subEntries where sub.id.stableString == targetID {
                let sections = sub.body.sections
                return sections.indices.contains(sectionIndex)
                    ? sections[sectionIndex]
                    : nil
            }
        }
        return nil
    }
}
