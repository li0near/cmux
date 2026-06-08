public import Foundation

/// Synthetic root container for the transcript model.
///
/// Phase G replaces the rebuild-from-scratch builder pipeline with
/// **incremental in-place mutation** of a single ``TranscriptRoot``
/// indexed by ``EntryID``. The dispatcher walks each new JSONL line,
/// then calls the corresponding mutating method on the root:
/// ``append(parent:entry:)`` for both top-level (parent = nil) and
/// nested (parent = container's id) appends, ``mutate(id:_:)`` for
/// in-place updates at any depth, ``remove(id:)`` for removals, and
/// ``branchOff(at:link:)`` for rewind slicing.
///
/// **Uniform tree (post-G1.5).** Both top-level and nested entries
/// are `Entry` values. Container variants — `.agent`, `.tool`,
/// `.synthesized` (specifically `.branchLink`) — expose
/// ``Entry/subEntries`` directly. The "only `.text` / `.tool` cases
/// appear inside an agent turn" invariant is enforced by the builder
/// + a runtime assert in ``append(parent:entry:)`` rather than the
/// type system.
///
/// **Index.** `[EntryID: ParentSlot]` lets every lookup find an entry
/// in O(depth) — typically 1-3 hops. Top-level entries store
/// `parent = nil`; nested entries store their immediate container's
/// id.
///
/// **Reads.** ``subEntries`` is the live top-level array — what
/// ``ClaudeTranscriptBuilder/transcript()`` returns. ``entry(id:)``
/// returns an entry at any depth.
///
/// ```swift
/// var root = TranscriptRoot()
/// root.append(parent: nil, entry: .user(userPrompt))           // top-level
/// root.append(parent: nil, entry: .agent(agentTurn))           // top-level
/// root.append(parent: agentTurn.id, entry: .tool(toolUse))     // nested
/// root.mutate(id: toolUse.id) { entry in
///     if case .tool(let t) = entry {
///         entry = .tool(/* ToolEntry with .ok status + result */)
///     }
/// }
/// ```
public struct TranscriptRoot: Equatable, Sendable {

    /// Live top-level entry array. Reads are cheap. Writes go through
    /// the mutating methods so the index stays in sync.
    public private(set) var subEntries: [Entry] = []

    /// `EntryID → (parent, indexInParent)`. Top-level entries store
    /// `parent = nil`. Walking the chain bottom-up yields the path
    /// from top level to the entry.
    private var index: [EntryID: ParentSlot] = [:]

    private struct ParentSlot: Equatable {
        let parent: EntryID?
        let indexInParent: Int
    }

    public init() {}

    // MARK: - Reads

    /// Look up an entry by id at any depth. Returns nil if absent.
    public func entry(id: EntryID) -> Entry? {
        guard let path = path(to: id) else { return nil }
        return entryAtPath(path)
    }

    /// Build the full path from top level to `id` as a list of indices.
    /// `[i]` means top-level slot `i`; `[i, j]` means top-level `i`'s
    /// subEntries slot `j`; etc. Returns nil if id is not in the index.
    private func path(to id: EntryID) -> [Int]? {
        var slots: [Int] = []
        var cursor: EntryID? = id
        while let cur = cursor {
            guard let slot = index[cur] else { return nil }
            slots.append(slot.indexInParent)
            cursor = slot.parent
        }
        slots.reverse()
        return slots
    }

    /// Read the entry at the given path. Returns nil for invalid paths.
    private func entryAtPath(_ path: [Int]) -> Entry? {
        guard let first = path.first, subEntries.indices.contains(first) else {
            return nil
        }
        var current = subEntries[first]
        for idx in path.dropFirst() {
            let kids = current.subEntries
            guard kids.indices.contains(idx) else { return nil }
            current = kids[idx]
        }
        return current
    }

    // MARK: - Mutations: append

