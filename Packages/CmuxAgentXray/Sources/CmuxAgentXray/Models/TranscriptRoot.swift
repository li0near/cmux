public import Foundation

/// Synthetic root container for the transcript model.
///
/// Phase G replaces the rebuild-from-scratch builder pipeline with
/// **incremental in-place mutation** of a single ``TranscriptRoot``
/// indexed by ``EntryID``. The dispatcher walks each new JSONL line,
/// then calls the corresponding mutating method on the root:
/// ``append(_:)`` for top-level entries, ``appendSubEntry(parentAgentId:_:)``
/// for sub-entries inside an ``AgentEntry``, ``mutate(id:_:)`` /
/// ``mutateSubEntry(id:_:)`` for in-place updates, ``remove(id:)`` for
/// the queued-prompt placeholder swap, and ``branchOff(at:link:)`` for
/// rewind slicing.
///
/// **Type asymmetry.** The existing model is two-tiered:
/// - top-level: `[Entry]` (user / agent / system / compact / synthesized)
/// - inside an ``AgentEntry``: `[AgentEntry.SubEntry]` (text / tool only)
///
/// ``TranscriptRoot`` preserves this — the index discriminates between
/// top-level slots and sub-entry slots, and there are matching paired
/// `append` / `mutate` methods for each. There is no flattening.
///
/// **Index.** `[EntryID: EntrySlot]` lets every lookup find an entry in
/// O(1) regardless of depth. The slot enum is private; callers never
/// reference it directly.
///
/// **Reads.** ``subEntries`` is the live top-level array — what
/// ``ClaudeTranscriptBuilder/transcript()`` returns. ``entry(id:)`` and
/// ``subEntry(id:)`` return the entry at any depth.
///
/// ```swift
/// var root = TranscriptRoot()
/// root.append(userPrompt)                              // top-level
/// root.append(agentTurn)                               // top-level
/// root.appendSubEntry(parentAgentId: agentTurn.id,
///                     .tool(toolUse))                   // nested
/// root.mutateSubEntry(id: toolUse.id) { sub in
///     if case .tool(var t) = sub {
///         t = ToolEntry(/* ...with result... */)
///         sub = .tool(t)
///     }
/// }
/// ```
public struct TranscriptRoot: Equatable, Sendable {

    /// Live top-level entry array. Reads are cheap. Writes go through
    /// the mutating methods so the index stays in sync.
    public private(set) var subEntries: [Entry] = []

    private var index: [EntryID: EntrySlot] = [:]

    /// Where an entry lives in the tree. Top-level entries store their
    /// position in ``subEntries``; nested entries store their parent
    /// agent's id and their index inside that agent's subEntries.
    private enum EntrySlot: Equatable {
        case topLevel(Int)
        case agentSub(parentAgentId: EntryID, subIndex: Int)
    }

    public init() {}

    // MARK: - Reads

    /// Look up a top-level entry by id. Returns nil if `id` is absent
    /// or refers to a sub-entry (use ``subEntry(id:)`` for nested).
    public func entry(id: EntryID) -> Entry? {
        guard case .topLevel(let i) = index[id], subEntries.indices.contains(i) else {
            return nil
        }
        return subEntries[i]
    }

    /// Look up a sub-entry by id. Returns nil if `id` is absent or
    /// refers to a top-level entry.
    public func subEntry(id: EntryID) -> AgentEntry.SubEntry? {
        guard case .agentSub(let parentId, let subIdx) = index[id],
              case .topLevel(let i) = index[parentId],
              subEntries.indices.contains(i),
              case .agent(let agent) = subEntries[i],
              agent.subEntries.indices.contains(subIdx)
        else { return nil }
        return agent.subEntries[subIdx]
    }

    // MARK: - Mutations: append

    /// Append a top-level entry. The new entry's id is recorded in the
    /// index. If it is an ``AgentEntry`` carrying pre-existing
    /// sub-entries, those are indexed too.
    public mutating func append(_ entry: Entry) {
        let i = subEntries.count
        subEntries.append(entry)
        index[entry.id] = .topLevel(i)
        indexAgentSubsIfNeeded(of: entry, parentIndex: i)
    }

    /// Append a sub-entry under the given parent ``AgentEntry`` (looked
    /// up by id). If the parent isn't a top-level agent entry, the
    /// append is a no-op (and a precondition failure in DEBUG builds —
    /// callers should know what they're appending into).
    public mutating func appendSubEntry(parentAgentId: EntryID, _ subEntry: AgentEntry.SubEntry) {
        guard case .topLevel(let i) = index[parentAgentId],
              subEntries.indices.contains(i),
              case .agent(let agent) = subEntries[i]
        else {
            assertionFailure("appendSubEntry: parent \(parentAgentId.stableString) is not a top-level AgentEntry")
            return
        }
        var subs = agent.subEntries
        let subIdx = subs.count
        subs.append(subEntry)
        subEntries[i] = .agent(rebuild(agent, subEntries: subs))
        index[subEntry.id] = .agentSub(parentAgentId: parentAgentId, subIndex: subIdx)
    }

    // MARK: - Mutations: mutate

    /// Mutate a top-level entry in place. The closure replaces the
    /// entry's value at its slot; the id should not change (if it does,
    /// the index is rebuilt for that slot).
    public mutating func mutate(id: EntryID, _ body: (inout Entry) -> Void) {
        guard case .topLevel(let i) = index[id], subEntries.indices.contains(i) else {
            return
        }
        let oldId = subEntries[i].id
        body(&subEntries[i])
        let newId = subEntries[i].id
        if newId != oldId {
            index.removeValue(forKey: oldId)
            index[newId] = .topLevel(i)
        }
        // The closure may have replaced the AgentEntry's subEntries
        // wholesale — rebuild the sub-index for this slot's children.
        reindexAgentSubs(at: i)
    }

