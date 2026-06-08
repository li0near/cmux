import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("TranscriptRoot — append/mutate/remove/branchOff over the synthetic root")
struct TranscriptRootTests {

    // MARK: - Fixtures

    private func userEntry(_ uuid: String) -> Entry {
        .user(UserEntry(id: .fromJSONL(uuid), header: Header(), body: Body()))
    }

    private func agentEntry(_ uuid: String, subEntries: [AgentEntry.SubEntry] = []) -> Entry {
        .agent(AgentEntry(
            id: .fromJSONL(uuid),
            header: Header(),
            body: Body(),
            usage: .zero,
            subEntries: subEntries
        ))
    }

    private func textSub(_ kind: TextSubEntry.Kind, _ uuid: String, parent: String) -> AgentEntry.SubEntry {
        .text(TextSubEntry(
            kind: kind,
            id: .derived(parent: parent, kind: kind == .thinking ? "thinking-0" : "assistantText-0"),
            parentEntryID: .fromJSONL(parent),
            header: Header(),
            body: Body(),
            wordCount: 0
        ))
    }

    private func toolSub(_ uuid: String, parent: String, status: ToolEntry.Status = .pending) -> AgentEntry.SubEntry {
        .tool(ToolEntry(
            id: .fromJSONL(uuid),
            parentEntryID: .fromJSONL(parent),
            header: Header(),
            body: Body(),
            status: status
        ))
    }

    private func branchLink(parentBranchRoot: String, abandoned: [Entry]) -> SynthesizedEntry {
        SynthesizedEntry(
            id: .derived(parent: parentBranchRoot, kind: "branchLink"),
            header: Header(),
            body: Body(sections: [.subentries(abandoned)]),
            kind: .branchLink(
                branchRootUuid: parentBranchRoot,
                rewindIndex: 0,
                totalRewinds: 1,
                entryCount: abandoned.count,
                firstPromptPreview: nil
            )
        )
    }

    // MARK: - append

    @Test("append top-level — entries land in subEntries in order")
    func appendTopLevelOrder() {
        var root = TranscriptRoot()
        root.append(userEntry("u1"))
        root.append(agentEntry("a1"))
        root.append(userEntry("u2"))
        #expect(root.subEntries.count == 3)
        #expect(root.subEntries[0].id == .fromJSONL("u1"))
        #expect(root.subEntries[1].id == .fromJSONL("a1"))
        #expect(root.subEntries[2].id == .fromJSONL("u2"))
    }

    @Test("append top-level — entry(id:) finds each by id")
    func appendTopLevelLookup() {
        var root = TranscriptRoot()
        root.append(userEntry("u1"))
        root.append(agentEntry("a1"))
        #expect(root.entry(id: .fromJSONL("u1"))?.id == .fromJSONL("u1"))
        #expect(root.entry(id: .fromJSONL("a1"))?.id == .fromJSONL("a1"))
        #expect(root.entry(id: .fromJSONL("missing")) == nil)
    }

    @Test("append sub-entry under existing agent — subEntry(id:) finds it")
    func appendSubEntryLookup() {
        var root = TranscriptRoot()
        root.append(agentEntry("a1"))
        root.appendSubEntry(parentAgentId: .fromJSONL("a1"), toolSub("t1", parent: "a1"))
        #expect(root.subEntry(id: .fromJSONL("t1"))?.id == .fromJSONL("t1"))
        // The sub-entry is also visible via the agent's subEntries.
        if case .agent(let agent) = root.subEntries[0] {
            #expect(agent.subEntries.count == 1)
            #expect(agent.subEntries[0].id == .fromJSONL("t1"))
        } else {
            Issue.record("expected agent at index 0")
        }
    }

    @Test("append sub-entry — entry(id:) returns nil for sub-entries (use subEntry(id:) instead)")
    func appendSubEntryNotInTopLevelLookup() {
        var root = TranscriptRoot()
        root.append(agentEntry("a1"))
        root.appendSubEntry(parentAgentId: .fromJSONL("a1"), toolSub("t1", parent: "a1"))
        #expect(root.entry(id: .fromJSONL("t1")) == nil)
    }

    // MARK: - mutate

