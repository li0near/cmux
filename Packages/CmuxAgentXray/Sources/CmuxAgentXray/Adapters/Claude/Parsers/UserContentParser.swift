import Foundation

/// Parses a user message's `content[]` array into a per-block
/// ``Section`` array, in arrival order.
///
/// Replaces the silent text-only `joinText` filter for the user-paste
/// path so user-pasted images (`type:"image"`, base64 source — confirmed
/// in 15 corpus files 2026-06-07) survive into the body.
///
/// Per–`type` mapping mirrors ``ToolResultParser/parse(_:isError:logger:)``
/// for consistency:
///  - `text`           → `.text([s], style: .normal)`
///  - `image` (base64) → `.image(ImageSource(...))` via ``ImageBlockParser``
///  - other            → silently dropped (user messages only carry
///                       text + image in the corpus; ToolSearch's
///                       `tool_reference` only appears in
///                       `tool_result.content`, never user content).
///
/// String-shaped content (legacy single-string user message) →
/// single `.text` section.
enum UserContentParser {

    static func parse(from content: ClaudeMessageContent?) -> [Section] {
        guard let content else { return [] }
        switch content {
        case .text(let s):
            return [.text([s], style: .normal)]
        case .blocks(let blocks):
            return blocks.compactMap { block -> Section? in
                switch block.type {
                case "text":
                    if let t = block.text { return .text([t], style: .normal) }
                    return nil
                case "image":
                    guard let source = block.source else { return nil }
                    return ImageBlockParser.parse(source).map(Section.image)
                default:
                    // Other block types in user content are not in the
                    // corpus today; drop silently. If a future corpus
                    // shows them, lift this into the same warning-log
                    // path used by `ToolResultParser`.
                    return nil
                }
            }
        }
    }
}
