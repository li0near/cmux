import Foundation
import Testing
@testable import CmuxAgentXray

/// Phase B.3: user-paste image emission. Before the rewrite, the
/// transcript builder filtered every non-text block at the `joinText`
/// helper, so user-pasted screenshots silently disappeared from the
/// rendered `UserEntry.body` — confirmed in the round-2 corpus audit
/// (15 files exercise the path). The rewrite walks each block and
/// emits a per-block ``Section``, keeping arrival order.
@Suite("ClaudeTranscriptBuilder — user-paste image regression")
struct ClaudeTranscriptBuilderUserContentTests {

    private func decodeLine(_ json: String) throws -> ClaudeJSONLLine {
        try AgentXrayJSON.decoder.decode(ClaudeJSONLLine.self, from: Data(json.utf8))
    }

    private func buildUserEntry(jsonl: String) throws -> UserEntry {
        var builder = ClaudeTranscriptBuilder()
        try builder.ingest(decodeLine(jsonl))
        let entries = builder.transcript()
        guard let user = entries.compactMap({ entry -> UserEntry? in
            if case .user(let u) = entry { return u }
            return nil
        }).first else {
            Issue.record("No UserEntry produced; entries: \(entries)")
            return UserEntry(
                id: .fromJSONL("missing"),
                header: Header(),
                body: .empty,
                queuedState: .none
            )
        }
        return user
    }

    @Test("user message with text + image emits both sections")
    func userTextAndImage() throws {
        let json = #"""
        {
          "type": "user",
          "uuid": "u1",
          "parentUuid": null,
          "timestamp": "2026-06-07T10:00:00.000Z",
          "message": {
            "role": "user",
            "content": [
              {"type":"text","text":"see screenshot"},
              {"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0K"}}
            ]
          }
        }
        """#
        let user = try buildUserEntry(jsonl: json)
        #expect(user.body.sections.count == 2)
        guard case .text(let blocks, _) = user.body.sections[0],
              case .image(let source) = user.body.sections[1] else {
            Issue.record("Wrong shape: \(user.body.sections)")
            return
        }
        #expect(blocks == ["see screenshot"])
        #expect(source.kind == .base64)
        #expect(source.mediaType == "image/png")
        #expect(source.data == "iVBORw0K")
    }

    @Test("user message with image-only produces UserEntry with .image section")
    func userImageOnly() throws {
        let json = #"""
        {
          "type": "user",
          "uuid": "u1",
          "parentUuid": null,
          "timestamp": "2026-06-07T10:00:00.000Z",
          "message": {
            "role": "user",
            "content": [
              {"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"/9j/4AA"}}
            ]
          }
        }
        """#
        let user = try buildUserEntry(jsonl: json)
        #expect(user.body.sections.count == 1)
        guard case .image(let source) = user.body.sections[0] else {
            Issue.record("Expected .image section, got \(user.body.sections)")
            return
        }
        #expect(source.mediaType == "image/jpeg")
    }

    @Test("string-shaped user content produces single .text section")
    func userStringShaped() throws {
        let json = #"""
        {
          "type": "user",
          "uuid": "u1",
          "parentUuid": null,
          "timestamp": "2026-06-07T10:00:00.000Z",
          "message": {"role": "user", "content": "hello"}
        }
        """#
        let user = try buildUserEntry(jsonl: json)
        #expect(user.body.sections.count == 1)
        guard case .text(let blocks, _) = user.body.sections[0] else {
            Issue.record("Expected .text section")
            return
        }
        #expect(blocks == ["hello"])
    }

    @Test("text-only blocks user content produces single .text section")
    func userTextBlocks() throws {
        let json = #"""
        {
          "type": "user",
          "uuid": "u1",
          "parentUuid": null,
          "timestamp": "2026-06-07T10:00:00.000Z",
          "message": {
            "role": "user",
            "content": [{"type":"text","text":"hello"}]
          }
        }
        """#
        let user = try buildUserEntry(jsonl: json)
        #expect(user.body.sections.count == 1)
        guard case .text(let blocks, _) = user.body.sections[0] else {
            Issue.record("Expected .text section")
            return
        }
        #expect(blocks == ["hello"])
    }

    @Test("URL-mode image block (spec but not in corpus) is dropped silently")
    func userUrlModeImageDropped() throws {
        let json = #"""
        {
          "type": "user",
          "uuid": "u1",
          "parentUuid": null,
          "timestamp": "2026-06-07T10:00:00.000Z",
          "message": {
            "role": "user",
            "content": [
              {"type":"text","text":"caption"},
              {"type":"image","source":{"type":"url","url":"https://x"}}
            ]
          }
        }
        """#
        let user = try buildUserEntry(jsonl: json)
        // URL-mode image dropped; only the text block survives.
        #expect(user.body.sections.count == 1)
        if case .text(let blocks, _) = user.body.sections[0] {
            #expect(blocks == ["caption"])
        }
    }
}
