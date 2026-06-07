import Foundation
import Testing
@testable import CmuxAgentXray

/// Phase E: source-aware shape-sniffer for the detail-tab dispatch.
/// Tests the detection ladder + markdown section split.
@Suite("DetailContentShapeSniffer — content-shape detection ladder")
struct DetailContentShapeSnifferTests {

    // MARK: - JSON detection

    @Test("Leading-{ with valid JSON object → .json")
    func validJsonObject() {
        let result = DetailContentShapeSniffer.sniff(text: #"{"a":1,"b":[2,3]}"#)
        #expect(result == .json)
    }

    @Test("Leading-[ with valid JSON array → .json")
    func validJsonArray() {
        let result = DetailContentShapeSniffer.sniff(text: "[1, 2, 3]")
        #expect(result == .json)
    }

    @Test("Leading-{ with invalid JSON (Bash output) → .plainText (false-positive guard)")
    func invalidJsonBashOutput() {
        // Real-world example: a Bash command producing log lines that
        // happen to start with `{`. Without the JSONSerialization
        // validity check, the leading-char-only sniff would misfire.
        let bashOutput = "{ echo hello\n  exit 1\n}"
        let result = DetailContentShapeSniffer.sniff(text: bashOutput)
        #expect(result == .plainText)
    }

    @Test("Leading-{ with partial JSON Lines → .plainText")
    func partialJsonLines() {
        // jq stdout: each line is a separate JSON object, but the
        // overall file isn't a valid JSON document.
        let jqOutput = "{\"id\":1}\n{\"id\":2}"
        let result = DetailContentShapeSniffer.sniff(text: jqOutput)
        #expect(result == .plainText)
    }

    @Test("Whitespace before leading-{ still detects JSON")
    func whitespaceBeforeJSON() {
        let result = DetailContentShapeSniffer.sniff(text: "  \n  {\"x\":1}")
        #expect(result == .json)
    }

    // MARK: - Markdown detection

    @Test("Two ### headings → .markdown (Playwright real-world shape)")
    func playwrightHeadings() {
        let text = """
        ### Result
        navigated successfully

        ### Ran Playwright code
        ```js
        await page.goto('https://example.com');
        ```
        """
        #expect(DetailContentShapeSniffer.sniff(text: text) == .markdown)
    }

    @Test("Single ### heading → .plainText (≥2-headings rule, avoids overfitting)")
    func singleHeading() {
        let text = "### One heading\nsome body text"
        #expect(DetailContentShapeSniffer.sniff(text: text) == .plainText)
    }

    @Test("No headings → .plainText")
    func noHeadings() {
        let text = "ordinary prose with no heading markers"
        #expect(DetailContentShapeSniffer.sniff(text: text) == .plainText)
    }

    @Test("Non-Playwright MCP plain prose stays .plainText (sap-jira fixture)")
    func sapJiraPlainProse() {
        // Real-world shape from sap-jira's get_issue: a plain markdown-
        // free description string. Sniffer correctly leaves it as plain.
        let text = "Issue DS00-1234: Add user authentication\nStatus: In Progress\nAssignee: jdoe"
        #expect(DetailContentShapeSniffer.sniff(text: text) == .plainText)
    }

    // MARK: - Section split

    @Test("splitMarkdownSections — Playwright pair extracts both sections")
    func splitPlaywrightSections() {
        let text = """
        ### Result
        navigated successfully

        ### Ran Playwright code
        ```js
        await page.goto('https://example.com');
        ```
        """
        let sections = DetailContentShapeSniffer.splitMarkdownSections(text: text)
        #expect(sections.count == 2)
        #expect(sections[0].heading == "Result")
        #expect(sections[0].body == "navigated successfully")
        #expect(sections[1].heading == "Ran Playwright code")
        #expect(sections[1].body.contains("await page.goto"))
    }

    @Test("splitMarkdownSections — content before first heading is preserved as nil-heading section")
    func splitWithPreamble() {
        let text = """
        intro text without heading

        ### First
        body 1

        ### Second
        body 2
        """
        let sections = DetailContentShapeSniffer.splitMarkdownSections(text: text)
        #expect(sections.count == 3)
        #expect(sections[0].heading == nil)
        #expect(sections[0].body == "intro text without heading")
        #expect(sections[1].heading == "First")
        #expect(sections[2].heading == "Second")
    }

    @Test("splitMarkdownSections — empty text returns no sections")
    func splitEmpty() {
        let sections = DetailContentShapeSniffer.splitMarkdownSections(text: "")
        #expect(sections.isEmpty)
    }

    // MARK: - Diff detection (≥2-of-3 signals)

    @Test("git diff with all three signals → .diff")
    func gitDiffAllSignals() {
        let text = """
        diff --git a/foo.swift b/foo.swift
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,3 +1,3 @@
        -let x = 1
        +let x = 2
         println(x)
        """
        #expect(DetailContentShapeSniffer.sniff(text: text) == .diff)
    }

    @Test("Unified diff without diff --git but with hunk header + file headers → .diff")
    func unifiedDiffWithoutGitWrapper() {
        let text = """
        --- a/foo.py
        +++ b/foo.py
        @@ -1 +1 @@
        -print('a')
        +print('b')
        """
        #expect(DetailContentShapeSniffer.sniff(text: text) == .diff)
    }

    @Test("Single --- a/ line without hunk header or +++ b/ → .plainText (one signal isn't enough)")
    func singleMinusALineNotDiff() {
        let text = "Some build output\n--- a/foo.py was modified\nNo other diff markers."
        #expect(DetailContentShapeSniffer.sniff(text: text) == .plainText)
    }

    @Test("diff --git alone (one signal) → .plainText")
    func diffGitAloneNotEnough() {
        let text = "Bash log:\ndiff --git was mentioned in the commit message\nbut no actual diff body"
        #expect(DetailContentShapeSniffer.sniff(text: text) == .plainText)
    }

    @Test("Hunk header + diff --git (two signals; no file headers) → .diff")
    func hunkPlusDiffGit() {
        let text = """
        diff --git a/foo.swift b/foo.swift
        @@ -1,2 +1,2 @@
        -old
        +new
        """
        #expect(DetailContentShapeSniffer.sniff(text: text) == .diff)
    }

    @Test("Empty hunk-shape with no @@ markers but with file-header pair → still one signal → .plainText")
    func filePairAloneNotDiff() {
        let text = """
        --- a/foo.swift
        +++ b/foo.swift
        (no hunks)
        """
        #expect(DetailContentShapeSniffer.sniff(text: text) == .plainText)
    }

    // MARK: - mcpServer (reserved for future hints)

    @Test("mcpServer hint is currently unused — same content returns same result regardless")
    func mcpServerUnused() {
        let text = "plain prose"
        #expect(DetailContentShapeSniffer.sniff(text: text, mcpServer: nil) == .plainText)
        #expect(DetailContentShapeSniffer.sniff(text: text, mcpServer: "playwright") == .plainText)
        #expect(DetailContentShapeSniffer.sniff(text: text, mcpServer: "sap-jira") == .plainText)
    }
}
