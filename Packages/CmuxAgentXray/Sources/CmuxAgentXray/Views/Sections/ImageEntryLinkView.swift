import SwiftUI

/// Inline link for a ``Section/image(_:)`` — surfaces a clickable
/// "↗ Image" affordance in the entry body. Clicking opens the image
/// in a real cmux preview panel via the host's
/// `openImageInPanel(...)` short-circuit; the package never decodes
/// or renders the bytes itself.
///
/// Replaces the prior 80×80 inline thumbnail. The thumbnail's
/// lazy-decode infrastructure was unnecessary cost — sessions with
/// many user-pasted screenshots paid the decode for every visible
/// entry. With the link shape, no bytes are touched until the user
/// clicks.
@available(macOS 15, *)
struct ImageEntryLinkView: View {

    let palette: HudPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                Text(label)
                    .font(Theme.SubEntry.title)
            }
            .foregroundStyle(palette.cyan)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.expandedBackground)
            )
        }
        .buttonStyle(.plain)
    }

    private var label: String {
        String(
            localized: "agentXray.section.image.label",
            defaultValue: "Image",
            bundle: .module
        )
    }
}
