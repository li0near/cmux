import Foundation

/// Static content shown by an `AgentXrayPanel` when its `mode` is
/// `.detail(content:)`. Created by the live panel when a row's
/// `↗ Open detail` link is clicked because an expandable section
/// overflowed the inline cap.
///
/// The detail panel reuses the live panel's renderer (palette, badges,
/// layout) in `.fullDetail` mode so users get a consistent look — it's
/// the *same* panel kind, just frozen on one entry's expanded slice.
public struct DetailContent: Equatable, Sendable {
    /// Title shown in the tab bar and detail header
    /// (e.g. "Tool result · Read /foo.ts").
    public let title: String
    /// Optional subtitle
    /// (e.g. "from entry at 14:23:01 · 1.2k lines").
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

// MARK: - Resolver

extension DetailContent {

    /// Build a `DetailContent` from a `DetailRequest` and the source
    /// `Entry` looked up in the live transcript. Returns nil when the
    /// request can't be resolved (entry-variant mismatch, missing tool
    /// id, empty content slice).
    public static func resolve(
        request: DetailRequest,
        entry: Entry
    ) -> DetailContent? {
        let timestamp = formatTimestamp(entry.timestamp)
        switch request {
        case .userPrompt(let id):
            guard case .user(let user) = entry, user.id.stableString == id else { return nil }
            let body = user.body.textContent
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.userPrompt",
                    defaultValue: "User prompt"
                ),
                subtitle: localized(
                    "agentXray.detail.subtitle.userPrompt",
                    defaultValue: "from \(timestamp) · \(body.count) chars"
                ),
                body: body,
                sourceEntryID: id,
                kind: .userPrompt
            )

