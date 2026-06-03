import SwiftUI

/// Uniform chrome modifier applied to every entry row — soft border,
/// inner padding, expanded-state background. Applied via `.modifier(...)`
/// at the EntryView outer level so per-section content is consistent.
@available(macOS 15, *)
struct EntryChrome: ViewModifier {
    let palette: HudPalette
    let isExpanded: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isExpanded
                    ? AnyView(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(palette.expandedBackground)
                    )
                    : AnyView(EmptyView())
            )
    }
}

@available(macOS 15, *)
extension View {
    func entryChrome(palette: HudPalette, isExpanded: Bool) -> some View {
        modifier(EntryChrome(palette: palette, isExpanded: isExpanded))
    }
}
