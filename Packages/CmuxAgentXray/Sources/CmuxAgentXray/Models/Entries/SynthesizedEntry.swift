public import Foundation

/// Cmux-invented entry — has no JSONL counterpart. Two kinds today:
/// - `branchLink`: appears at a divergence point in the active branch,
///   pointing at the abandoned branch's transcript. The body carries
///   `.subentries(...)` with the abandoned chunks; the renderer treats
///   this as a header-only link that opens the subtree in a detail tab.
/// - `prLink`: external GitHub PR reference detected in chunk text. The
///   body is empty; click opens the PR URL externally.
public struct SynthesizedEntry: Identifiable, Equatable, Sendable {
    public let id: EntryID
    public let timestamp: Date?
    public let header: Header
    public let body: Body
    public let kind: Kind

    public init(
        id: EntryID,
        timestamp: Date?,
        header: Header,
        body: Body,
        kind: Kind
    ) {
        self.id = id
        self.timestamp = timestamp
        self.header = header
        self.body = body
        self.kind = kind
    }

    /// Closed enum over the cmux-invented row kinds. New synthesized
    /// rows land here.
    public enum Kind: Equatable, Sendable {
        /// Indented tree-style row at a divergence point. The full
        /// abandoned-branch transcript travels in `body.sections` as a
        /// `.subentries` section so the detail-tab renderer can walk it
        /// like any other transcript.
        case branchLink(
            branchRootUuid: String,
            rewindIndex: Int,
            totalRewinds: Int,
            entryCount: Int,
            firstPromptPreview: String?
        )
        /// External PR link row. Carries the prNumber/url/repository so
        /// the renderer can format both title and external link target.
        case prLink(prNumber: Int, url: String, repository: String)
    }
}