    @Test("mutate top-level — replace via inout closure preserves index")
    func mutateTopLevel() {
        var root = TranscriptRoot()
        root.append(userEntry("u1"))
        root.mutate(id: .fromJSONL("u1")) { entry in
            entry = .user(UserEntry(
                id: .fromJSONL("u1"),
                header: Header(name: "mutated"),
                body: Body()
            ))
        }
        #expect(root.entry(id: .fromJSONL("u1"))?.header.name == "mutated")
    }

    @Test("mutate sub-entry — replace tool's status; parent agent reconstructed in place")
    func mutateSubEntry() {
        var root = TranscriptRoot()
        root.append(agentEntry("a1"))
        root.appendSubEntry(parentAgentId: .fromJSONL("a1"), toolSub("t1", parent: "a1", status: .pending))
        root.mutateSubEntry(id: .fromJSONL("t1")) { sub in
            if case .tool(let t) = sub {
                sub = .tool(ToolEntry(
                    id: t.id, parentEntryID: t.parentEntryID,
                    header: t.header, body: t.body, status: .ok
                ))
            }
        }
        if case .tool(let t) = root.subEntry(id: .fromJSONL("t1")) {
            #expect(t.status == .ok)
        } else {
            Issue.record("expected tool sub-entry after mutation")
        }
    }

    // MARK: - remove

    @Test("remove top-level — index shifts; trailing entries still findable")
    func removeTopLevel() {
        var root = TranscriptRoot()
        root.append(userEntry("u1"))
        root.append(userEntry("u2"))
        root.append(userEntry("u3"))
        root.remove(id: .fromJSONL("u2"))
        #expect(root.subEntries.count == 2)
        #expect(root.subEntries[0].id == .fromJSONL("u1"))
        #expect(root.subEntries[1].id == .fromJSONL("u3"))
        #expect(root.entry(id: .fromJSONL("u1"))?.id == .fromJSONL("u1"))
        #expect(root.entry(id: .fromJSONL("u3"))?.id == .fromJSONL("u3"))
        #expect(root.entry(id: .fromJSONL("u2")) == nil)
    }

    // MARK: - branchOff

    @Test("branchOff — slices tail past divergence into the link")
    func branchOffBasicTail() {
        var root = TranscriptRoot()
        root.append(userEntry("p1"))                  // divergence point
        root.append(agentEntry("a1"))                 // abandoned
        root.append(userEntry("a2"))                  // abandoned

        // Build the link with abandoned entries embedded.
        let abandoned = Array(root.subEntries[1...])
        let link = branchLink(parentBranchRoot: "a1", abandoned: abandoned)

        root.branchOff(at: .fromJSONL("p1"), link: link)

        #expect(root.subEntries.count == 2)
        #expect(root.subEntries[0].id == .fromJSONL("p1"))
        if case .synthesized(let synth) = root.subEntries[1] {
            #expect(synth.id == .derived(parent: "a1", kind: "branchLink"))
            // Verify the abandoned entries travel inside the link's body.
            if case .subentries(let inner) = synth.body.sections.first {
                #expect(inner.count == 2)
                #expect(inner[0].id == .fromJSONL("a1"))
                #expect(inner[1].id == .fromJSONL("a2"))
            } else {
                Issue.record("link body missing .subentries section")
            }
        } else {
            Issue.record("expected synthesized branch-link at index 1")
        }
    }

    @Test("branchOff — empty tail past divergence is a no-op")
    func branchOffEmptyTailNoop() {
        var root = TranscriptRoot()
        root.append(userEntry("p1"))
        let link = branchLink(parentBranchRoot: "p1", abandoned: [])
        root.branchOff(at: .fromJSONL("p1"), link: link)
        #expect(root.subEntries.count == 1)
        #expect(root.subEntries[0].id == .fromJSONL("p1"))
    }

    @Test("branchOff — unknown divergence point is a no-op")
    func branchOffUnknownNoop() {
        var root = TranscriptRoot()
        root.append(userEntry("p1"))
        root.append(userEntry("p2"))
        let link = branchLink(parentBranchRoot: "p2", abandoned: [root.subEntries[1]])
        root.branchOff(at: .fromJSONL("ghost"), link: link)
        #expect(root.subEntries.count == 2)
    }

