import Foundation

/// Result of walking the rewind tree of a Claude Code session JSONL file.
/// `ClaudeTranscriptBuilder` consumes this to filter the entry stream
/// to the active branch and emit branch-link entries at each divergence
/// point.
///
/// "Active branch" = the chain of `user`/`assistant`/`system`/`attachment`
/// UUIDs that walk back from the latest `last-prompt` marker's
/// `leafUuid` to the conversation root. Anything tree-affiliated but
/// not on this chain is an *abandoned branch* — the user rewound past it.
struct ClaudeBranchResolution: Equatable {
    let activeUUIDs: Set<String>
    /// One entry per abandoned branch, in file order of the branch root.
    let abandonedBranches: [ClaudeAbandonedBranch]
    /// `leafUuid` of the latest `last-prompt` marker, nil when the file
    /// has no marker at all (older sessions, or sessions never rewound).
    /// The active branch also includes tree descendants appended after
    /// that marker, since live responses and post-rewind reroutes can
    /// arrive before Claude writes a newer marker.
    let leafUuid: String?
    /// Convenience: equal to `abandonedBranches.count`.
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
    let entryCount: Int
    /// Truncated preview of the first user-prompt text in the subtree,
    /// for the `↳ Rewind #N — <preview>` row label. nil when the subtree
    /// contains no user prompt with text content.
    let firstPromptPreview: String?
    /// 1-based ordinal in `abandonedBranches`.
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
            // `compact_boundary` lines have `parentUuid: null` (they break
            // the tree at the compact event) but carry `logicalParentUuid`
            // pointing back at the pre-compaction tail. Treat the logical
            // link as the effective parent so branch-walks stitch the
            // active chain across the compact event.
            let effectiveParent = line.parentUuid ?? line.logicalParentUuid
            parentMap[uuid] = effectiveParent
            lineByUuid[uuid] = line
            fileOrderIndex[uuid] = i
        }

        // Latest `last-prompt` marker in file order is the active leaf.
        var leafUuid: String?
        var latestMarkerIndex: Int?
        for (index, line) in lines.enumerated() where line.isLastPromptMarker {
            if let leaf = line.leafUuid { leafUuid = leaf }
            latestMarkerIndex = index
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
            if let latestMarkerIndex, latestMarkerIndex + 1 < lines.count {
                for line in lines[(latestMarkerIndex + 1)...] {
                    guard let uuid = line.uuid,
                          let parent = line.parentUuid,
                          activeUUIDs.contains(parent) else { continue }
                    activeUUIDs.insert(uuid)
                }
            }
            // Parallel tool results are user-role children of their
            // tool-use assistant line. They are semantically part of the
            // active tool call even when sibling tool execution means
            // they are not on the final parent chain to the latest leaf.
            var addedToolResult = true
            while addedToolResult {
                addedToolResult = false
                for line in lines where isToolResultLine(line) {
                    guard let uuid = line.uuid,
                          !activeUUIDs.contains(uuid),
                          let parent = line.parentUuid,
                          activeUUIDs.contains(parent) else { continue }
                    activeUUIDs.insert(uuid)
                    addedToolResult = true
                }
            }
        } else {
            activeUUIDs = Set(parentMap.keys)
            return ClaudeBranchResolution(
                activeUUIDs: activeUUIDs,
                abandonedBranches: [],
                leafUuid: leafUuid
            )
        }

        // Group every non-active UUID by its branch root.
        var membersByBranchRoot: [String: [String]] = [:]
        var divergencePointByBranchRoot: [String: String?] = [:]

        for uuid in parentMap.keys where !activeUUIDs.contains(uuid) {
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
                entryCount: members.count,
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

    private static func isToolResultLine(_ line: ClaudeJSONLLine) -> Bool {
        guard line.type == "user",
              case .blocks(let blocks)? = line.message?.content else { return false }
        return blocks.contains { $0.type == "tool_result" }
    }

    /// First user-prompt text in `members` (in file order), truncated to
    /// `ClaudeRenderConsts.abandonedBranchPreviewMaxChars`. nil when the
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
        let max = ClaudeRenderConsts.abandonedBranchPreviewMaxChars
        if oneLine.count <= max { return oneLine }
        return String(oneLine.prefix(max - 1)) + "…"
    }
}
