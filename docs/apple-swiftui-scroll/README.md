# Apple SwiftUI Scroll APIs — local reference

> **Stale-content warning.** Per `Sources/Panels/AgentInspector/AGENT_WORKFLOW.md`, the canonical source for SwiftUI/AppKit docs is now the JSON DocC endpoint at `developer.apple.com/tutorials/data/documentation/<path>.json` (Xcode 26.5 ships no downloadable DocC archives for system frameworks). The snapshots below were captured from `cmux browser get text` on a single date and have not been refreshed since. Treat them as a starting reference only; re-fetch anything load-bearing via curl + SOCKS5 before citing. The "Decisions encoded in the inspector" section below was wrong about `.defaultScrollAnchor(.bottom)` — see correction below.

## Files

| File | API | Min platform |
|---|---|---|
| `defaultscrollanchor.md` | `View.defaultScrollAnchor(_ anchor: UnitPoint?) -> some View` | iOS 17 / macOS 14 |
| `defaultscrollanchor-for.md` | `View.defaultScrollAnchor(_ anchor: UnitPoint?, for role: ScrollAnchorRole) -> some View` | iOS 18 / macOS 15 |
| `scrollanchorrole.md` | `struct ScrollAnchorRole` (`.alignment`, `.initialOffset`, `.sizeChanges`) | iOS 18 / macOS 15 |
| `scrollposition-id.md` | `View.scrollPosition(id: Binding<(some Hashable)?>, anchor: UnitPoint?) -> some View` | iOS 17 / macOS 14 |
| `scrollposition-binding.md` | `View.scrollPosition(_ position: Binding<ScrollPosition>, anchor: UnitPoint?) -> some View` | iOS 17 / macOS 14 |
| `scrollgeometry.md` | `struct ScrollGeometry` | iOS 18 / macOS 15 |
| `lazyvstack.md` | `struct LazyVStack` | iOS 14 / macOS 11 |
| `scrollview.md` | `struct ScrollView` | iOS 13 / macOS 10.15 |

## Decisions encoded in the inspector — corrected

A previous version of this file claimed `.defaultScrollAnchor(.bottom)` was "the systematic fix" for the blank-screen-on-shrink bug class. **That claim was incorrect.** `DECISIONS.md` Don't-re-walk #5 records that the modifier was tried and rejected — it broke snap-mode top-alignment because the small-content `.alignment` role inherits the `.bottom` anchor and pins chunks at viewport bottom.

### What's actually shipped

`Sources/Panels/AgentInspector/AgentInspectorPanelView.swift` uses:

```swift
ScrollView {
    LazyVStack { ForEach(snapshots) { ChunkRowView(...) } }
}
```

with **no** `.defaultScrollAnchor(...)` modifier. The bulk-collapse and live-tail handlers call `proxy.scrollTo(visibleLastSnapshotId(), anchor: .bottom)` — targeting the last visible chunk's id, not the LazyVStack container id — to sidestep the documented "trade some degree of layout correctness for performance, because the system only calculates the geometry for subviews as they become visible" contract from Apple's "Creating Performant Scrollable Stacks" page. This is a **partial mitigation**, not a complete fix; see `DECISIONS.md` "Mitigations currently shipped" and Don't-re-walk #8 for the residual case (mid-`.fullyExpanded → .topLevelExpanded` transitions can still occasionally blank when accumulated off-screen drift is large). AppKit migration is ruled out per Don't-re-walk #4.