    /// Append an entry under the given parent. Pass `parent: nil` to
    /// append at top level; pass a parent id to append into that
    /// entry's `subEntries`. The parent must already be in the tree.
    ///
    /// Asserts in DEBUG that top-level appends never receive `.text`
    /// / `.tool` (those cases only appear nested inside a container).
    public mutating func append(parent: EntryID?, entry: Entry) {
        if parent == nil {
            assert(!isSubEntryOnlyCase(entry),
                   "TranscriptRoot.append: top-level append received \(entry.id.stableString) which is .text/.tool — those cases must appear nested only.")
        }
        if let parentId = parent {
            guard let parentPath = path(to: parentId) else {
                assertionFailure("TranscriptRoot.append: parent \(parentId.stableString) not in tree")
                return
            }
            let parentEntry = entryAtPath(parentPath)
            let newIdx = parentEntry?.subEntries.count ?? 0
            mutateAtPath(parentPath) { container in
                container = withAppendedSubEntry(container, entry)
            }
            index[entry.id] = ParentSlot(parent: parentId, indexInParent: newIdx)
            indexNestedChildren(of: entry)
        } else {
            let i = subEntries.count
            subEntries.append(entry)
            index[entry.id] = ParentSlot(parent: nil, indexInParent: i)
            indexNestedChildren(of: entry)
        }
    }

    // MARK: - Mutations: mutate

    /// Mutate an entry in place at any depth. The closure receives the
    /// current value; assigning to `entry` replaces it (with full
    /// ancestor reconstruction since enum cases hold immutable
    /// associated values).
    ///
    /// If the closure changes the entry's id, the index is rebuilt for
    /// that slot (rare; primarily used by the synthetic-tool fallback
    /// path during tool_result attachment).
    ///
    /// If the closure replaces the entry's `subEntries`, the affected
    /// children are re-indexed.
    public mutating func mutate(id: EntryID, _ body: (inout Entry) -> Void) {
        guard let path = path(to: id) else { return }
        guard let oldEntry = entryAtPath(path) else { return }
        let oldChildIds = collectAllDescendantIds(oldEntry)

        var newEntry = oldEntry
        body(&newEntry)
        mutateAtPath(path) { $0 = newEntry }

        // Rebuild index for affected slots.
        if newEntry.id != oldEntry.id {
            let oldSlot = index[oldEntry.id]
            index.removeValue(forKey: oldEntry.id)
            if let oldSlot {
                index[newEntry.id] = oldSlot
            }
        }
        // Drop old descendants, re-index new descendants.
        for childId in oldChildIds where childId != newEntry.id {
            index.removeValue(forKey: childId)
        }
        indexNestedChildren(of: newEntry, parent: index[newEntry.id]?.parent, parentPath: Array(path.dropLast()))
    }

    // MARK: - Mutations: remove

    /// Remove an entry by id at any depth. Trailing siblings shift
    /// down by one; the index is rebuilt for the affected siblings.
    public mutating func remove(id: EntryID) {
        guard let path = path(to: id) else { return }
        guard let removed = entryAtPath(path) else { return }
        let descendantIds = collectAllDescendantIds(removed)

        if path.count == 1 {
            subEntries.remove(at: path[0])
        } else {
            let parentPath = Array(path.dropLast())
            mutateAtPath(parentPath) { container in
                container = withRemovedSubEntryAt(container, index: path.last!)
            }
        }

        index.removeValue(forKey: id)
        for d in descendantIds { index.removeValue(forKey: d) }

        // Re-index trailing siblings AT THE SAME LEVEL whose
        // indexInParent shifted down.
        let parentId = index[id]?.parent
        _ = parentId // unused after removal; siblings re-indexed below
        let siblings: [Entry]
        if path.count == 1 {
            siblings = subEntries
        } else {
            siblings = entryAtPath(Array(path.dropLast()))?.subEntries ?? []
        }
        let parentForSlot: EntryID? = (path.count == 1)
            ? nil
            : entryAtPath(Array(path.dropLast()))?.id
        for (siblingIdx, sibling) in siblings.enumerated() where siblingIdx >= path.last! {
            index[sibling.id] = ParentSlot(parent: parentForSlot, indexInParent: siblingIdx)
            indexNestedChildren(of: sibling, parent: parentForSlot, parentPath: Array(path.dropLast()))
        }
    }

    // MARK: - branchOff support (used by the extension)

    /// Internal: read top-level slot index for an id. Used by
    /// ``branchOff(at:link:)``.
    internal func topLevelIndex(of id: EntryID) -> Int? {
        guard let slot = index[id], slot.parent == nil else { return nil }
        return slot.indexInParent
    }

