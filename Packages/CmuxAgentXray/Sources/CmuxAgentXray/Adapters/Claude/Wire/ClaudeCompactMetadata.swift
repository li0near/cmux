import Foundation

/// `system.subtype: compact_boundary` companion payload — token totals
/// and duration for the compact event.
struct ClaudeCompactMetadata: Decodable, Equatable {
    let preTokens: Int?
    let postTokens: Int?
    let durationMs: Int?
}
