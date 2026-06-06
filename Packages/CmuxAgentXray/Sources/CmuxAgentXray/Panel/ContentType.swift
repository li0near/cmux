/// Discriminator for how a ``DetailContent``'s body should be rendered.
///
/// Phase A introduces the two foundational cases (`.plainText` for the
/// existing string-body rendering, `.transcript` for `.entries`-bearing
/// content). Phase D extends with `.markdown / .code / .json / .diff`
/// for rich detail-tab rendering — the cases land alongside the rich
/// renderers; for Phase A every resolver arm picks one of the two
/// foundational cases based on whether `entries` is nil.
public enum ContentType: Equatable, Sendable {
    /// Render the `body` string as plain text (default).
    case plainText
    /// Render the `entries` array as a transcript using the standard
    /// EntryView dispatcher in detail mode.
    case transcript
}
