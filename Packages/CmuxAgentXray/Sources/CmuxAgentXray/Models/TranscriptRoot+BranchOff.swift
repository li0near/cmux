public import Foundation

extension TranscriptRoot {

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
    ///    embedded the abandoned entries in its
    ///    `body.sections[.subentries(...)]`.
    ///
    /// Deriving the link id from `branchRootUuid` (not from the
    /// divergence point) is what makes link ids unique across multiple
    /// rewinds to the same parent — each abandoned branch's first entry
    /// has its own JSONL uuid.
    ///
    /// **Behavior.**
    /// - If `divergencePoint` is not in the top-level index, no-op.
    /// - If the abandoned range is empty (no entries past divergence),
    ///   no-op.
    /// - Otherwise: replaces `subEntries[(divIdx+1)..<count]` with
    ///   `[link]`. The displaced entries' index slots are dropped
    ///   (G1's index does not track archived entries — G4 will extend
    ///   the index if it needs index-driven mutation through archived
    ///   branches).
    /// - If the displaced range contained a prior branch link, that
    ///   prior link is captured inside the new link's body verbatim
    ///   (caller built it that way) — nested rewinds work for free
    ///   without folding logic.
    public mutating func branchOff(at divergencePoint: EntryID, link: SynthesizedEntry) {
        guard let divIdx = topLevelIndex(of: divergencePoint) else { return }
        let start = divIdx + 1
        let end = subEntries.count
        guard start < end else { return }
        replaceTopLevelRange(start..<end, with: .synthesized(link))
    }
}
