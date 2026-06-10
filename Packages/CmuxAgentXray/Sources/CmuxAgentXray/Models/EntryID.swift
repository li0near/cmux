/// Stable identifier for an `Entry` across stream rebuilds.
///
/// Entries fall into two id categories:
/// - **Mirrored from JSONL** — the entry's id is a JSONL `uuid` (or
///   tool-use `id`). Use `.fromJSONL(_:)` at the boundary where raw
///   JSONL strings cross into the domain model.
/// - **Derived** — synthetic id for entries that have no JSONL
///   counterpart (thinking blocks projected from assistant content
///   blocks, abstract `branchLink`/`prLink` synthesizer entries, queued
///   pseudo-entries, etc.). The `parent` is the owning JSONL uuid;
///   the `kind` namespaces the derivation so siblings under the same
///   parent are unique.
///
/// `EntryID` is a value type with full `Equatable` and `Hashable`
/// conformance — safe to use as a `Set` element or `Dictionary` key.
/// The `stableString` projection is the canonical key form for
/// expansion-state dictionaries and view-tree id matching.
public struct EntryID: Hashable, Sendable {

    public enum Source: Hashable, Sendable {
        /// Direct mirror of a JSONL `uuid` or tool-use `id`.
        case jsonl(String)
        /// Synthetic id namespaced under a parent JSONL id.
        case derived(parent: String, kind: String)
    }

    public let source: Source

    public init(_ source: Source) {
        self.source = source
    }

    /// Build an id from a JSONL uuid string. Use at the parser boundary.
    public static func fromJSONL(_ uuid: String) -> EntryID {
        EntryID(.jsonl(uuid))
    }

    /// Build a derived id namespaced under a parent JSONL uuid.
    public static func derived(parent: String, kind: String) -> EntryID {
        EntryID(.derived(parent: parent, kind: kind))
    }

    /// Canonical string representation. Used as a `Set<String>` key for
    /// expansion state and as a SwiftUI `id(_:)` value at the entry level.
    public var stableString: String {
        switch source {
        case .jsonl(let uuid):
            return uuid
        case .derived(let parent, let kind):
            return "d:\(kind):\(parent)"
        }
    }

    /// True when this id mirrors a raw JSONL uuid. Useful when matching
    /// against raw JSONL parents (e.g. branch resolution).
    public var isJSONLMirrored: Bool {
        if case .jsonl = source { return true }
        return false
    }
}
