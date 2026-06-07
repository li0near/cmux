import Foundation

/// Loosely-typed JSON value for tool input/result payloads. Stringified
/// when displaying so downstream code never has to deal with the full
/// JSON object model.
///
/// Despite the `Claude` prefix, this is a generic JSON container —
/// kept here because Claude is the only consumer today. If a future
/// adapter needs the same shape, lift to `Adapters/Common/`.
indirect enum ClaudeJSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ClaudeJSONValue])
    case object([String: ClaudeJSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([ClaudeJSONValue].self) { self = .array(v); return }
        if let v = try? container.decode([String: ClaudeJSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognised JSON value"
        )
    }

    /// Best-effort string for tool-call summaries.
    var displayString: String {
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        case .array(let arr):
            return arr.map(\.displayString).joined(separator: ", ")
        case .object(let obj):
            return obj.map { "\($0.key): \($0.value.displayString)" }
                .sorted()
                .joined(separator: ", ")
        }
    }
}
