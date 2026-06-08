public import Foundation

/// The transcript document — a flat collection of top-level ``Entry``
/// values plus a flat ``EntryID`` → path index for O(depth) lookups at
/// any nesting depth. Container variants of `Entry` (`.agent`,
/// `.synthesized(.branchLink)`) carry their own `subEntries: [Entry]`
/// arrays; the recursion lives in the mutating helpers on this type
/// rather than as a nested `Transcript` field on every container.
///
/// **Mutation API.** Three operations cover everything the streaming
/// dispatcher needs:
///
/// - ``append(parent:entry:)`` — `parent: nil` for top-level; pass a
///   container entry's id to append into its `subEntries`.
/// - ``mutate(id:_:)`` — in-place `inout` mutation at any depth via
///   the `_modify` accessor chain.
/// - ``slice(from:length:replacingWith:)`` — the unified slice
///   operation. Subsumes both removal (`replacingWith: nil`) and the
///   abandoned-branch fold (`replacingWith: .synthesized(link)`).
///   ``branchOff(at:link:)`` is a thin wrapper.
///
/// Reads are ``entry(id:)`` (any depth) and ``entries`` (top-level
/// projection — what the panel renders).
///
/// **Index aliasing (post-G6).** ``index`` carries two kinds of rows:
/// real entries (written by ``append``) and **aliases** (written by
/// ``registerAlias(lineUuid:path:)``). Aliases let JSONL line uuids
/// that don't themselves produce a transcript entry — chained
/// assistant lines whose blocks fold into an existing AgentEntry,
/// `tool_result` user lines that mutate a ToolEntry, `turn_duration`
/// system lines, skipped decorator attachments — point at the
/// containing entry's path so future children resolve in O(1) without
/// re-walking the raw JSONL chain. Aliases share the same key space
/// as real entries (EntryID), and ``slice``'s post-pass drops or
/// shifts aliases identically to real-entry rows.
///
/// **The `internal(set) var subEntries` unlock.** ``AgentEntry`` and
/// ``SynthesizedEntry`` declare `subEntries` as `internal(set) var`,
/// and ``Entry/subEntries`` is a settable computed property that
/// case-rebuilds for container variants. Together they make
/// `&entries[head].subEntries` a writeable lvalue. Swift's `_modify`
/// accessor composes the chain through nested arrays, so the
/// recursive helpers (`doAppend` / `doMutate` / `doSlice`) descend
/// without copy-extract-repack.
///
/// **Slice scope (post-G6).** Production callers slice top-level only
/// — both tail (``branchOff`` slices `divIdx + 1 ..< entries.count`)
/// and non-tail (FIFO consumption slices a single `.pending` UserEntry
/// by id, length=1, regardless of position). The general algorithm
/// in ``slice(from:length:replacingWith:)`` supports nested slices,
/// kept as a safety net for future containers; no production caller
/// exercises that path today.
///
/// Also: ``mutate(id:_:)`` closures must not change `entry.id`. The
/// implementation does NOT swap index keys — a DEBUG assert catches
/// any future closure that violates the contract.
public struct Transcript: Sendable, Equatable {

    /// Live top-level entry array. Reads are cheap. Writes go through
    /// the mutating methods so the ``index`` stays in sync.
    public private(set) var entries: [Entry] = []

    /// `EntryID` → full path from the root entries array. `[i]` means
    /// top-level slot `i`; `[i, j]` means top-level `i`'s `subEntries`
    /// slot `j`; etc.
    private var index: [EntryID: [Int]] = [:]

    public init() {}

    // MARK: - Reads

    /// Look up an entry by id at any depth. Returns nil if absent.
    public func entry(id: EntryID) -> Entry? {
        guard let path = index[id] else { return nil }
        return entryAt(path)
    }

    /// Look up the full path of an entry by id. Returns nil if absent.
    /// Internal — used by the Phase G dispatcher to find the
    /// divergence point's top-level slot at rewind time.
    internal func path(of id: EntryID) -> [Int]? {
        return index[id]
    }

