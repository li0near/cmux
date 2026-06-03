/// Body data for every `Entry`. The body is a list of sections; an empty
/// list means a header-only entry (Variant A — clickable link with no
/// inline content, e.g. `assistantText`, `prLink`).
///
/// Sections fall into two kinds:
/// - `.text(...)` — one or more inline text blocks rendered in a gray
///   background. The `style` discriminator drives per-section visual
///   treatment (italic for thinking, red for errors, future diff colors).
/// - `.subentries(...)` — nested children. The renderer policy decides
///   whether to render them inline (current behavior for `AgentTurn`) or
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
public enum Section: Equatable, Sendable {
    /// Inline text block(s) rendered in a gray background. The `style`
    /// drives per-section visual treatment (italic, error red, etc.).
    case text([String], style: TextStyle)
    /// Nested entries. Rendering policy is decided by the variant
    /// (inline for `AgentTurn`; link-to-detail for tool sidechains and
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
