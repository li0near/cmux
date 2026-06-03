import SwiftUI

/// Three-state colored status dot — pending (yellow) / ok (green) /
/// error (red). Used by Tool entries' header trailing items.
@available(macOS 15, *)
struct StatusDotView: View {
    let kind: StatusDotKind
    let palette: HudPalette

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    private var color: Color {
        switch kind {
        case .pending: return palette.yellow
        case .ok:      return palette.green
        case .error:   return palette.red
        }
    }
}