    @Test("branchOff — multi-rewind to same parent yields distinct link ids")
    func branchOffMultiRewindCollisionFree() {
        // Setup: P → A (abandoned), then P → B (abandoned), then P → C (active).
        var root = TranscriptRoot()
        root.append(userEntry("p"))
        root.append(agentEntry("A"))                   // first abandoned branch's first entry

        // First rewind: slice [A] into link1.
        let link1 = branchLink(parentBranchRoot: "A", abandoned: [root.subEntries[1]])
        root.branchOff(at: .fromJSONL("p"), link: link1)
        // root: [p, link1]

        // Second branch arrives.
        root.append(agentEntry("B"))                   // second abandoned branch's first entry
        // root: [p, link1, B]

        // Second rewind to p: tail past p is [link1, B]. Wrap into link2.
        // link2's parentBranchRoot is the FIRST abandoned entry's id —
        // which is now link1 (the displaced link from the first rewind).
        // Critical for uniqueness: derive from the actual first-of-tail,
        // not from p.
        let abandonedNow = Array(root.subEntries[1...])
        let firstOfTailUuid = "linkA"  // synthetic — actually link1.id, but we use a string for the helper
        let link2 = SynthesizedEntry(
            id: .derived(parent: firstOfTailUuid, kind: "branchLink"),
            header: Header(),
            body: Body(sections: [.subentries(abandonedNow)]),
            kind: .branchLink(
                branchRootUuid: firstOfTailUuid,
                rewindIndex: 1,
                totalRewinds: 2,
                entryCount: abandonedNow.count,
                firstPromptPreview: nil
            )
        )
        root.branchOff(at: .fromJSONL("p"), link: link2)

        // The two link ids must be distinct, demonstrating no collision
        // even though both rewinds diverged from `p`.
        #expect(link1.id != link2.id)
        #expect(link1.id == .derived(parent: "A", kind: "branchLink"))
        #expect(link2.id == .derived(parent: firstOfTailUuid, kind: "branchLink"))

        // Tree shape: [p, link2]. link2's body contains [link1, B].
        #expect(root.subEntries.count == 2)
        if case .synthesized(let synth) = root.subEntries[1],
           case .subentries(let inner) = synth.body.sections.first {
            #expect(inner.count == 2)
            #expect(inner[0].id == link1.id)
            #expect(inner[1].id == .fromJSONL("B"))
        } else {
            Issue.record("expected link2 wrapping [link1, B]")
        }
    }

    @Test("branchOff — nested rewind: prior link captured inside new link's body")
    func branchOffNestedRewind() {
        // Same as multi-rewind but verifying that a prior branchLink in
        // the abandoned range becomes a child of the new branchLink
        // structurally — without any folding logic.
        var root = TranscriptRoot()
        root.append(userEntry("p"))
        root.append(agentEntry("A"))

        let link1 = branchLink(parentBranchRoot: "A", abandoned: [root.subEntries[1]])
        root.branchOff(at: .fromJSONL("p"), link: link1)

        root.append(agentEntry("B"))
        let abandonedNow = Array(root.subEntries[1...])
        let link2 = SynthesizedEntry(
            id: .derived(parent: "outer-root", kind: "branchLink"),
            header: Header(),
            body: Body(sections: [.subentries(abandonedNow)]),
            kind: .branchLink(
                branchRootUuid: "outer-root",
                rewindIndex: 1,
                totalRewinds: 2,
                entryCount: abandonedNow.count,
                firstPromptPreview: nil
            )
        )
        root.branchOff(at: .fromJSONL("p"), link: link2)

        // Drill in: link2's body's subentries[0] is link1; that link1's
        // body's subentries[0] is agent "A".
        guard case .synthesized(let outer) = root.subEntries.last,
              case .subentries(let outerInner) = outer.body.sections.first,
              case .synthesized(let inner) = outerInner.first,
              case .subentries(let innerInner) = inner.body.sections.first
        else {
            Issue.record("expected link2 → link1 → agent A nesting")
            return
        }
        #expect(inner.id == link1.id)
        #expect(innerInner.first?.id == .fromJSONL("A"))
    }
}
