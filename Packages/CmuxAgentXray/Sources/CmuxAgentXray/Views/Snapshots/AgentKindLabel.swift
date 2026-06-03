/// Discriminator for the agent kind a panel is currently displaying.
/// Drives small render-side affordances such as the agent role label
/// in `Header.name` and the model-version pill format.
public enum AgentKindLabel: Equatable, Sendable {
    case claude
    case codex
    /// Unknown / not yet resolved — used while session resolution is
    /// in flight.
    case unknown
}
