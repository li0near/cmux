import Foundation

/// `message` body for user / assistant entries.
struct ClaudeMessage: Decodable {
    let id: String?
    let role: String?
    let model: String?
    /// `string | ContentBlock[]` in the JSON.
    let content: ClaudeMessageContent?
    let stopReason: String?
    let usage: ClaudeUsage?

    enum CodingKeys: String, CodingKey {
        case id, role, model, content
        case stopReason = "stop_reason"
        case usage
    }

    init(
        id: String? = nil,
        role: String?,
        model: String?,
        content: ClaudeMessageContent?,
        stopReason: String?,
        usage: ClaudeUsage? = nil
    ) {
        self.id = id
        self.role = role
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.role = try container.decodeIfPresent(String.self, forKey: .role)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.content = try container.decodeIfPresent(ClaudeMessageContent.self, forKey: .content)
        self.stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
        self.usage = try container.decodeIfPresent(ClaudeUsage.self, forKey: .usage)
    }
}
