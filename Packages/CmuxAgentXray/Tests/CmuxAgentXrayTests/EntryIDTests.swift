import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("EntryID round-trip + variant detection")
struct EntryIDTests {

    @Test("jsonl-mirrored id round-trips its uuid")
    func jsonlRoundTrip() {
        let id = EntryID.fromJSONL("550e8400-e29b-41d4-a716-446655440000")
        #expect(id.stableString == "550e8400-e29b-41d4-a716-446655440000")
        #expect(id.isJSONLMirrored == true)
    }

    @Test("derived id namespaces under parent + kind")
    func derived() {
        let id = EntryID.derived(parent: "abc", kind: "thinking")
        #expect(id.stableString == "d:thinking:abc")
        #expect(id.isJSONLMirrored == false)
    }

    @Test("two equal sources hash equal")
    func hashing() {
        let a = EntryID.fromJSONL("x")
        let b = EntryID.fromJSONL("x")
        var set: Set<EntryID> = []
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }

    @Test("derived siblings under one parent are distinct")
    func siblings() {
        let thinking = EntryID.derived(parent: "abc", kind: "thinking")
        let assistant = EntryID.derived(parent: "abc", kind: "assistantText")
        #expect(thinking != assistant)
        #expect(thinking.stableString != assistant.stableString)
    }
}
