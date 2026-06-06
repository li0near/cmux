import SwiftUI

/// Source-code content renderer (foundation stub).
///
/// Phase D foundation only — renders as a monospaced `Text(...)`.
/// Per-language syntax highlighting ships in a follow-up PR — see
/// `MIGRATION_PLAN.md` §14 for the rollout.
@available(macOS 15, *)
struct CodeSectionView: View {

    let text: String
    let language: String?
    let palette: HudPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.dim)
            }
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(palette.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
