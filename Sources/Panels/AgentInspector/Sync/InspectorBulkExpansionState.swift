import Foundation

/// Three-state global expansion model used by the inspector's bulk
/// "Collapse all" / "Expand snap" status-bar actions. Replaces the
/// earlier independent click-counters which produced "extra click"
/// behaviour when the visible state didn't match the counter parity.
///
/// The panel tracks the current state. Each bulk-action click advances
/// the state one step in its direction:
///
///   - **Collapse all** click: `fullyExpanded → topLevelExpanded →
///     fullyCollapsed → fullyCollapsed` (terminal).
///   - **Expand snap** click: `fullyCollapsed → topLevelExpanded →
///     fullyExpanded → fullyExpanded` (terminal).
///
/// Rows observe the panel's `bulkExpansionTick`; on each increment they
/// snap their per-row `@State` expansion fields to the new bulk state.
/// Per-row manual interactions still override locally until the next
/// bulk-action tick.
enum InspectorBulkExpansionState: String, Equatable {
    /// AI chunk header closed; nothing inside visible.
    case fullyCollapsed
    /// AI chunk header open; thinking + tool calls closed.
    case topLevelExpanded
    /// Everything open: AI chunks, thinking blocks, every tool call.
    case fullyExpanded
}
