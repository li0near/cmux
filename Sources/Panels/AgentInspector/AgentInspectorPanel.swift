import AppKit
import Combine
import Foundation

/// A side-by-side companion panel that mirrors the Claude Code or Codex
/// session running in the workspace's currently focused terminal surface.
///
/// Operates in two modes:
/// - `.live` (default): auto-attaches to the focused terminal's hook session
///   via `FocusedSurfaceObserver`, opens the transcript via `JSONLTail`,
///   builds chunks via `ClaudeChunkBuilder`, and exposes the live chunk list.
/// - `.detail(content:)`: renders one frozen `AgentInspectorDetailContent`
///   without streaming or auto-attach. Used for the "↗ Open detail" route in
///   the transcript renderer when an expandable section overflows the inline
///   cap. Detail panels open as sibling tabs in the same pane.
@MainActor
final class AgentInspectorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .agentInspector

    /// The workspace this panel belongs to.
    private(set) weak var workspace: Workspace?
    var workspaceId: UUID

    enum Mode: Equatable {
        case live
        case detail(content: AgentInspectorDetailContent)
    }

    let mode: Mode

    var displayTitle: String {
        switch mode {
        case .live:
            if let session = focusedSurfaceObserver?.current {
                return String(
                    localized: "agentInspector.title.attached",
                    defaultValue: "Inspector — \(session.sessionId.prefix(8))"
                )
            }
            return String(
                localized: "agentInspector.title",
                defaultValue: "Agent Inspector"
            )
        case .detail(let content):
            return content.title
        }
    }

    var displayIcon: String? {
        switch mode {
        case .live: return "chart.bar.doc.horizontal"
        case .detail: return "doc.text"
        }
    }

    @Published private(set) var focusFlashToken: Int = 0
    @Published private(set) var resolvedSession: ResolvedAgentSession?

    /// Transcript stream — live `AgentChunk` snapshots. Empty in detail mode.
    let stream = TranscriptStream()

    private var focusedSurfaceObserver: FocusedSurfaceObserver?
    private var sessionCancellable: AnyCancellable?
    private var streamCancellable: AnyCancellable?

    init(workspace: Workspace) {
        self.id = UUID()
        self.workspace = workspace
        self.workspaceId = workspace.id
        self.mode = .live

        let observer = FocusedSurfaceObserver(workspace: workspace)
        focusedSurfaceObserver = observer
        sessionCancellable = observer.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.handleSessionChange(session)
            }

        // SwiftUI's @ObservedObject only tracks the immediate object's
        // @Published properties — it does NOT auto-track nested ones like
        // `panel.stream.chunks`. Forward stream updates into our own
        // objectWillChange so the inspector view re-renders when chunks /
        // lineCount change after a tab switch resets the stream.
        streamCancellable = stream.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
    }

    /// Detail-mode initializer. Renders a static, non-streaming snapshot of
    /// one expanded section from the live inspector.
    init(workspace: Workspace, detail: AgentInspectorDetailContent) {
        self.id = UUID()
        self.workspace = workspace
        self.workspaceId = workspace.id
        self.mode = .detail(content: detail)
        // No observer / no stream attach — detail panels are frozen.
    }

    private func handleSessionChange(_ session: ResolvedAgentSession?) {
        resolvedSession = session
        stream.attach(session: session)
        objectWillChange.send()
    }

    // MARK: - Panel protocol

    func focus() {
        // Phase 1: no internal focus state to claim — the row list owns its
        // own selection state via SwiftUI focus.
    }

    func unfocus() {}

    func close() {
        focusedSurfaceObserver?.stop()
        focusedSurfaceObserver = nil
        sessionCancellable?.cancel()
        sessionCancellable = nil
        streamCancellable?.cancel()
        streamCancellable = nil
        stream.attach(session: nil)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Detail-panel routing

    /// Called when a chunk row triggers `↗ Open detail` because the requested
    /// expandable section exceeded the inline cap. Looks up the chunk in the
    /// stream, resolves the requested content slice, and asks the workspace
    /// to add a sibling detail tab in the same pane.
    ///
    /// No-op in `.detail` mode (detail panels don't host a live stream).
    func openDetail(request: InspectorDetailRequest) {
        guard case .live = mode else { return }
        guard let workspace else { return }
        let chunkId = request.chunkId
        guard let chunk = stream.chunks.first(where: { $0.id == chunkId }) else { return }
        guard let content = AgentInspectorDetailContent.resolve(request: request, chunk: chunk) else {
            return
        }
        workspace.openAgentInspectorDetail(content: content, fromInspectorPanelId: id)
    }
}

private extension InspectorDetailRequest {
    var chunkId: String {
        switch self {
        case .userPrompt(let id),
             .thinking(let id),
             .systemOutput(let id):
            return id
        case .toolInput(let chunkId, _),
             .toolResult(let chunkId, _):
            return chunkId
        }
    }
}
