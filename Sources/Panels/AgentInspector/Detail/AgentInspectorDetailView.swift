import SwiftUI
import AppKit

/// Static rendering for an `AgentInspectorPanel` in `.detail` mode. Reuses the
/// same palette, fonts, and metadata-pill conventions as the live transcript
/// list so the detail tab reads as a natural extension of the inspector.
struct AgentInspectorDetailView: View {
    let content: AgentInspectorDetailContent
    let appearance: PanelAppearance

    var body: some View {
        let palette = HudPalette(appearance: appearance)
        VStack(alignment: .leading, spacing: 0) {
            header(palette: palette)
            Divider()
                .background(Color(nsColor: appearance.foregroundColor).opacity(0.15))
            ScrollView {
                Text(content.body)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(bodyColor(palette: palette))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }

    private func header(palette: HudPalette) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(headerGlyph)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(headerColor(palette: palette))
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(headerColor(palette: palette))
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(palette.dim)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerGlyph: String {
        switch content.kind {
        case .userPrompt: return "▶"
        case .thinking: return "⊡"
        case .systemOutput: return HudGlyph.toolArrow
        case .toolInput: return HudGlyph.toolArrow
        case .toolResult(_, let isError): return isError ? HudGlyph.errorCross : HudGlyph.completedCheck
        }
    }

    private func headerColor(palette: HudPalette) -> Color {
        switch content.kind {
        case .userPrompt: return palette.yellow
        case .thinking: return palette.dim
        case .systemOutput: return palette.cyan
        case .toolInput: return palette.cyan
        case .toolResult(_, let isError): return isError ? palette.red : palette.green
        }
    }

    private func bodyColor(palette: HudPalette) -> Color {
        switch content.kind {
        case .thinking: return palette.dim
        case .toolResult(_, let isError): return isError ? palette.red : palette.primary.opacity(0.85)
        default: return palette.primary
        }
    }
}
