public import SwiftUI

/// Semantic visual tokens for the AgentX-ray panel — layout dimensions
/// and typography groups, all under the `Theme` namespace. Nested
/// inside an outer enum to avoid colliding with SwiftUI's `Layout`
/// protocol while keeping call sites short:
///
///     Theme.Spacing.rowIconText        // 8pt
///     Theme.Opacity.dim                // 0.55
///     Theme.Row.name                   // 12pt semibold mono
///     Theme.SubRow.icon                // 11pt mono
///
/// Layout / Typography distinction is documentation-only — see the
/// `// MARK:` headers below — and does not show up at call sites.
///
/// Views in this package consume these tokens instead of literal
/// numbers so future visual tweaks land in one place.
@available(macOS 15, *)
public enum Theme {

    // MARK: - Layout — Spacing

    /// Inter-element gaps inside a single horizontal or vertical group.
    public enum Spacing {
        /// Top-level row HStack: icon ↔ text gap (8pt).
        public static let rowIconText: CGFloat = 8
        /// Sub-row HStack: smaller gap (6pt).
        public static let subRowIconText: CGFloat = 6
        /// Inside-pill segment gap; "scroll:" / "snap" tight pairing (4pt).
        public static let tight: CGFloat = 4
        /// Internal vertical spacing between header and expanded body
        /// inside a single row VStack (4pt).
        public static let verticalStack: CGFloat = 4
    }

    // MARK: - Layout — Padding

    /// Padding tokens applied with `.padding(.<edge>, ...)`.
    public enum Padding {
        /// Outer container left/right padding (12pt).
        public static let horizontal: CGFloat = 12
        /// Inside each pill (token / word-count / scroll-mode); 6pt L/R.
        public static let pillHorizontal: CGFloat = 6
        /// Inside each pill — top/bottom padding (2pt).
        public static let pillVertical: CGFloat = 2
        /// Inside the gray expanded body block (8pt around content).
        public static let expandedBodyBlock: CGFloat = 8
        /// `LazyVStack(spacing:)` between consecutive entries (4pt).
        /// Composed at the parent — entries have intrinsic height so
        /// this is the list's `spacing`, not a per-row padding.
        public static let topLevelEntryGap: CGFloat = 4
        /// Vertical breathing room around the LazyVStack inside the
        /// ScrollView (6pt).
        public static let transcriptVertical: CGFloat = 6
        /// Empty / detail panel outer left-right padding (16pt).
        public static let panelEdgeHorizontal: CGFloat = 16
        /// Empty / detail panel outer top-bottom padding (12pt).
        public static let panelEdgeVertical: CGFloat = 12
    }

    // MARK: - Layout — Metric

    /// Fixed visual metrics that pin element widths.
    public enum Metric {
        /// SF Symbol visual width for a top-level entry header icon (14pt).
        /// Determines `Indent.subRow` derivation.
        public static let rowIconWidth: CGFloat = 14
        /// SF Symbol visual width for a sub-entry icon (12pt).
        public static let subRowIconWidth: CGFloat = 12
        /// Status-dot diameter for the trailing tool-status indicator (6pt).
        public static let statusDot: CGFloat = 6
    }

    // MARK: - Layout — Indent

    /// Indent levels for nested rendering. Derived so the icon column
    /// alignment stays correct if `Metric.rowIconWidth` changes.
    public enum Indent {
        /// Sub-row icon aligns with the parent entry's first text
        /// character: `rowIconWidth + rowIconText` = 22pt.
        public static let subRow: CGFloat = Metric.rowIconWidth + Spacing.rowIconText
        /// Nested content (tool input/result inside the tool sub-row)
        /// aligns just past the row's icon column:
        /// `subRow + rowIconWidth` = 36pt. Predecessor parity
        /// (PARITY_PUNCH_LIST §3.8 — formula
        /// `expandedIndent + iconColumnWidth`).
        public static let nestedSubRow: CGFloat = Indent.subRow + Metric.rowIconWidth
    }

