public import Foundation

/// Umbrella enum for every transcript item — a `Transcript` is a
/// `[Entry]`. Five top-level cases:
///
/// - `.user` — user-authored prompt.
/// - `.agent` — one assistant turn (the only container variant).
/// - `.system` — JSONL `type: "system"` line in any of its subtypes.
/// - `.compact` — `type: "summary"` compact event.
/// - `.synthesized` — cmux-invented row (branch link, PR link).
///
/// Sub-entries (`thinking`, `tool`, `assistantText`) live inside
/// `AgentTurn.subEntries` and never appear at the top level. They are
/// represented as `AgentTurn.SubEntry`, not as cases of `Entry` —
/// the Swift type system enforces "sub-entries are turn-internal."
///
/// Every variant carries the same display contract: `header: Header`
/// + `body: Body`. Variant-specific scalars (token usage, queued flags,
/// system subtype, etc.) live on the inner struct.
public enum Entry: Identifiable, Equatable, Sendable {
    case user(UserEntry)
    case agent(AgentTurn)
    case system(SystemEntry)
    case compact(CompactEntry)
    case synthesized(SynthesizedEntry)

    public var id: EntryID {
        switch self {
        case .user(let e):        return e.id
        case .agent(let e):       return e.id
        case .system(let e):      return e.id
        case .compact(let e):     return e.id
        case .synthesized(let e): return e.id
        }
    }

    public var header: Header {
        switch self {
        case .user(let e):        return e.header
        case .agent(let e):       return e.header
        case .system(let e):      return e.header
        case .compact(let e):     return e.header
        case .synthesized(let e): return e.header
        }
    }

    public var body: Body {
        switch self {
        case .user(let e):        return e.body
        case .agent(let e):       return e.body
        case .system(let e):      return e.body
        case .compact(let e):     return e.body
        case .synthesized(let e): return e.body
        }
    }

    public var timestamp: Date? {
        switch self {
        case .user(let e):        return e.timestamp
        case .agent(let e):       return e.timestamp
        case .system(let e):      return e.timestamp
        case .compact(let e):     return e.timestamp
        case .synthesized(let e): return e.timestamp
        }
    }
}

/// Convenience type alias for `[Entry]` — the document the panel
/// renders. Used throughout the package as a clear domain term.
public typealias Transcript = [Entry]
