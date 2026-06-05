public import Foundation

/// Time-related marker rendered at the right edge of an entry's header
/// row. Top-level rows display a wall-clock timestamp; tool sub-rows
/// display the tool's runtime duration. They are mutually exclusive in
/// practice — `Header.timeMarker: TimeMarker?` carries whichever one
/// applies for the row.
///
/// Folding both into one optional field replaces the previous split of
/// `Header.timestamp: Date?` plus `TrailingItem.duration(String)`,
/// which were always rendered in the same screen position but encoded
/// as unrelated fields.
public enum TimeMarker: Equatable, Sendable {
    /// Wall-clock time of the entry. Renderer formats as `HH:MM:SS`.
    case clock(Date)
    /// Runtime in milliseconds (used by tool sub-rows). Renderer
    /// formats as `"\(ms) ms"`.
    case duration(Int)

    /// The wall-clock `Date` if this is a `.clock` marker; nil for
    /// `.duration`. Used by entries to project their `timestamp`
    /// computed property from the header's marker.
    public var clockDate: Date? {
        if case .clock(let date) = self { return date }
        return nil
    }

    /// Pre-formatted text rendered at the right edge of a header row.
    /// One source of truth so `EntryHeaderView` and sub-entry header
    /// helpers don't duplicate the formatting rule.
    public var displayString: String {
        switch self {
        case .clock(let date):
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: date)
        case .duration(let ms):
            return "\(ms) ms"
        }
    }
}
