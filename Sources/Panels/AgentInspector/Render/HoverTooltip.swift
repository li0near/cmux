import SwiftUI

/// Custom hover tooltip that fires after a configurable delay (default
/// 0.5 s). macOS's stock `.help(...)` honors the system tooltip delay
/// (`NSInitialToolTipDelay`, typically ~1.5 s) and provides no per-view
/// override — this modifier replaces it for cmux's status-bar pills
/// where users want feedback faster.
///
/// Renders as a non-interactive overlay anchored above the host view.
/// `.allowsHitTesting(false)` ensures clicks pass through to the
/// underlying button so the tooltip never voids a click — an earlier
/// `.popover`-based version did exactly that and was rejected.
struct HoverTooltip: ViewModifier {
    let text: String
    var delay: TimeInterval = 0.5

    @State private var isShowing = false
    @State private var pendingTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isShowing {
                    tooltipBubble
                        .offset(y: -32)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .zIndex(1000)
                }
            }
            .onHover { hovering in
                pendingTask?.cancel()
                if hovering {
                    let delaySeconds = delay
                    let task = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                        if !Task.isCancelled {
                            withAnimation(.easeOut(duration: 0.1)) {
                                isShowing = true
                            }
                        }
                    }
                    pendingTask = task
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isShowing = false
                    }
                }
            }
    }

    private var tooltipBubble: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.85))
            )
            .fixedSize()
    }
}

extension View {
    /// Show `text` as a hover tooltip after `delay` seconds. The tooltip
    /// floats above the host view as a non-interactive overlay — clicks
    /// pass through to the host.
    func hoverTooltip(_ text: String, delay: TimeInterval = 0.5) -> some View {
        modifier(HoverTooltip(text: text, delay: delay))
    }
}

