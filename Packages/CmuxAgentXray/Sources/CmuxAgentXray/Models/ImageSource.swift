/// Image content carried in a ``Section/image(_:)``. Two parents in the
/// corpus today (verified 2026-06-07):
/// - User-pasted screenshots in top-level `user.message.content[]`.
/// - Tool-returned screenshots in `tool_result.content[]` (e.g. Playwright
///   `browser_take_screenshot`).
///
/// The base64 payload is kept as `String` and **lazy-decoded** at render
/// time (in `Task.detached`, never on the main thread) so we don't pay
/// the ~150KB-per-image decode cost during transcript build.
public struct ImageSource: Equatable, Sendable {
    /// Encoding of `data`. Today only `.base64` is observed; URL-mode
    /// is in the Anthropic Messages API spec but absent from the corpus.
    public enum Kind: Equatable, Sendable { case base64 }

    public let kind: Kind
    /// MIME type, e.g. `"image/png"`, `"image/jpeg"`.
    public let mediaType: String
    /// Base64-encoded image bytes (no `data:` prefix).
    public let data: String

    public init(kind: Kind = .base64, mediaType: String, data: String) {
        self.kind = kind
        self.mediaType = mediaType
        self.data = data
    }
}
