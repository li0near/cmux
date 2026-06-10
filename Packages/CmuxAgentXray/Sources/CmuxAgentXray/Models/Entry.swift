public import Foundation

/// Umbrella enum for every transcript item. Seven cases:
///
/// - `.user` — user-authored prompt.
/// - `.agent` — one assistant turn (top-level container variant).
/// - `.system` — JSONL `type: "system"` line in any of its subtypes.
/// - `.compact` — `type: "summary"` compact event.
/// - `.synthesized` — cmux-invented entry (branch link, PR link).
/// - `.text` — assistant thinking / text sub-entry. Appears ONLY inside
///   ``AgentEntry/subEntries`` (and recursively inside abandoned
///   branch-link bodies). NEVER at top level — `Transcript.append`
///   asserts this in DEBUG builds.
/// - `.tool` — assistant tool invocation sub-entry. Same scoping
///   constraint as `.text`.
///
/// Post-Phase-G G1.5 the prior split between `Entry` (top-level only)
/// and `AgentEntry.SubEntry` (text/tool only) is collapsed into the
/// uniform `Entry` enum. The "sub-entries can't appear at top level"
/// invariant is enforced by the builder + a runtime assert rather
/// than the type system, in exchange for a single uniform mutating
/// API on ``Transcript``.
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
    ///
    /// **Settable (post-G1.6).** The setter case-rebuilds the inner
    /// container struct with `newValue` for `.agent` / `.synthesized`,
    /// and silently no-ops for non-container cases (a DEBUG assert
    /// flags the misuse). This makes `&entries[i].subEntries` a
    /// writeable lvalue — Swift's `_modify` accessor composes the
    /// chain through nested arrays so ``Transcript`` can recurse to
    /// any depth without the copy-extract-repack ceremony the
    /// pre-G1.6 helpers (`withSubEntries` / `withAppendedSubEntry` /
    /// `withRemovedSubEntryAt`) needed.
    ///
    /// `.tool` is NOT a container variant — sub-agent (Task / Agent
    /// tool) transcripts will be modeled as top-level ``AgentEntry``
    /// entries in a future commit, not as nested children of the
    /// originating tool entry.
    public var subEntries: [Entry] {
        get {
            switch self {
            case .agent(let e):       return e.subEntries
            case .synthesized(let e): return e.subEntries
            case .user, .system, .compact, .text, .tool:
                return []
            }
        }
        set {
            switch self {
            case .agent(var e):
                e.subEntries = newValue
                self = .agent(e)
            case .synthesized(var e):
                e.subEntries = newValue
                self = .synthesized(e)
            case .user, .system, .compact, .text, .tool:
                assert(newValue.isEmpty,
                       "Entry.subEntries setter on non-container case (\(self.id.stableString)) — \(newValue.count) entries dropped.")
                return
            }
        }
    }

    /// Abandoned-branch rewinds whose divergence point is this entry.
    /// Universal across every top-level Entry kind so
    /// ``Transcript/branchOff(at:link:)`` can attach a rewind regardless
    /// of the divergence-point parent's type. The renderer lifts
    /// branches to top-level visual peers right after the entry —
    /// the data model keeps them off the live `Transcript.entries`
    /// array (so slice operations don't have to skip prior rewind
    /// siblings) while the visual surface still shows them as
    /// always-visible affordances.
    ///
    /// `.text` / `.tool` sub-entry cases never receive branches today
    /// (rewinds always parent at top-level entries), but the setter
    /// asserts in DEBUG to catch accidental misuse.
    public var branches: [SynthesizedEntry] {
        get {
            switch self {
            case .user(let e):        return e.branches
            case .agent(let e):       return e.branches
            case .system(let e):      return e.branches
            case .compact(let e):     return e.branches
            case .synthesized(let e): return e.branches
            case .text, .tool:        return []
            }
        }
        set {
            switch self {
            case .user(var e):
                e.branches = newValue
                self = .user(e)
            case .agent(var e):
                e.branches = newValue
                self = .agent(e)
            case .system(var e):
                e.branches = newValue
                self = .system(e)
            case .compact(var e):
                e.branches = newValue
                self = .compact(e)
            case .synthesized(var e):
                e.branches = newValue
                self = .synthesized(e)
            case .text, .tool:
                assert(newValue.isEmpty,
                       "Entry.branches setter on sub-entry case (\(self.id.stableString)) — \(newValue.count) branches dropped.")
                return
            }
        }
    }
}
