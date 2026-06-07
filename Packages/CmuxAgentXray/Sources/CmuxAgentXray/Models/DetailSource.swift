/// Discriminated source for a ``DetailContent``. Carries everything
/// the host needs to materialize and open the detail tab — no
/// content-type inference, no body bytes the host might re-read.
///
/// The four cases map to the four routing paths in the cmux host
/// conformance:
/// - ``file(path:)`` — already on disk; host opens the URL directly.
/// - ``text(body:suggestedFilename:)`` — host writes UTF-8 to a temp
///   file with the suggested basename. The file extension drives
///   cmux's `Workspace.openFileSurfaces` dispatch (`.md` → markdown
///   panel; everything else → file-preview panel + highlight.js).
/// - ``image(_:suggestedFilename:)`` — host decodes base64 + writes
///   binary to a temp file with the suggested basename.
/// - ``transcript(sourceEntryID:entries:)`` — sub-agent or
///   abandoned-branch transcript. Stays in-package via
///   `TranscriptView.detailEntriesList` (structured `Entry` arrays
///   don't fit cmux's file-driven panel system).
public enum DetailSource: Sendable {
    /// Already on disk — offloaded `<persisted-output>`.
    case file(path: String)
    /// Inline UTF-8 text. The suggested basename's extension drives
    /// cmux's panel dispatch.
    case text(body: String, suggestedFilename: String)
    /// Inline base64 image.
    case image(ImageSource, suggestedFilename: String)
    /// Sub-agent or abandoned-branch transcript, identified by
    /// ``sourceEntryID``. Equality compares only that id (entries are
    /// the cached transcript for the id; comparing them recursively
    /// on every reactive update is wasted work).
    case transcript(sourceEntryID: String, entries: [Entry])
}

extension DetailSource: Equatable {
    public static func == (lhs: DetailSource, rhs: DetailSource) -> Bool {
        switch (lhs, rhs) {
        case (.file(let lp), .file(let rp)):
            return lp == rp
        case (.text(let lb, let lf), .text(let rb, let rf)):
            return lb == rb && lf == rf
        case (.image(let li, let lf), .image(let ri, let rf)):
            return li == ri && lf == rf
        case (.transcript(let lid, _), .transcript(let rid, _)):
            return lid == rid
        case (.file, _), (.text, _), (.image, _), (.transcript, _):
            return false
        }
    }
}
