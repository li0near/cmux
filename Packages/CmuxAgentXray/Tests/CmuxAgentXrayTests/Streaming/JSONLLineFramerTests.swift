import Foundation
import Testing
@testable import CmuxAgentXray

@Suite("JSONLLineFramer — UTF-8 boundary safety")
struct JSONLLineFramerTests {

    @Test("Plain ASCII lines round-trip atomically")
    func asciiBasic() {
        let framer = JSONLLineFramer()
        let chunk = Data("hello\nworld\n".utf8)
        let lines = framer.ingest(chunk)
        #expect(lines == ["hello", "world"])
    }

    @Test("Partial line carries to the next chunk")
    func partialLineCarry() {
        let framer = JSONLLineFramer()
        let chunk1 = Data("foo\nbar".utf8)
        let chunk2 = Data("baz\nqux\n".utf8)
        #expect(framer.ingest(chunk1) == ["foo"])
        #expect(framer.ingest(chunk2) == ["barbaz", "qux"])
    }

    @Test("Multi-byte UTF-8 codepoint split mid-byte stays decodable")
    func utf8SplitInsideCodepoint() {
        // "héllo\n" — 'é' is 0xC3 0xA9 in UTF-8 (2 bytes).
        let full = Data("héllo\n".utf8)
        // Find the byte index of the 'é' — it's the 2nd byte (after 'h').
        // Bytes: ['h'=0x68, 0xC3, 0xA9, 'l'=0x6C, 'l', 'o', '\n'].
        // Split after the leading 0xC3 (incomplete codepoint).
        let splitIdx = 2
        let chunk1 = full.prefix(splitIdx)         // "h" + 0xC3 (partial)
        let chunk2 = full.suffix(from: splitIdx)   // 0xA9 + "llo\n"
        let framer = JSONLLineFramer()
        // First chunk: returns nothing (partial line + partial codepoint).
        #expect(framer.ingest(Data(chunk1)) == [])
        // Second chunk: completes the codepoint and emits "héllo".
        let lines = framer.ingest(Data(chunk2))
        #expect(lines == ["héllo"])
    }

    @Test("3-byte codepoint split anywhere internally still completes")
    func utf8ThreeByteCodepointSplit() {
        // "日本語\n" — each kanji is 3 UTF-8 bytes.
        let full = Data("日本語\n".utf8)
        // Sweep through every possible split position.
        for splitIdx in 1..<full.count {
            let chunk1 = Data(full.prefix(splitIdx))
            let chunk2 = Data(full.suffix(from: splitIdx))
            let framer = JSONLLineFramer()
            let firstEmit = framer.ingest(chunk1)
            let secondEmit = framer.ingest(chunk2)
            // Either the line lands on the first or second emit; it
            // must NEVER drop bytes regardless of split position.
            let combined = firstEmit + secondEmit
            #expect(combined == ["日本語"], "split at \(splitIdx) lost bytes")
        }
    }

    @Test("4-byte codepoint (emoji) split is also safe")
    func utf8EmojiSplit() {
        // "🦀\n" — 🦀 is U+1F980, encodes to 4 UTF-8 bytes.
        let full = Data("🦀\n".utf8)
        for splitIdx in 1..<full.count {
            let chunk1 = Data(full.prefix(splitIdx))
            let chunk2 = Data(full.suffix(from: splitIdx))
            let framer = JSONLLineFramer()
            let combined = framer.ingest(chunk1) + framer.ingest(chunk2)
            #expect(combined == ["🦀"], "split at \(splitIdx) lost emoji bytes")
        }
    }

    @Test("Three-chunk split with codepoint torn across chunk 2 still works")
    func threeChunkCodepointTear() {
        // "a日b\n" — bytes: 'a' 0xE6 0x97 0xA5 'b' '\n'
        let full = Data("a日b\n".utf8)
        // Split into ["a", 0xE6 0x97, 0xA5 + "b\n"] — codepoint
        // straddles chunks 1 and 2.
        let chunk1 = Data(full.prefix(1))
        let chunk2 = Data(full[1..<3])
        let chunk3 = Data(full.suffix(from: 3))
        let framer = JSONLLineFramer()
        let combined = framer.ingest(chunk1) + framer.ingest(chunk2) + framer.ingest(chunk3)
        #expect(combined == ["a日b"])
    }

    @Test("Empty chunk is a no-op")
    func emptyChunk() {
        let framer = JSONLLineFramer()
        #expect(framer.ingest(Data()) == [])
    }

    @Test("Reset clears any carried bytes")
    func resetClearsCarry() {
        let framer = JSONLLineFramer()
        _ = framer.ingest(Data("abc".utf8))  // partial line, no \n
        framer.reset()
        let lines = framer.ingest(Data("xyz\n".utf8))
        #expect(lines == ["xyz"])
    }

    @Test("Whitespace-only lines are filtered out")
    func whitespaceLines() {
        let framer = JSONLLineFramer()
        let chunk = Data("\n   \nhello\n".utf8)
        #expect(framer.ingest(chunk) == ["hello"])
    }

    // MARK: - splitAtUTF8Boundary direct unit tests

    @Test("splitAtUTF8Boundary: clean ASCII boundary")
    func boundaryClean() {
        let data = Data("abc".utf8)
        let (head, tail) = JSONLLineFramer.splitAtUTF8Boundary(data)
        #expect(head == data)
        #expect(tail.isEmpty)
    }

    @Test("splitAtUTF8Boundary: trailing 1 byte of 2-byte sequence is partial")
    func boundary2BytePartial() {
        var data = Data("abc".utf8)
        data.append(0xC3)  // leading byte of 2-byte sequence
        let (head, tail) = JSONLLineFramer.splitAtUTF8Boundary(data)
        #expect(head == Data("abc".utf8))
        #expect(tail == Data([0xC3]))
    }

    @Test("splitAtUTF8Boundary: trailing 2 bytes of 3-byte sequence is partial")
    func boundary3BytePartial() {
        var data = Data("abc".utf8)
        data.append(0xE6)  // leading byte of 3-byte sequence
        data.append(0x97)  // continuation
        let (head, tail) = JSONLLineFramer.splitAtUTF8Boundary(data)
        #expect(head == Data("abc".utf8))
        #expect(tail == Data([0xE6, 0x97]))
    }

    @Test("splitAtUTF8Boundary: complete 3-byte sequence at end is decodable")
    func boundary3ByteComplete() {
        var data = Data("abc".utf8)
        data.append(0xE6)  // 日 begins
        data.append(0x97)
        data.append(0xA5)
        let (head, tail) = JSONLLineFramer.splitAtUTF8Boundary(data)
        #expect(head == data)
        #expect(tail.isEmpty)
    }
}
