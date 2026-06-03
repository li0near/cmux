/// Static content shown by an `AgentXrayPanel` when its `mode` is
/// `.detail(content:)`. Created by the live panel when a row's
/// `↗ Open detail` link is clicked because an expandable section
/// overflowed the inline cap.
///
/// The detail panel reuses the live panel's renderer (palette, badges,
/// layout) in `.fullDetail` mode so users get a consistent look — it's
/// the *same* panel kind, just frozen on one entry's expanded slice.
///
/// Phase 10 fleshes out the resolver from `DetailRequest` to
/// `DetailContent`. This phase carries enough state that the panel
/// can compile and the host protocol can refer to it.
public struct DetailContent: Equatable, Sendable {
    /// Title shown in the tab bar and detail header
    /// (e.g. "Tool result · Read /foo.ts").
    public let title: String
    /// Optional subtitle
    /// (e.g. "from chunk at 14:23:01 · 1.2k lines").
    public let subtitle: String?
    /// Full unfolded body text — rendered without truncation when
    /// `entries` is nil.
    public let body: String
    /// Source entry id, kept for future cross-references / search.
    public let sourceEntryID: String
    /// Discriminator for styling (color of the title accent, glyph).
    public let kind: Kind
    /// Optional entry transcript. When non-nil, the detail view
    /// renders these entries using the standard `EntryView` instead of
    /// the plain `body` text. Used for abandoned-branch and sub-agent
    /// transcript surfaces.
    public let entries: [Entry]?

    public init(
        title: String,
        subtitle: String? = nil,
        body: String,
        sourceEntryID: String,
        kind: Kind,
        entries: [Entry]? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sourceEntryID = sourceEntryID
        self.kind = kind
        self.entries = entries
    }

    /// Closed enumeration over the surfaces a detail tab can render.
    public enum Kind: Equatable, Sendable {
        case userPrompt
        case thinking
        case systemOutput
        case toolInput(toolName: String)
        case toolResult(toolName: String, isError: Bool)
        case assistantResponse
        case abandonedBranch(rewindIndex: Int, totalRewinds: Int)
        case subagentTranscript(toolName: String, subagentType: String?)
        case skillBody(skillName: String)
        case slashCommandBody(commandName: String)
        case systemReminderBody
        case recapBody
    }
}
