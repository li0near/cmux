# Agent workflow for Swift code in cmux

Companion to `AGENTS.md` / `CLAUDE.md`. Those files cover cmux-specific
operational rules (build/reload, debug log, pitfalls, policies). This
file covers how a coding agent should **navigate Swift code, find bugs
systematically, and reference up-to-date Apple documentation** without
relying on stale training memory.

Read this before non-trivial Swift work.

## Code navigation

### Prefer LSP over grep for symbols

`sourcekit-lsp` (ships with Xcode) understands Swift types, generics,
and module boundaries. Grep matches text in comments, strings, and
unrelated identifiers. For any non-trivial work:

- "Where is `X` defined / used" → LSP go-to-definition / find-references.
- Type info on hover catches generic-substitution mistakes that grep
  cannot see.
- Workspace-wide rename should go through LSP so the safety check is
  type-aware.

The harness exposes `sourcekit-lsp` via the `LSP` deferred tool. Load
its schema with `ToolSearch query="select:LSP"` before any refactor or
"find all callers of X" task. Falling back to `rg` is fine for plain
text — but pair it with LSP whenever the target is a symbol.

### Delegate exploration to subagents

For "where is X" / "list every caller of Y" / "audit all uses of Z"
spread across many files, prefer the `Explore` agent over reading
files sequentially yourself. Reasons:

- Protects the main context window — you get a focused report instead
  of raw file dumps.
- Parallelizable — multiple `Explore` calls in one tool block run
  concurrently.
- Forces a written summary, which is easier to audit later than a
  scrollback of `Read` calls.

Reserve `general-purpose` or `systematic-debugger` agents for
multi-step root-cause work that spans research + reasoning, not
plain location lookups.

### Build verification

Always use a tagged derived-data path so you don't trample the user's
running debug instance:

```bash
xcodebuild -project cmux.xcodeproj \
  -scheme cmux -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-<your-tag> build
```

For type-check-only validation of a Swift package subdirectory,
`swift build` from inside the package is faster than full `xcodebuild`.

Don't rely on type-checking in your head. The compiler is the
authority; run it.

## Finding and fixing bugs

Bug-fix workflow rules — two-commit regression pattern, real-device
reproduction on the reporter's macOS, behavior-level coverage over
source-text assertions — live in `AGENTS.md`
("Regression test commit policy", "Test quality policy", "Shared
behavior policy", and the macOS-version-divergence pitfall). Read
those before fixing any user-reported bug. This file does not
restate them.

## Referencing Apple / Swift documentation

Your training knowledge of SwiftUI, AppKit, and Foundation APIs is
**partial and outdated**. Cutoff dates predate most of the macOS 15
and macOS 26 API surface, and Apple silently changes behavior between
OS majors without renaming APIs. Default to verifying against
authoritative sources before recommending an API.

**Source priority (highest first):**

1. **Local Xcode DocC archives** for first-party `.docc` catalogues
   you compile yourself with `xcrun docc convert`. **Note for
   system frameworks**: Xcode 26.5 ships *no* downloadable DocC
   archives for SwiftUI / AppKit / Foundation
   (`mdfind -name "*.doccarchive"` is empty;
   `xcodebuild -downloadComponent` accepts only `MetalToolchain`;
   `xcrun docc` is a compiler/previewer not a downloader; Xcode's
   `Help > Developer Documentation` is a web-backed viewer that
   hits `developer.apple.com`). Apple removed the
   "Download All Documentation" option in Xcode ~13. So this
   priority slot is meaningful for *your own* DocC catalogues
   only, not for system frameworks.

2. **Apple Developer documentation (online)**. Access via the
   `/browse-url` skill — `developer.apple.com` pages are JS-rendered,
   so plain HTTP fetchers often return empty bodies. The browse-url
   skill renders the page properly. **Do not use `WebSearch`** for
   Apple docs; the search results are noisy and the snippets are not
   authoritative.

   For system-framework docs, the most direct fetch is the JSON
   DocC endpoint at
   `https://developer.apple.com/tutorials/data/documentation/<path>.json`
   — same machine-readable renderJSON Xcode's documentation viewer
   parses, fetchable via `curl --socks5 localhost:3333` for plain
   text extraction. Example:

   ```bash
   curl -sS --socks5 localhost:3333 -A "Mozilla/5.0" \
     "https://developer.apple.com/tutorials/data/documentation/swiftui/lazyvstack.json"
   ```

3. **Swift evolution proposals**. `github.com/swiftlang/swift-evolution`
   is plain markdown — fetch directly. Authoritative for "when did API
   X land" and "what was the design rationale."

4. **The Swift / SwiftUI source** when something is undocumented or the
   docs disagree with observed behavior. `swift-syntax`, `swift-foundation`,
   and the open-source bits of the standard library are on GitHub.

### Always state provenance

When recommending an API, name the source: "per Xcode 16.x DocC for
`ScrollView`" or "per `developer.apple.com` page fetched via
`/browse-url` on <date>". This lets the user spot when you're pulling
from memory and call it out.

### Match the deployment target

`cmux` targets `MACOSX_DEPLOYMENT_TARGET = 14.0`. An API that exists
in macOS 15+ is not usable here without an `if #available` gate. Check
the deployment target in `cmux.xcodeproj/project.pbxproj` before
recommending anything tagged "macOS 15+" or "macOS 26+".

## Repo-specific Swift gotchas

The full pitfall list — snapshot boundary for SwiftUI list subtrees,
no state mutation inside view-body computations, typing-latency hot
paths, localization, test-file pbxproj wiring, custom UTType
declarations, submodule-push ordering — lives in `AGENTS.md`
"Pitfalls". Read it before touching SwiftUI list code, terminal hot
paths, or anything in `cmuxTests/`. This file does not restate them.

## Verify-before-trust checklist

Before recommending an approach, especially one drawn from prior
sessions or memory:

1. The file/path/symbol I'm about to cite — does it exist on the
   current branch tip? (`Read` it; don't guess.)
2. The API I'm recommending — is it available at the project's
   deployment target? (Check `MACOSX_DEPLOYMENT_TARGET`.)
3. The doc I'm citing — when did I fetch it? Is there a chance Apple
   has updated it since? (If unsure, re-fetch via `/browse-url`.)
4. The behavior I'm asserting — have I observed it on the user's
   macOS, or am I assuming it from a different OS major?

Cite sources, name dates, run the compiler, and let observed behavior
override memory whenever they disagree.
