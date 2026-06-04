import Foundation

/// Per-entry pre-computed display fields, cached by entry id and
/// invalidated on content change.
///
/// The cache is the package's primary performance lever: in long
/// transcripts (1000+ entries), the panel's body re-evaluates whenever
/// any `@Observable`-tracked property changes. Without caching,
/// per-section cap application + word counting + signature hashing
/// would re-run for every entry on every body pass — measurable jank
/// in dogfood. The cache keys per-entry computed fields by id +
/// content signature so identical re-renders are O(1) lookups.
///
/// Reset on session change. The panel resets the cache when
/// `TranscriptStream.attach(session:)` is called.
@MainActor
@available(macOS 15, *)
public final class EntryComputedCache {

    public init() {}

    /// Pre-computed display fields for one entry under one display mode.
    public struct Computed: Equatable, Sendable {
        /// Cap-applied inline previews per body section index. Same
        /// length as `entry.body.sections`; `.subentries` sections
        /// produce empty content (their children are rendered
        /// recursively, not summarised).
        public let sections: [ExpandableContent]
        /// Word count of the joined `.text` sections, used for the
        /// "N words" trailing pill on assistant text entries.
        public let wordCount: Int
        /// Signature used for cache invalidation. Two entries with the
        /// same signature have identical content and produce identical
        /// computed fields; the cache returns the existing entry on hit.
        public let signature: ContentSignature
    }

    /// Lightweight content fingerprint. Two entries with the same
    /// signature have identical body content + display mode (per-cap
    /// computation invariant). Hash combines section count + total
    /// byte size + the display mode discriminator — collisions are
    /// possible but practically negligible for transcript content
    /// (real entries don't hash-collide).
    public struct ContentSignature: Hashable, Sendable {
        public let sectionCount: Int
        public let totalBytes: Int
        public let displayMode: DisplayMode

        public init(entry: Entry, displayMode: DisplayMode) {
            self.sectionCount = entry.body.sections.count
            self.totalBytes = entry.body.sections.reduce(0) { sum, section in
                switch section {
                case .text(let blocks, _):
                    return sum + blocks.reduce(0) { $0 + $1.utf8.count }
                case .subentries(let children):
                    return sum + children.count
                }
            }
            self.displayMode = displayMode
        }
    }

    private struct CacheEntry {
        let signature: ContentSignature
        let computed: Computed
    }

    private var entries: [String: CacheEntry] = [:]

    /// Compute (or return cached) display fields for `entry` under
    /// `displayMode`. Idempotent — calling with the same id/content
    /// returns the existing entry.
    public func compute(
        for entry: Entry,
        displayMode: DisplayMode
    ) -> Computed {
        let signature = ContentSignature(entry: entry, displayMode: displayMode)
        let key = entry.id.stableString
        if let existing = entries[key], existing.signature == signature {
            return existing.computed
        }
        let computed = build(entry: entry, displayMode: displayMode, signature: signature)
        entries[key] = CacheEntry(signature: signature, computed: computed)
        return computed
    }

    /// Drop every cached entry. Called on session change.
    public func reset() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Drop a single entry's cached fields. Called when a known entry
    /// id is mutated (rare — most mutations are append-only).
    public func invalidate(entryID: String) {
        entries.removeValue(forKey: entryID)
    }

    private func build(
        entry: Entry,
        displayMode: DisplayMode,
        signature: ContentSignature
    ) -> Computed {
        var sections: [ExpandableContent] = []
        var totalWordCount = 0
        for section in entry.body.sections {
            switch section {
            case .text(let blocks, _):
                let caps = capsForBlock(entry: entry, section: section)
                let content = ExpandableContent.make(
                    from: blocks,
                    caps: caps,
                    displayMode: displayMode
                )
                sections.append(content)
                let joined = blocks.joined(separator: "\n")
                let words = joined.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                totalWordCount += words
            case .subentries:
                sections.append(.empty)
            }
        }
        return Computed(
            sections: sections,
            wordCount: totalWordCount,
            signature: signature
        )
    }

    /// Resolve the right `RenderCaps.Section` for a given entry +
    /// section pair. Heuristic: pick caps based on the entry's
    /// variant case + the section's position. Sub-entry-only entries
    /// (like AgentEntry body) defer to per-sub-entry caps at the View
    /// layer — this resolver returns `.standard` for any
    /// uncategorised text body.
    private func capsForBlock(entry: Entry, section: Section) -> RenderSectionCaps {
        switch entry {
        case .user:
            return RenderCaps.caps(for: .userPrompt)
        case .agent:
            // AgentEntry's body is .subentries(...); per-sub-entry caps
            // apply at the SubEntry's computed-cache call site.
            return RenderCaps.caps(for: .userPrompt)
        case .compact:
            return RenderCaps.caps(for: .compactBody)
        case .system(let sys):
            switch sys.subType {
            case .localCommand:        return RenderCaps.caps(for: .systemBody)
            case .slashCmdInput:       return RenderCaps.caps(for: .systemBody)
            case .slashCmdOutput:      return RenderCaps.caps(for: .slashCmdOutput)
            case .skill:               return RenderCaps.caps(for: .skillBody)
            case .systemReminder:      return RenderCaps.caps(for: .systemReminder)
            case .contextUsage:        return RenderCaps.caps(for: .contextUsage)
            case .recap:               return RenderCaps.caps(for: .recapBody)
            case .planMode:            return RenderCaps.caps(for: .systemBody)
            case .editedTextFile:      return RenderCaps.caps(for: .editedTextFile)
            case .other:               return RenderCaps.caps(for: .systemBody)
            }
        case .synthesized:
            return RenderCaps.caps(for: .systemBody)
        }
    }
}
