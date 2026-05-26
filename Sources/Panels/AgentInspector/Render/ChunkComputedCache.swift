import Foundation

/// Side cache of expensive precomputed fields for each `AgentChunk`.
///
/// Why this exists: every panel-body invocation in
/// `AgentInspectorPanelView` rebuilds `ChunkRowSnapshot` for each visible
/// chunk via `ChunkRowSnapshot.from(...)`. The expensive bits inside
/// `from(...)` are repeated `makeExpandable(...)` calls (per-section
/// truncation with line-split + UTF-8 byte walk) and word-count splits.
/// These are deterministic per `(chunk content, displayMode)`, so we
/// cache them keyed by chunk id with a cheap content-byte signature.
///
/// Lifecycle: cache is owned by `AgentInspectorPanel` and `reset()` runs
/// on every session change (`handleSessionChange`). Per-panel scope means
/// no global state and no cross-session contamination.
///
/// Threading: `@MainActor` — the panel body runs on the main actor and
/// is the only caller. The annotation is a compile-time guard against
/// off-main misuse.
@MainActor
final class ChunkComputedCache {
    private struct Entry {
        let signature: ChunkContentSignature
        let fields: ChunkComputedFields
    }

    private var entries: [String: Entry] = [:]

    /// Number of cache misses since creation/reset. Behavioural
    /// observation seam for tests — readable without exposing the
    /// internal storage and without checking source text.
    private(set) var computeCount: Int = 0

    func compute(
        for chunk: AgentChunk,
        displayMode: ChunkRowSnapshot.DisplayMode
    ) -> ChunkComputedFields {
        let signature = ChunkContentSignature(chunk: chunk, displayMode: displayMode)
        if let cached = entries[chunk.id], cached.signature == signature {
            return cached.fields
        }
        let fields = ChunkComputedFields.compute(for: chunk, displayMode: displayMode)
        entries[chunk.id] = Entry(signature: signature, fields: fields)
        computeCount += 1
        return fields
    }

    func reset() {
        entries.removeAll()
        computeCount = 0
    }
}

/// Cheap fingerprint that detects content drift on the same chunk id.
///
/// Chunk content in this domain is append-only via `ClaudeChunkBuilder` /
/// `CodexChunkBuilder` — the trailing AI chunk's text grows as the
/// assistant streams, but text is never edited in place at constant
/// length. So the UTF-8 byte total per chunk is a sufficient identity:
/// content growth → different byte total → cache miss → recompute.
///
/// `displayMode` is included because `.compact` vs `.fullDetail` produce
/// different `ExpandableContent` values for the same text (compact
/// truncates; fullDetail does not).
struct ChunkContentSignature: Hashable, Sendable {
    let chunkId: String
    let signatureBytes: Int
    let displayMode: ChunkRowSnapshot.DisplayMode

    init(chunk: AgentChunk, displayMode: ChunkRowSnapshot.DisplayMode) {
        self.chunkId = chunk.id
        self.signatureBytes = chunk.signatureBytes
        self.displayMode = displayMode
    }
}

private extension AgentChunk {
    /// UTF-8 byte total across all expensive-to-process content. Used by
    /// `ChunkContentSignature` to detect append-only growth on the same id.
    var signatureBytes: Int {
        switch self {
        case .user(let c):
            return c.text.utf8.count
        case .ai(let c):
            var total = c.thinkingText.utf8.count + c.assistantText.utf8.count
            for tc in c.toolCalls {
                total += tc.inputDetail.utf8.count
                total += tc.result?.utf8.count ?? 0
            }
            return total
        case .system(let c):
            return c.output.utf8.count
        case .compact:
            return 0
        case .meta(let m):
            switch m {
            case .recap(let r): return r.body.utf8.count
            case .slashCmdOutput(let o): return o.body.utf8.count
            case .localCommandCaveat(let l): return l.body.utf8.count
            case .systemReminder(let r): return r.body.utf8.count
            case .contextUsage(let cu): return cu.body.utf8.count
            // Variants without inline-expandable bodies — no cache invalidation
            // signal needed beyond identity.
            case .branchLink, .prLink, .skillTitle, .slashCmdInput, .continueResume:
                return 0
            }
        }
    }
}

/// Precomputed expensive fields for one `AgentChunk`, organised by kind.
/// Only the substruct matching the chunk's variant carries meaningful
/// values; the others are `.empty` placeholders.
///
/// Computed once per `(chunk content, displayMode)` combination and
/// served from the cache thereafter. The cheap derivations
/// (`oneLine`, `formatDurationLabel`, model-name-map, status enum) stay
/// inline in `ChunkRowSnapshot.from(...)` since they are O(1) or O(short).
struct ChunkComputedFields: Equatable, Sendable {
    let user: User
    let ai: AI
    let system: System
    let meta: Meta

    static let empty = ChunkComputedFields(
        user: .empty,
        ai: .empty,
        system: .empty,
        meta: .empty
    )

    struct User: Equatable, Sendable {
        let full: ChunkRowSnapshot.ExpandableContent
        let wordCount: Int
        static let empty = User(full: .empty, wordCount: 0)
    }

