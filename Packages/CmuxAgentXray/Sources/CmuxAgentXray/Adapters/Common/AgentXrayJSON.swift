import Foundation

/// JSON decoder shared across the package's adapter layer. ISO-8601
/// dates with fractional seconds match the Claude/Codex transcript
/// format; falls back to no-fraction and RFC3339-ish parsing.
///
/// Both `ClaudeJSONLLine` (decoded by Claude adapter) and
/// `CodexRolloutLine` (decoded by Codex adapter) flow through this
/// single decoder via `Streaming/TranscriptStream`. Lives in
/// `Adapters/Common/` because it's agent-agnostic — the only reason
/// it lived in the Claude adapter previously was historical (Claude
/// landed first).
enum AgentXrayJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            // Formatters created per-call: ISO8601DateFormatter is not
            // Sendable, so we cannot capture instances in this @Sendable
            // closure. Allocation cost is ~µs and the parse path runs
            // off-main, so this is fine.
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: s) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: s) {
                return date
            }
            let rfc = DateFormatter()
            rfc.locale = Locale(identifier: "en_US_POSIX")
            rfc.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
            if let date = rfc.date(from: s) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised timestamp: \(s)"
            )
        }
        return d
    }()
}
