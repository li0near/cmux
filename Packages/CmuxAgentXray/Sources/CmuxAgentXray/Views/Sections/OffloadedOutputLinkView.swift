import SwiftUI

/// Inline link for a ``Section/offloadedOutput(_:)`` — surfaces an
/// "↗ Open offloaded result · 29.3KB" affordance in the entry body.
/// Clicking opens the offloaded file in the detail tab via the
/// `onOpen` closure.
@available(macOS 15, *)
struct OffloadedOutputLinkView: View {

    let offloaded: OffloadedOutput
    let palette: HudPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.forward.square")
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
        let template = String(
            localized: "agentXray.section.offloadedOutput.link",
            defaultValue: "Open offloaded result · %@",
            bundle: .module
        )
        return String(format: template, offloaded.sizeLabel)
    }
}
