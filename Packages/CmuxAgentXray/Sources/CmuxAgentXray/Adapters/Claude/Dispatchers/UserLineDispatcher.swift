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
    static func parse(_ line: ClaudeJSONLLine) -> ClaudeLineRouting {
        // Compact summary (older flow) → CompactEntry.
        if line.isCompactSummary == true {
            return .render(.compact)
        }
        // Skill-shaped slash command — render as UserEntry carrying the
        // typed `/<cmd> [args]`. Discriminator: skills emit
        // `<command-message>` first, built-ins emit `<command-name>`
        // first. Build path lives in the transcript builder.
        if isSkillShaped(line) {
            return .render(.user)
        }
        // isMeta=true user lines route by content classification. Newer
        // Claude Code emits slash-command-input user lines with
        // `isMeta: null` — peek at the content prefix and route those
        // through the same meta classifier.
        if line.isMeta == true || isSlashCommandUserLine(line) {
            return routingForMetaUser(line)
        }
        return .render(.user)
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
        case .slashCommandInput(let name, let args):
            return .renderSpecial(.slashCmdInput(name: name, args: args))
        case .slashCommandOutput(let body, let isStderr):
            return .renderSpecial(.slashCmdOutput(body: body, isStderr: isStderr))
        case .systemReminder(let body):
            return .renderSpecial(.systemReminder(body: body))
        case .skillInvocation(let name, let basePath, let body):
            return .renderSpecial(.skill(name: name, basePath: basePath, body: body))
        case .contextUsage(let body):
            return .renderSpecial(.contextUsage(body: body))
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

    /// True when `line` is a skill invocation (vs a built-in slash
    /// command like `/exit` or `/clear`).
    ///
    /// Discriminator: skills emit `<command-message>` first (flush-left);
    /// built-ins emit `<command-name>` first. Single-line check —
    /// supersedes the prior next-line lookup that required an
    /// `isMeta:true` `"Base directory for this skill:"` follow-up,
    /// which missed plugin-shaped skills (e.g. `/simplify`,
    /// `/claude-hud:configure`) whose metadata doesn't include it.
    private static func isSkillShaped(_ line: ClaudeJSONLLine) -> Bool {
        guard line.type == "user" else { return false }
        let trimmed = (line.message?.content?.firstText() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<command-message>")
    }
}
