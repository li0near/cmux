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
}
