import Foundation
import Testing
@testable import CmuxAgentXray

/// Phase F commit 8: resolver coverage. The resolver picks per-click
/// suggested filenames whose extensions drive cmux's
/// `Workspace.openFileSurfaces` panel dispatch (`.md` → markdown
/// panel; everything else → file-preview panel + highlight.js).
/// Pre-Phase-F there was zero coverage on this path; the per-context
/// table below pins the suggested-basename and source-variant
/// invariants the host depends on.
@Suite("DetailContent.resolve — per-click-context routing")
struct DetailContentResolverTests {

    // MARK: - Helpers

    private func userEntry(
        id: String = "u1",
        body: Body
    ) -> Entry {
        .user(
            UserEntry(
                id: .fromJSONL(id),
                header: Header(),
                body: body
            )
        )
    }

    private func agentEntry(
        id: String = "a1",
        subEntries: [Entry]
    ) -> Entry {
        .agent(
            AgentEntry(
                id: .fromJSONL(id),
                header: Header(),
                body: Body(sections: []),
                usage: AgentEntry.TokenUsage(),
                subEntries: subEntries
            )
        )
    }

    private func textSub(
        id: String,
        kind: TextSubEntry.Kind,
        body: String
    ) -> Entry {
        .text(
            TextSubEntry(
                kind: kind,
                id: .derived(parent: "a1", kind: id),
                parentEntryID: .fromJSONL("a1"),
                header: Header(),
                body: Body(sections: [.text([body], style: .normal)]),
                wordCount: body.split(separator: " ").count
            )
        )
    }

    private func toolSub(
        id: String,
        toolName: String,
        body: Body,
        status: ToolEntry.Status = .ok,
        inputFilePath: String? = nil
    ) -> Entry {
        .tool(
            ToolEntry(
                id: .fromJSONL(id),
                parentEntryID: .fromJSONL("a1"),
                header: Header(name: toolName),
                body: body,
                status: status,
                inputFilePath: inputFilePath
            )
        )
    }

    // MARK: - Top-level entries

