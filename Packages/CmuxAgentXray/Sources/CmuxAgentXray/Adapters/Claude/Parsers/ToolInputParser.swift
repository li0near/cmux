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

    /// Extract `file_path` from the tool's input JSON for tools that
    /// carry it (Read / Edit / Write / MultiEdit). Returns nil for
    /// any other tool name or if the input doesn't have a string
    /// `file_path`. Used by the detail-tab resolver to pick a
    /// `.code(language:)` ContentType from the file's extension.
    static func filePath(name: String, input: ClaudeJSONValue?) -> String? {
        guard ["Read", "Edit", "Write", "MultiEdit"].contains(name) else {
            return nil
        }
        guard let input, case .object(let obj) = input else { return nil }
        guard case .string(let path)? = obj["file_path"] else { return nil }
        return path
    }

    /// Extract `(old_string, new_string)` from the tool input for
    /// `Edit` and the first edit in `MultiEdit.edits[]`. Returns nil
    /// for tools that don't carry edit shape. The resolver synthesizes
    /// a unified-diff body from these so the detail tab opens with
    /// `.diff` content (cmux's `FilePreviewPanel` + highlight.js diff
    /// mode color the +/- lines).
    static func editStrings(
        name: String,
        input: ClaudeJSONValue?
    ) -> (old: String, new: String)? {
        guard let input, case .object(let obj) = input else { return nil }
        switch name {
        case "Edit":
            guard case .string(let oldStr)? = obj["old_string"],
                  case .string(let newStr)? = obj["new_string"] else { return nil }
            return (oldStr, newStr)
        case "MultiEdit":
            guard case .array(let edits)? = obj["edits"],
                  let first = edits.first,
                  case .object(let e) = first,
                  case .string(let oldStr)? = e["old_string"],
                  case .string(let newStr)? = e["new_string"] else { return nil }
            return (oldStr, newStr)
        default:
            return nil
        }
    }

    /// Convert an `Edit` / `MultiEdit` tool input into a list of
    /// diff-styled body sections — one `.diffRemoved` + `.diffAdded`
    /// pair per edit, in arrival order — so inline rendering shows
    /// colored old/new blocks and the detail-tab resolver can emit a
    /// unified-diff materialization without re-reading the tool input.
    ///
    /// Shape for `Edit`: `[.text([old_string], .diffRemoved),
    /// .text([new_string], .diffAdded)]`.
    ///
    /// Shape for `MultiEdit`: every entry in `input.edits[]` flattened
    /// into the same removed/added pair, in arrival order. Replaces
    /// the old `editStrings(...)` helper, which silently kept only the
    /// first edit.
    ///
    /// Returns `nil` for any other tool name, or when the input doesn't
    /// carry the expected `old_string` / `new_string` strings.
    static func diffSections(
        name: String,
        input: ClaudeJSONValue?
    ) -> [Section]? {
        guard let input, case .object(let obj) = input else { return nil }
        switch name {
        case "Edit":
            guard case .string(let oldStr)? = obj["old_string"],
                  case .string(let newStr)? = obj["new_string"] else { return nil }
            return [
                .text([oldStr], style: .diffRemoved),
                .text([newStr], style: .diffAdded)
            ]
        case "MultiEdit":
            guard case .array(let edits)? = obj["edits"], !edits.isEmpty else {
                return nil
            }
            var sections: [Section] = []
            for edit in edits {
                guard case .object(let e) = edit,
                      case .string(let oldStr)? = e["old_string"],
                      case .string(let newStr)? = e["new_string"] else { continue }
                sections.append(.text([oldStr], style: .diffRemoved))
                sections.append(.text([newStr], style: .diffAdded))
            }
            return sections.isEmpty ? nil : sections
        default:
            return nil
        }
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
