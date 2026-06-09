import Foundation

/// Claude-Code-specific side-channel envelope attached to a JSONL line
/// alongside the standard Anthropic Messages API `tool_result.content`.
/// Distinct from ``ClaudeContentBlock/toolResultContent`` (which is the
/// content array inside a `tool_result` block); this envelope carries
/// edit metadata that Claude Code computes at apply time and persists
/// for session-resume parity.
///
/// The wire JSON field is `toolUseResult` and is **polymorphic** across
/// tool kinds:
/// - **Edit / MultiEdit / Write** → an object with this struct's shape.
/// - **Bash error** → a bare `String` (e.g. `"Error: Exit code 1\n…"`).
/// - **Playwright** and similar → a `JSON array` of text-block objects.
/// - **Task / sub-agent** → an object with a different shape entirely
///   (`status` / `prompt` / `agentId` / etc.).
///
/// Because of this polymorphism, ``ClaudeJSONLLine/toolUseResult`` is
/// typed as `ClaudeJSONValue?` (matching the precedent
/// ``ClaudeContentBlock/toolResultContent``). Callers project to this
/// typed envelope only when they know the tool produces it (Edit-shape
/// tools) via ``from(_:)``, which returns nil for non-object shapes
/// rather than throwing — Bash errors and Playwright results pass
/// through untouched.
struct ClaudeToolUseResult: Decodable, Equatable {
    /// Absolute path of the file that was edited.
    let filePath: String?
    /// `Edit.input.old_string` / `MultiEdit.edits[i].old_string`. Carried
    /// for redundancy with the structured patch.
    let oldString: String?
    /// `Edit.input.new_string` / `MultiEdit.edits[i].new_string`.
    let newString: String?
    /// The full file content captured at edit time. The disk file moves
    /// on after subsequent edits or external changes — this is the only
    /// reliable source of pre-edit context outside the structured
    /// patch's hunk window.
    let originalFile: String?
    /// Pre-computed hunks. Empty for `Write` with `type: "create"`
    /// (no diff for new files). Each ``DiffHunk`` is the rendering
    /// shape directly — the wire JSON and the model type are the same
    /// struct (see ``DiffHunk`` for the layering rationale).
    let structuredPatch: [DiffHunk]?
    /// True when the user manually edited the diff in the Claude Code
    /// approval UI before applying. cmux can surface this as a hint.
    let userModified: Bool?
    /// `Edit.input.replace_all` / `MultiEdit.edits[i].replace_all`. True
    /// when the edit is intended to replace every occurrence rather than
    /// the first.
    let replaceAll: Bool?
    /// `Write` only — `"create"` for a new file, `"update"` for an
    /// overwrite. Distinguishes the two diff shapes (empty patch vs.
    /// real hunks). Absent on Edit / MultiEdit lines.
    let type: String?

    /// Project a polymorphic ``ClaudeJSONValue`` to a typed envelope by
    /// hand-walking the object dictionary. Returns nil for anything
    /// that isn't a JSON object (Bash error strings, Playwright
    /// text-block arrays, null) — the caller falls through to the
    /// standard `tool_result.content` path. ``ClaudeJSONValue`` is
    /// `Decodable`-only (no `Encodable` conformance for a roundtrip),
    /// so this projection is explicit per-field rather than a
    /// JSONEncoder/Decoder roundtrip.
    static func from(_ value: ClaudeJSONValue?) -> ClaudeToolUseResult? {
        guard case .object(let obj)? = value else { return nil }
        return ClaudeToolUseResult(
            filePath: stringValue(obj["filePath"]),
            oldString: stringValue(obj["oldString"]),
            newString: stringValue(obj["newString"]),
            originalFile: stringValue(obj["originalFile"]),
            structuredPatch: structuredPatchArray(obj["structuredPatch"]),
            userModified: boolValue(obj["userModified"]),
            replaceAll: boolValue(obj["replaceAll"]),
            type: stringValue(obj["type"])
        )
    }

    private static func stringValue(_ value: ClaudeJSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private static func boolValue(_ value: ClaudeJSONValue?) -> Bool? {
        if case .bool(let b)? = value { return b }
        return nil
    }

    private static func intValue(_ value: ClaudeJSONValue?) -> Int? {
        if case .int(let v)? = value { return v }
        if case .double(let d)? = value { return Int(d) }
        return nil
    }

    private static func structuredPatchArray(_ value: ClaudeJSONValue?) -> [DiffHunk]? {
        guard case .array(let arr)? = value else { return nil }
        var hunks: [DiffHunk] = []
        hunks.reserveCapacity(arr.count)
        for entry in arr {
            guard case .object(let h) = entry,
                  let oldStart = intValue(h["oldStart"]),
                  let oldLines = intValue(h["oldLines"]),
                  let newStart = intValue(h["newStart"]),
                  let newLines = intValue(h["newLines"]),
                  case .array(let lineValues)? = h["lines"] else {
                continue
            }
            let lines: [String] = lineValues.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
            hunks.append(DiffHunk(
                oldStart: oldStart,
                oldLines: oldLines,
                newStart: newStart,
                newLines: newLines,
                lines: lines
            ))
        }
        return hunks
    }

    enum CodingKeys: String, CodingKey {
        case filePath, oldString, newString, originalFile
        case structuredPatch, userModified, replaceAll, type
    }
}
