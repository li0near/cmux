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
    /// request can't be resolved (target id miss, missing section).
    /// `targetID` may identify either the top-level entry itself or
    /// one of its agent-turn sub-entries; the resolver classifies
    /// per-kind from the matched entry's variant + section index.
    public static func resolve(
        request: DetailRequest,
        entry: Entry
    ) -> DetailContent? {
        let timestamp = formatTimestamp(entry.timestamp)
        switch request {
        case .bodySection(let targetID, let sectionIndex):
            // Top-level entry — addressable by its own id.
            if entry.id.stableString == targetID {
                return resolveTopLevel(
                    entry,
                    sectionIndex: sectionIndex,
                    timestamp: timestamp
                )
            }
            // Agent sub-entry — addressable by its derived id.
            if case .agent(let turn) = entry {
                for sub in turn.subEntries where sub.id.stableString == targetID {
                    return resolveSubEntry(
                        sub,
                        sectionIndex: sectionIndex,
                        timestamp: timestamp
                    )
                }
            }
            return nil
        }
    }

    /// Resolve a `.bodySection` request whose target is a top-level
    /// `Entry`. The variant + section combine to pick the
    /// `DetailContent.Kind`.
    private static func resolveTopLevel(
        _ entry: Entry,
        sectionIndex: Int,
        timestamp: String
    ) -> DetailContent? {
        switch entry {
        case .user(let user):
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
                sourceEntryID: user.id.stableString,
                kind: .userPrompt
            )

        case .system(let sys):
            return resolveSystem(sys, timestamp: timestamp)

        case .compact(let c):
            let body = c.body.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.systemOutput",
                    defaultValue: "System output"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: body,
                sourceEntryID: c.id.stableString,
                kind: .systemOutput
            )

        case .synthesized(let s):
            guard case .branchLink(
                let rootUuid,
                let rewindIndex,
                let totalRewinds,
                let entryCount,
                let firstPromptPreview
            ) = s.kind else { return nil }
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
                sourceEntryID: rootUuid,
                kind: .abandonedBranch(
                    rewindIndex: rewindIndex,
                    totalRewinds: totalRewinds
                ),
                entries: s.body.subentriesContent.isEmpty ? nil : s.body.subentriesContent
            )

        case .agent:
            // AgentEntry's body is `.subentries(...)` only — its
            // detail is reached via individual sub-entries, not a
            // top-level open.
            return nil
        }
    }

    private static func resolveSystem(
        _ sys: SystemEntry,
        timestamp: String
    ) -> DetailContent? {
        let id = sys.id.stableString
        switch sys.subType {
        case .skill(let name, let basePath):
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.skill",
                    defaultValue: "Skill · \(name)"
                ),
                subtitle: localized(
                    "agentXray.detail.subtitle.skill",
                    defaultValue: "from \(timestamp) · \(basePath ?? "")"
                ),
                body: sys.body.textContent,
                sourceEntryID: id,
                kind: .skillBody(skillName: name)
            )
        case .slashCmdInput(let name, let args):
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
        case .slashCmdOutput:
            let body = sys.body.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.slashCommand",
                    defaultValue: "Slash command output"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: body,
                sourceEntryID: id,
                kind: .slashCommandBody(commandName: "")
            )
        case .systemReminder:
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.systemReminder",
                    defaultValue: "System reminder"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: sys.body.textContent,
                sourceEntryID: id,
                kind: .systemReminderBody
            )
        case .recap:
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.recap",
                    defaultValue: "Recap"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: sys.body.textContent,
                sourceEntryID: id,
                kind: .recapBody
            )
        case .localCommand, .contextUsage, .planMode, .editedTextFile, .other:
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
        }
    }

    /// Resolve a `.bodySection` request whose target is one of an
    /// agent turn's sub-entries (text or tool). The sub-entry kind +
    /// `sectionIndex` combine to pick the `DetailContent.Kind`.
    private static func resolveSubEntry(
        _ sub: AgentEntry.SubEntry,
        sectionIndex: Int,
        timestamp: String
    ) -> DetailContent? {
        switch sub {
        case .text(let text):
            let body = text.body.textContent
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let isThinking = text.kind == .thinking
            return DetailContent(
                title: localized(
                    isThinking ? "agentXray.detail.title.thinking" : "agentXray.detail.title.assistantResponse",
                    defaultValue: isThinking ? "Thinking" : "Assistant response"
                ),
                subtitle: subtitleLines(timestamp, lineCount: lineCount(body)),
                body: body,
                sourceEntryID: text.id.stableString,
                kind: isThinking ? .thinking : .assistantResponse
            )

        case .tool(let tool):
            // Section 0 = input, 1 = result text, 2+ = sub-agent
            // transcript (`.subentries`).
            if sectionIndex == 2 || (sectionIndex == 1 && tool.body.sections.count >= 3) {
                guard let transcript = tool.sidechainTranscript,
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
                    sourceEntryID: tool.id.stableString,
                    kind: .subagentTranscript(
                        toolName: tool.toolName,
                        subagentType: tool.subagentType
                    ),
                    entries: transcript
                )
            }
            guard let text = sectionText(tool.body, index: sectionIndex) else { return nil }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if sectionIndex == 0 {
                return DetailContent(
                    title: localized(
                        "agentXray.detail.title.toolInput",
                        defaultValue: "Tool input · \(tool.toolName)"
                    ),
                    subtitle: subtitleFromTimestamp(timestamp),
                    body: text,
                    sourceEntryID: tool.id.stableString,
                    kind: .toolInput(toolName: tool.toolName)
                )
            }
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.toolResult",
                    defaultValue: "Tool result · \(tool.toolName)"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                body: text,
                sourceEntryID: tool.id.stableString,
                kind: .toolResult(
                    toolName: tool.toolName,
                    isError: tool.status == .error
                )
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

    /// Concatenated text of a `Body`'s `.text` section at `index`,
    /// joined by `\n`. Returns nil if the section doesn't exist or
    /// isn't a text section.
    private static func sectionText(_ body: Body, index: Int) -> String? {
        guard index >= 0, index < body.sections.count,
              case .text(let blocks, _) = body.sections[index] else { return nil }
        return blocks.joined(separator: "\n")
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
