/// Body data for every `Entry`. The body is a list of sections; an empty
/// list means a header-only entry (Variant A — clickable link with no
/// inline content, e.g. `assistantText`, `prLink`).
///
/// Sections cover inline rendering payloads only. Nested children
/// (sub-agent transcripts, abandoned-branch entries, agent turn
/// sub-entries) live on the entry's top-level `subEntries` field, not
/// in `body.sections`.
public struct Body: Equatable, Sendable {
    public let sections: [Section]

    public init(sections: [Section] = []) {
        self.sections = sections
    }

    /// Convenience: header-only body (no inline content).
    public static let empty = Body(sections: [])

    /// Convenience: single text section in the default style.
    public static func text(_ blocks: [String]) -> Body {
        Body(sections: [.text(blocks, style: .normal)])
    }
}

/// One section within an entry's body.
///
/// Pure rendering payloads. Container-shape data (nested children)
/// lives on the parent ``Entry``'s `subEntries` projection, not in a
/// section. Re-evaluate if a 5th rendering case becomes necessary.
public enum Section: Equatable, Sendable {
    /// Inline text block(s) rendered in a gray background. The `style`
    /// drives per-section visual treatment (italic, error red, etc.).
    /// Detail-tab rendering hint (markdown / json / code / diff) is
    /// **derived at resolve time** by the detail resolver — it is NOT
    /// stored on the Section. Inline rendering only ever uses `style`.
    case text([String], style: TextStyle)
    /// Inline image (user-pasted or tool-returned). Base64 lazy-decoded
    /// at render time. See ``ImageSource``.
    case image(ImageSource)
    /// A `tool_reference` block from CC's client-side `ToolSearch` deferred
    /// loader, naming a tool the model is being made aware of (e.g.
    /// `mcp__sap-jira__get_issue`). Carries just the bare tool name —
    /// the renderer parses any `mcp__<server>__` prefix at display time.
    case toolReference(toolName: String)
    /// Claude Code's `<persisted-output>` wrapper — a tool result that
    /// exceeded CC's inline size threshold and was offloaded to a file
    /// on disk. The renderer surfaces an "↗ Open offloaded result" link;
    /// the detail-tab resolver reads the file lazily on click.
    case offloadedOutput(OffloadedOutput)
}

/// Visual treatment applied to a `.text` section.
public enum TextStyle: Equatable, Sendable {
    /// Default: monospace, slightly dimmed primary color.
    case normal
    /// Italic, dim — used for the thinking sub-entry.
    case thinking
    /// Red foreground — used for tool error results.
    case error
    /// Green foreground — used for added lines in unified-diff
    /// rendering. Ships with Phase D's foundation; the detail-tab
    /// diff renderer (follow-up PR) consumes the style alongside
    /// ``ContentType/diff``.
    case diffAdded
    /// Red foreground — used for removed lines in unified-diff
    /// rendering.
    case diffRemoved
    /// Monospace foreground — used for code spans inside markdown
    /// or for a fully-monospaced code section (alongside
    /// ``ContentType/code(language:)``).
    case codeMonospace
}

// MARK: - Convenience accessors

extension Body {
    /// Concatenated text content from every `.text` section, joined
    /// by `"\n"`. Returns "" when the body is header-only.
    public var textContent: String {
        var parts: [String] = []
        for section in sections {
            if case .text(let blocks, _) = section {
                parts.append(contentsOf: blocks)
            }
        }
        return parts.joined(separator: "\n")
    }
}

