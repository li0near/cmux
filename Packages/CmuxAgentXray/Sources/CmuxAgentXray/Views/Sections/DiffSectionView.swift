import SwiftUI

/// Unified-diff content renderer (foundation stub).
///
/// Phase D foundation only — applies per-line `.diffAdded` / `.diffRemoved`
/// `TextStyle` coloring against a leading `+` / `-` heuristic. Real
/// patch-aware diff renderer (hunk grouping, context lines, in-line
/// highlights) ships in a follow-up PR — see `MIGRATION_PLAN.md` §14
/// for the rollout.
@available(macOS 15, *)
struct DiffSectionView: View {

    let text: String
    let palette: HudPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(color(for: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("+") { return palette.green }
        if line.hasPrefix("-") { return palette.red }
        return palette.primary.opacity(0.85)
    }
}
