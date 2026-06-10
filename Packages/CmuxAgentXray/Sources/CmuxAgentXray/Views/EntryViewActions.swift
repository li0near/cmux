import SwiftUI

/// Bundle of closures the parent dispatch site passes to ``EntryView``.
///
/// See ``AgentEntryActions`` for the rationale (closure-skip Equatable,
/// snapshot-boundary policy, pattern parity with cmux's
/// `IndexSectionActions`).
@available(macOS 15, *)
public struct EntryViewActions: Sendable {
    /// Toggle the entry's expansion state.
    public let onToggleExpansion: @MainActor @Sendable () -> Void
    /// Open the entry's body in a detail tab.
    public let onOpenDetail: @MainActor @Sendable () -> Void

    public init(
        onToggleExpansion: @escaping @MainActor @Sendable () -> Void,
        onOpenDetail: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onToggleExpansion = onToggleExpansion
        self.onOpenDetail = onOpenDetail
    }
}

@available(macOS 15, *)
extension EntryViewActions: Equatable {
    public static func == (lhs: EntryViewActions, rhs: EntryViewActions) -> Bool {
        true
    }
}
