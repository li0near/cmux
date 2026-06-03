import SwiftUI

/// Rounded-rect pill used for metadata trailing items (token counts,
/// word counts, durations, custom labels).
@available(macOS 15, *)
struct MetadataPillView: View {
    let text: String
    let palette: HudPalette

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(palette.dim)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.expandedBackground)
            )
    }
}