    @Test("User prompt → .text with prompt.txt")
    func userPrompt() {
        let entry = userEntry(body: .text(["please refactor"]))
        let request = DetailRequest.bodySection(targetID: "u1", sectionIndex: 0)
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .text(body: "please refactor", suggestedFilename: "prompt.txt"))
    }

    @Test("User image-only message → .image with image.<ext>")
    func userImageOnly() {
        let image = ImageSource(mediaType: "image/png", data: "AAAA")
        let entry = userEntry(body: Body(sections: [.image(image)]))
        let request = DetailRequest.bodySection(targetID: "u1", sectionIndex: 0)
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .image(image, suggestedFilename: "image.png"))
    }

    @Test("User prompt with text + trailing image keeps text routing")
    func userTextWithImage() {
        let image = ImageSource(mediaType: "image/png", data: "AAAA")
        let entry = userEntry(body: Body(sections: [
            .text(["take a look"], style: .normal),
            .image(image)
        ]))
        let request = DetailRequest.bodySection(targetID: "u1", sectionIndex: 0)
        let content = DetailContent.resolve(request: request, entry: entry)
        // Text body non-empty → text wins over image arm.
        #expect(content?.source == .text(body: "take a look", suggestedFilename: "prompt.txt"))
    }

    @Test("User entry with empty text body and no image → nil")
    func userEntryEmpty() {
        let entry = userEntry(body: Body(sections: [.text([""], style: .normal)]))
        let request = DetailRequest.bodySection(targetID: "u1", sectionIndex: 0)
        #expect(DetailContent.resolve(request: request, entry: entry) == nil)
    }

    @Test("Synthesized branchLink → .transcript with rootUuid as sourceEntryID")
    func branchLinkTranscript() {
        let abandoned: [Entry] = [
            userEntry(id: "u-abandoned", body: .text(["old prompt"]))
        ]
        let entry = Entry.synthesized(
            SynthesizedEntry(
                id: .fromJSONL("synth-1"),
                header: Header(),
                body: Body(sections: []),
                kind: .branchLink(branchRootUuid: "branch-root-uuid"),
                subEntries: abandoned
            )
        )
        let request = DetailRequest.bodySection(targetID: "synth-1", sectionIndex: 0)
        let content = DetailContent.resolve(request: request, entry: entry)
        if case .transcript(let sourceEntryID, let entries) = content?.source {
            #expect(sourceEntryID == "branch-root-uuid")
            #expect(entries.count == 1)
        } else {
            Issue.record("Expected .transcript source; got \(String(describing: content?.source))")
        }
    }

    // MARK: - Agent sub-entries

    @Test("Assistant text sub-entry → .text with response.md")
    func assistantText() {
        let sub = textSub(id: "assistantText-0", kind: .assistant, body: "all done")
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(
            targetID: sub.id.stableString,
            sectionIndex: 0
        )
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .text(body: "all done", suggestedFilename: "response.md"))
    }

    @Test("Thinking sub-entry → .text with thinking.md")
    func thinkingText() {
        let sub = textSub(id: "thinking-0", kind: .thinking, body: "let me think")
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(
            targetID: sub.id.stableString,
            sectionIndex: 0
        )
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .text(body: "let me think", suggestedFilename: "thinking.md"))
    }

    // MARK: - Tool sub-entries: input section (sectionIndex == 0)

    @Test("Tool input (non-Edit) at sectionIndex 0 → .text with tool-input.json")
    func toolInputJsonSection() {
        let body = Body(sections: [
            .text(["{\n  \"file_path\": \"/foo\"\n}"], style: .normal),
            .text(["read 50 lines"], style: .normal)
        ])
        let sub = toolSub(id: "t1", toolName: "Read", body: body, inputFilePath: "/foo.swift")
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(targetID: "t1", sectionIndex: 0)
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .text(
            body: "{\n  \"file_path\": \"/foo\"\n}",
            suggestedFilename: "tool-input.json"
        ))
    }

    // MARK: - Tool sub-entries: result section

    @Test("Tool result with inputFilePath uses the basename as suggestedFilename")
    func toolResultWithInputFilePath() {
        let body = Body(sections: [
            .text(["{...}"], style: .normal),
            .text(["public struct Foo {}"], style: .normal)
        ])
        let sub = toolSub(
            id: "r1",
            toolName: "Read",
            body: body,
            inputFilePath: "/abs/path/Foo.swift"
        )
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(targetID: "r1", sectionIndex: 1)
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .text(
            body: "public struct Foo {}",
            suggestedFilename: "Foo.swift"
        ))
    }

    @Test("Tool result without inputFilePath, plain text → fenced markdown + tool-result.md")
    func toolResultBashPlainTextWrapped() {
        let body = Body(sections: [
            .text(["bash command"], style: .normal),
            .text(["just plain output\nno structure"], style: .normal)
        ])
        let sub = toolSub(id: "b1", toolName: "Bash", body: body)
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(targetID: "b1", sectionIndex: 1)
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .text(
            body: "```\njust plain output\nno structure\n```",
            suggestedFilename: "tool-result.md"
        ))
    }

    @Test("Tool result without inputFilePath, JSON → tool-result.json (no wrap)")
    func toolResultJsonNoWrap() {
        let json = "{\"a\":1,\"b\":[2,3]}"
        let body = Body(sections: [
            .text(["fetch"], style: .normal),
            .text([json], style: .normal)
        ])
        let sub = toolSub(id: "j1", toolName: "WebFetch", body: body)
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(targetID: "j1", sectionIndex: 1)
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .text(body: json, suggestedFilename: "tool-result.json"))
    }

    @Test("Tool result without inputFilePath, diff-shaped → tool-result.diff.md (diff-fenced)")
    func toolResultDiffShaped() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1 +1 @@
        -let x = 1
        +let x = 2
        """
        let body = Body(sections: [
            .text(["git diff"], style: .normal),
            .text([diff], style: .normal)
        ])
        let sub = toolSub(id: "d1", toolName: "Bash", body: body)
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(targetID: "d1", sectionIndex: 1)
        let content = DetailContent.resolve(request: request, entry: entry)
        let expected = "```diff\n\(diff)\n```"
        #expect(content?.source == .text(body: expected, suggestedFilename: "tool-result.diff.md"))
    }

    @Test("Tool result .code(.diff) → tool-result.diff.md as HTML table (DiffHTMLRenderer)")
    func toolResultDiffHunks() {
        let hunk = DiffHunk(
            oldStart: 10,
            oldLines: 3,
            newStart: 10,
            newLines: 3,
            lines: [
                " context line",
                "-let x = 1",
                "+let x = 2",
                " trailing"
            ]
        )
        let body = Body(sections: [
            .text(["{...}"], style: .normal),
            .code(.diff(hunks: [hunk], language: "swift"))
        ])
        let sub = toolSub(
            id: "edit1",
            toolName: "Edit",
            body: body,
            inputFilePath: "/abs/foo.swift"
        )
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(targetID: "edit1", sectionIndex: 1)
        let content = DetailContent.resolve(request: request, entry: entry)
        guard case .text(let html, let suggestedFilename) = content?.source else {
            Issue.record("Expected .text source; got \(String(describing: content?.source))")
            return
        }
        #expect(suggestedFilename == "tool-result.diff.md")
        // HTML structural assertions — full structural match is brittle
        // (CSS classes can churn). Verify the chunk shape that drives
        // the markdown panel's render: table + per-classification rows
        // + line numbers + correct file path in caption.
        #expect(html.contains("<table class=\"diff-table\""))
        #expect(html.contains("<caption class=\"diff-caption\">/abs/foo.swift</caption>"))
        #expect(html.contains("@@ -10,3 +10,3 @@"))
        #expect(html.contains("class=\"diff-context\""))
        #expect(html.contains("class=\"diff-rem\""))
        #expect(html.contains("class=\"diff-add\""))
        #expect(html.contains("let x = 1"))
        #expect(html.contains("let x = 2"))
    }

    @Test("Tool result with markdown ≥2 H3 → tool-result.md (no wrap)")
    func toolResultMarkdownNoWrap() {
        let md = """
        ### Result
        navigated successfully

        ### Ran code
        await page.goto('x');
        """
        let body = Body(sections: [
            .text(["browser action"], style: .normal),
            .text([md], style: .normal)
        ])
        let sub = toolSub(id: "p1", toolName: "browser_navigate", body: body)
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(targetID: "p1", sectionIndex: 1)
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .text(body: md, suggestedFilename: "tool-result.md"))
    }

    // MARK: - Tool sub-entries: image / offloaded / transcript

    @Test("Tool result image (Playwright screenshot) → .image with screenshot.<ext>")
    func toolImageScreenshot() {
        let image = ImageSource(mediaType: "image/jpeg", data: "AAAA")
        let body = Body(sections: [
            .text(["screenshot"], style: .normal),
            .image(image)
        ])
        let sub = toolSub(id: "img1", toolName: "browser_take_screenshot", body: body)
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(targetID: "img1", sectionIndex: 1)
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .image(image, suggestedFilename: "screenshot.jpg"))
    }

    @Test("Offloaded tool result → .file(path)")
    func toolOffloadedFile() {
        let off = OffloadedOutput(path: "/tmp/cc-offloaded.txt", sizeLabel: "29.3KB")
        let body = Body(sections: [
            .text(["bash"], style: .normal),
            .offloadedOutput(off)
        ])
        let sub = toolSub(id: "off1", toolName: "Bash", body: body)
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(targetID: "off1", sectionIndex: 1)
        let content = DetailContent.resolve(request: request, entry: entry)
        #expect(content?.source == .file(path: "/tmp/cc-offloaded.txt"))
    }

    @Test("Sub-agent transcript routing — TODO when sidechain-as-AgentEntry lands")
    func subAgentTranscript() {
        // Sub-agent transcript opens through the detail-tab are
        // intentionally not wired yet — proper shape is top-level
        // AgentEntry rows. Placeholder test just confirms a Task tool
        // doesn't crash detail resolution.
        let body = Body(sections: [
            .text(["task input"], style: .normal),
            .text(["task result"], style: .normal)
        ])
        let sub = toolSub(id: "task1", toolName: "Task", body: body)
        let entry = agentEntry(subEntries: [sub])
        let request = DetailRequest.bodySection(targetID: "task1", sectionIndex: 0)
        let content = DetailContent.resolve(request: request, entry: entry)
        // Section 0 is the input text — the resolver returns a normal
        // tool input detail, NOT a sidechain transcript.
        #expect(content != nil)
    }
}
