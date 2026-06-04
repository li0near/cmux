import AppKit
import Bonsplit
import Foundation
import SwiftUI

#if DEBUG
/// Adds an "Agent X-ray" entry to the Debug menu. Opens a new
/// AgentX-ray panel in the focused workspace's focused pane (or the
/// first available pane). Mirrors how the spike's
/// `cmuxApp+AgentInspectorDebugMenu.swift` integrates with the cmux
/// Debug menu.
@MainActor
@available(macOS 15, *)
enum AgentXrayDebugMenu {
    /// Open a new live AgentX-ray panel in the currently focused
    /// workspace's currently focused pane. No-op if no workspace is
    /// active or no pane is available.
    static func openAgentXrayInFocusedWorkspace() {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let workspace = appDelegate.tabManager?.selectedWorkspace else {
            NSSound.beep()
            return
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else {
            NSSound.beep()
            return
        }
        _ = workspace.newAgentXraySurface(inPane: paneId, focus: true)
    }
}
#endif
