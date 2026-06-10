public import SwiftUI

/// Bundle of closures the parent dispatch site passes to ``RewindEntryView``.
///
/// See ``AgentEntryActions`` for the rationale (closure-skip Equatable,
/// snapshot-boundary policy, pattern parity with cmux's
/// `IndexSectionActions`).
@available(macOS 15, *)
public struct RewindEntryActions: Sendable {
    /// Lookup closure: given a sub-entry expansion key, report whether
    /// it's currently in the expanded set.
    public let isSubEntryExpanded: @MainActor @Sendable (String) -> Bool
    /// Bubble an expansion toggle up to the panel.
    public let onToggleExpansion: @MainActor @Sendable (AgentXrayPanel.ExpansionToggle) -> Void
    /// Bubble a detail-tab open request up to the panel.
    public let onOpenDetail: @MainActor @Sendable (DetailRequest) -> Void
    /// Recursive child renderer. The parent's per-`Entry` dispatch
    /// function is injected here so abandoned-branch children render
    /// through the same code path the main transcript's `ForEach` uses
    /// — they automatically gain all the snapshot-boundary expansion
    /// wiring (panel.currentExpanded.contains, panel.toggleExpansion,
    /// panel.openDetail).
    public let renderSubEntry: @MainActor @Sendable (Entry) -> AnyView

    public init(
        isSubEntryExpanded: @escaping @MainActor @Sendable (String) -> Bool,
        onToggleExpansion: @escaping @MainActor @Sendable (AgentXrayPanel.ExpansionToggle) -> Void,
        onOpenDetail: @escaping @MainActor @Sendable (DetailRequest) -> Void,
        renderSubEntry: @escaping @MainActor @Sendable (Entry) -> AnyView
    ) {
        self.isSubEntryExpanded = isSubEntryExpanded
        self.onToggleExpansion = onToggleExpansion
        self.onOpenDetail = onOpenDetail
        self.renderSubEntry = renderSubEntry
    }
}

@available(macOS 15, *)
extension RewindEntryActions: Equatable {
    public static func == (lhs: RewindEntryActions, rhs: RewindEntryActions) -> Bool {
        true
    }
}
