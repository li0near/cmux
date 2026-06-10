/// Configurable per-Entry emphasis predicate. The unified renderer reads
/// this to pick between ``/Theme/Entry/nameEmphasis`` (semibold) and
/// ``/Theme/Entry/nameRegular`` (no weight) for the header's `name`
/// slot.
///
/// Edit the switch below to add or remove kinds from the emphasized
/// set without touching the typography enum or any view file. Today
/// every top-level kind (`.user` / `.agent` / `.system` / `.compact` /
/// `.synthesized`) is emphasized; sub-entry kinds (`.text` / `.tool`)
/// render plain.
extension Entry {
    /// True iff this entry's name renders with semibold weight.
    public var isEmphasized: Bool {
        switch self {
        case .user, .agent, .system, .compact, .synthesized:
            return true
        case .text, .tool:
            return false
        }
    }
}
