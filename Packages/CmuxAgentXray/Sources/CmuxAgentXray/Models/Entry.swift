public import Foundation

/// Umbrella enum for every transcript item — a `Transcript` is a
/// `[Entry]`. Seven cases:
///
/// - `.user` — user-authored prompt.
/// - `.agent` — one assistant turn (top-level container variant).
/// - `.system` — JSONL `type: "system"` line in any of its subtypes.
/// - `.compact` — `type: "summary"` compact event.
/// - `.synthesized` — cmux-invented row (branch link, PR link).
/// - `.text` — assistant thinking / text sub-entry. Appears ONLY inside
///   ``AgentEntry/subEntries`` (and recursively inside abandoned
///   branch-link bodies). NEVER at top level — `TranscriptRoot.append`
///   asserts this in DEBUG builds.
/// - `.tool` — assistant tool invocation sub-entry. Same scoping
///   constraint as `.text`.
///
/// Post-Phase-G G1.5 the prior split between `Entry` (top-level only)
/// and `AgentEntry.SubEntry` (text/tool only) is collapsed into the
/// uniform `Entry` enum. The "sub-entries can't appear at top level"
/// invariant is enforced by the builder + a runtime assert rather
/// than the type system, in exchange for a single uniform mutating
/// API on ``TranscriptRoot``.
///
/// Every variant carries the same display contract: `header: Header`
/// + `body: Body`. Variant-specific scalars (token usage, queued flags,
/// system subtype, etc.) live on the inner struct.
public enum Entry: Identifiable, Equatable, Sendable {
    case user(UserEntry)
    case agent(AgentEntry)
    case system(SystemEntry)
    case compact(CompactEntry)
    case synthesized(SynthesizedEntry)
    case text(TextSubEntry)
    case tool(ToolEntry)

    public var id: EntryID {
        switch self {
        case .user(let e):        return e.id
        case .agent(let e):       return e.id
        case .system(let e):      return e.id
        case .compact(let e):     return e.id
        case .synthesized(let e): return e.id
        case .text(let e):        return e.id
        case .tool(let e):        return e.id
        }
    }

    public var header: Header {
        switch self {
        case .user(let e):        return e.header
        case .agent(let e):       return e.header
        case .system(let e):      return e.header
        case .compact(let e):     return e.header
        case .synthesized(let e): return e.header
        case .text(let e):        return e.header
        case .tool(let e):        return e.header
        }
    }

    public var body: Body {
        switch self {
        case .user(let e):        return e.body
        case .agent(let e):       return e.body
        case .system(let e):      return e.body
        case .compact(let e):     return e.body
        case .synthesized(let e): return e.body
        case .text(let e):        return e.body
        case .tool(let e):        return e.body
        }
    }

    public var timestamp: Date? {
        switch self {
        case .user(let e):        return e.timestamp
        case .agent(let e):       return e.timestamp
        case .system(let e):      return e.timestamp
        case .compact(let e):     return e.timestamp
        case .synthesized(let e): return e.timestamp
        case .text(let e):        return e.timestamp
        case .tool(let e):        return e.timestamp
        }
    }

    /// Children carried by container variants. Empty for non-container
    /// variants. Replaces the ad-hoc walks of `body.sections` for
    /// `.subentries(...)` that existed pre-G1.5.
    public var subEntries: [Entry] {
        switch self {
        case .agent(let e):       return e.subEntries
        case .synthesized(let e): return e.subEntries
        case .tool(let e):        return e.subEntries
        case .user, .system, .compact, .text:
            return []
        }
    }
}

/// Convenience type alias for `[Entry]` — the document the panel
/// renders. Used throughout the package as a clear domain term.
public typealias Transcript = [Entry]

