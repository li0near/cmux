/// Body data for every `Entry`. The body is a list of sections; an empty
/// list means a header-only entry (Variant A — clickable link with no
/// inline content, e.g. `assistantText`, `prLink`).
///
/// Sections fall into two kinds:
/// - `.text(...)` — one or more inline text blocks rendered in a gray
///   background. The `style` discriminator drives per-section visual
///   treatment (italic for thinking, red for errors, future diff colors).
/// - `.subentries(...)` — nested children. The renderer policy decides
///   whether to render them inline (current behavior for `AgentEntry`) or
///   as a single "open detail" link (current behavior for tool sidechains
///   and abandoned-branch link). The data shape is the same in both
///   cases.
///
/// `Body` is a recursive type via `Section.subentries([Entry])` — Swift
/// resolves the cycle within the module, no `indirect` keyword needed
/// because the recursion goes through `Array<Entry>` (a reference-sized
/// box).
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
/// Variants are intentionally a flat enum (5 cases by end of Phase C —
/// `.text`, `.image`, `.toolReference`, `.subentries`, `.offloadedOutput`)
/// rather than an indirected typed-payload struct. Every consumer is
/// already a switch; lifting to a struct would force a rewrite of each
/// site without buying back type safety. Re-evaluate if a 6th case
/// becomes necessary.
public enum Section: Equatable, Sendable {
    /// Inline text block(s) rendered in a gray background. The `style`
    /// drives per-section visual treatment (italic, error red, etc.).
    case text([String], style: TextStyle)
    /// Inline image (user-pasted or tool-returned). Base64 lazy-decoded
    /// at render time. See ``ImageSource``.
    case image(ImageSource)
    /// A `tool_reference` block from CC's client-side `ToolSearch` deferred
    /// loader, naming a tool the model is being made aware of (e.g.
    /// `mcp__sap-jira__get_issue`). Carries just the bare tool name —
    /// the renderer parses any `mcp__<server>__` prefix at display time.
    case toolReference(toolName: String)
    /// Nested entries. Rendering policy is decided by the variant
    /// (inline for `AgentEntry`; link-to-detail for tool sidechains and
    /// abandoned-branch synthesizer rows).
    case subentries([Entry])
}

/// Visual treatment applied to a `.text` section.
public enum TextStyle: Equatable, Sendable {
    /// Default: monospace, slightly dimmed primary color.
    case normal
    /// Italic, dim — used for the thinking sub-entry.
    case thinking
    /// Red foreground — used for tool error results.
    case error
    // Future cases (deferred until corresponding feature lands; tracked
    // in plan §16): diffAdded, diffRemoved, codeMonospace.
}

// MARK: - Convenience accessors

extension Body {
    /// Concatenated text content from every `.text` section, joined
    /// by `"\n"`. Sub-entry sections are not traversed (use
    /// `subentriesContent` for that). Returns "" when the body is
    /// header-only or contains only sub-entries.
    public var textContent: String {
        var parts: [String] = []
        for section in sections {
            if case .text(let blocks, _) = section {
                parts.append(contentsOf: blocks)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// First `.subentries` section's children, or `[]` if none.
    public var subentriesContent: [Entry] {
        for section in sections {
            if case .subentries(let entries) = section {
                return entries
            }
        }
        return []
    }
}
