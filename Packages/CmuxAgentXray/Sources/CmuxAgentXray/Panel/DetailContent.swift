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
    /// ``contentType`` is `.plainText`.
    public let body: String
    /// Source entry id, kept for future cross-references / search.
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
    /// How the body should be rendered. ``ContentType/transcript`` is
    /// used for surfaces backed by `entries` (abandoned-branch and
    /// sub-agent transcripts); everything else is ``ContentType/plainText``.
    public let contentType: ContentType
    /// Optional entry transcript. When non-nil and `contentType` is
    /// ``ContentType/transcript``, the detail view renders these
    /// entries using the standard `EntryView` instead of the plain
    /// `body` text.
    public let entries: [Entry]?
    /// Image content carrier for image-bearing detail tabs. Non-nil
    /// only when the source section is `.image(ImageSource)` (user-
    /// pasted screenshot or a tool result that returned an image).
    /// When set, `body` is empty and the detail view routes to the
    /// host's `detailImageView(...)` instead of `detailBodyView(...)`.
    public let imageSource: ImageSource?
    /// Section index that produced ``imageSource``, used by the host
    /// adapter to deduplicate the temp-file path across detail-tab
    /// re-opens of the same image. Required whenever
    /// ``imageSource`` is non-nil.
    public let imageSectionIndex: Int?

    public init(
        title: String,
        subtitle: String? = nil,
        body: String,
        sourceEntryID: String,
        icon: EntryIcon,
        accent: PaletteRole,
        contentType: ContentType = .plainText,
        entries: [Entry]? = nil,
        imageSource: ImageSource? = nil,
        imageSectionIndex: Int? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sourceEntryID = sourceEntryID
        self.icon = icon
        self.accent = accent
        self.contentType = contentType
        self.entries = entries
        self.imageSource = imageSource
        self.imageSectionIndex = imageSectionIndex
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
    /// and content-type triple.
    private static func resolveTopLevel(
        _ entry: Entry,
        sectionIndex: Int,
        timestamp: String
    ) -> DetailContent? {
        switch entry {
        case .user(let user):
            // Image section click — the source body has a
            // `.image(ImageSource)` at this index. The detail tab
            // routes to the host's image renderer, so `body` is
            // empty and the carrier fields drive the UI.
            if sectionIndex >= 0,
               sectionIndex < user.body.sections.count,
               case .image(let img) = user.body.sections[sectionIndex] {
                return DetailContent(
                    title: localized(
                        "agentXray.detail.title.userImage",
                        defaultValue: "User-pasted image"
                    ),
                    subtitle: subtitleFromTimestamp(timestamp),
                    body: "",
                    sourceEntryID: user.id.stableString,
                    icon: EntryIcon.user,
                    accent: .blue,
                    imageSource: img,
                    imageSectionIndex: sectionIndex
                )
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
                body: body,
                sourceEntryID: user.id.stableString,
                icon: EntryIcon.user,
                accent: .blue
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
                icon: EntryIcon.system,
                // Match `EntryView.kindAccentColor`'s live-row mapping
                // for `.compact` (`palette.dim`). The pre-Phase-A code
                // mistakenly mapped to `.cyan` via the legacy
                // `Kind.systemOutput`; corrected here so live row +
                // detail header read identically.
                accent: .dim
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
                body: preview,
                sourceEntryID: rootUuid,
                icon: EntryIcon.branchLink,
                accent: .dim,
                contentType: transcript.isEmpty ? .plainText : .transcript,
                entries: transcript.isEmpty ? nil : transcript
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
                icon: EntryIcon.skill,
                accent: .cyan
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
                icon: EntryIcon.slashCommand,
                accent: .cyan
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
                icon: EntryIcon.slashCommand,
                accent: .cyan
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
                icon: EntryIcon.systemReminder,
                accent: .yellow
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
                icon: EntryIcon.recap,
                accent: .cyan
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
                icon: EntryIcon.system,
                accent: .cyan
            )
        }
    }

    /// Resolve a `.bodySection` request whose target is one of an
    /// agent turn's sub-entries (text or tool). The sub-entry kind +
    /// `sectionIndex` combine to pick the icon, accent, and
    /// content-type triple.
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
                icon: isThinking ? EntryIcon.thinking : EntryIcon.agent,
                accent: .claude
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
                    icon: EntryIcon.tool(named: "Task"),
                    accent: .primary,
                    contentType: .transcript,
                    entries: transcript
                )
            }
            // `.offloadedOutput` section — read the file lazily and
            // surface its full bytes in the detail tab. Phase C feature.
            if sectionIndex >= 0,
               sectionIndex < tool.body.sections.count,
               case .offloadedOutput(let off) = tool.body.sections[sectionIndex] {
                return resolveOffloadedOutput(off, tool: tool, timestamp: timestamp)
            }
            // `.image` section — tool returned an image
            // (e.g. Playwright `browser_take_screenshot`). The
            // detail tab routes to the host's image renderer.
            if sectionIndex >= 0,
               sectionIndex < tool.body.sections.count,
               case .image(let img) = tool.body.sections[sectionIndex] {
                return DetailContent(
                    title: localized(
                        "agentXray.detail.title.toolResult",
                        defaultValue: "Tool result · \(tool.toolName)"
                    ),
                    subtitle: subtitleFromTimestamp(timestamp),
                    body: "",
                    sourceEntryID: tool.id.stableString,
                    icon: EntryIcon.tool(named: tool.toolName),
                    accent: tool.status == .error ? .red : .primary,
                    imageSource: img,
                    imageSectionIndex: sectionIndex
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
                    icon: EntryIcon.tool(named: tool.toolName),
                    accent: .primary
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
                icon: EntryIcon.tool(named: tool.toolName),
                accent: tool.status == .error ? .red : .primary,
                // Phase E: shape-sniff the result text for rich
                // detail-tab rendering. Inline rendering ignores the
                // contentType — only the detail tab dispatches.
                contentType: DetailContentShapeSniffer.sniff(
                    text: text,
                    mcpServer: tool.mcpServer
                )
            )
        }
    }

    /// Read the offloaded file at `off.path` lazily and surface its
    /// full bytes in the detail tab. Falls back to a localized error
    /// message + the wrapper's preview (when available) if the file
    /// can't be read.
    ///
    /// **KNOWN LIMITATION (audited 2026-06-07):** `String(contentsOf:encoding:)`
    /// is synchronous. The corpus contains files up to ~1.2MB which is
    /// fast on modern hardware (a few ms) but can perceptibly jank the
    /// UI for very large outputs. Migrating to an async resolver would
    /// cascade through every `DetailContent.resolve(...)` caller; for
    /// now the read stays sync. Bounded by the offload size cap CC
    /// uses and the user's click rate (low frequency). Track in
    /// `MIGRATION_PLAN.md` §16 for a future async-resolver pass.
    private static func resolveOffloadedOutput(
        _ off: OffloadedOutput,
        tool: ToolEntry,
        timestamp: String
    ) -> DetailContent {
        let url = URL(fileURLWithPath: off.path)
        let body: String
        do {
            body = try String(contentsOf: url, encoding: .utf8)
        } catch {
            let template = localized(
                "agentXray.detail.offloadedOutput.readError",
                defaultValue: "Failed to read offloaded result at %1$@: %2$@"
            )
            let summary = String(format: template, off.path, "\(error.localizedDescription)")
            body = off.preview.map { "\(summary)\n\nPreview from transcript:\n\($0)" } ?? summary
        }
        return DetailContent(
            title: localized(
                "agentXray.detail.title.toolResult",
                defaultValue: "Tool result · \(tool.toolName)"
            ),
            subtitle: localized(
                "agentXray.detail.subtitle.offloadedOutput",
                defaultValue: "from \(timestamp) · offloaded \(off.sizeLabel)"
            ),
            body: body,
            sourceEntryID: tool.id.stableString,
            icon: EntryIcon.tool(named: tool.toolName),
            accent: tool.status == .error ? .red : .primary
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
