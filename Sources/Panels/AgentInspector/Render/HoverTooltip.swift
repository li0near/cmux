import SwiftUI

/// Custom hover tooltip that fires after a configurable delay (default
/// 0.5 s). macOS's stock `.help(...)` honors the system tooltip delay
/// (`NSInitialToolTipDelay`, typically ~1.5 s) and provides no per-view
/// override — this modifier replaces it for cmux's status-bar pills
/// where users want feedback faster.
///
/// Renders the tooltip as a small popover anchored to the top of the
/// host view. Cancelled if the cursor leaves before the delay elapses.
struct HoverTooltip: ViewModifier {
    let text: String
    var delay: TimeInterval = 0.5

    @State private var isShowing = false
    @State private var pendingTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isShowing, arrowEdge: .top) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .fixedSize()
            }
            .onHover { hovering in
                pendingTask?.cancel()
                if hovering {
                    let delaySeconds = delay
                    let task = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                        if !Task.isCancelled {
                            isShowing = true
                        }
                    }
                    pendingTask = task
                } else {
                    isShowing = false
                }
            }
    }
}

extension View {
    /// Show `text` as a popover-style tooltip after the cursor has
    /// hovered over the view for `delay` seconds.
    func hoverTooltip(_ text: String, delay: TimeInterval = 0.5) -> some View {
        modifier(HoverTooltip(text: text, delay: delay))
    }
}
