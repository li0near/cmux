import Foundation

/// Decodes a Claude image content block into an ``ImageSource``.
///
/// One image-decoding logic surface, two input shapes — addresses the
/// audit's W1 dedup item:
/// - ``parse(_:)-(ClaudeContentBlock.Source)`` for the typed user-paste
///   path (Codable-decoded `ClaudeContentBlock.source`).
/// - ``parse(json:)`` for the untyped tool-result path (raw
///   `ClaudeJSONValue` object dict).
///
/// Both return nil for unsupported shapes (e.g. `source.type == "url"`
/// — in the spec but absent from the corpus 2026-06-07) or missing
/// fields. The two callers (``ToolResultParser`` and
/// ``UserContentParser``) lift their inputs through this single
/// helper to avoid drift.
enum ImageBlockParser {

    /// Decode the typed `ClaudeContentBlock.Source` shape produced by
    /// Codable when an `image` block lands in `user.message.content[]`.
    static func parse(_ source: ClaudeContentBlock.Source) -> ImageSource? {
        guard source.type == "base64",
              let mediaType = source.mediaType,
              let data = source.data else {
            return nil
        }
        return ImageSource(kind: .base64, mediaType: mediaType, data: data)
    }

    /// Decode the raw JSON-object shape that `tool_result.content[]`
    /// arrives as (a `ClaudeJSONValue` array element with a `source`
    /// child object).
    static func parse(json obj: [String: ClaudeJSONValue]) -> ImageSource? {
        guard case .object(let source)? = obj["source"],
              case .string(let kindStr)? = source["type"],
              kindStr == "base64",
              case .string(let mediaType)? = source["media_type"],
              case .string(let data)? = source["data"] else {
            return nil
        }
        return ImageSource(kind: .base64, mediaType: mediaType, data: data)
    }
}
