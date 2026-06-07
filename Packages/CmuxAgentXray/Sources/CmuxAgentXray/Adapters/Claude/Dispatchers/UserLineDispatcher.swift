import Foundation

/// Per-type parser for `type: "user"` JSONL lines.
///
/// Branches on `isCompactSummary`, `isMeta`, and string-content prefixes
/// (slash-command wrappers) to decide whether the line is a real
/// user-authored prompt, the legacy compact-summary marker, an
/// `isMeta=true` injection (skill body, system reminder, command-output
/// wrapper, etc.), or — under the newer slash-command shape — an
/// `isMeta=null` user line whose content opens with `<command-message>`
/// / `<command-name>` and routes through the same meta classifier.
enum UserLineDispatcher {
    static func parse(
        _ line: ClaudeJSONLLine,
        activeBranch: Set<String>,
        activeBranchAvailable: Bool,
        skillCommandUuids: Set<String> = []
    ) -> ClaudeLineRouting {
        // Compact summary (older flow) → CompactEntry.
        if line.isCompactSummary == true {
            return ClaudeLineDispatcher.branchGated(
                line, kind: .render(.compact),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        }
        // Skill-shaped slash command — render as UserEntry carrying the
        // typed `/<cmd> [args]`. Build path lives in the transcript
        // builder.
        if let uuid = line.uuid, skillCommandUuids.contains(uuid) {
            return ClaudeLineDispatcher.branchGated(
                line, kind: .render(.user),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        }
        // isMeta=true user lines route by content classification. Newer
        // Claude Code emits slash-command-input user lines with
        // `isMeta: null` — peek at the content prefix and route those
        // through the same meta classifier.
        if line.isMeta == true || isSlashCommandUserLine(line) {
            return ClaudeLineDispatcher.branchGated(
                line, kind: routingForMetaUser(line),
                activeBranch: activeBranch,
                activeBranchAvailable: activeBranchAvailable
            )
        }
        return ClaudeLineDispatcher.branchGated(
            line, kind: .render(.user),
            activeBranch: activeBranch,
            activeBranchAvailable: activeBranchAvailable
        )
    }

    /// Decide the routing for an `isMeta=true` user line based on the
    /// classification of its inner text.
    ///
    /// `tool_result` blocks ride on `isMeta=true` user lines too — those
    /// must keep folding into the pending `AgentEntry` so the parent
    /// tool call gets its result attached.
    private static func routingForMetaUser(_ line: ClaudeJSONLLine) -> ClaudeLineRouting {
        if let content = line.message?.content,
           case .blocks(let blocks) = content,
           blocks.contains(where: { $0.type == "tool_result" }) {
            return .render(.agent)
        }
        let raw = line.message?.content?.firstText() ?? ""
        switch ClaudeContentDetector.classify(raw) {
        case .slashCommandInput:    return .renderSpecial(.slashCmdInput)
        case .slashCommandOutput:   return .renderSpecial(.slashCmdOutput)
        case .systemReminder:       return .renderSpecial(.systemReminder)
        case .skillInvocation:      return .renderSpecial(.skill)
        case .contextUsage:         return .renderSpecial(.contextUsage)
        // Resume markers and command-caveat wrappers carry no
        // user-actionable content; drop both.
        case .continueResume:       return .skip
        case .localCommandCaveat:   return .skip
        case .unknown:              return .renderSpecial(.unknownMeta)
        }
    }

    /// True when `line` is a `user`-typed line whose content opens with
    /// the slash-command-input wrapper (`<command-message>` or
    /// `<command-name>`). Newer Claude Code emits these with
    /// `isMeta: null` instead of the older `isMeta: true`.
    private static func isSlashCommandUserLine(_ line: ClaudeJSONLLine) -> Bool {
        let trimmed = (line.message?.content?.firstText() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<command-name>")
            || trimmed.hasPrefix("<command-message>")
    }
}
