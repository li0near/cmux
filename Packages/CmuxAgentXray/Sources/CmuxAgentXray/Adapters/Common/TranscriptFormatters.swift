internal import Foundation

/// Agent-agnostic transcript formatters. Used by both Claude and Codex
/// transcript builders for header trailing items (token pills,
/// word-count pills) and prompt-preview canonicalization.
///
/// Truncation is **not** done here — view-layer code applies
/// `.lineLimit(1).truncationMode(.tail)` so the title shrinks
/// dynamically with container width instead of hard-truncating to a
/// fixed character count.

/// Whitespace-collapsed prompt preview used as `Header.title` for a
/// `UserEntry`. Collapses runs of any whitespace (newlines, tabs,
/// spaces) into a single space and trims leading/trailing whitespace,
/// producing a single-line summary suitable for inline display.
///
/// Length truncation is the renderer's job — see view-layer
/// `.truncationMode(.tail)`. This function preserves the full
/// canonicalized text.
internal func singleLinePromptPreview(_ text: String) -> String {
    text
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

/// Approximate word count used in the `[N words]` trailing pill.
/// Whitespace-split, empty parts skipped — matches the behaviour
/// expected by the predecessor implementation.
internal func wordCount(_ text: String) -> Int {
    text
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .count
}

/// Compact human-readable token count: `"123"`, `"12.3k"`, `"4.2M"`.
/// Used both for total pills (via ``formatTokenCounts(_:)``) and for
/// per-bucket breakdown labels (input / output / cacheRead / cacheCreation).
internal func formatTokens(_ n: Int) -> String {
    if n < 1000 { return "\(n)" }
    if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000) }
    return String(format: "%.1fM", Double(n) / 1_000_000)
}

/// Human-readable total-token pill text for an `AgentEntry`'s
/// `[X.Yk tokens]` / `[X.YM tokens]` trailing item. Sums all four
/// buckets (input + output + cacheRead + cacheCreation) and formats
/// the total via ``formatTokens(_:)``.
internal func formatTokenCounts(_ usage: AgentEntry.TokenUsage) -> String {
    let total = usage.inputTokens
        + usage.outputTokens
        + usage.cacheReadTokens
        + usage.cacheCreationTokens
    return formatTokens(total)
}
