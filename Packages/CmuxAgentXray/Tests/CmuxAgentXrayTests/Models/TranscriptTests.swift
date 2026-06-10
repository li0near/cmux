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

    private func rewind(parentBranchRoot: String, abandoned: [Entry]) -> SynthesizedEntry {
        SynthesizedEntry(
            id: .derived(parent: parentBranchRoot, kind: "rewind"),
            header: Header(),
            body: Body(sections: []),
            kind: .rewind(rootUuid: parentBranchRoot),
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
        let link = rewind(parentBranchRoot: "a1", abandoned: abandoned)

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

    // MARK: - branchOff (slice live tail + attach to parent's branches)

    @Test("branchOff — slices live tail past divergence and attaches link to parent's branches")
    func branchOffBasicTail() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p1"))
        root.append(parent: nil, entry: agentEntry("a1"))
        root.append(parent: nil, entry: userEntry("a2"))

        let abandoned = Array(root.entries[1...])
        let link = rewind(parentBranchRoot: "a1", abandoned: abandoned)

        root.branchOff(at: .fromJSONL("p1"), link: link)

        // Top-level keeps only the live conversation; the rewind hangs
        // off p1's `branches` field.
        #expect(root.entries.count == 1)
        #expect(root.entries[0].id == .fromJSONL("p1"))
        #expect(root.entries[0].branches.count == 1)
        let attached = root.entries[0].branches[0]
        #expect(attached.id == .derived(parent: "a1", kind: "rewind"))
        #expect(attached.subEntries.count == 2)
        #expect(attached.subEntries[0].id == .fromJSONL("a1"))
        #expect(attached.subEntries[1].id == .fromJSONL("a2"))
    }

    @Test("branchOff — empty tail past divergence is a no-op")
    func branchOffEmptyTailNoop() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p1"))
        let link = rewind(parentBranchRoot: "p1", abandoned: [])
        root.branchOff(at: .fromJSONL("p1"), link: link)
        #expect(root.entries.count == 1)
        #expect(root.entries[0].id == .fromJSONL("p1"))
        #expect(root.entries[0].branches.isEmpty)
    }

    @Test("branchOff — unknown divergence point is a no-op")
    func branchOffUnknownNoop() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p1"))
        root.append(parent: nil, entry: userEntry("p2"))
        let link = rewind(parentBranchRoot: "p2", abandoned: [root.entries[1]])
        root.branchOff(at: .fromJSONL("ghost"), link: link)
        #expect(root.entries.count == 2)
    }

    @Test("branchOff — multi-rewind to same parent: each new rewind appends to parent.branches as a sibling")
    func branchOffMultiRewindAppendsSibling() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p"))
        root.append(parent: nil, entry: agentEntry("A"))

        let link1 = rewind(parentBranchRoot: "A", abandoned: [root.entries[1]])
        root.branchOff(at: .fromJSONL("p"), link: link1)
        // After first rewind: top-level = [p]; p.branches = [link1].
        #expect(root.entries.count == 1)
        #expect(root.entries[0].branches.count == 1)

        // Continue with new live content on top of p.
        root.append(parent: nil, entry: agentEntry("B"))
        // Top-level = [p, B]; p.branches still has [link1].

        // Second rewind off p: only the new live tail [B] is abandoned.
        // Caller must not include the prior rewind sibling in
        // `link2.subEntries` — branches preserve it independently.
        let link2 = SynthesizedEntry(
            id: .derived(parent: "B", kind: "rewind"),
            header: Header(),
            body: Body(sections: []),
            kind: .rewind(rootUuid: "B"),
            subEntries: [root.entries[1]]
        )
        root.branchOff(at: .fromJSONL("p"), link: link2)

        // After second rewind: top-level = [p]; p.branches = [link1, link2].
        // The two rewinds coexist as siblings on p.
        #expect(root.entries.count == 1)
        #expect(root.entries[0].id == .fromJSONL("p"))
        #expect(root.entries[0].branches.count == 2)
        #expect(root.entries[0].branches[0].id == link1.id)
        #expect(root.entries[0].branches[1].id == link2.id)
        #expect(link1.id != link2.id)
    }

    @Test("branchOff — nested rewind: outer rewind captures parent containing inner rewind in its branches")
    func branchOffNestedRewind() {
        // Setup: p, A, B where A had an inner rewind attached to its
        // branches. Outer rewind off p abandons [A, B]; A's branches
        // ride along inside link2.subEntries[0].branches.
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p"))
        root.append(parent: nil, entry: agentEntry("A"))
        root.append(parent: nil, entry: agentEntry("B"))

        // Inner rewind attached to A's branches (e.g. divergence at A).
        // Construct directly on A rather than via branchOff to keep the
        // setup linear.
        let innerRewindLink = rewind(parentBranchRoot: "inner-tail", abandoned: [])
        root.mutate(id: .fromJSONL("A")) { entry in
            entry.branches.append(innerRewindLink)
        }

        // Outer rewind off p abandons [A, B]. A's branches travel on
        // A as a value field — the outer rewind's subEntries[0] is A
        // with its branches intact.
        let abandoned = Array(root.entries[1...])
        let outerLink = SynthesizedEntry(
            id: .derived(parent: "A", kind: "rewind"),
            header: Header(),
            body: Body(sections: []),
            kind: .rewind(rootUuid: "A"),
            subEntries: abandoned
        )
        root.branchOff(at: .fromJSONL("p"), link: outerLink)

        // Top-level = [p]; p.branches = [outerLink].
        #expect(root.entries.count == 1)
        #expect(root.entries[0].branches.count == 1)
        let outer = root.entries[0].branches[0]
        // outer.subEntries[0] is A with its inner branch preserved.
        #expect(outer.subEntries.count == 2)
        #expect(outer.subEntries[0].id == .fromJSONL("A"))
        #expect(outer.subEntries[0].branches.count == 1)
        #expect(outer.subEntries[0].branches[0].id == innerRewindLink.id)
    }
}
