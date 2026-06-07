import Foundation

/// Either a single string or an array of typed content blocks. The
/// `message.content` field on `user` / `assistant` lines decodes into
/// one of these variants depending on the wire shape.
enum ClaudeMessageContent: Decodable, Equatable {
    case text(String)
    case blocks([ClaudeContentBlock])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .text(str)
            return
        }
        let arr = try container.decode([ClaudeContentBlock].self)
        self = .blocks(arr)
    }

    /// String content of this message: the wrapped string for `.text`,
    /// the first text-block's payload for `.blocks` (else empty).
    /// Used as a probe for prefix sniffs (slash-command detection,
    /// classifier dispatch). For the full text projection across all
    /// blocks, use ``allText()``.
    func firstText() -> String {
        switch self {
        case .text(let s): return s
        case .blocks(let blocks):
            for block in blocks where block.type == "text" {
                if let t = block.text { return t }
            }
            return ""
        }
    }

    /// Concatenated text across every block exposing a `text` field
    /// (text + thinking blocks), joined by `\n`. Returns the wrapped
    /// string verbatim for `.text`. Used by system/compact builders
    /// where the body is rendered verbatim and non-text blocks aren't
    /// expected.
    func allText() -> String {
        switch self {
        case .text(let s): return s
        case .blocks(let blocks):
            return blocks.compactMap(\.text).joined(separator: "\n")
        }
    }
}
