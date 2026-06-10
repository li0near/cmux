import SwiftUI

/// Bundle of closures the parent dispatch site passes to ``EntryView``.
///
/// One actions struct, threaded through every recursion level. The
/// recursive ``EntryView`` reads expansion state via ``isExpanded``,
/// publishes user toggles via ``onToggleExpansion``, opens detail tabs
/// via ``onOpenDetail``, and looks up cached display fields via
/// ``computed``. The same struct is reused at every depth so child
/// rows share the parent's wiring.
///
/// Closures are non-Equatable, but conformance is required so the row
/// view can be ``Equatable`` and benefit from SwiftUI's `.equatable()`
/// diffing — without that, every parent re-render regenerates the row
/// body even when value-typed inputs haven't changed
/// (`LazyLayoutViewCache` thrash).
///
/// The custom `==` returns `true` unconditionally: closure identity is
/// not part of the snapshot-boundary input. Functional stability is
/// provided by the captured ``AgentXrayPanel`` reference, which is a
/// `@MainActor @Observable final class` with stable identity across
/// re-renders.
@available(macOS 15, *)
public struct EntryActions: Sendable, Equatable {
    /// Lookup closure: given an entry's stable id, report whether the
    /// entry is currently in the expanded set.
    public let isExpanded: @MainActor @Sendable (String) -> Bool
    /// Toggle the entry's expansion membership in the panel's set.
    public let onToggleExpansion: @MainActor @Sendable (String) -> Void
    /// Open a detail-tab request derived from the entry + section index.
    public let onOpenDetail: @MainActor @Sendable (DetailRequest) -> Void
    /// Resolve cached display fields for an entry through the panel's
    /// ``EntryComputedCache``.
    public let computed: @MainActor @Sendable (Entry) -> EntryComputedCache.Computed

    public init(
        isExpanded: @escaping @MainActor @Sendable (String) -> Bool,
        onToggleExpansion: @escaping @MainActor @Sendable (String) -> Void,
        onOpenDetail: @escaping @MainActor @Sendable (DetailRequest) -> Void,
        computed: @escaping @MainActor @Sendable (Entry) -> EntryComputedCache.Computed
    ) {
        self.isExpanded = isExpanded
        self.onToggleExpansion = onToggleExpansion
        self.onOpenDetail = onOpenDetail
        self.computed = computed
    }

    public static func == (_: EntryActions, _: EntryActions) -> Bool { true }
}