    // MARK: - Layout — Height

    /// Hit-frame heights for chrome elements. Containers center content
    /// via SwiftUI default; no `.padding(.vertical)` calls are needed
    /// when these heights are pinned.
    public enum Height {
        /// Status bar HStack height (32pt).
        public static let statusBar: CGFloat = 32
        /// Pill hit frame (20pt — token / word-count / scroll-mode).
        public static let pill: CGFloat = 20
        /// Icon-button hit frame (20pt — control buttons in status bar).
        /// The icon font itself stays at its `Theme.*.icon` size.
        public static let iconButton: CGFloat = 20
    }

    // MARK: - Layout — Stroke

    /// Stroke widths applied to overlays.
    public enum Stroke {
        /// Pill border line width (0.5pt — sub-pixel hairline).
        public static let pill: CGFloat = 0.5
    }

    // MARK: - Layout — Corner radius

    /// Rounded-rectangle corner radii.
    public enum CornerRadius {
        /// Pill corner radius (4pt).
        public static let pill: CGFloat = 4
        /// Expanded body block corner radius (4pt).
        public static let expandedBodyBlock: CGFloat = 4
    }

    // MARK: - Layout — Opacity

    /// Four discrete opacity levels — every other variant collapses into
    /// one of these. Pill stroke + assistant-response link underline both
    /// use ``dim``; tool-summary detail text uses ``detail``.
    public enum Opacity {
        /// Expanded body gray-block fill (0.06 — barely-perceptible wash).
        public static let bgWash: Double = 0.06
        /// Top divider above the transcript (0.15).
        public static let divider: Double = 0.15
        /// Secondary text, pill borders, link underline (0.55).
        public static let dim: Double = 0.55
        /// Tertiary text on dim — sub-row line counts, tool summary (0.75).
        public static let detail: Double = 0.75
    }

    // MARK: - Typography — Status bar

    /// Fonts for the panel's status bar (top strip).
    public enum StatusBar {
        public static let title = Font.system(size: 11, weight: .medium, design: .monospaced)
        public static let pillLabel = Font.system(size: 11, design: .monospaced)
        /// Glyph + control buttons (matches ``title`` size; no weight).
        public static let icon = Font.system(size: 11)
    }

    // MARK: - Typography — Top-level entry row

    /// Fonts for top-level entries (one entry per agent turn / user prompt).
    public enum Row {
        public static let name = Font.system(size: 12, weight: .semibold, design: .monospaced)
        public static let summary = Font.system(size: 12, design: .monospaced)
        /// Trailing items: label / pill / timestamp (11pt).
        public static let meta = Font.system(size: 11, design: .monospaced)
        /// Header icon — matches ``name`` size; no weight, so SF Symbols
        /// don't render bold.
        public static let icon = Font.system(size: 12)
    }

    // MARK: - Typography — Sub-entry row

    /// Fonts for sub-entries (thinking / tool / assistantText) — all one
    /// point smaller than the corresponding ``Row`` font. Sub-row names
    /// use `.medium` weight (one step lighter than the parent ``Row``'s
    /// `.semibold`) — they read as a quieter continuation of the parent
    /// row, not a sibling header.
    public enum SubRow {
        public static let name = Font.system(size: 11, weight: .medium, design: .monospaced)
        public static let summary = Font.system(size: 11, design: .monospaced)
        /// Line counts, tool durations (10pt).
        public static let meta = Font.system(size: 10, design: .monospaced)
        public static let icon = Font.system(size: 11)
    }

    // MARK: - Typography — Detail panel

    /// Fonts for the detail-mode panel (full transcript / assistant-text /
    /// abandoned branch list).
    public enum DetailPanel {
        public static let heading = Font.system(size: 13, weight: .semibold, design: .monospaced)
        public static let subtitle = Font.system(size: 11, design: .monospaced)
        public static let body = Font.system(size: 12, design: .monospaced)
    }
}
