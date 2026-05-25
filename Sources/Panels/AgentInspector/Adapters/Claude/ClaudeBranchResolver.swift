import Foundation

/// Result of walking the rewind tree of a Claude Code session JSONL file.
/// `ClaudeChunkBuilder` consumes this to filter the chunk stream to the
/// active branch and emit `BranchLink` chunks at each divergence point.
///
/// "Active branch" = the chain of `user`/`assistant`/`system`/`attachment`
/// UUIDs that walk back from the latest `last-prompt` marker's `leafUuid`
/// to the conversation root. Anything tree-affiliated but not on this
/// chain is an *abandoned branch* — the user rewound past it.
struct ClaudeBranchResolution: Equatable {
    let activeUUIDs: Set<String>
    /// One entry per abandoned branch, in file order of the branch root.
    let abandonedBranches: [ClaudeAbandonedBranch]
    /// `leafUuid` of the latest `last-prompt` marker, nil when the file has
    /// no marker at all (older sessions, or sessions never rewound).
    let leafUuid: String?
    /// Convenience: equal to `abandonedBranches.count`. Used for the
    /// "Rewind N of M" detail-tab title.
    var totalRewinds: Int { abandonedBranches.count }
}

/// One abandoned branch in the rewind tree.
struct ClaudeAbandonedBranch: Equatable {
    /// UUID of the closest ancestor on the active branch — the branch's
    /// "branch point" in tree terms. nil when the branch has no active
    /// ancestor (orphan / corrupt session).
    let divergencePointUuid: String?
    /// First abandoned UUID — child of the divergence point. Identifies
    /// the branch.
    let branchRootUuid: String
    /// Total number of UUIDs in the abandoned subtree (including the root).
    let chunkCount: Int
    /// Truncated preview of the first user-prompt text in the subtree, for
    /// the `↳ Rewind #N — <preview>` row label. nil when the subtree
    /// contains no user prompt with text content.
    let firstPromptPreview: String?
    /// 1-based ordinal in `abandonedBranches`. Stable for use in the
    /// "Rewind N of M" detail-tab title.
    let rewindIndex: Int
    /// Every UUID in the abandoned subtree (including the root). The
    /// builder uses this to filter raw lines into the per-branch
    /// transcript shown in the detail panel.
    let memberUUIDs: Set<String>
}

enum ClaudeBranchResolver {
    /// Resolve the active branch and group abandoned branches given the
    /// raw line stream. Pure value function; safe to call from any thread.
    static func resolve(lines: [ClaudeJSONLLine]) -> ClaudeBranchResolution {
        var parentMap: [String: String?] = [:]
        var lineByUuid: [String: ClaudeJSONLLine] = [:]
        var fileOrderIndex: [String: Int] = [:]

        for (i, line) in lines.enumerated() {
            guard let uuid = line.uuid else { continue }
            parentMap[uuid] = line.parentUuid
            lineByUuid[uuid] = line
            fileOrderIndex[uuid] = i
        }

        // Latest `last-prompt` marker in file order is the active leaf.
        var leafUuid: String?
        for line in lines where line.isLastPromptMarker {
            if let leaf = line.leafUuid { leafUuid = leaf }
        }

        // Walk leaf → root. If the file has no marker, or the marker's
        // leafUuid isn't in the file (corrupt / partial), degrade to
        // "no rewind"; treat every UUID as active.
        var activeUUIDs = Set<String>()
        if let leaf = leafUuid, parentMap[leaf] != nil {
            var cur: String? = leaf
            while let u = cur, !activeUUIDs.contains(u) {
                activeUUIDs.insert(u)
                cur = parentMap[u] ?? nil
            }
        } else {
            activeUUIDs = Set(parentMap.keys)
            return ClaudeBranchResolution(
                activeUUIDs: activeUUIDs,
                abandonedBranches: [],
                leafUuid: leafUuid
            )
        }

        // Group every non-active UUID by its branch root (the first
        // abandoned UUID up the chain whose parent IS on the active branch).
        var membersByBranchRoot: [String: [String]] = [:]
        var divergencePointByBranchRoot: [String: String?] = [:]

        for uuid in parentMap.keys where !activeUUIDs.contains(uuid) {
            // Walk up; remember the last abandoned UUID before hitting an
            // active ancestor.
            var prev = uuid
            var cur: String? = parentMap[uuid] ?? nil
            var divergencePoint: String? = nil
            while let u = cur {
                if activeUUIDs.contains(u) {
                    divergencePoint = u
                    break
                }
                prev = u
                cur = parentMap[u] ?? nil
            }
            let branchRoot = prev
            membersByBranchRoot[branchRoot, default: []].append(uuid)
            if divergencePointByBranchRoot[branchRoot] == nil {
                divergencePointByBranchRoot[branchRoot] = divergencePoint
            }
        }

        // Sort branch roots by file order so the resulting list mirrors
        // the order rewinds happened.
        let sortedRoots = membersByBranchRoot.keys.sorted { a, b in
            (fileOrderIndex[a] ?? 0) < (fileOrderIndex[b] ?? 0)
        }

        var abandoned: [ClaudeAbandonedBranch] = []
        for (idx, root) in sortedRoots.enumerated() {
            let members = membersByBranchRoot[root] ?? []
            let preview = firstPromptPreview(
                memberUUIDs: members,
                lineByUuid: lineByUuid,
                fileOrderIndex: fileOrderIndex
            )
            abandoned.append(ClaudeAbandonedBranch(
                divergencePointUuid: divergencePointByBranchRoot[root] ?? nil,
                branchRootUuid: root,
                chunkCount: members.count,
                firstPromptPreview: preview,
                rewindIndex: idx + 1,
                memberUUIDs: Set(members)
            ))
        }

        return ClaudeBranchResolution(
            activeUUIDs: activeUUIDs,
            abandonedBranches: abandoned,
            leafUuid: leafUuid
        )
    }

    /// First user-prompt text in `members` (in file order), truncated to
    /// `ClaudeBuilderConsts.abandonedBranchPreviewMaxChars`. nil when the
    /// subtree contains no user line with non-empty text.
    private static func firstPromptPreview(
        memberUUIDs: [String],
        lineByUuid: [String: ClaudeJSONLLine],
        fileOrderIndex: [String: Int]
    ) -> String? {
        let sorted = memberUUIDs.sorted { a, b in
            (fileOrderIndex[a] ?? 0) < (fileOrderIndex[b] ?? 0)
        }
        for uuid in sorted {
            guard let line = lineByUuid[uuid], line.type == "user" else { continue }
            // Only treat user lines whose content is plain text. Tool-result
            // user lines (`isMeta == true`) wouldn't make a useful preview.
            if line.isMeta == true { continue }
            guard let content = line.message?.content else { continue }
            switch content {
            case .text(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return truncateForPreview(trimmed)
                }
            case .blocks(let blocks):
                for block in blocks where block.type == "text" {
                    if let t = block.text {
                        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return truncateForPreview(trimmed) }
                    }
                }
            }
        }
        return nil
    }

    private static func truncateForPreview(_ text: String) -> String {
        let oneLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let max = ClaudeBuilderConsts.abandonedBranchPreviewMaxChars
        if oneLine.count <= max { return oneLine }
        return String(oneLine.prefix(max - 1)) + "…"
    }
}
