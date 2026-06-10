/// Single source of truth for "what does an entry's expansion show?"
///
/// The unified ``EntryView`` dispatches on this enum when the row is
/// expanded:
///
/// - ``children`` — the expansion shows a `LazyVStack` of child Entries
///   that recurse through the same renderer. The renderer wraps the
///   list with the expansion-gutter overlay.
/// - ``body`` — the expansion shows leaf body sections (text / image /
///   code / tool reference / offloaded link). No gutter.
/// - ``none`` — header-only row; nothing expands.
public enum ExpansionShape: Sendable {
    case children([Entry])
    case body(Body)
    case none
}

extension Entry {
    /// What this entry shows when expanded. Bodies that contain no
    /// sections collapse to ``ExpansionShape/none`` so the renderer
    /// doesn't draw an empty box.
    public var expansionShape: ExpansionShape {
        switch self {
        case .agent(let a):
            return a.subEntries.isEmpty ? .none : .children(a.subEntries)
        case .synthesized(let s):
            switch s.kind {
            case .rewind:
                return s.subEntries.isEmpty ? .none : .children(s.subEntries)
            case .prLink:
                // Body confirmed empty per SynthesizedEntry doc — header-only.
                return .none
            }
        case .tool(let t):
            return t.body.sections.isEmpty ? .none : .body(t.body)
        case .text(let t):
            return t.body.sections.isEmpty ? .none : .body(t.body)
        case .user, .system, .compact:
            return body.sections.isEmpty ? .none : .body(body)
        }
    }
}
