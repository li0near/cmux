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
            if let chunks = content.chunks, !chunks.isEmpty {
                transcriptList(chunks: chunks, palette: palette)
            } else {
                ScrollView {
                    Text(content.body)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(bodyColor(palette: palette))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }

    /// Render a chunk transcript inside the detail tab using the same
    /// `ChunkRowView` as the live inspector. Used by abandoned-branch
    /// and sub-agent transcript detail surfaces.
    @ViewBuilder
    private func transcriptList(chunks: [AgentChunk], palette: HudPalette) -> some View {
        let agentKind: ChunkRowSnapshot.AgentKindLabel = .claude
        let snapshots = chunks.map {
            ChunkRowSnapshot.from($0, agentKind: agentKind, displayMode: .fullDetail)
        }
        let token = HudPaletteToken.from(palette)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(snapshots) { snapshot in
                    ChunkRowView(
                        snapshot: snapshot,
                        palette: token,
                        streamingAIChunkId: nil,
                        collapseAllTick: 0,
                        expandSnapTick: 0,
                        lastBulkAction: nil,
                        onOpenDetail: { _ in /* no nested detail */ }
                    )
                    .equatable()
                    .id(snapshot.id)
                    Divider()
                        .background(Color(nsColor: appearance.foregroundColor).opacity(0.06))
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
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
        case .assistantResponse: return "✶"
        case .abandonedBranch: return "↳"
        case .subagentTranscript: return "↳"
        case .skillBody: return "✦"
        case .slashCommandBody: return "/"
        case .systemReminderBody: return "!"
        case .recapBody: return "↺"
        case .localCommandCaveatBody: return "ⓘ"
        }
    }

    private func headerColor(palette: HudPalette) -> Color {
        switch content.kind {
        case .userPrompt: return palette.yellow
        case .thinking: return palette.dim
        case .systemOutput: return palette.cyan
        case .toolInput: return palette.cyan
        case .toolResult(_, let isError): return isError ? palette.red : palette.green
        case .assistantResponse: return palette.claude
        case .abandonedBranch: return palette.dim
        case .subagentTranscript: return palette.magenta
        case .skillBody: return palette.magenta
        case .slashCommandBody: return palette.cyan
        case .systemReminderBody: return palette.yellow
        case .recapBody: return palette.cyan
        case .localCommandCaveatBody: return palette.dim
        }
    }

    private func bodyColor(palette: HudPalette) -> Color {
        switch content.kind {
        case .thinking, .abandonedBranch, .localCommandCaveatBody:
            return palette.dim
        case .toolResult(_, let isError):
            return isError ? palette.red : palette.primary.opacity(0.85)
        default:
            return palette.primary
        }
    }
}
