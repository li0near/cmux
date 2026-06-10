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

    @Test("branchOff — multi-rewind to same parent yields sibling links at top level (with index-advance edge cases)")
    func branchOffMultiRewindSiblings() {
        // Multi-rewind off the same divergence: each rewind advances
        // the divergence-point's index past itself, so the next
        // rewind's `parentPath` resolves to the slot just after the
        // prior rewind. Result: sibling rewinds at top level, not
        // nested. Matches the empirical Claude Code shape: session
        // 48672f90… in /Users/I505728/temp/github/aicore-router has
        // 5 typed prompts at one anchor uuid, which produced 4-deep
        // visual nesting in the pre-fix renderer.
        //
        // This test covers four edge cases of the index-advance trick
        // in one fixture:
        //   1. Two siblings (the basic case).
        //   2. Four siblings (validates repeated invocation).
        //   3. `entry(id:)` for non-divergence entries still resolves
        //      after advance (live entries' index integrity).
        //   4. Slicing a live continuation entry by its own id still
        //      works after advance (downstream slice consistency).
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p"))   // slot 0

        var linkIDs: [EntryID] = []
        for i in 1...4 {
            let agentUuid = "A\(i)"
            root.append(parent: nil, entry: agentEntry(agentUuid))
            // detectAndApplyRewind-style: compute abandoned via the
            // current `parentPath(of: p)` (advances each round).
            let parentPath = root.path(of: .fromJSONL("p"))!
            let abandoned = Array(root.entries[(parentPath[0] + 1)...])
            #expect(abandoned.count == 1, "round \(i): expected only \(agentUuid) in live tail; got \(abandoned.count)")
            #expect(abandoned[0].id == .fromJSONL(agentUuid))
            let link = SynthesizedEntry(
                id: .derived(parent: agentUuid, kind: "rewind"),
                header: Header(),
                body: Body(sections: []),
                kind: .rewind(rootUuid: agentUuid),
                subEntries: abandoned
            )
            root.branchOff(at: .fromJSONL("p"), link: link)
            linkIDs.append(link.id)
        }

        // Edge case 1+2: [p, link1, link2, link3, link4] — 4 sibling
        // rewinds, none nested inside another, each with exactly its
        // one abandoned A_i.
        #expect(root.entries.count == 5)
        // Verify ids and abandoned-content match per slot.
        for (i, expectedID) in linkIDs.enumerated() {
            guard case .synthesized(let s) = root.entries[i + 1] else {
                Issue.record("slot \(i + 1): expected .synthesized rewind")
                continue
            }
            #expect(s.id == expectedID, "slot \(i + 1): wrong link id")
            #expect(s.subEntries.count == 1)
            #expect(s.subEntries[0].id == .fromJSONL("A\(i + 1)"))
            // Edge case 3: link itself still resolves by id.
            #expect(root.entry(id: expectedID)?.id == expectedID)
        }
        // Distinct ids across siblings (no collision under the
        // `.derived(parent:, kind:)` scheme).
        #expect(Set(linkIDs).count == linkIDs.count)

        // Edge case 4: slicing a live continuation entry past the
        // siblings stays consistent after multiple advances.
        root.append(parent: nil, entry: agentEntry("B"))   // appended at slot 5
        #expect(root.entry(id: .fromJSONL("B"))?.id == .fromJSONL("B"))
        root.slice(from: .fromJSONL("B"), length: 1, replacingWith: nil)
        #expect(root.entry(id: .fromJSONL("B")) == nil)
        #expect(root.entries.count == 5)
    }

    @Test("branchOff — nested rewind: prior rewind further into abandoned range stays nested inside the new link")
    func branchOffNestedRewindCapturedAsContent() {
        // Counterpart to the sibling test. When a broader rewind has
        // its divergence at an EARLIER slot than a prior rewind's
        // divergence, the prior rewind sits in the broader abandoned
        // range and rides along inside the new link's subEntries —
        // genuinely nested. The index-advance only matters for the
        // PRIOR rewind's own divergence point; the new (earlier)
        // divergence has its own un-advanced path.
        //
        // Setup: tree = [p, A, B, D]
        //   First rewind off B: abandons [D]. Tree → [p, A, B, link1].
        //   B's index advances from [2] to [3].
        //   Append C live. Tree → [p, A, B, link1, C].
        //   Second rewind off p (divergence at slot 0): abandons
        //   everything from slot 1 onward — INCLUDING link1 and C.
        //   That captures link1 nested inside the new link.
        var root = Transcript()
        root.append(parent: nil, entry: userEntry("p"))
        root.append(parent: nil, entry: agentEntry("A"))
        root.append(parent: nil, entry: agentEntry("B"))
        root.append(parent: nil, entry: agentEntry("D"))

        let link1 = rewind(parentBranchRoot: "D", abandoned: [root.entries[3]])
        root.branchOff(at: .fromJSONL("B"), link: link1)
        root.append(parent: nil, entry: agentEntry("C"))

        // Tree now: [p, A, B, link1, C]. p's index hasn't been
        // advanced (only B's was).
        #expect(root.entries.count == 5)

        let parentPath = root.path(of: .fromJSONL("p"))!
        let abandonedNow = Array(root.entries[(parentPath[0] + 1)...])
        let outerLink = SynthesizedEntry(
            id: .derived(parent: "A", kind: "rewind"),
            header: Header(),
            body: Body(sections: []),
            kind: .rewind(rootUuid: "A"),
            subEntries: abandonedNow
        )
        root.branchOff(at: .fromJSONL("p"), link: outerLink)

        // [p, outerLink]. outerLink contains [A, B, link1, C].
        #expect(root.entries.count == 2)
        guard case .synthesized(let outer) = root.entries[1] else {
            Issue.record("expected outerLink at slot 1; got \(root.entries[1])")
            return
        }
        #expect(outer.subEntries.count == 4)
        // link1 sits at index 2 inside outer.subEntries — genuinely
        // nested, not flattened.
        guard case .synthesized(let nested) = outer.subEntries[2],
              case .rewind = nested.kind else {
            Issue.record("expected link1 nested at outer.subEntries[2]; got \(outer.subEntries[2])")
            return
        }
        #expect(nested.id == link1.id)
    }
}