    /// Register an alias mapping `lineUuid → path`. Used by the
    /// streaming dispatcher when a JSONL line doesn't itself produce
    /// an entry whose id equals `EntryID.fromJSONL(lineUuid)`:
    ///
    /// - Chained assistant lines whose blocks fold into an existing
    ///   AgentEntry (the line uuid is not an entry id; the AgentEntry's
    ///   id is the *first* assistant line of the turn).
    /// - `tool_result` user lines that mutate a ToolEntry — the line
    ///   itself disappears, but children chain off its uuid.
    /// - `system.subtype: turn_duration` lines that mutate an
    ///   AgentEntry.
    /// - Skipped decorator lines (`progress`, `attachment/task_reminder`,
    ///   etc.) that have to act as transparent forwarders so children
    ///   chaining off them resolve to the correct ancestor.
    ///
    /// `path` is the containing entry's path (typically the parent's
    /// resolved path). Aliases share the same key space as real
    /// entries and are dropped or shifted by ``slice``'s post-pass
    /// uniformly with real-entry rows.
    ///
    /// No-op if `lineUuid` is already in `index` (real append wins).
    internal mutating func registerAlias(lineUuid: EntryID, path: [Int]) {
        if index[lineUuid] != nil { return }
        index[lineUuid] = path
    }

    /// Read the entry at the given path. Returns nil for an invalid
    /// path. Internal — callers use ``entry(id:)``.
    private func entryAt(_ path: [Int]) -> Entry? {
        guard let first = path.first, entries.indices.contains(first) else {
            return nil
        }
        var current = entries[first]
        for idx in path.dropFirst() {
            let kids = current.subEntries
            guard kids.indices.contains(idx) else { return nil }
            current = kids[idx]
        }
        return current
    }

    // MARK: - Mutations: append

    /// Append `entry` under `parent` (or at the top level if `parent`
    /// is nil). The parent must already be in the tree; otherwise the
    /// append is a no-op (DEBUG assert).
    ///
    /// In DEBUG, top-level appends assert that `entry` is not a
    /// `.text` / `.tool` case (those only appear nested inside a
    /// container — see ``Entry`` doc).
    public mutating func append(parent: EntryID?, entry: Entry) {
        if parent == nil {
            assert({
                if case .text = entry { return false }
                if case .tool = entry { return false }
                return true
            }(),
            "Transcript.append: top-level append received \(entry.id.stableString) which is .text/.tool — those cases must appear nested only.")
        }
        // path = parent's path (empty for top-level).
        let path: [Int] = parent.flatMap { index[$0] } ?? []
        if let parentId = parent, index[parentId] == nil {
            assertionFailure("Transcript.append: parent \(parentId.stableString) not in tree")
            return
        }
        let slot = Self.doAppend(&entries, at: path, entry: entry)
        // Streaming-builder appends are always leaves (no pre-built
        // subEntries on the appended value), so a single index write
        // is sufficient — no recursive subtree walk.
        index[entry.id] = path + [slot]
    }

    private static func doAppend(_ entries: inout [Entry], at path: [Int], entry: Entry) -> Int {
        if path.isEmpty {
            entries.append(entry)
            return entries.count - 1
        }
        let head = path[0]
        return doAppend(&entries[head].subEntries,
                        at: Array(path.dropFirst()),
                        entry: entry)
    }

    // MARK: - Mutations: mutate

    /// Mutate the entry with `id` in place. The closure receives the
    /// current value as `inout`; any field write is propagated to the
    /// tree via the `_modify` accessor chain on ``Entry/subEntries``.
    ///
    /// **Contract** (DEBUG-asserted): the closure must not change
    /// `entry.id`. No production caller does this — the index keys on
    /// id, so a key change without an explicit re-key path would
    /// invalidate the index.
    public mutating func mutate(id: EntryID, _ body: (inout Entry) -> Void) {
        guard let path = index[id] else { return }
        Self.doMutate(&entries, at: path, body)
        assert(entryAt(path)?.id == id,
               "Transcript.mutate: closure changed entry.id from \(id.stableString) — not supported.")
    }

