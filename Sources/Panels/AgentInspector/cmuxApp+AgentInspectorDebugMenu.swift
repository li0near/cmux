import SwiftUI
import Bonsplit

#if DEBUG
/// Debug menu entries for the Agent Inspector panel. Hosted as a SwiftUI
/// `Group` so it can be inserted into `cmuxApp.swift`'s "Debug" command menu
/// with a single-line reference, keeping the upstream-edited file diff minimal
/// for fork-merges.
struct AgentInspectorDebugMenu: View {
    let appDelegate: AppDelegate

    var body: some View {
        Button(
            String(
                localized: "agentInspector.debug.menu.openCurrent",
                defaultValue: "Open Agent Inspector (Split Right)"
            )
        ) {
            appDelegate.openAgentInspectorInCurrentPane(nil)
        }
    }
}

extension AppDelegate {
    /// Splits the focused workspace's focused pane horizontally and places a
    /// new Agent Inspector panel in the right-hand sibling. This matches the
    /// "side-by-side pane alongside the current working session" UX from the
    /// implementation plan; future phases wire scroll-sync between the two.
    @objc func openAgentInspectorInCurrentPane(_ sender: Any?) {
        _ = sender
        guard let tabManager else { return }
        guard let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first else {
            return
        }
        let controller = workspace.bonsplitController
        guard let paneId = controller.focusedPaneId ?? controller.allPaneIds.first else {
            return
        }
        _ = workspace.splitPaneWithAgentInspector(
            targetPane: paneId,
            orientation: .horizontal,
            insertFirst: false
        )
    }
}
#endif
