import Foundation

/// Parses a Claude `tool_result.content` JSON value into a per-block
/// ``Section`` array, in JSONL arrival order.
///
/// Replaces the legacy `flattenToolResult(_:) -> String` helper which
/// join-flattened every block into one string and silently dropped
/// images / `tool_reference` blocks.
///
/// `isError` is applied only to `.text` sections (the visual treatment
/// the old single-string path applied to error results); images and
/// tool-references have no error variant.
///
/// Per–`type` mapping (Anthropic Messages API spec ∩ corpus
/// 2026-06-07):
///  - `text`              → `.text([s], style: .normal/.error)`
///  - `image`             → `.image(ImageSource(...))` (base64 only)
///  - `tool_reference`    → `.toolReference(toolName:)` (CC's
///                          client-side `ToolSearch` deferred-loader
///                          emits these inside `tool_result.content`)
///  - `redacted_thinking` /
///    `search_result` /
///    `document`          → `.text(["[type]"], .normal)` placeholder.
///                          VERIFY-CORPUS-2026-06-07: 0 hits past
///                          this date. Spec-allowed but never emitted
///                          by Claude Code in practice. Re-grep
///                          `~/.claude/projects/*/*.jsonl` modified
///                          after this date if any of these surface
///                          in the UI; if so, design rich rendering
///                          rather than this stub.
///  - unknown             → `.text(["[type]"], .normal)`.
///
/// String-shaped legacy `tool_result.content` (single string instead
/// of array) is coerced to `[.text([s], textStyle)]`.
///
/// The post-pass through ``OffloadedOutputParser/promote(_:)`` (for
/// the `<persisted-output>` wrapper) is invoked at the public
/// ``parse(_:isError:logger:)`` boundary; ``rawSections(_:isError:logger:)``
/// is exposed for tests that want the per-block emission without the
/// post-pass.
enum ToolResultParser {

    static func parse(
        _ value: ClaudeJSONValue?,
        isError: Bool,
        logger: any AgentXrayLogger = NoOpAgentXrayLogger()
    ) -> [Section] {
        let raw = rawSections(value, isError: isError, logger: logger)
        return OffloadedOutputParser.promote(raw)
    }

    /// Per-block emission without the `<persisted-output>` post-pass.
    /// Kept internal so the wrapper-detection pass can run on every
    /// text section without leaking parsing concerns into the per-block
    /// dispatch.
    static func rawSections(
        _ value: ClaudeJSONValue?,
        isError: Bool,
        logger: any AgentXrayLogger
    ) -> [Section] {
        let textStyle: TextStyle = isError ? .error : .normal
        guard let value else { return [] }
        switch value {
        case .string(let s):
            return [.text([s], style: textStyle)]
        case .array(let arr):
            return arr.compactMap { sectionForBlock($0, textStyle: textStyle, logger: logger) }
        default:
            // Object / number / bool / null shaped tool_result.content
            // is unreachable in the corpus; the legacy fallback used
            // `value.displayString`, which preserves at least a textual
            // representation rather than dropping the block entirely.
            return [.text([value.displayString], style: textStyle)]
        }
    }

    /// Map a single `tool_result.content[]` block (must be a JSON
    /// object with a `type` field) to a single ``Section``. Returns nil
    /// if the block isn't an object — the array branch in
    /// ``rawSections(_:isError:logger:)`` filters those out so a
    /// malformed block doesn't produce an empty section.
    ///
    /// `logger` receives a `.warning` whenever a spec-allowed but
    /// corpus-empty block type (or an unknown type) is encountered, so
    /// future drift is detectable in sysdiagnose without re-grepping
    /// the corpus.
    private static func sectionForBlock(
        _ item: ClaudeJSONValue,
        textStyle: TextStyle,
        logger: any AgentXrayLogger
    ) -> Section? {
        guard case .object(let obj) = item,
              case .string(let type)? = obj["type"] else {
            return nil
        }
        switch type {
        case "text":
            if case .string(let s)? = obj["text"] {
                return .text([s], style: textStyle)
            }
            return .text([""], style: textStyle)
        case "image":
            return ImageBlockParser.parse(json: obj).map(Section.image)
        case "tool_reference":
            if case .string(let name)? = obj["tool_name"] {
                return .toolReference(toolName: name)
            }
            return nil
        case "redacted_thinking", "search_result", "document":
            // VERIFY-CORPUS-2026-06-07: 0 hits in the user's corpus past
            // this date. Spec-allowed (Anthropic Messages API) but
            // never emitted by Claude Code in practice. Stub as text
            // so we don't drop data; revisit when corpus shows hits.
            // Warning logged so future surfacing is visible without
            // re-grepping the corpus.
            logger.warning(
                "ToolResultParser: spec-only-not-corpus block type \"\(type)\" surfaced; "
                + "rendering as text stub. Re-design rich rendering if this becomes common."
            )
            return .text(["[\(type)]"], style: textStyle)
        default:
            // Unknown block type — preserve the type label visibly in
            // the UI so future drift is debuggable. Logged at warning
            // level for the same reason.
            logger.warning(
                "ToolResultParser: unknown block type \"\(type)\"; rendering as text stub."
            )
            return .text(["[\(type)]"], style: textStyle)
        }
    }
}
