/// Named constants used by `ClaudeTranscriptBuilder` for builder-side
/// summarisation — short previews shown when a tool call's full
/// input/output is later expanded inline. Inline-render caps live in
/// `RenderCaps`.
enum ClaudeRenderConsts {
    /// Cap for one-line tool-call summaries (e.g. the first command of a
    /// `Bash` invocation, the prompt of a `WebFetch`). Keeps the
    /// collapsed agent-turn tool list scannable at a glance.
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
    /// (`↳ Rewind #N — <preview>`).
    static let abandonedBranchPreviewMaxChars = 80
}