    /// Internal: replace a contiguous range of top-level entries with a
    /// single new entry, dropping the old entries' index slots and
    /// recording the new one. Used by ``branchOff(at:link:)``.
    internal mutating func replaceTopLevelRange(_ range: Range<Int>, with entry: Entry) {
        for j in range {
            let removed = subEntries[j]
            let descendantIds = collectAllDescendantIds(removed)
            index.removeValue(forKey: removed.id)
            for d in descendantIds { index.removeValue(forKey: d) }
        }
        subEntries.replaceSubrange(range, with: [entry])
        for j in range.lowerBound..<subEntries.count {
            let e = subEntries[j]
            index[e.id] = ParentSlot(parent: nil, indexInParent: j)
            indexNestedChildren(of: e, parent: nil, parentPath: [])
        }
    }

    // MARK: - Internal helpers

    /// Apply `mutation` to the entry at `path`. Reconstructs every
    /// ancestor on the path so the change propagates to the top-level
    /// `subEntries` array.
    private mutating func mutateAtPath(_ path: [Int], _ mutation: (inout Entry) -> Void) {
        precondition(!path.isEmpty)
        TranscriptRoot.mutateInside(&subEntries, path: path, mutation: mutation)
    }

    private static func mutateInside(_ entries: inout [Entry], path: [Int], mutation: (inout Entry) -> Void) {
        guard let first = path.first, entries.indices.contains(first) else { return }
        if path.count == 1 {
            mutation(&entries[first])
        } else {
            var child = entries[first]
            var childSubs = child.subEntries
            mutateInside(&childSubs, path: Array(path.dropFirst()), mutation: mutation)
            child = withSubEntries(child, childSubs)
            entries[first] = child
        }
    }

    /// Index every nested child of `entry`. Recursive: walks
    /// container variants and registers each descendant's slot.
    private mutating func indexNestedChildren(of entry: Entry) {
        indexNestedChildren(of: entry, parent: index[entry.id]?.parent, parentPath: [])
    }

    private mutating func indexNestedChildren(of entry: Entry, parent: EntryID?, parentPath: [Int]) {
        for (subIdx, child) in entry.subEntries.enumerated() {
            index[child.id] = ParentSlot(parent: entry.id, indexInParent: subIdx)
            indexNestedChildren(of: child, parent: entry.id, parentPath: parentPath)
        }
    }

    /// Collect every descendant id under `entry`, recursively.
    private func collectAllDescendantIds(_ entry: Entry) -> [EntryID] {
        var ids: [EntryID] = []
        for child in entry.subEntries {
            ids.append(child.id)
            ids.append(contentsOf: collectAllDescendantIds(child))
        }
        return ids
    }

    private func isSubEntryOnlyCase(_ entry: Entry) -> Bool {
        if case .text = entry { return true }
        if case .tool = entry { return true }
        return false
    }
}

// MARK: - Container reconstruction

/// Rebuild a container `Entry` (`.agent` / `.tool` / `.synthesized`)
/// with replaced `subEntries`. Other variants pass through unchanged.
internal func withSubEntries(_ entry: Entry, _ newSubs: [Entry]) -> Entry {
    switch entry {
    case .agent(let a):
        return .agent(AgentEntry(
            id: a.id, header: a.header, body: a.body,
            usage: a.usage, stopReason: a.stopReason,
            perTurnDurationMs: a.perTurnDurationMs,
            messageCount: a.messageCount, model: a.model,
            endTime: a.endTime, subEntries: newSubs
        ))
    case .synthesized(let s):
        return .synthesized(SynthesizedEntry(
            id: s.id, header: s.header, body: s.body,
            kind: s.kind, subEntries: newSubs
        ))
    case .tool(let t):
        return .tool(ToolEntry(
            id: t.id, parentEntryID: t.parentEntryID,
            header: t.header, body: t.body, status: t.status,
            durationMs: t.durationMs, subagentType: t.subagentType,
            teamMemberName: t.teamMemberName, teamName: t.teamName,
            mcpServer: t.mcpServer, inputFilePath: t.inputFilePath,
            subEntries: newSubs
        ))
    case .user, .system, .compact, .text:
        return entry
    }
}

/// Rebuild `container` with `entry` appended to its subEntries.
internal func withAppendedSubEntry(_ container: Entry, _ entry: Entry) -> Entry {
    var subs = container.subEntries
    subs.append(entry)
    return withSubEntries(container, subs)
}

/// Rebuild `container` with the subEntry at `index` removed.
internal func withRemovedSubEntryAt(_ container: Entry, index: Int) -> Entry {
    var subs = container.subEntries
    guard subs.indices.contains(index) else { return container }
    subs.remove(at: index)
    return withSubEntries(container, subs)
}
