import Foundation

/// Named constants used by `ClaudeChunkBuilder`. Centralising these keeps
/// the builder free of scattered magic numbers and makes it explicit when
/// limits are tuned.
///
/// Every limit here applies to **builder-side summarisation** — short
/// previews shown when a tool call's full input/output is later expanded
/// inline. Inline-render caps live in `InspectorCaps` (Phase B).
enum ClaudeBuilderConsts {
    /// Cap for one-line tool-call summaries (e.g. the first command of a
    /// `Bash` invocation, the prompt of a `WebFetch`, etc.). Keeps the
    /// collapsed AI-row tool list scannable at a glance.
    static let toolSummaryMaxChars = 120

    /// Cap for the per-key value rendering inside a tool's structured
    /// input panel. Larger inputs surface the `↗ Open detail` link.
    static let toolInputValueMaxChars = 400

    /// Cap for the flattened single-string projection of a tool result.
    /// Anything larger is truncated for the inline preview; the full
    /// content is reachable via the detail panel.
    static let flattenedResultMaxChars = 1000

    /// Soft fallback line-cap applied to `isMeta=true` user-line content
    /// that has no specific size classification (e.g. a short
    /// `<system-reminder>` rendered inline). Content longer than this
    /// is routed to a detail panel.
    static let metaContentInlineMaxLines = 60

    /// Cap on the prompt-preview shown next to abandoned-branch links
    /// (`↳ Rewind #N — <preview>`). Branch links sit in the active list
    /// at branch points; the preview must stay one line on typical screens.
    static let abandonedBranchPreviewMaxChars = 80
}
