import Foundation

/// One element of an array-shaped `message.content`. Carries the union
/// of fields across all block types Claude Code emits — only the
/// fields relevant to the block's `type` are populated; the rest are
/// nil. Per–`type` semantics live in
/// `Adapters/Claude/ClaudeTranscriptBuilder.swift` and
/// `Adapters/Claude/Parsers/`.
struct ClaudeContentBlock: Decodable, Equatable {
    let type: String
    let text: String?
    let thinking: String?
    let id: String?
    let name: String?
    let input: ClaudeJSONValue?
    let toolUseId: String?
    let toolResultContent: ClaudeJSONValue?
    let isError: Bool?
    /// Image / document block payload. Present on `type:"image"` (and
    /// `type:"document"`, though documents have 0 corpus hits at
    /// 2026-06-07). Decoded into a typed inner shape so the user-paste
    /// builder can lift base64 images into `Section.image` directly.
    let source: Source?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input, source
        case toolUseId = "tool_use_id"
        case toolResultContent = "content"
        case isError = "is_error"
    }

    /// Inner `source` payload of an image (or document) block. The
    /// corpus only exercises `type:"base64"` today; `type:"url"` is
    /// in the spec but absent so the consumer treats it as
    /// unsupported.
    struct Source: Decodable, Equatable {
        let type: String
        let mediaType: String?
        let data: String?

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }
}
