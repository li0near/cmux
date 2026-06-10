import SwiftUI

/// Bundle of closures the parent dispatch site passes to ``AgentEntryView``.
///
/// Closures are non-Equatable, but conformance is required so the parent
/// view can be marked ``View``/``Equatable`` and benefit from SwiftUI's
/// `.equatable()` diffing — without that, every parent re-render
/// regenerates the row body even when the entry's value-typed inputs
/// haven't changed (`LazyLayoutViewCache` thrash).
///
/// The custom `==` returns `true` unconditionally: closure identity is
/// not part of the snapshot-boundary input. Functional stability is
/// provided by the captured ``AgentXrayPanel`` reference, which is a
/// `@MainActor @Observable final class` with stable identity across
/// re-renders.
///
/// Pattern parity with cmux's `IndexSectionActions` /
/// `SectionGapActions` reference at `Sources/SessionIndexView.swift`.
@available(macOS 15, *)
public struct AgentEntryActions: Sendable {
    /// Lookup closure: given a sub-entry expansion key, report whether
    /// it's currently in the expanded set.
    public let isSubEntryExpanded: @MainActor @Sendable (String) -> Bool
    /// Bubble an expansion toggle up to the panel.
    public let onToggleExpansion: @MainActor @Sendable (AgentXrayPanel.ExpansionToggle) -> Void
    /// Bubble a detail-tab open request up to the panel.
    public let onOpenDetail: @MainActor @Sendable (DetailRequest) -> Void

    public init(
        isSubEntryExpanded: @escaping @MainActor @Sendable (String) -> Bool,
        onToggleExpansion: @escaping @MainActor @Sendable (AgentXrayPanel.ExpansionToggle) -> Void,
        onOpenDetail: @escaping @MainActor @Sendable (DetailRequest) -> Void
    ) {
        self.isSubEntryExpanded = isSubEntryExpanded
        self.onToggleExpansion = onToggleExpansion
        self.onOpenDetail = onOpenDetail
    }
}

@available(macOS 15, *)
extension AgentEntryActions: Equatable {
    public static func == (lhs: AgentEntryActions, rhs: AgentEntryActions) -> Bool {
        true
    }
}