        case .thinking(let id, let subEntryID):
            guard case .agent(let turn) = entry, turn.id.stableString == id else { return nil }
            var thinkingBody: String?
            for sub in turn.subEntries {
                if case .thinking(let t) = sub, t.id.stableString == subEntryID {
                    thinkingBody = t.body.textContent
                    break
                }
            }
            guard let body = thinkingBody else { return nil }
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.thinking",
                    defaultValue: "Thinking"
                ),
                subtitle: subtitleLines(timestamp, lineCount: lineCount(body)),
                body: body,
                sourceEntryID: id,
                kind: .thinking
            )

        case .systemOutput(let id):
            guard case .system(let sys) = entry, sys.id.stableString == id else { return nil }
            let body = sys.body.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.systemOutput",
                    defaultValue: "System output"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: body,
                sourceEntryID: id,
                kind: .systemOutput
            )

        case .toolInput(let entryID, let toolID):
            guard case .agent(let turn) = entry,
                  turn.id.stableString == entryID,
                  let tool = turn.subEntries.toolEntry(withID: toolID),
                  let inputDetail = tool.inputDetail else { return nil }
            guard !inputDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.toolInput",
                    defaultValue: "Tool input · \(tool.toolName)"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: inputDetail,
                sourceEntryID: entryID,
                kind: .toolInput(toolName: tool.toolName)
            )

        case .toolResult(let entryID, let toolID):
            guard case .agent(let turn) = entry,
                  turn.id.stableString == entryID,
                  let tool = turn.subEntries.toolEntry(withID: toolID),
                  let resultDetail = tool.resultDetail else { return nil }
            guard !resultDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.toolResult",
                    defaultValue: "Tool result · \(tool.toolName)"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: resultDetail,
                sourceEntryID: entryID,
                kind: .toolResult(
                    toolName: tool.toolName,
                    isError: tool.status == .error
                )
            )

        case .assistantResponse(let id, let subEntryID):
            guard case .agent(let turn) = entry, turn.id.stableString == id else { return nil }
            var assistantBody: String?
            for sub in turn.subEntries {
                if case .assistantText(let a) = sub, a.id.stableString == subEntryID {
                    assistantBody = a.body.textContent
                    break
                }
            }
            guard let body = assistantBody else { return nil }
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.assistantResponse",
                    defaultValue: "Assistant response"
                ),
                subtitle: subtitleLines(timestamp, lineCount: lineCount(body)),
                body: body,
                sourceEntryID: id,
                kind: .assistantResponse
            )

        case .abandonedBranch(let branchRootUuid):
            guard case .synthesized(let s) = entry,
                  case .branchLink(
                    let rootUuid,
                    let rewindIndex,
                    let totalRewinds,
                    let entryCount,
                    let firstPromptPreview
                  ) = s.kind,
                  rootUuid == branchRootUuid else { return nil }
            let preview = firstPromptPreview ?? localized(
                "agentXray.detail.body.noPromptPreview",
                defaultValue: "(no prompt preview)"
            )
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.abandonedBranch",
                    defaultValue: "Abandoned branch — rewind \(rewindIndex) of \(totalRewinds)"
                ),
                subtitle: localized(
                    "agentXray.detail.subtitle.abandonedBranch",
                    defaultValue: "\(entryCount) entries · diverged at \(timestamp)"
                ),
                body: preview,
                sourceEntryID: branchRootUuid,
                kind: .abandonedBranch(
                    rewindIndex: rewindIndex,
                    totalRewinds: totalRewinds
                ),
                entries: s.body.subentriesContent.isEmpty ? nil : s.body.subentriesContent
            )

        case .subagentTranscript(let entryID, let toolID):
            guard case .agent(let turn) = entry,
                  turn.id.stableString == entryID,
                  let tool = turn.subEntries.toolEntry(withID: toolID),
                  let transcript = tool.sidechainTranscript,
                  !transcript.isEmpty else { return nil }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.subagentTranscript",
                    defaultValue: "Sub-agent transcript · \(tool.toolName)"
                ),
                subtitle: localized(
                    "agentXray.detail.subtitle.subagentTranscript",
                    defaultValue: "from \(timestamp) · \(transcript.count) entries"
                ),
                body: "",
                sourceEntryID: entryID,
                kind: .subagentTranscript(
                    toolName: tool.toolName,
                    subagentType: tool.subagentType
                ),
                entries: transcript
            )

        case .skillBody(let id):
            guard case .system(let sys) = entry,
                  sys.id.stableString == id,
                  case .skill(let name, let basePath) = sys.subType else { return nil }
            let body = sys.body.textContent
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.skill",
                    defaultValue: "Skill · \(name)"
                ),
                subtitle: localized(
                    "agentXray.detail.subtitle.skill",
                    defaultValue: "from \(timestamp) · \(basePath ?? "")"
                ),
                body: body,
                sourceEntryID: id,
                kind: .skillBody(skillName: name)
            )

        case .slashCommandBody(let id):
            guard case .system(let sys) = entry,
                  sys.id.stableString == id,
                  case .slashCmdInput(let name, let args) = sys.subType else { return nil }
            let body = args ?? ""
            guard !body.isEmpty else { return nil }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.slashCommand",
                    defaultValue: "Slash command · /\(name)"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: body,
                sourceEntryID: id,
                kind: .slashCommandBody(commandName: name)
            )

        case .systemReminderBody(let id):
            guard case .system(let sys) = entry,
                  sys.id.stableString == id,
                  case .systemReminder = sys.subType else { return nil }
            let body = sys.body.textContent
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.systemReminder",
                    defaultValue: "System reminder"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: body,
                sourceEntryID: id,
                kind: .systemReminderBody
            )

        case .recapBody(let id):
            guard case .system(let sys) = entry,
                  sys.id.stableString == id,
                  case .recap = sys.subType else { return nil }
            let body = sys.body.textContent
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.recap",
                    defaultValue: "Recap"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: body,
                sourceEntryID: id,
                kind: .recapBody
            )
        }
    }

    // MARK: - Resolver helpers

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func formatTimestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return timestampFormatter.string(from: date)
    }

    private static func lineCount(_ s: String) -> Int {
        s.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Subtitle template `"from HH:mm:ss"`.
    private static func subtitleFromTimestamp(_ ts: String) -> String {
        localized(
            "agentXray.detail.subtitle.fromTimestamp",
            defaultValue: "from \(ts)"
        )
    }

    /// Subtitle template `"from HH:mm:ss · N lines"`.
    private static func subtitleLines(_ ts: String, lineCount: Int) -> String {
        localized(
            "agentXray.detail.subtitle.linesFromTimestamp",
            defaultValue: "from \(ts) · \(lineCount) lines"
        )
    }

    /// Wrapper around `String(localized:defaultValue:bundle:)` so the
    /// resolver doesn't repeat `bundle: .module` at every call site.
    /// `key` is a `StaticString` so the call site looks like a plain
    /// string literal — same shape as direct `String(localized:)` usage.
    private static func localized(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }
}

// MARK: - Tool sub-entry lookup

extension Array where Element == AgentEntry.SubEntry {
    /// Find the `.tool(...)` sub-entry whose id matches `toolID`.
    public func toolEntry(withID toolID: String) -> ToolEntry? {
        for sub in self {
            if case .tool(let t) = sub, t.id.stableString == toolID {
                return t
            }
        }
        return nil
    }
}
