import Foundation

/// Parses a tool's `input` JSON value into display strings and
/// optional structured projections (sub-agent type, team metadata).
///
/// Two display projections:
/// - ``summarize(name:input:)`` — single-line summary used as
///   `Header.title` for tool sub-rows. Per-tool heuristics for the
///   common shapes (Read/Edit/Write file_path, Bash command, Grep
///   pattern, Task description, etc.) with a priority-list fallback
///   for unknown tools.
/// - ``format(_:)`` — multi-line key-value dump used as the inline
///   "Tool input" body section. Keys sorted; long values truncated.
///
/// Three structured projections, all `Task`-tool-only:
/// - ``subagentType(name:input:)`` → `input.subagent_type` if present.
/// - ``teamMemberName(name:input:)`` → `input.name`.
/// - ``teamName(name:input:)`` → `input.team_name`.
enum ToolInputParser {

    static func summarize(name: String, input: ClaudeJSONValue?) -> String {
        guard let input else { return "" }
        guard case .object(let obj) = input else { return input.displayString }

        switch name {
        case "Read", "Edit", "Write", "MultiEdit":
            if case .string(let path)? = obj["file_path"] { return path }
        case "Bash":
            if case .string(let cmd)? = obj["command"] {
                return truncated(cmd, max: ClaudeRenderConsts.toolSummaryMaxChars)
            }
        case "Grep", "Glob":
            if case .string(let pat)? = obj["pattern"] { return pat }
        case "Task":
            if case .string(let desc)? = obj["description"] { return desc }
            if case .string(let prompt)? = obj["prompt"] {
                return truncated(prompt, max: ClaudeRenderConsts.toolSummaryMaxChars)
            }
        case "WebFetch", "WebSearch":
            if case .string(let url)? = obj["url"] ?? obj["query"] { return url }
        default:
            break
        }
        // Priority-list fallback for unhandled tools (including MCP).
        // Tries the most-likely-meaningful keys before falling back to
        // the alphabetic-first key=value dump.
        let preferred = ["url", "path", "file_path", "query", "command",
                         "name", "id", "skill", "key"]
        for key in preferred {
            if case .string(let v)? = obj[key] {
                return truncated(v, max: ClaudeRenderConsts.toolSummaryMaxChars)
            }
        }
        return obj.map { "\($0.key)=\($0.value.displayString)" }.sorted().first ?? ""
    }

    static func format(_ input: ClaudeJSONValue?) -> String {
        guard let input else { return "" }
        guard case .object(let obj) = input else { return input.displayString }
        let keys = obj.keys.sorted()
        var lines: [String] = []
        for key in keys {
            guard let value = obj[key] else { continue }
            let rendered: String
            switch value {
            case .string(let s):
                rendered = truncated(s, max: ClaudeRenderConsts.flattenedResultMaxChars)
            case .null, .bool, .int, .double:
                rendered = value.displayString
            case .array, .object:
                rendered = truncated(
                    value.displayString,
                    max: ClaudeRenderConsts.toolInputValueMaxChars
                )
            }
            lines.append("\(key): \(rendered)")
        }
        return lines.joined(separator: "\n")
    }

    static func subagentType(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["subagent_type"] else { return nil }
        return s
    }

    static func teamMemberName(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["name"] else { return nil }
        return s
    }

    static func teamName(name: String, input: ClaudeJSONValue?) -> String? {
        guard name == "Task" else { return nil }
        guard case .object(let obj)? = input,
              case .string(let s)? = obj["team_name"] else { return nil }
        return s
    }

    /// Hard length cap with `…` ellipsis. Used for inline tool-input
    /// JSON rendering where unbounded object/array dumps would blow up
    /// row height. Distinct concern from user-prompt preview, which
    /// dynamically truncates at the view layer via
    /// `.truncationMode(.tail)`.
    static func truncated(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
