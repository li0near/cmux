/// A request to surface one body section in a detail tab. Emitted by
/// the entry view when the inline cap is exceeded; consumed by
/// `AgentXrayPanel.openDetail(request:)`, which resolves it against
/// the live transcript into a `DetailContent` and asks the host to
/// open a sibling tab.
///
/// One case covers every detail surface today — top-level entries
/// (user / system / compact), agent sub-entries (text / tool), and
/// synthesized entries (abandoned-branch transcripts) all address one
/// section of one body. `targetID` resolves to either a top-level
/// entry's id or an agent turn's sub-entry id; `sectionIndex` picks
/// the section within that body.
///
/// `DetailContent.resolve(...)` derives the per-kind title, icon, and
/// accent at resolution time from the entry's variant + the matched
/// section's `TextStyle` — the request stays content-agnostic.
public enum DetailRequest: Equatable, Sendable {
    case bodySection(targetID: String, sectionIndex: Int)

    /// The id used to look up the source entry / sub-entry.
    public var sourceEntryID: String {
        switch self {
        case .bodySection(let id, _):
            return id
        }
    }
}