    struct AI: Equatable, Sendable {
        let thinking: ChunkRowSnapshot.ExpandableContent?
        let assistantOverflow: ChunkRowSnapshot.ExpandableContent?
        let assistantWordCount: Int
        /// Per-tool truncated input/result, keyed by tool id.
        let toolExpandables: [String: ToolExpandables]
        static let empty = AI(
            thinking: nil,
            assistantOverflow: nil,
            assistantWordCount: 0,
            toolExpandables: [:]
        )
    }

    struct ToolExpandables: Equatable, Sendable {
        let input: ChunkRowSnapshot.ExpandableContent
        let result: ChunkRowSnapshot.ExpandableContent
    }

    struct System: Equatable, Sendable {
        let body: ChunkRowSnapshot.ExpandableContent
        static let empty = System(body: .empty)
    }

    struct Meta: Equatable, Sendable {
        /// Single body slot. Only set for meta variants whose Phase B
        /// renderer surfaces an inline ExpandableContent (recap,
        /// slashCmdOutput, localCommandCaveat, systemReminder,
        /// contextUsage). Empty for branchLink, prLink, skillTitle,
        /// slashCmdInput, continueResume.
        let body: ChunkRowSnapshot.ExpandableContent
        static let empty = Meta(body: .empty)
    }

    /// Run all expensive precomputations for the chunk. Called by the
    /// cache on miss; can also be called directly for tests or for
    /// callers that don't have a cache (e.g. detail view, unit tests).
    static func compute(
        for chunk: AgentChunk,
        displayMode: ChunkRowSnapshot.DisplayMode
    ) -> ChunkComputedFields {
        switch chunk {
        case .user(let c):
            let trimmed = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = trimmed.split { $0.isWhitespace || $0.isNewline }.count
            return ChunkComputedFields(
                user: User(
                    full: ChunkRowSnapshot.makeExpandable(
                        c.text,
                        caps: InspectorCaps.userPrompt,
                        displayMode: displayMode
                    ),
                    wordCount: words
                ),
                ai: .empty,
                system: .empty,
                meta: .empty
            )

        case .ai(let c):
            let thinking: ChunkRowSnapshot.ExpandableContent? = {
                let trimmed = c.thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return ChunkRowSnapshot.makeExpandable(
                    c.thinkingText,
                    caps: InspectorCaps.thinking,
                    displayMode: displayMode
                )
            }()
            let assistantOverflow: ChunkRowSnapshot.ExpandableContent? = {
                let trimmed = c.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return ChunkRowSnapshot.makeExpandable(
                    c.assistantText,
                    caps: InspectorCaps.assistantText,
                    displayMode: displayMode
                )
            }()
            let assistantWordCount: Int = {
                let trimmed = c.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return 0 }
                return trimmed.split { $0.isWhitespace || $0.isNewline }.count
            }()
            var toolExpandables: [String: ToolExpandables] = [:]
            toolExpandables.reserveCapacity(c.toolCalls.count)
            for tc in c.toolCalls {
                toolExpandables[tc.id] = ToolExpandables(
                    input: ChunkRowSnapshot.makeExpandable(
                        tc.inputDetail,
                        caps: InspectorCaps.toolInput,
                        displayMode: displayMode
                    ),
                    result: ChunkRowSnapshot.makeExpandable(
                        tc.result ?? "",
                        caps: InspectorCaps.toolResult,
                        displayMode: displayMode
                    )
                )
            }
            return ChunkComputedFields(
                user: .empty,
                ai: AI(
                    thinking: thinking,
                    assistantOverflow: assistantOverflow,
                    assistantWordCount: assistantWordCount,
                    toolExpandables: toolExpandables
                ),
                system: .empty,
                meta: .empty
            )

        case .system(let c):
            return ChunkComputedFields(
                user: .empty,
                ai: .empty,
                system: System(
                    body: ChunkRowSnapshot.makeExpandable(
                        c.output,
                        caps: InspectorCaps.systemBody,
                        displayMode: displayMode
                    )
                ),
                meta: .empty
            )

        case .compact:
            return .empty

        case .meta(let m):
            let body: ChunkRowSnapshot.ExpandableContent = {
                switch m {
                case .recap(let r):
                    return ChunkRowSnapshot.makeExpandable(
                        r.body, caps: InspectorCaps.recapBody, displayMode: displayMode
                    )
                case .slashCmdOutput(let o):
                    return ChunkRowSnapshot.makeExpandable(
                        o.body, caps: InspectorCaps.slashCmdOutput, displayMode: displayMode
                    )
                case .localCommandCaveat(let l):
                    return ChunkRowSnapshot.makeExpandable(
                        l.body, caps: InspectorCaps.localCommandCaveat, displayMode: displayMode
                    )
                case .systemReminder(let r):
                    return ChunkRowSnapshot.makeExpandable(
                        r.body, caps: InspectorCaps.systemReminder, displayMode: displayMode
                    )
                case .contextUsage(let cu):
                    return ChunkRowSnapshot.makeExpandable(
                        cu.body, caps: InspectorCaps.contextUsage, displayMode: displayMode
                    )
                case .branchLink, .prLink, .skillTitle, .slashCmdInput, .continueResume:
                    return .empty
                }
            }()
            return ChunkComputedFields(
                user: .empty,
                ai: .empty,
                system: .empty,
                meta: Meta(body: body)
            )
        }
    }
}
