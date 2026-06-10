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

    // MARK: - branchOff (thin wrapper over slice)

    @Test("branchOff — slices tail past divergence into the link")
    func branchOffBasicTail() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p1"))
        root.append(parent: nil, entry: agentEntry("a1"))
        root.append(parent: nil, entry: userEntry("a2"))

        let abandoned = Array(root.entries[1...])
        let link = rewind(parentBranchRoot: "a1", abandoned: abandoned)

        root.branchOff(at: .fromJSONL("p1"), link: link)

        #expect(root.entries.count == 2)
        #expect(root.entries[0].id == .fromJSONL("p1"))
        if case .synthesized(let synth) = root.entries[1] {
            #expect(synth.id == .derived(parent: "a1", kind: "rewind"))
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
        let link = rewind(parentBranchRoot: "p1", abandoned: [])
        root.branchOff(at: .fromJSONL("p1"), link: link)
        #expect(root.entries.count == 1)
        #expect(root.entries[0].id == .fromJSONL("p1"))
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

    @Test("branchOff — multi-rewind to same parent yields distinct link ids")
    func branchOffMultiRewindCollisionFree() {
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p"))
        root.append(parent: nil, entry: agentEntry("A"))

        let link1 = rewind(parentBranchRoot: "A", abandoned: [root.entries[1]])
        root.branchOff(at: .fromJSONL("p"), link: link1)

        root.append(parent: nil, entry: agentEntry("B"))
        // Caller must NOT include the prior rewind sibling in
        // link2.subEntries — only the new live tail past the prior
        // rewinds. branchOff's slice skips the prior rewind in lockstep.
        let abandonedNow = [root.entries[2]] // [B] — not [link1, B]
        let firstOfTailUuid = "B"
        let link2 = SynthesizedEntry(
            id: .derived(parent: firstOfTailUuid, kind: "rewind"),
            header: Header(),
            body: Body(sections: []),
            kind: .rewind(rootUuid: firstOfTailUuid),
            subEntries: abandonedNow
        )
        root.branchOff(at: .fromJSONL("p"), link: link2)

        #expect(link1.id != link2.id)
        #expect(link1.id == .derived(parent: "A", kind: "rewind"))
        #expect(link2.id == .derived(parent: firstOfTailUuid, kind: "rewind"))

        // Two sibling rewinds at top level (NOT nested).
        #expect(root.entries.count == 3)
        #expect(root.entries[0].id == .fromJSONL("p"))
        if case .synthesized(let s1) = root.entries[1] {
            #expect(s1.id == link1.id)
            #expect(s1.subEntries.count == 1)
            #expect(s1.subEntries[0].id == .fromJSONL("A"))
        } else {
            Issue.record("expected link1 at slot 1")
        }
        if case .synthesized(let s2) = root.entries[2] {
            #expect(s2.id == link2.id)
            #expect(s2.subEntries.count == 1)
            #expect(s2.subEntries[0].id == .fromJSONL("B"))
        } else {
            Issue.record("expected link2 at slot 2 (sibling)")
        }
    }

    @Test("branchOff — sibling rewind: prior rewind sibling stays at top level, NOT folded into the new link")
    func branchOffSiblingRewindNotNested() {
        // Inverse of the prior "nested rewind" assumption — when the
        // caller passes link2 with `subEntries: [B]` (only the new
        // live tail), branchOff slices past the prior rewind and
        // appends link2 as a sibling. Validates the structural
        // invariant that fixes the visually-nested bug seen in
        // session 48672f90… (5 sibling rewinds rendered as 4 levels
        // of nesting in the pre-fix renderer).
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p"))
        root.append(parent: nil, entry: agentEntry("A"))

        let link1 = rewind(parentBranchRoot: "A", abandoned: [root.entries[1]])
        root.branchOff(at: .fromJSONL("p"), link: link1)

        root.append(parent: nil, entry: agentEntry("B"))
        let link2 = SynthesizedEntry(
            id: .derived(parent: "B", kind: "rewind"),
            header: Header(),
            body: Body(sections: []),
            kind: .rewind(rootUuid: "B"),
            subEntries: [root.entries[2]]
        )
        root.branchOff(at: .fromJSONL("p"), link: link2)

        // [p, link1, link2] — siblings at top level.
        #expect(root.entries.count == 3)
        guard case .synthesized(let outer) = root.entries[2] else {
            Issue.record("expected link2 at slot 2 as sibling; got \(root.entries[2])")
            return
        }
        #expect(outer.id == link2.id)
        // link2 must NOT contain a prior rewind; only the new live tail.
        for sub in outer.subEntries {
            if case .synthesized(let s) = sub, case .rewind = s.kind {
                Issue.record("link2 must not nest a prior rewind sibling; found \(sub)")
            }
        }
    }

    @Test("branchOff — nested rewind: prior rewind further into abandoned range stays nested inside new link")
    func branchOffNestedRewindCapturedAsContent() {
        // Counterpart to the sibling test above. The contiguous-skip
        // rule in branchOff distinguishes sibling (prior rewind at the
        // immediate post-divergence slot — same divergence point) from
        // nested (prior rewind further into the abandoned range —
        // earlier divergence captured by the broader new rewind).
        //
        // Setup: tree = [p, A, B, prior-rewind, C]
        //   prior-rewind has divergence at B (sits at slot 3, post-B).
        //   New rewind has divergence at p (slot 0). Abandoned range
        //   starts at slot 1 = A (NOT a rewind), so contiguous-skip
        //   stops immediately. Abandoned = [A, B, prior-rewind, C] —
        //   prior-rewind is nested inside the new link's subEntries.
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p"))
        root.append(parent: nil, entry: agentEntry("A"))
        root.append(parent: nil, entry: agentEntry("B"))
        root.append(parent: nil, entry: agentEntry("D"))

        // First rewind off B: abandons [D]. Tree becomes [p, A, B, priorRewind].
        let priorRewind = rewind(parentBranchRoot: "D", abandoned: [root.entries[3]])
        root.branchOff(at: .fromJSONL("B"), link: priorRewind)
        root.append(parent: nil, entry: agentEntry("C"))

        // Tree now: [p, A, B, priorRewind, C].
        #expect(root.entries.count == 5)

        // New rewind off p (divergence at slot 0): abandons everything
        // past slot 0, INCLUDING priorRewind which had a later
        // divergence (B) — those abandoned entries belong inside the
        // broader new rewind's content.
        let abandoned = Array(root.entries[1...])
        let newRewind = SynthesizedEntry(
            id: .derived(parent: "A", kind: "rewind"),
            header: Header(),
            body: Body(sections: []),
            kind: .rewind(rootUuid: "A"),
            subEntries: abandoned
        )
        root.branchOff(at: .fromJSONL("p"), link: newRewind)

        // [p, newRewind] — newRewind contains [A, B, priorRewind, C].
        #expect(root.entries.count == 2)
        guard case .synthesized(let outer) = root.entries[1] else {
            Issue.record("expected newRewind at slot 1; got \(root.entries[1])")
            return
        }
        #expect(outer.subEntries.count == 4)
        // priorRewind is at index 2 inside newRewind's subEntries —
        // genuinely nested, not flattened.
        guard case .synthesized(let nested) = outer.subEntries[2],
              case .rewind = nested.kind else {
            Issue.record("expected priorRewind at subEntries[2] inside newRewind; got \(outer.subEntries[2])")
            return
        }
        #expect(nested.id == priorRewind.id)
    }
}
