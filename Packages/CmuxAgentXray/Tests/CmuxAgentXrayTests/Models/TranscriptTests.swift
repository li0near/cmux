import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("Transcript — append/mutate/slice/branchOff over the recursive flat document (post-G1.6 unified API)")
struct TranscriptTests {

    // MARK: - Fixtures

    private func userEntry(_ uuid: String) -> Entry {
        .user(UserEntry(id: .fromJSONL(uuid), header: Header(), body: Body()))
    }

    private func agentEntry(_ uuid: String, subEntries: [Entry] = []) -> Entry {
        .agent(AgentEntry(
            id: .fromJSONL(uuid),
            header: Header(),
            body: Body(),
            usage: .zero,
            subEntries: subEntries
        ))
    }

    private func textSub(_ kind: TextSubEntry.Kind, _ uuid: String, parent: String) -> Entry {
        .text(TextSubEntry(
            kind: kind,
            id: .derived(parent: parent, kind: kind == .thinking ? "thinking-0" : "assistantText-0"),
            parentEntryID: .fromJSONL(parent),
            header: Header(),
            body: Body(),
            wordCount: 0
        ))
    }

    private func toolSub(_ uuid: String, parent: String, status: ToolEntry.Status = .pending) -> Entry {
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
            body: Body(sections: []),
            kind: .branchLink(
                branchRootUuid: parentBranchRoot,
                rewindIndex: 0,
                totalRewinds: 1,
                entryCount: abandoned.count,
                firstPromptPreview: nil
            ),
            subEntries: abandoned
        )
    }

    // MARK: - append

    @Test("append top-level — entries land in `entries` in order")
    func appendTopLevelOrder() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("u1"))
        root.append(parent: nil, entry: agentEntry("a1"))
        root.append(parent: nil, entry: userEntry("u2"))
        #expect(root.entries.count == 3)
        #expect(root.entries[0].id == .fromJSONL("u1"))
        #expect(root.entries[1].id == .fromJSONL("a1"))
        #expect(root.entries[2].id == .fromJSONL("u2"))
    }

    @Test("append top-level — entry(id:) finds each by id")
    func appendTopLevelLookup() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("u1"))
        root.append(parent: nil, entry: agentEntry("a1"))
        #expect(root.entry(id: .fromJSONL("u1"))?.id == .fromJSONL("u1"))
        #expect(root.entry(id: .fromJSONL("a1"))?.id == .fromJSONL("a1"))
        #expect(root.entry(id: .fromJSONL("missing")) == nil)
    }

    @Test("append sub-entry under existing agent — entry(id:) finds it at depth")
    func appendSubEntryLookup() {
        var root = Transcript()
        root.append(parent: nil, entry: agentEntry("a1"))
        root.append(parent: .fromJSONL("a1"), entry: toolSub("t1", parent: "a1"))
        #expect(root.entry(id: .fromJSONL("t1"))?.id == .fromJSONL("t1"))
        if case .agent(let agent) = root.entries[0] {
            #expect(agent.subEntries.count == 1)
            #expect(agent.subEntries[0].id == .fromJSONL("t1"))
        } else {
            Issue.record("expected agent at index 0")
        }
    }

    // MARK: - mutate

    @Test("mutate top-level — replace via inout closure preserves index")
    func mutateTopLevel() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("u1"))
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
        var root = Transcript()
        root.append(parent: nil, entry: agentEntry("a1"))
        root.append(parent: .fromJSONL("a1"), entry: toolSub("t1", parent: "a1", status: .pending))
        root.mutate(id: .fromJSONL("t1")) { entry in
            if case .tool(let t) = entry {
                entry = .tool(ToolEntry(
                    id: t.id, parentEntryID: t.parentEntryID,
                    header: t.header, body: t.body, status: .ok
                ))
            }
        }
        if case .tool(let t) = root.entry(id: .fromJSONL("t1")) {
            #expect(t.status == .ok)
        } else {
            Issue.record("expected tool sub-entry after mutation")
        }
    }

    // MARK: - slice (subsumes remove + branchOff)

    @Test("slice top-level — length 1, no replacement (legacy `remove` shape)")
    func sliceRemoveSingle() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("u1"))
        root.append(parent: nil, entry: userEntry("u2"))
        root.append(parent: nil, entry: userEntry("u3"))
        root.slice(from: .fromJSONL("u2"), length: 1, replacingWith: nil)
        #expect(root.entries.count == 2)
        #expect(root.entries[0].id == .fromJSONL("u1"))
        #expect(root.entries[1].id == .fromJSONL("u3"))
        #expect(root.entry(id: .fromJSONL("u1"))?.id == .fromJSONL("u1"))
        #expect(root.entry(id: .fromJSONL("u3"))?.id == .fromJSONL("u3"))
        #expect(root.entry(id: .fromJSONL("u2")) == nil)
    }

    @Test("slice top-level — mid-array drop + shift updates the index for trailing entries")
    func sliceMidArrayDropAndShift() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("u1"))
        root.append(parent: nil, entry: userEntry("u2"))
        root.append(parent: nil, entry: userEntry("u3"))
        root.append(parent: nil, entry: userEntry("u4"))
        root.append(parent: nil, entry: userEntry("u5"))

        // Slice u2 + u3 (length 2) without a replacement.
        // Expected: u4/u5 shift to slots 1/2; u2/u3 are gone from the index.
        root.slice(from: .fromJSONL("u2"), length: 2, replacingWith: nil)

        #expect(root.entries.count == 3)
        #expect(root.entries[0].id == .fromJSONL("u1"))
        #expect(root.entries[1].id == .fromJSONL("u4"))
        #expect(root.entries[2].id == .fromJSONL("u5"))
        #expect(root.entry(id: .fromJSONL("u2")) == nil)
        #expect(root.entry(id: .fromJSONL("u3")) == nil)
        // Trailing entries still resolvable via the index after shift.
        #expect(root.entry(id: .fromJSONL("u4"))?.id == .fromJSONL("u4"))
        #expect(root.entry(id: .fromJSONL("u5"))?.id == .fromJSONL("u5"))
    }

    @Test("slice with replacement — abandoned subtree re-pathed under the link")
    func sliceWithReplacementSubtree() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p1"))
        root.append(parent: nil, entry: agentEntry("a1"))
        root.append(parent: .fromJSONL("a1"), entry: toolSub("t1", parent: "a1"))
        root.append(parent: nil, entry: userEntry("u2"))

        // Caller folds the abandoned tail (a1 with its tool sub-entry, plus u2)
        // into the link's subEntries before calling slice.
        let abandoned = Array(root.entries[1...])
        let link = branchLink(parentBranchRoot: "a1", abandoned: abandoned)

        // length = 2 (a1, u2). startIdx = 1.
        root.slice(from: .fromJSONL("a1"), length: 2,
                   replacingWith: .synthesized(link))

        #expect(root.entries.count == 2)
        #expect(root.entries[0].id == .fromJSONL("p1"))

        // The link itself is reachable, and its abandoned subtree's entries
        // have been re-pathed under it (registered at [1, 0], [1, 0, 0], [1, 1]).
        #expect(root.entry(id: link.id)?.id == link.id)
        #expect(root.entry(id: .fromJSONL("a1"))?.id == .fromJSONL("a1"))
        #expect(root.entry(id: .fromJSONL("t1"))?.id == .fromJSONL("t1"))
        #expect(root.entry(id: .fromJSONL("u2"))?.id == .fromJSONL("u2"))
    }

    // MARK: - branchOff (thin wrapper over slice)

    @Test("branchOff — slices tail past divergence into the link")
    func branchOffBasicTail() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p1"))
        root.append(parent: nil, entry: agentEntry("a1"))
        root.append(parent: nil, entry: userEntry("a2"))

        let abandoned = Array(root.entries[1...])
        let link = branchLink(parentBranchRoot: "a1", abandoned: abandoned)

        root.branchOff(at: .fromJSONL("p1"), link: link)

        #expect(root.entries.count == 2)
        #expect(root.entries[0].id == .fromJSONL("p1"))
        if case .synthesized(let synth) = root.entries[1] {
            #expect(synth.id == .derived(parent: "a1", kind: "branchLink"))
            #expect(synth.subEntries.count == 2)
            #expect(synth.subEntries[0].id == .fromJSONL("a1"))
            #expect(synth.subEntries[1].id == .fromJSONL("a2"))
        } else {
            Issue.record("expected synthesized branch-link at index 1")
        }
    }

    @Test("branchOff — empty tail past divergence is a no-op")
    func branchOffEmptyTailNoop() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p1"))
        let link = branchLink(parentBranchRoot: "p1", abandoned: [])
        root.branchOff(at: .fromJSONL("p1"), link: link)
        #expect(root.entries.count == 1)
        #expect(root.entries[0].id == .fromJSONL("p1"))
    }

    @Test("branchOff — unknown divergence point is a no-op")
    func branchOffUnknownNoop() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p1"))
        root.append(parent: nil, entry: userEntry("p2"))
        let link = branchLink(parentBranchRoot: "p2", abandoned: [root.entries[1]])
        root.branchOff(at: .fromJSONL("ghost"), link: link)
        #expect(root.entries.count == 2)
    }

    @Test("branchOff — multi-rewind to same parent yields distinct link ids")
    func branchOffMultiRewindCollisionFree() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p"))
        root.append(parent: nil, entry: agentEntry("A"))

        let link1 = branchLink(parentBranchRoot: "A", abandoned: [root.entries[1]])
        root.branchOff(at: .fromJSONL("p"), link: link1)

        root.append(parent: nil, entry: agentEntry("B"))
        let abandonedNow = Array(root.entries[1...])
        let firstOfTailUuid = "linkA"
        let link2 = SynthesizedEntry(
            id: .derived(parent: firstOfTailUuid, kind: "branchLink"),
            header: Header(),
            body: Body(sections: []),
            kind: .branchLink(
                branchRootUuid: firstOfTailUuid,
                rewindIndex: 1,
                totalRewinds: 2,
                entryCount: abandonedNow.count,
                firstPromptPreview: nil
            ),
            subEntries: abandonedNow
        )
        root.branchOff(at: .fromJSONL("p"), link: link2)

        #expect(link1.id != link2.id)
        #expect(link1.id == .derived(parent: "A", kind: "branchLink"))
        #expect(link2.id == .derived(parent: firstOfTailUuid, kind: "branchLink"))

        #expect(root.entries.count == 2)
        if case .synthesized(let synth) = root.entries[1] {
            #expect(synth.subEntries.count == 2)
            #expect(synth.subEntries[0].id == link1.id)
            #expect(synth.subEntries[1].id == .fromJSONL("B"))
        } else {
            Issue.record("expected link2 wrapping [link1, B]")
        }
    }

    @Test("branchOff — nested rewind: prior link captured inside new link's subEntries")
    func branchOffNestedRewind() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p"))
        root.append(parent: nil, entry: agentEntry("A"))

        let link1 = branchLink(parentBranchRoot: "A", abandoned: [root.entries[1]])
        root.branchOff(at: .fromJSONL("p"), link: link1)

        root.append(parent: nil, entry: agentEntry("B"))
        let abandonedNow = Array(root.entries[1...])
        let link2 = SynthesizedEntry(
            id: .derived(parent: "outer-root", kind: "branchLink"),
            header: Header(),
            body: Body(sections: []),
            kind: .branchLink(
                branchRootUuid: "outer-root",
                rewindIndex: 1,
                totalRewinds: 2,
                entryCount: abandonedNow.count,
                firstPromptPreview: nil
            ),
            subEntries: abandonedNow
        )
        root.branchOff(at: .fromJSONL("p"), link: link2)

        guard case .synthesized(let outer) = root.entries.last,
              let inner = outer.subEntries.first,
              case .synthesized(let innerSynth) = inner
        else {
            Issue.record("expected link2 → link1 nesting")
            return
        }
        #expect(innerSynth.id == link1.id)
        #expect(innerSynth.subEntries.first?.id == .fromJSONL("A"))
    }
}
