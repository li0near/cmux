import Foundation

/// One line of a Codex rollout file (`~/.codex/sessions/.../<id>.jsonl`).
///
/// Codex wraps everything in a `payload` object whose shape varies by
/// `type`. We model only the four shapes the panel needs.
///
/// Unlike Claude JSONL, Codex lines do **not** carry per-line
/// timestamps. We synthesise monotonic timestamps from line index +
/// the file's mtime so the downstream entry model can still order
/// items. See `CodexSyntheticTimestamps`.
struct CodexRolloutLine: Decodable {
    let type: String
    let payload: ClaudeJSONValue?
}

extension CodexRolloutLine {
    var sessionMeta: CodexSessionMeta? {
        guard type == "session_meta", case .object(let obj) = payload else { return nil }
        return CodexSessionMeta(
            id: obj["id"]?.stringValue ?? "",
            cwd: obj["cwd"]?.stringValue,
            gitBranch: (obj["git"]?.objectValue?["branch"])?.stringValue
        )
    }

    var turnContext: CodexTurnContext? {
        guard type == "turn_context", case .object(let obj) = payload else { return nil }
        return CodexTurnContext(
            model: obj["model"]?.stringValue,
            approvalPolicy: obj["approval_policy"]?.stringValue,
            sandboxMode: (obj["sandbox_policy"]?.objectValue?["type"])?.stringValue,
            effort: obj["effort"]?.stringValue
        )
    }

    var eventMsg: CodexEventMsg? {
        guard type == "event_msg", case .object(let obj) = payload else { return nil }
        let inner = obj["type"]?.stringValue ?? ""
        return CodexEventMsg(
            innerType: inner,
            message: obj["message"]?.stringValue,
            threadName: obj["thread_name"]?.stringValue
        )
    }

    var responseItem: CodexResponseItem? {
        guard type == "response_item", case .object(let obj) = payload else { return nil }
        let kind = obj["type"]?.stringValue ?? ""
        guard kind == "message" else { return nil }
        let role = obj["role"]?.stringValue ?? ""
        let texts: [String]
        if case .array(let arr)? = obj["content"] {
            texts = arr.compactMap { item -> String? in
                guard case .object(let block) = item else { return nil }
                let blockType = block["type"]?.stringValue ?? ""
                guard blockType == "input_text" || blockType == "output_text"
                    else { return nil }
                return block["text"]?.stringValue
            }
        } else {
            texts = []
        }
        return CodexResponseItem(role: role, textBlocks: texts)
    }
}

struct CodexSessionMeta: Equatable {
    let id: String
    let cwd: String?
    let gitBranch: String?
}

struct CodexTurnContext: Equatable {
    let model: String?
    let approvalPolicy: String?
    let sandboxMode: String?
    let effort: String?
}

struct CodexEventMsg: Equatable {
    let innerType: String  // user_message | thread_name_updated | other
    let message: String?
    let threadName: String?
}

struct CodexResponseItem: Equatable {
    let role: String  // user | assistant
    let textBlocks: [String]
}

private extension ClaudeJSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var objectValue: [String: ClaudeJSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
