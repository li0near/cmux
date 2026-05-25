import Foundation

/// One-shot bulk action emitted by the inspector status bar's
/// "Collapse all" / "Expand snap" buttons. Stepped semantics: each
/// click cycles through finer-to-coarser states so users can toggle
/// in degrees rather than all-or-nothing.
///
/// Click sequence (from any state):
///   - **Collapse all** → first click: `.collapseSubItems` (close tool
///     calls + thinking; AI chunk header stays open). Second click:
///     `.collapseEverything` (close AI chunks too). Third click loops.
///   - **Expand snap** → first click: `.expandTopLevel` (open AI chunk
///     headers only). Second click: `.expandEverything` (open thinking
///     + every tool call). Third click loops.
enum InspectorBulkAction: Equatable {
    case collapseSubItems
    case collapseEverything
    case expandTopLevel
    case expandEverything
}
