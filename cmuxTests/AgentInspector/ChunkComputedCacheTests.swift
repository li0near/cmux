import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class ChunkComputedCacheTests: XCTestCase {
    // MARK: - Fixtures

    private func userChunk(id: String = "user-1", text: String = "hello world") -> AgentChunk {
        .user(UserChunk(id: id, text: text, startTime: Date(timeIntervalSince1970: 0)))
    }

    private func aiChunk(id: String = "ai-1", assistantText: String = "the answer") -> AgentChunk {
        .ai(AIChunk(
            id: id,
            assistantText: assistantText,
            thinkingText: "",
            toolCalls: [],
            model: nil,
            startTime: Date(timeIntervalSince1970: 0)
        ))
    }

    // MARK: - Cache hit / miss / invalidation

    func testFirstLookupComputesAndPopulatesUserFields() {
        let cache = ChunkComputedCache()
        let chunk = userChunk(text: "alpha beta gamma")
        let fields = cache.compute(for: chunk, displayMode: .compact)
        XCTAssertEqual(fields.user.wordCount, 3)
        XCTAssertEqual(fields.user.full.inlineBody, "alpha beta gamma")
        XCTAssertEqual(cache.computeCount, 1)
    }

    func testRepeatLookupReturnsCached() {
        let cache = ChunkComputedCache()
        let chunk = userChunk(text: "one two three")
        _ = cache.compute(for: chunk, displayMode: .compact)
        _ = cache.compute(for: chunk, displayMode: .compact)
        _ = cache.compute(for: chunk, displayMode: .compact)
        XCTAssertEqual(
            cache.computeCount,
            1,
            "second and third lookups must hit cache, not recompute"
        )
    }

    func testContentGrowthInvalidatesEntry() {
        let cache = ChunkComputedCache()
        let small = aiChunk(assistantText: "abc")
        let grown = aiChunk(assistantText: "abc def ghi")
        let smallFields = cache.compute(for: small, displayMode: .compact)
        let grownFields = cache.compute(for: grown, displayMode: .compact)
        XCTAssertEqual(smallFields.ai.assistantWordCount, 1)
        XCTAssertEqual(grownFields.ai.assistantWordCount, 3)
        XCTAssertEqual(
            cache.computeCount,
            2,
            "content growth must trigger recomputation"
        )
    }

    func testDifferentIdsCacheSeparately() {
        let cache = ChunkComputedCache()
        let a = userChunk(id: "a", text: "x")
        let b = userChunk(id: "b", text: "y z")
        _ = cache.compute(for: a, displayMode: .compact)
        _ = cache.compute(for: b, displayMode: .compact)
        // both repeats must hit cache
        _ = cache.compute(for: a, displayMode: .compact)
        _ = cache.compute(for: b, displayMode: .compact)
        XCTAssertEqual(cache.computeCount, 2)
    }

    func testResetClearsAllEntries() {
        let cache = ChunkComputedCache()
        _ = cache.compute(for: userChunk(text: "first"), displayMode: .compact)
        XCTAssertEqual(cache.computeCount, 1)
        cache.reset()
        XCTAssertEqual(cache.computeCount, 0)
        _ = cache.compute(for: userChunk(text: "first"), displayMode: .compact)
        XCTAssertEqual(
            cache.computeCount,
            1,
            "lookup after reset must recompute, not serve stale entry"
        )
    }

    func testDisplayModeIsPartOfTheSignature() {
        let cache = ChunkComputedCache()
        let chunk = userChunk(text: "alpha beta")
        _ = cache.compute(for: chunk, displayMode: .compact)
        _ = cache.compute(for: chunk, displayMode: .fullDetail)
        XCTAssertEqual(
            cache.computeCount,
            2,
            ".compact and .fullDetail must produce distinct cache entries"
        )
    }

    // MARK: - Equivalence with direct compute

    func testCachedFieldsEqualDirectCompute() {
        let cache = ChunkComputedCache()
        let chunk = aiChunk(assistantText: "lorem ipsum dolor")
        let cached = cache.compute(for: chunk, displayMode: .compact)
        let direct = ChunkComputedFields.compute(for: chunk, displayMode: .compact)
        XCTAssertEqual(cached, direct)
    }
}
