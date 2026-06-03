import Foundation

/// Identifies `<command-message>` user lines that are **skill**
/// invocations (vs built-in slash commands like `/exit` or `/clear`).
///
/// Discriminator: a skill's `<command-message>` user line is followed
/// in file order by an `isMeta:true` user line whose first text block
/// starts with `"Base directory for this skill:"`. Built-ins have no
/// such follow-up.
///
/// Output is consumed by `UserLineParser` to route skill-shaped slash
/// commands to a User entry (the user-typed prompt content) instead
/// of the `slashCmdInput` meta surface (reserved for built-in
/// session-control commands).
struct ClaudeSkillCommandResolution: Equatable {
    /// UUIDs of `<command-message>` user lines whose immediate
    /// next-in-file-order line is the skill body injection.
    let skillCommandUuids: Set<String>

    init(skillCommandUuids: Set<String>) {
        self.skillCommandUuids = skillCommandUuids
    }
}

enum ClaudeSkillCommandResolver {
    /// Pure value function. Walks `lines` looking for the
    /// `<command-message>` user-line + `isMeta:true` `Base directory
    /// for this skill:` user-line pair.
    static func resolve(lines: [ClaudeJSONLLine]) -> ClaudeSkillCommandResolution {
        var matched: Set<String> = []
        for i in 0..<lines.count {
            let cur = lines[i]
            guard cur.type == "user", let uuid = cur.uuid else { continue }
            guard isCommandMessageUserLine(cur) else { continue }
            guard i + 1 < lines.count else { continue }
            let next = lines[i + 1]
            if isSkillBodyUserLine(next) {
                matched.insert(uuid)
            }
        }
        return ClaudeSkillCommandResolution(skillCommandUuids: matched)
    }

    /// True when `line` is a `<command-message>`-shaped user line.
    /// Local mirror of `UserLineParser.isSlashCommandUserLine` to keep
    /// the resolver self-contained.
    private static func isCommandMessageUserLine(_ line: ClaudeJSONLLine) -> Bool {
        guard let content = line.message?.content else { return false }
        let raw: String
        switch content {
        case .text(let s): raw = s
        case .blocks(let blocks):
            var found: String?
            for b in blocks where b.type == "text" {
                if let t = b.text { found = t; break }
            }
            raw = found ?? ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<command-name>")
            || trimmed.hasPrefix("<command-message>")
    }

    /// True when `line` is the `isMeta:true` skill-body injection
    /// that Claude Code emits after a skill `<command-message>` line.
    private static func isSkillBodyUserLine(_ line: ClaudeJSONLLine) -> Bool {
        guard line.type == "user", line.isMeta == true else { return false }
        guard let content = line.message?.content else { return false }
        switch content {
        case .text(let s):
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("Base directory for this skill:")
        case .blocks(let blocks):
            for b in blocks where b.type == "text" {
                if let t = b.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   t.hasPrefix("Base directory for this skill:") {
                    return true
                }
            }
            return false
        }
    }
}