    /// Recursive descent that bottoms out at the target entry and
    /// invokes `body(&entries[head])`. The recursion threads through
    /// `&entries[head].subEntries` — a writeable lvalue thanks to
    /// `Entry.subEntries`'s settable accessor + `internal(set) var`
    /// on ``AgentEntry/subEntries`` and
    /// ``SynthesizedEntry/subEntries``. Without that lvalue chain, we
    /// would need the pre-G1.6 copy-extract-repack helpers
    /// (`withSubEntries` etc.). With it, this is three lines.
    private static func doMutate(_ entries: inout [Entry],
                                 at path: [Int],
                                 _ body: (inout Entry) -> Void) {
        let head = path[0]
        if path.count == 1 {
            body(&entries[head])
        } else {
            doMutate(&entries[head].subEntries,
                     at: Array(path.dropFirst()),
                     body)
        }
    }

    // MARK: - Mutations: slice

    /// Slice `length` consecutive entries starting at `id` out of the
    /// tree. If `replacingWith` is non-nil, the replacement entry is
    /// inserted at the slice site (used by ``branchOff(at:link:)`` to
    /// drop a synthesized branch link in place of the abandoned tail).
    ///
    /// **Algorithm.**
    ///
    /// 1. Resolve `id` to its full path via the index. The path is
    ///    `parentPath + [startIdx]` — the slice happens in the array
    ///    addressed by `parentPath`.
    /// 2. Recursive descent (``doSlice``) consumes the path, clamps
    ///    `length` to the available range, calls
    ///    `entries.replaceSubrange(startIdx..<endIdx, with: …)` at the
    ///    base case, and returns the **actual** count removed. Through
    ///    the `_modify` chain this writes back to the root.
    /// 3. Flat post-pass over the index map applies two rules to every
    ///    entry whose path starts with `parentPath`:
    ///    - **Drop** ids whose `path[depth] ∈ [startIdx, startIdx+actualLength)`
    ///      — they were in the sliced range (or descendants of one)
    ///      and are gone from the array.
    ///    - **Shift** ids whose `path[depth] ≥ startIdx + actualLength`
    ///      by `(insertCount - actualLength)` — they survived but
    ///      their slot moved left.
    /// 4. If a replacement was inserted, ``registerSubtree(_:at:)``
    ///    walks it once to register its id at `parentPath + [startIdx]`
    ///    and any descendants at the corresponding nested paths.
    ///    For ``branchOff``, this re-paths the abandoned tail's
    ///    entries — which the caller folded into `link.subEntries` —
    ///    from their old top-level paths to nested paths under the link.
    ///
    /// Aliases registered via ``registerAlias(lineUuid:path:)`` share
    /// `index`'s key space and are dropped/shifted identically here.
    public mutating func slice(from id: EntryID, length: Int, replacingWith: Entry?) {
        guard let path = index[id], length > 0 else { return }

        let actualLength = Self.doSlice(&entries, at: path, length: length,
                                        replacement: replacingWith)
        guard actualLength > 0 else { return }

        // path = parent's path + [startIdx]. Peel for the post-pass.
        let depth = path.count - 1
        let startIdx = path.last!
        let removeRange = startIdx..<(startIdx + actualLength)
        let shift = (replacingWith == nil ? 0 : 1) - actualLength    // ≤ 0

        // Snapshot keys explicitly — iterating a Dictionary while
        // mutating its values is safe in Swift but reads as if it
        // shouldn't be. Inner prefix comparison is elementwise to
        // avoid a fresh `Array` allocation per index key. For
        // top-level slices (`depth == 0`) the inner loop has zero
        // iterations and `prefixMatches` stays true — fast path
        // automatic.
        for key in Array(index.keys) {
            guard let P = index[key], P.count > depth else { continue }
            var prefixMatches = true
            for i in 0..<depth where P[i] != path[i] {
                prefixMatches = false
                break
            }
            guard prefixMatches else { continue }
            let pos = P[depth]
            if removeRange.contains(pos) {
                index.removeValue(forKey: key)              // dropped — sliced range
            } else if pos >= startIdx + actualLength {
                var Q = P; Q[depth] = pos + shift            // shifted — past the slice
                index[key] = Q
            }
            // pos < startIdx → untouched
        }
        if let replacement = replacingWith {
            let prefix = Array(path.prefix(depth))
            registerSubtree(replacement, at: prefix + [startIdx])
        }
    }

