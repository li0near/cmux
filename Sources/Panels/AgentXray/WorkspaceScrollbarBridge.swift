import AppKit
import CmuxAgentXray
import Foundation

/// Caches the latest scrollbar snapshot per terminal surface, projected
/// from cmux's `GhosttyScrollbar` into the package's neutral
/// `ScrollbarSnapshot` value type at the boundary.
///
/// Subscribes once to `.ghosttyDidUpdateScrollbar` and keys the cache by
/// `panelId` (= `TerminalSurface.id` = `CMUX_SURFACE_ID`). The cache is
/// in-memory only — it tracks the live state cmux already publishes so
/// the AgentX-ray host adapter can read scrollback geometry
/// synchronously when it needs to record a turn anchor or convert a
/// terminal scroll position to an entry.
///
/// The package never sees the cmux-internal `GhosttyScrollbar` type —
/// it only consumes the neutral `ScrollbarSnapshot` value type.
///
/// The package never sees the cmux-internal `GhosttyScrollbar` type —
/// it only consumes the neutral `ScrollbarSnapshot` value type.
@MainActor
@available(macOS 15, *)
final class WorkspaceScrollbarBridge {
    static let shared = WorkspaceScrollbarBridge()

    /// Latest published snapshot per panel UUID.
    private(set) var latestByPanel: [UUID: ScrollbarSnapshot] = [:]

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handle(note)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Latest cached snapshot for a given panel. nil before the first
    /// update has been published for that surface.
    func latest(for panelId: UUID) -> ScrollbarSnapshot? {
        latestByPanel[panelId]
    }

    /// Forget all cached entries. Used by tests; callers in production
    /// should not need this.
    func reset() {
        latestByPanel.removeAll()
    }

    private func handle(_ note: Notification) {
        guard let scrollbar = note.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        guard let view = note.object as? GhosttyNSView,
              let panelId = view.terminalSurface?.id else {
            return
        }
        // Project cmux's GhosttyScrollbar into the package's neutral
        // ScrollbarSnapshot at the boundary — fields map 1:1.
        latestByPanel[panelId] = ScrollbarSnapshot(
            total: scrollbar.total,
            offset: scrollbar.offset,
            len: scrollbar.len
        )
    }
}
