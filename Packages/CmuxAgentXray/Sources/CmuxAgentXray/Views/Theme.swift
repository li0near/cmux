public import SwiftUI

/// Semantic visual tokens for the AgentX-ray panel — layout dimensions
/// and typography groups, all under the `Theme` namespace. Nested
/// inside an outer enum to avoid colliding with SwiftUI's `Layout`
/// protocol while keeping call sites short:
///
///     Theme.Spacing.entryIconText        // 8pt
///     Theme.Opacity.dim                  // 0.55
///     Theme.Entry.nameEmphasis           // 12pt semibold mono
///     Theme.Entry.icon                   // 12pt mono
///
/// **One typography for everything.** Top-level entries and sub-entries
/// share `Theme.Entry`. Emphasis (semibold name) is selected per-entry
/// via the ``Entry/isEmphasized`` predicate, not via a separate typography
/// token group.
///
/// **One indent unit.** `Theme.Indent.unit` is the per-level indent step
/// (= icon column + icon-text gap). `Theme.Indent.at(depth:)` multiplies
/// to scale to any nest depth.
///
/// Views in this package consume these tokens instead of literal
/// numbers so future visual tweaks land in one place.
@available(macOS 15, *)
public enum Theme {

    // MARK: - Layout — Spacing

    /// Inter-element gaps inside a single horizontal or vertical group.
    public enum Spacing {
        /// HStack icon ↔ text gap (6pt). Same at every depth — header
        /// rendering is universal.
        public static let entryIconText: CGFloat = 6
        /// Inside-pill segment gap; "scroll:" / "snap" tight pairing (4pt).
        public static let tight: CGFloat = 4
        /// Internal vertical spacing between header and expanded body
        /// inside a single entry VStack (4pt).
        public static let verticalStack: CGFloat = 4
        /// Vertical gap between consecutive sections inside a body
        /// (3pt — slightly tighter than ``verticalStack`` so the body
        /// reads as one block rather than a column of paragraphs).
        public static let sectionGap: CGFloat = 3
    }

    // MARK: - Layout — Padding

    /// Padding tokens applied with `.padding(.<edge>, ...)`.
    /// **Vertical-centering paddings on fixed-height containers
    /// (status bar, pill, icon button) are deliberately absent** —
    /// those use `Theme.Height.*` plus SwiftUI's default centering
    /// instead of explicit `.padding(.vertical, …)`.
    public enum Padding {
        /// Status-bar horizontal padding (8pt — slightly larger than
        /// the transcript's outer padding so the chrome row breathes
        /// against the panel edge).
        public static let statusBar: CGFloat = 8
        /// Outer transcript-list padding (6pt) applied symmetrically on
        /// every edge — the gutter between entry content and the panel
        /// border. Smaller than ``statusBar`` because entries already
        /// start at their own icon column.
        public static let transcriptOuter: CGFloat = 6
        /// Inside each pill (token / word-count / scroll-mode); 6pt L/R.
        public static let pillHorizontal: CGFloat = 6
        /// Inside the gray expanded body block (6pt around content).
        public static let expandedBodyBlock: CGFloat = 6
        /// Universal `LazyVStack(spacing:)` between consecutive entries
        /// at any nest depth (4pt).
        public static let entryGap: CGFloat = 4
    }

    // MARK: - Layout — Metric

    /// Fixed visual metrics that pin element widths.
    public enum Metric {
        /// SF Symbol visual width for an entry header icon (14pt). One
        /// icon column at every depth — the unified renderer pins this
        /// width on every header so the gutter geometry is stable
        /// regardless of which symbol is rendered.
        public static let entryIconWidth: CGFloat = 14
        /// Status-dot diameter for the trailing tool-status indicator (6pt).
        public static let statusDot: CGFloat = 6
    }

    // MARK: - Layout — Indent

    /// Per-level indent step. The unified renderer applies one ``unit``
    /// per recursion level so cumulative indent at depth N = N × unit.
    public enum Indent {
        /// One indent step: `entryIconWidth + entryIconText` = 22pt.
        public static let unit: CGFloat = Metric.entryIconWidth + Spacing.entryIconText
        /// Cumulative leading indent for an entry at the given depth.
        /// Depth 0 = 0pt (outer chrome handles the global horizontal
        /// padding); depth N = N × unit.
        public static func at(depth: Int) -> CGFloat {
            CGFloat(depth) * unit
        }
    }

