import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("Entry tree construction + dispatch")
struct EntryTreeTests {

    // MARK: - Variant fixture

    private func makeUser(id: String = "u1") -> UserEntry {
        UserEntry(
            id: .fromJSONL(id),
            header: Header(
                name: "User",
                title: "Hello",
                timeMarker: .clock(Date(timeIntervalSince1970: 1_000))
            ),
            body: .text(["Hello"])
        )
    }

    private func makeAgent(id: String = "a1") -> AgentEntry {
        let thinking = TextSubEntry(
            kind: .thinking,
            id: .derived(parent: id, kind: "thinking-0"),
            parentEntryID: .fromJSONL(id),
            header: Header(icon: .thinking, name: "Thinking"),
            body: Body(sections: [.text(["I should..."], style: .thinking)]),
            wordCount: 2
        )
        let tool = ToolEntry(
            id: .fromJSONL("\(id)-tool-1"),
            parentEntryID: .fromJSONL(id),
            header: Header(icon: .tool(named: "Read"), name: "Read", title: "/foo.swift"),
            body: Body(sections: [.text(["{ \"path\": \"/foo.swift\" }"], style: .normal)]),
            status: .ok
        )
        return AgentEntry(
            id: .fromJSONL(id),
            header: Header(
                icon: .agent,
                name: "Claude",
                label: "Sonnet 4.5",
                timeMarker: .clock(Date(timeIntervalSince1970: 1_001))
            ),
            body: Body(sections: [.subentries([])]),
            usage: AgentEntry.TokenUsage(inputTokens: 100, outputTokens: 50),
            stopReason: "end_turn",
            subEntries: [.text(thinking), .tool(tool)]
        )
    }

    // MARK: - Entry dispatch

    @Test("Entry dispatches id / header / body / timestamp per variant")
    func dispatch() {
        let user = Entry.user(makeUser())
        #expect(user.id.stableString == "u1")
        #expect(user.header.name == "User")
        #expect(user.body.sections.count == 1)
        #expect(user.timestamp == Date(timeIntervalSince1970: 1_000))

        let agent = Entry.agent(makeAgent())
        #expect(agent.id.stableString == "a1")
        #expect(agent.header.label == "Sonnet 4.5")
        #expect(agent.timestamp == Date(timeIntervalSince1970: 1_001))
    }

    @Test("Transcript is [Entry]")
    func transcriptAlias() {
        let transcript: Transcript = [.user(makeUser()), .agent(makeAgent())]
        #expect(transcript.count == 2)
        #expect(transcript[0].id.stableString == "u1")
        #expect(transcript[1].id.stableString == "a1")
    }

    // MARK: - AgentEntry sub-entries

    @Test("AgentEntry.SubEntry dispatches id and header")
    func subEntryDispatch() {
        let turn = makeAgent()
        #expect(turn.subEntries.count == 2)

        let thinking = turn.subEntries[0]
        #expect(thinking.id.stableString == "d:thinking-0:a1")
        #expect(thinking.header.name == "Thinking")

        let tool = turn.subEntries[1]
        if case .tool(let t) = tool {
            #expect(t.toolName == "Read")
            #expect(t.status == .ok)
        } else {
            Issue.record("expected .tool case")
        }
    }

    // MARK: - Body convenience

    @Test("Body.empty has no sections")
    func emptyBody() {
        #expect(Body.empty.sections.isEmpty)
    }

    @Test("Body.text builds single .text section")
    func textBody() {
        let body = Body.text(["a", "b"])
        #expect(body.sections.count == 1)
        if case .text(let blocks, let style) = body.sections[0] {
            #expect(blocks == ["a", "b"])
            #expect(style == .normal)
        } else {
            Issue.record("expected .text section")
        }
    }

    // MARK: - Variant equatability

    @Test("Two equal entries compare equal")
    func equality() {
        let e1 = Entry.user(makeUser())
        let e2 = Entry.user(makeUser())
        #expect(e1 == e2)
    }
}
