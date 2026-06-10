public import Foundation

/// Cmux-invented entry — has no JSONL counterpart. Two kinds today:
/// - `rewind`: appears at a divergence point in the active branch,
///   pointing at the abandoned branch's transcript. The abandoned
///   entries travel in the top-level ``subEntries`` field; the
///   renderer treats this as a header-only link that opens the
///   subtree in a detail tab.
/// - `prLink`: external GitHub PR reference detected in entry text.
///   ``subEntries`` is empty; click opens the PR URL externally.
public struct SynthesizedEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let header: Header
    public let body: Body
    public let kind: Kind
    /// Nested children (post-G1.5). Mirrors ``AgentEntry/subEntries``
    /// so all container variants expose children at the same structural
    /// position. Populated for `.rewind` (abandoned-branch entries);
    /// empty for `.prLink`.
    ///
    /// `internal(set) var` (post-G1.6): same read-only-from-outside,
    /// writeable-inside-the-package contract as
    /// ``AgentEntry/subEntries`` — see that field's doc.
    public internal(set) var subEntries: [Entry]

    /// Abandoned-branch rewinds whose divergence point is this entry.
    /// See ``Entry/branches``. Rare on synthesized entries (a rewind
    /// dangling off another rewind isn't typical) but the field exists
    /// uniformly for symmetry.
    public internal(set) var branches: [SynthesizedEntry]

    public init(
        id: EntryID,
        header: Header,
        body: Body,
        kind: Kind,
        subEntries: [Entry] = [],
        branches: [SynthesizedEntry] = []
    ) {
        self.id = id
        self.header = header
        self.body = body
        self.kind = kind
        self.subEntries = subEntries
        self.branches = branches
    }

    public var timestamp: Date? { header.timeMarker?.clockDate }

    /// Closed enum over the cmux-invented entry kinds. New synthesized
    /// entries land here.
    public enum Kind: Equatable, Sendable {
        /// Indented tree-style entry at a divergence point. The full
        /// abandoned-branch transcript travels on the parent
        /// ``SynthesizedEntry/subEntries`` field; the renderer walks
        /// it like any other transcript.
        ///
        /// `rootUuid` is the JSONL uuid of the *first* abandoned
        /// entry — derives the link's own id (`.derived(parent: rootUuid,
        /// kind: "rewind")`), making it unique across multiple
        /// rewinds to the same divergence point.
        case rewind(rootUuid: String)
        /// External PR link entry. Carries the prNumber/url/repository so
        /// the renderer can format both title and external link target.
        case prLink(prNumber: Int, url: String, repository: String)
    }
}
