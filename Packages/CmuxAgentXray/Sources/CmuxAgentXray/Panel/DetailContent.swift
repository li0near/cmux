import Foundation

/// Static content shown by an `AgentXrayPanel` when its `mode` is
/// `.detail(content:)`. Created by the live panel when a row's
/// `↗ Open detail` link is clicked because an expandable section
/// overflowed the inline cap.
///
/// Phase F reshape: the content payload now lives in a single
/// discriminated `source: DetailSource` field instead of the prior
/// mix of `body` / `entries` / `existingFilePath` / `contentType`
/// fields. The host conformance switches on `DetailSource` directly
/// — file paths open via cmux's panel pipeline, inline text /
/// image content materializes to a temp file with the suggested
/// basename (extension drives cmux dispatch), and transcripts keep
/// in-package rendering.
public struct DetailContent: Equatable, Sendable {
    /// Title shown in the tab bar and detail header
    /// (e.g. "Tool result · Read /foo.ts").
    public let title: String
    /// Optional subtitle
    /// (e.g. "from entry at 14:23:01 · 1.2k lines").
    public let subtitle: String?
    /// Source entry id — kept for cross-references / search and for
    /// the host's per-row materialization cache key.
    public let sourceEntryID: String
    /// Leading glyph in the detail-mode header. Resolver picks the
    /// canonical ``EntryIcon`` for the source variant; the view reads
    /// `icon.collapsed` (detail header is always in collapsed-icon
    /// state).
    public let icon: EntryIcon
    /// Accent color for the leading glyph. Carried as a semantic role
    /// so DetailContent stays SwiftUI-free; the view resolves via
    /// `HudPalette.color(for:)`.
    public let accent: PaletteRole
    /// Discriminated payload — file / text / image / transcript.
    public let source: DetailSource