    /// Recursive descent that bottoms out at `path`'s base case and
    /// `replaceSubrange`s the slice. Returns the **actual** number of
    /// entries removed (may be less than `length` if `length` exceeded
    /// the available range — the clamp prevents `replaceSubrange` from
    /// trapping). Used by ``slice`` to compute the correct shift in
    /// the post-pass index update.
    @discardableResult
    private static func doSlice(_ entries: inout [Entry], at path: [Int],
                                length: Int, replacement: Entry?) -> Int {
        let head = path[0]
        if path.count == 1 {
            let arr: [Entry] = replacement.map { [$0] } ?? []
            let endIdx = min(head + length, entries.count)
            guard head < endIdx else { return 0 }
            entries.replaceSubrange(head..<endIdx, with: arr)
            return endIdx - head
        } else {
            return doSlice(&entries[head].subEntries,
                           at: Array(path.dropFirst()),
                           length: length, replacement: replacement)
        }
    }

    /// Register `entry.id` at `path` and recursively register every
    /// descendant at the corresponding nested path. Overwrites any
    /// pre-existing index entry for the same id (used by `slice` to
    /// re-path abandoned-tail entries from their old top-level paths
    /// to their new nested paths under a `branchLink`).
    private mutating func registerSubtree(_ entry: Entry, at path: [Int]) {
        index[entry.id] = path
        for (i, child) in entry.subEntries.enumerated() {
            registerSubtree(child, at: path + [i])
        }
    }

    // MARK: - branchOff (thin wrapper over slice)

    /// Slice the tail past `divergencePoint` into a synthesized branch
    /// link, replacing those entries with `[link]` at the divergence
    /// point's successor slot.
    ///
    /// **Caller contract.** Before calling, the caller has:
    /// 1. Found the abandoned range (top-level entries past
    ///    `divergencePoint` that are NOT on the new active branch).
    /// 2. Captured `branchRootUuid = abandonedRange.first.id` (the
    ///    first abandoned entry's id — **NOT** the divergence point).
    /// 3. Built the link with id
    ///    `.derived(parent: branchRootUuid, kind: "branchLink")` and
    ///    set the abandoned entries on the link's
    ///    ``SynthesizedEntry/subEntries`` field.
    ///
    /// Deriving the link id from `branchRootUuid` (not from the
    /// divergence point) is what makes link ids unique across multiple
    /// rewinds to the same parent — each abandoned branch's first
    /// entry has its own JSONL uuid.
    ///
    /// **Behavior.**
    /// - If `divergencePoint` is not at top-level, no-op.
    /// - If the abandoned range is empty (no entries past divergence),
    ///   no-op.
    /// - Otherwise: replaces `entries[(divIdx+1)..<count]` with
    ///   `[.synthesized(link)]` via ``slice(from:length:replacingWith:)``.
    ///   The displaced entries' index slots are re-pathed from their
    ///   old top-level paths (`[k]`) to their new nested paths under
    ///   the link (`[divIdx+1, k - (divIdx+1)]`).
    /// - If the displaced range contained a prior branch link, that
    ///   prior link is captured inside the new link's `subEntries`
    ///   verbatim (caller built it that way) — nested rewinds work
    ///   for free without folding logic.
    public mutating func branchOff(at divergencePoint: EntryID, link: SynthesizedEntry) {
        guard let divPath = index[divergencePoint], divPath.count == 1 else { return }
        let firstAbandonedSlot = divPath[0] + 1
        guard firstAbandonedSlot < entries.count else { return }
        let firstAbandoned = entries[firstAbandonedSlot]
        let length = entries.count - firstAbandonedSlot
        slice(from: firstAbandoned.id, length: length, replacingWith: .synthesized(link))
    }
}
