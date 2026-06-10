/// Named constants used by `ClaudeTranscriptBuilder` for builder-side
/// summarisation — short previews shown when a tool call's full
/// input/output is later expanded inline. Inline-render caps live in
/// `RenderCaps`.
enum ClaudeRenderConsts {
    /// Cap for the per-key value rendering inside a tool's structured
    /// input panel. Larger inputs surface the `↗ Open detail` link.
    static let toolInputValueMaxChars = 400

    /// Cap for the flattened single-string projection of a tool result.
    /// Anything larger is truncated for the inline preview; the full
    /// content is reachable via the detail panel.
    static let flattenedResultMaxChars = 1000
}
