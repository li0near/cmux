import SwiftUI

/// `↗ Open detail · N lines` link. Rendered after a body section
/// that overflows its caps, OR as the entire inline surface for
/// `.alwaysLink` sections (assistant text, skill body).
@available(macOS 15, *)
struct OpenDetailLinkView: View {
    let totalLines: Int
    let palette: HudPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
                Text("Open detail · \(totalLines) lines")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(palette.cyan)
        }
        .buttonStyle(.plain)
    }
}
