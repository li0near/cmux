import SwiftUI

/// Markdown content renderer (foundation stub).
///
/// Phase D foundation only — renders as plain `Text(...)` with the
/// `.codeMonospace` font. Rich markdown rendering (headings, bullets,
/// fenced code blocks, links) ships in a follow-up PR — see
/// `MIGRATION_PLAN.md` §14 for the rollout.
@available(macOS 15, *)
struct MarkdownSectionView: View {

    let text: String
    let palette: HudPalette

    var body: some View {
        Text(text)
            .font(Theme.DetailPanel.body)
            .foregroundStyle(palette.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
