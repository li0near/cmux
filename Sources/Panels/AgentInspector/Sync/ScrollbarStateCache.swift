import AppKit
import Foundation

/// Caches the latest `GhosttyScrollbar` state per terminal surface.
///
/// Subscribes once to `Notification.Name.ghosttyDidUpdateScrollbar` and keys
/// the cache by `panelId` (= `TerminalSurface.id` = `CMUX_SURFACE_ID`). The
/// cache is in-memory only — it tracks the live state cmux already
/// publishes, so the inspector's bridge can read scrollback geometry
/// synchronously when it needs to record a turn anchor or convert a
/// terminal scroll position to a chunk.
///
/// Snapshot-boundary friendly: this class is `@MainActor` but does NOT
/// expose `@Published` state. Consumers either read on demand via
/// `latest(for:)` or subscribe their own `NotificationCenter` token to the
/// underlying `Notification.Name.ghosttyDidUpdateScrollbar` if they need
/// to react to every update.
@MainActor
final class ScrollbarStateCache {
    static let shared = ScrollbarStateCache()

    /// Latest published `GhosttyScrollbar` per panel UUID. Updates land on
    /// the main queue (the notification is posted via `DispatchQueue.main`
    /// in `flushPendingScrollbar`).
    private(set) var latestByPanel: [UUID: GhosttyScrollbar] = [:]

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // `addObserver` with `queue: .main` already dispatches the
            // closure on the main queue. The capture is safe because
            // `latestByPanel` is `@MainActor`-isolated.
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

    /// Latest cached scrollbar state for a given panel. Returns nil before
    /// the first update has been published for that surface.
    func latest(for panelId: UUID) -> GhosttyScrollbar? {
        latestByPanel[panelId]
    }

    /// Forget all cached entries. Used by tests; callers in production
    /// should not need this — entries are stable across a session.
    func reset() {
        latestByPanel.removeAll()
    }

    private func handle(_ note: Notification) {
        guard let scrollbar = note.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        // The notification's `object` is the posting `GhosttyNSView`. Its
        // `terminalSurface.id` is the panel UUID (= the same id cmux uses
        // for `CMUX_SURFACE_ID` and for `Workspace.panels[id]`).
        guard let view = note.object as? GhosttyNSView,
              let panelId = view.terminalSurface?.id else {
            return
        }
        latestByPanel[panelId] = scrollbar
    }
}
