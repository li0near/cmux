/// Stub representing Claude Code's `<persisted-output>` wrapper —
/// the inline placeholder that CC injects when a tool's stdout exceeds
/// its size threshold. Real bytes are written to a `.txt` / `.json`
/// file on disk and referenced by absolute path.
///
/// Two-commit corpus shape (verified 2026-06-07, 97 files / 78 distinct
/// sessions):
/// ```
/// <persisted-output>
/// Output too large (29.3KB). Full output saved to: /Users/<...>/<...>.txt
///
/// Preview (first 2KB):
/// <preview bytes>
/// </persisted-output>
/// ```
/// ~21 of 252 corpus occurrences truncate before the close tag — the
/// detector must match on the open tag + canonical "Output too large"
/// line only. Path always ends in `.txt` (most) or `.json`.
public struct OffloadedOutput: Equatable, Sendable {
    /// Absolute path to the offloaded `.txt` or `.json` file.
    public let path: String
    /// Display-friendly size label (e.g. `"29.3KB"`, `"1.2MB"`).
    public let sizeLabel: String
    /// First ~2 KB inlined by CC after the path line. nil when the
    /// wrapper truncated before the preview header (rare).
    public let preview: String?

    public init(path: String, sizeLabel: String, preview: String? = nil) {
        self.path = path
        self.sizeLabel = sizeLabel
        self.preview = preview
    }
}
