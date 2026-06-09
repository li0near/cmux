import Foundation

/// In-place mutation that converts a pending ``ToolEntry`` (created
/// at `tool_use` append-time with input sections in its body and
/// `status: .pending`, `timeMarker: .clock(start)`) into a completed
/// entry by appending result sections, flipping status, and replacing
/// the time marker with the computed duration.
///
/// **Caller contract.** Pool ordering guarantees the matching
/// ``ToolEntry`` already exists in the transcript at call time —
/// `tool_use` lands first; `tool_result` landing before its
/// `tool_use` is parked in `awaitingParent` until ordering is
/// restored. There is no synthetic-fallback path in the post-G6
/// dispatcher.
///
/// Example:
///
/// ```swift
/// let update = ToolResultUpdate(
///     resultSections: ToolResultParser.parse(block.toolResultContent, ...),
///     isError: block.isError ?? false,
///     durationMs: durationMs
/// )
/// transcript.mutate(id: .fromJSONL(toolUseId)) { entry in
///     update.apply(&entry)
/// }
/// ```
struct ToolResultUpdate {
    /// One or more `.text` (or `.image` / `.offloadedOutput` / etc.)
    /// sections — the parsed `tool_result.content[]` blocks. Appended
    /// after the existing body sections.
    ///
    /// `var` (not `let`) so the builder can swap the parser-produced
    /// sections after construction. The Edit / MultiEdit / Write-update
    /// path uses this to replace the plain-text result with
    /// `[.code(.diff(hunks: ..., language: ...))]` once
    /// `toolUseResult.structuredPatch` is projected — cleaner than
    /// threading the swap through the constructor and matches how
    /// `apply(_:)` is the only consumer.
    var resultSections: [Section]
    /// Whether the result was an error. Drives `status: .error` vs
    /// `.ok` and the renderer's per-section style for any text-style
    /// result sections caller passes in.
    let isError: Bool
    /// Computed `tool_use → tool_result` duration in milliseconds, or
    /// nil if the start timestamp wasn't known. Replaces the entry's
    /// `header.timeMarker` with `.duration(...)` when non-nil.
    let durationMs: Int?

    /// Apply this update to the matching ``ToolEntry`` in place.
    /// No-op if `entry` is not a `.tool` case (defensive — caller
    /// always passes a `.tool` entry by id-equality).
    func apply(_ entry: inout Entry) {
        guard case .tool(var tool) = entry else { return }
        tool.status = isError ? .error : .ok
        tool.durationMs = durationMs
        if let durationMs {
            tool.header = Header(
                icon: tool.header.icon,
                name: tool.header.name,
                label: tool.header.label,
                title: tool.header.title,
                trailing: tool.header.trailing,
                timeMarker: .duration(durationMs)
            )
        }
        tool.body = Body(sections: tool.body.sections + resultSections)
        entry = .tool(tool)
    }
}