    public init(
        title: String,
        subtitle: String? = nil,
        sourceEntryID: String,
        icon: EntryIcon,
        accent: PaletteRole,
        source: DetailSource
    ) {
        self.title = title
        self.subtitle = subtitle
        self.sourceEntryID = sourceEntryID
        self.icon = icon
        self.accent = accent
        self.source = source
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
    /// `Entry`. The variant + section combine to pick the icon, accent,
    /// and source triple.
    private static func resolveTopLevel(
        _ entry: Entry,
        sectionIndex: Int,
        timestamp: String
    ) -> DetailContent? {
        switch entry {
        case .user(let user):
            // Image-only message: text body is empty but the user
            // pasted an image. Open the image directly instead of
            // returning nil (Phase F fix — the prior resolver bailed
            // here, so user-paste images couldn't reach a detail tab
            // through the normal click flow).
            if let imageSource = firstImageSection(user.body) {
                let body = user.body.textContent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty {
                    let filename = imageSuggestedFilename(
                        for: imageSource,
                        prefix: "image"
                    )
                    return DetailContent(
                        title: localized(
                            "agentXray.detail.title.userImage",
                            defaultValue: "User image"
                        ),
                        subtitle: subtitleFromTimestamp(timestamp),
                        sourceEntryID: user.id.stableString,
                        icon: EntryIcon.user,
                        accent: .blue,
                        source: .image(imageSource, suggestedFilename: filename)
                    )
                }
            }
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
                sourceEntryID: user.id.stableString,
                icon: EntryIcon.user,
                accent: .blue,
                source: .text(body: body, suggestedFilename: "prompt.txt")
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
                sourceEntryID: c.id.stableString,
                icon: EntryIcon.system,
                // Match `EntryView.kindAccentColor`'s live-row mapping
                // for `.compact` (`palette.dim`).
                accent: .dim,
                source: .text(body: body, suggestedFilename: "system-output.txt")
            )

        case .synthesized(let s):
            guard case .branchLink(
                let rootUuid,
                let rewindIndex,
                let totalRewinds,
                let entryCount,
                _
            ) = s.kind else { return nil }
            let transcript = s.body.subentriesContent
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.abandonedBranch",
                    defaultValue: "Abandoned branch — rewind \(rewindIndex) of \(totalRewinds)"
                ),
                subtitle: localized(
                    "agentXray.detail.subtitle.abandonedBranch",
                    defaultValue: "\(entryCount) entries · diverged at \(timestamp)"
                ),
                sourceEntryID: rootUuid,
                icon: EntryIcon.branchLink,
                accent: .dim,
                source: .transcript(sourceEntryID: rootUuid, entries: transcript)
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
                sourceEntryID: id,
                icon: EntryIcon.skill,
                accent: .cyan,
                source: .text(
                    body: sys.body.textContent,
                    suggestedFilename: "skill.md"
                )
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
                sourceEntryID: id,
                icon: EntryIcon.slashCommand,
                accent: .cyan,
                source: .text(body: body, suggestedFilename: "slash-command.txt")
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
                sourceEntryID: id,
                icon: EntryIcon.slashCommand,
                accent: .cyan,
                source: .text(body: body, suggestedFilename: "slash-output.txt")
            )
        case .systemReminder:
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.systemReminder",
                    defaultValue: "System reminder"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                sourceEntryID: id,
                icon: EntryIcon.systemReminder,
                accent: .yellow,
                source: .text(
                    body: sys.body.textContent,
                    suggestedFilename: "system-reminder.md"
                )
            )
        case .recap:
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.recap",
                    defaultValue: "Recap"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                sourceEntryID: id,
                icon: EntryIcon.recap,
                accent: .cyan,
                source: .text(
                    body: sys.body.textContent,
                    suggestedFilename: "recap.md"
                )
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
                sourceEntryID: id,
                icon: EntryIcon.system,
                accent: .cyan,
                source: .text(body: body, suggestedFilename: "system-output.txt")
            )
        }
    }

    /// Resolve a `.bodySection` request whose target is one of an
    /// agent turn's sub-entries (text or tool). The sub-entry kind +
    /// `sectionIndex` combine to pick the icon, accent, and source
    /// triple.
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
            let filename = isThinking ? "thinking.md" : "response.md"
            return DetailContent(
                title: localized(
                    isThinking ? "agentXray.detail.title.thinking" : "agentXray.detail.title.assistantResponse",
                    defaultValue: isThinking ? "Thinking" : "Assistant response"
                ),
                subtitle: subtitleLines(timestamp, lineCount: lineCount(body)),
                sourceEntryID: text.id.stableString,
                icon: isThinking ? EntryIcon.thinking : EntryIcon.agent,
                accent: .claude,
                source: .text(body: body, suggestedFilename: filename)
            )

        case .tool(let tool):
            return resolveToolSection(
                tool: tool,
                sectionIndex: sectionIndex,
                timestamp: timestamp
            )
        }
    }

    private static func resolveToolSection(
        tool: ToolEntry,
        sectionIndex: Int,
        timestamp: String
    ) -> DetailContent? {
        // Sub-agent transcript opens — sectionIndex 2 (or 1 when the
        // tool also has a result section) addresses the trailing
        // `.subentries` section in `body.sections`.
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
                sourceEntryID: tool.id.stableString,
                icon: EntryIcon.tool(named: "Task"),
                accent: .primary,
                source: .transcript(
                    sourceEntryID: tool.id.stableString,
                    entries: transcript
                )
            )
        }
        // Section-shape branches.
        guard sectionIndex >= 0,
              sectionIndex < tool.body.sections.count else { return nil }
        let section = tool.body.sections[sectionIndex]

        // Offloaded `<persisted-output>` — host opens the on-disk
        // file directly via `openFileInPanel`.
        if case .offloadedOutput(let off) = section {
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.toolResult",
                    defaultValue: "Tool result · \(tool.toolName)"
                ),
                subtitle: localized(
                    "agentXray.detail.subtitle.offloadedOutput",
                    defaultValue: "from \(timestamp) · offloaded \(off.sizeLabel)"
                ),
                sourceEntryID: tool.id.stableString,
                icon: EntryIcon.tool(named: tool.toolName),
                accent: tool.status == .error ? .red : .primary,
                source: .file(path: off.path)
            )
        }

        // Tool-returned image (e.g. Playwright screenshot).
        if case .image(let imageSource) = section {
            let filename = imageSuggestedFilename(
                for: imageSource,
                prefix: "screenshot"
            )
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.toolResult",
                    defaultValue: "Tool result · \(tool.toolName)"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                sourceEntryID: tool.id.stableString,
                icon: EntryIcon.tool(named: tool.toolName),
                accent: tool.status == .error ? .red : .primary,
                source: .image(imageSource, suggestedFilename: filename)
            )
        }

        // Diff-styled section (Edit / MultiEdit input). Concatenate
        // every diff-styled section in the body into a unified diff
        // so the detail tab opens with a single full-context view.
        if case .text(_, let style) = section,
           style == .diffAdded || style == .diffRemoved,
           let diffBody = synthesizeUnifiedDiff(from: tool.body) {
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.toolInput",
                    defaultValue: "Tool input · \(tool.toolName)"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                sourceEntryID: tool.id.stableString,
                icon: EntryIcon.tool(named: tool.toolName),
                accent: .primary,
                source: .text(body: diffBody, suggestedFilename: "tool-input.diff")
            )
        }

        // Plain-text section.
        guard case .text(let blocks, _) = section else { return nil }
        let text = blocks.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Tool input section — sectionIndex 0 for non-Edit tools.
        if sectionIndex == 0 {
            return DetailContent(
                title: localized(
                    "agentXray.detail.title.toolInput",
                    defaultValue: "Tool input · \(tool.toolName)"
                ),
                subtitle: subtitleFromTimestamp(timestamp),
                sourceEntryID: tool.id.stableString,
                icon: EntryIcon.tool(named: tool.toolName),
                accent: .primary,
                source: .text(body: text, suggestedFilename: "tool-input.json")
            )
        }

        // Tool result. With a known `inputFilePath`, the suggested
        // basename is the file's basename so cmux's panel pipeline
        // dispatches to the right syntax mode by extension. Otherwise
        // sniff the content shape and pick a `tool-result.<ext>`
        // filename; plain text gets wrapped in a fenced code block
        // and surfaced as `.md` so cmux's markdown renderer paints
        // it with monospace + copy/edit chrome.
        let icon = EntryIcon.tool(named: tool.toolName)
        let accent: PaletteRole = tool.status == .error ? .red : .primary
        let title = localized(
            "agentXray.detail.title.toolResult",
            defaultValue: "Tool result · \(tool.toolName)"
        )
        let subtitle = subtitleFromTimestamp(timestamp)
        if let path = tool.inputFilePath {
            let basename = (path as NSString).lastPathComponent
            return DetailContent(
                title: title,
                subtitle: subtitle,
                sourceEntryID: tool.id.stableString,
                icon: icon,
                accent: accent,
                source: .text(body: text, suggestedFilename: basename)
            )
        }
        let filename = suggestedFilenameForToolResult(
            text: text,
            mcpServer: tool.mcpServer
        )
        let suggestedBody = filename.wrapAsFencedMarkdown
            ? wrapAsFencedMarkdown(text)
            : text
        return DetailContent(
            title: title,
            subtitle: subtitle,
            sourceEntryID: tool.id.stableString,
            icon: icon,
            accent: accent,
            source: .text(body: suggestedBody, suggestedFilename: filename.name)
        )
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

    private static func localized(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }

    /// Walk every `.text(_, .diffAdded/.diffRemoved)` section in
    /// arrival order and build a unified-diff-shaped string — `-`
    /// prefix for removed lines, `+` for added. Returns nil when no
    /// diff sections are present (caller falls through to the
    /// plain-text resolution path).
    private static func synthesizeUnifiedDiff(from body: Body) -> String? {
        var lines: [String] = []
        var sawAny = false
        for section in body.sections {
            guard case .text(let blocks, let style) = section else { continue }
            let prefix: String
            switch style {
            case .diffRemoved: prefix = "-"
            case .diffAdded:   prefix = "+"
            default: continue
            }
            sawAny = true
            for block in blocks {
                for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("\(prefix)\(line)")
                }
            }
        }
        return sawAny ? lines.joined(separator: "\n") : nil
    }

    /// First `.image` section in a body, if any. Used by the user
    /// image-only message arm.
    private static func firstImageSection(_ body: Body) -> ImageSource? {
        for section in body.sections {
            if case .image(let source) = section { return source }
        }
        return nil
    }

    /// Map an ``ImageSource``'s media type to a
    /// `<prefix>.<ext>` filename suggestion. Cmux's
    /// `Workspace.openFileSurfaces` dispatches by extension to
    /// `FilePreviewPanel`'s image preview.
    private static func imageSuggestedFilename(
        for source: ImageSource,
        prefix: String
    ) -> String {
        let ext: String
        switch source.mediaType.lowercased() {
        case "image/png":      ext = "png"
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/gif":      ext = "gif"
        case "image/webp":     ext = "webp"
        case "image/heic":     ext = "heic"
        case "image/svg+xml":  ext = "svg"
        default:               ext = "bin"
        }
        return "\(prefix).\(ext)"
    }

    /// Sniff the result text's shape (markdown / json / diff /
    /// plaintext) and return the basename to use plus whether the
    /// body should be wrapped in a fenced code block before being
    /// written as markdown.
    private static func suggestedFilenameForToolResult(
        text: String,
        mcpServer: String?
    ) -> (name: String, wrapAsFencedMarkdown: Bool) {
        let shape = DetailContentShapeSniffer.sniff(text: text, mcpServer: mcpServer)
        switch shape {
        case .markdown:  return ("tool-result.md", false)
        case .json:      return ("tool-result.json", false)
        case .diff:      return ("tool-result.diff", false)
        case .plainText: return ("tool-result.md", true)
        case .transcript, .code:
            // Sniffer doesn't currently return these; defensive
            // fallback keeps the panel pipeline picking a known
            // extension.
            return ("tool-result.md", true)
        }
    }

    /// Wrap a plain-text body in a triple-backtick fenced code block
    /// so the markdown renderer paints it as a monospace block with
    /// copy/edit chrome.
    private static func wrapAsFencedMarkdown(_ body: String) -> String {
        "```\n\(body)\n```"
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