    // MARK: - Layout — Height

    /// Hit-frame heights for chrome elements. Containers center content
    /// via SwiftUI default; no `.padding(.vertical)` calls are needed
    /// when these heights are pinned.
    public enum Height {
        /// Status bar HStack height (32pt).
        public static let statusBar: CGFloat = 32
        /// Status-bar pill hit frame (20pt — the scroll-mode pill).
        /// Entry-header pills (`MetadataPill`, `TokenPillView`) size to
        /// text content and do NOT use this height.
        public static let pill: CGFloat = 20
        /// Visible frame for status-bar icon buttons (14pt). Tight
        /// enough that icons rendered at 11pt visually fill the frame
        /// with only a small margin, packing the button row close
        /// together. Hit area is bigger via the second `.frame(...)` —
        /// see ``iconButtonHitWidth``.
        public static let iconButton: CGFloat = 14
        /// Click hit size for status-bar icon buttons (18pt — square).
        /// Extends 2pt past the visible 14pt frame on each side so
        /// adjacent hit zones meet exactly at the HStack-4pt spacing
        /// midpoint — no dead-space between buttons, no overlap.
        public static let iconButtonHit: CGFloat = 18
    }

    // MARK: - Layout — Stroke

    /// Stroke widths applied to overlays.
    public enum Stroke {
        /// Pill border line width (0.5pt — sub-pixel hairline).
        public static let pill: CGFloat = 0.5
        /// Expansion-gutter rail width (3pt — structural element drawn
        /// in the expanded entry's accent color, dimmed via
        /// ``Theme/Opacity/gutter``).
        public static let gutter: CGFloat = 3
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

    /// Discrete opacity levels — every other variant collapses into one
    /// of these.
    public enum Opacity {
        /// Hover-highlight foreground tint (0.10 — translucent lighter
        /// spot, theme-adaptive via the palette's foreground color).
        public static let hoverTint: Double = 0.10
        /// Top divider above the transcript (0.15).
        public static let divider: Double = 0.15
        /// Expansion-gutter rail (0.35 — accent-tinted but understated;
        /// the rail is a structural cue, not a color emphasis).
        public static let gutter: Double = 0.35
        /// Secondary text, pill borders, link underline (0.55).
        public static let dim: Double = 0.55
    }

    // MARK: - Animation timing

    /// Animation durations (seconds). All UI fades / state-change
    /// transitions in this package read from this group so timing
    /// stays consistent.
    public enum Timing {
        /// Quick fade — hover affordance, gutter brighten, button
        /// state changes (0.12s).
        public static let quick: Double = 0.12
    }

    // MARK: - Typography — Status bar

    /// Fonts for the panel's status bar (top strip).
    public enum StatusBar {
        public static let title = Font.system(size: 11, weight: .medium, design: .monospaced)
        public static let pillLabel = Font.system(size: 11, design: .monospaced)
        /// Glyph + control buttons (11pt — matches the title font size;
        /// tightening the cluster relies on the button frame
        /// (``Theme/Height/iconButton``) and HStack spacing rather than
        /// shrinking the icons themselves).
        public static let icon = Font.system(size: 11)
    }

    // MARK: - Typography — Entry (universal)

    /// One typography group for every entry and sub-entry. The unified
    /// renderer reads ``nameEmphasis`` vs ``nameRegular`` from the
    /// ``Entry/isEmphasized`` predicate; everything else (title, meta,
    /// icon) is the same at every nest depth.
    public enum Entry {
        /// Name slot when the entry is emphasized (top-level kinds today
        /// — see ``Entry/isEmphasized``). 12pt semibold mono.
        public static let nameEmphasis = Font.system(size: 12, weight: .semibold, design: .monospaced)
        /// Name slot when the entry is not emphasized (sub-entries
        /// today). 12pt mono no weight.
        public static let nameRegular = Font.system(size: 12, design: .monospaced)
        /// Title slot — dynamic content text rendered after the name
        /// (file path, command name, recap title, preview text). 12pt
        /// mono, no weight.
        public static let title = Font.system(size: 12, design: .monospaced)
        /// Trailing items: label / pill / timestamp / sub-entry trailing
        /// metadata (11pt).
        public static let meta = Font.system(size: 11, design: .monospaced)
        /// Header icon — matches ``nameEmphasis`` size; no weight, so SF
        /// Symbols don't render bold.
        public static let icon = Font.system(size: 12)
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
