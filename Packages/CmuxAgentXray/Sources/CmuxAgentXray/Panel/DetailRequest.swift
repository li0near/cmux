/// A request to surface one entry's expandable content in a detail tab.
/// Emitted by the row view when the inline cap is exceeded; consumed by
/// `AgentXrayPanel.openDetail(request:)`, which resolves it against
/// the live transcript into a `DetailContent` and asks the host to open
/// a sibling tab.
///
/// Cases follow the panel's content surfaces; payloads carry the entry
/// id (and sub-entry id where required) needed to look up the entry in
/// the live stream. `textBlock` covers both thinking and assistant
/// text sub-entries (a single turn now contains multiple of either,
/// interleaved with tools).
public enum DetailRequest: Equatable, Sendable {
    case userPrompt(entryID: String)
    case textBlock(entryID: String, subEntryID: String)
    case systemOutput(entryID: String)
    case skillBody(entryID: String)
    case slashCommandBody(entryID: String)
    case systemReminderBody(entryID: String)
    case recapBody(entryID: String)

    /// Tool input expansion. `entryID` is the parent agent turn's id
    /// (so the panel can resolve the turn's `.tool` sub-entry by
    /// `toolEntryID` within it).
    case toolInput(entryID: String, toolEntryID: String)
    case toolResult(entryID: String, toolEntryID: String)
    case subagentTranscript(entryID: String, toolEntryID: String)

    /// Open the abandoned-branch transcript surface for the given
    /// branch root.
    case abandonedBranch(branchRootUuid: String)

    /// The id used to look up the source entry in the stream.
    public var sourceEntryID: String {
        switch self {
        case .userPrompt(let id),
             .systemOutput(let id),
             .skillBody(let id),
             .slashCommandBody(let id),
             .systemReminderBody(let id),
             .recapBody(let id):
            return id
        case .textBlock(let id, _):
            return id
        case .toolInput(let id, _),
             .toolResult(let id, _),
             .subagentTranscript(let id, _):
            return id
        case .abandonedBranch(let id):
            return id
        }
    }
}