    /// Mutate a sub-entry in place. The closure receives the
    /// ``AgentEntry/SubEntry`` value; the implementation reconstructs
    /// the parent ``AgentEntry`` to write the change back (all
    /// `AgentEntry` stored properties are `let`).
    public mutating func mutateSubEntry(id: EntryID, _ body: (inout AgentEntry.SubEntry) -> Void) {
        guard case .agentSub(let parentId, let subIdx) = index[id],
              case .topLevel(let i) = index[parentId],
              subEntries.indices.contains(i),
              case .agent(let agent) = subEntries[i],
              agent.subEntries.indices.contains(subIdx)
        else { return }

        var subs = agent.subEntries
        let oldId = subs[subIdx].id
        body(&subs[subIdx])
        let newId = subs[subIdx].id
        subEntries[i] = .agent(rebuild(agent, subEntries: subs))
        if newId != oldId {
            index.removeValue(forKey: oldId)
            index[newId] = .agentSub(parentAgentId: parentId, subIndex: subIdx)
        }
    }

    // MARK: - Mutations: remove

    /// Remove a top-level entry by id. No-op if `id` is absent or refers
    /// to a sub-entry. Indices of trailing top-level entries shift down
    /// by one; the index is rebuilt for the affected slots.
    public mutating func remove(id: EntryID) {
        guard case .topLevel(let i) = index[id], subEntries.indices.contains(i) else {
            return
        }
        let removed = subEntries.remove(at: i)
        index.removeValue(forKey: removed.id)
        if case .agent(let agent) = removed {
            for sub in agent.subEntries {
                index.removeValue(forKey: sub.id)
            }
        }
        // Shift down the index for trailing top-level entries and their
        // sub-entries.
        for j in i..<subEntries.count {
            let entry = subEntries[j]
            index[entry.id] = .topLevel(j)
            if case .agent(let agent) = entry {
                for (subIdx, sub) in agent.subEntries.enumerated() {
                    index[sub.id] = .agentSub(parentAgentId: entry.id, subIndex: subIdx)
                }
            }
        }
    }

    // MARK: - Branch slicing

    // The branchOff implementation lives in TranscriptRoot+BranchOff.swift.

    // MARK: - Internal helpers

    /// If `entry` is an ``AgentEntry``, record its sub-entries in the
    /// index keyed by `parentIndex`. Otherwise no-op.
    private mutating func indexAgentSubsIfNeeded(of entry: Entry, parentIndex: Int) {
        guard case .agent(let agent) = entry else { return }
        for (subIdx, sub) in agent.subEntries.enumerated() {
            index[sub.id] = .agentSub(parentAgentId: entry.id, subIndex: subIdx)
        }
        _ = parentIndex // future: store on slot if needed
    }

    /// Re-index the sub-entries of the agent at top-level slot `i`. Used
    /// after a top-level mutation that may have rewritten an
    /// ``AgentEntry``'s subEntries.
    private mutating func reindexAgentSubs(at i: Int) {
        guard case .agent(let agent) = subEntries[i] else { return }
        // Drop any stale sub-entry slots that pointed at this parent.
        let parentId = agent.id
        for (key, slot) in index {
            if case .agentSub(let pid, _) = slot, pid == parentId {
                index.removeValue(forKey: key)
            }
        }
        for (subIdx, sub) in agent.subEntries.enumerated() {
            index[sub.id] = .agentSub(parentAgentId: parentId, subIndex: subIdx)
        }
    }

    /// Reconstruct an ``AgentEntry`` with replaced ``AgentEntry/subEntries``.
    /// All other fields carry over verbatim.
    private func rebuild(_ agent: AgentEntry, subEntries newSubs: [AgentEntry.SubEntry]) -> AgentEntry {
        AgentEntry(
            id: agent.id,
            header: agent.header,
            body: agent.body,
            usage: agent.usage,
            stopReason: agent.stopReason,
            perTurnDurationMs: agent.perTurnDurationMs,
            messageCount: agent.messageCount,
            model: agent.model,
            endTime: agent.endTime,
            subEntries: newSubs
        )
    }

    // MARK: - branchOff support (used by the extension)

    /// Internal: read top-level slot index for an id. Used by
    /// ``branchOff(at:link:)``.
    internal func topLevelIndex(of id: EntryID) -> Int? {
        if case .topLevel(let i) = index[id] { return i }
        return nil
    }

    /// Internal: replace a contiguous range of ``subEntries`` with a
    /// single new entry, dropping the old entries' index slots and
    /// recording the new one. Used by ``branchOff(at:link:)``.
    internal mutating func replaceTopLevelRange(_ range: Range<Int>, with entry: Entry) {
        for j in range {
            let removed = subEntries[j]
            index.removeValue(forKey: removed.id)
            if case .agent(let agent) = removed {
                for sub in agent.subEntries {
                    index.removeValue(forKey: sub.id)
                }
            }
        }
        subEntries.replaceSubrange(range, with: [entry])
        // Re-index from the start of the replaced range onward — every
        // index past `range.lowerBound` may have shifted.
        for j in range.lowerBound..<subEntries.count {
            let e = subEntries[j]
            index[e.id] = .topLevel(j)
            if case .agent(let agent) = e {
                for (subIdx, sub) in agent.subEntries.enumerated() {
                    index[sub.id] = .agentSub(parentAgentId: e.id, subIndex: subIdx)
                }
            }
        }
    }
}
