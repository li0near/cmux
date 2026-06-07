import Foundation
import Testing
@testable import CmuxAgentXray

/// Phase D-rev: when a row's `.image(ImageSource)` section is the
/// click target, the resolver builds a `DetailContent` with the
/// image-carrier fields populated. The detail view routes such
/// content to `host.detailImageView(...)` (for the host's
/// `QLPreviewView`-backed image preview); `body` is empty.
@Suite("DetailContent resolver — image-section branch")
struct DetailContentResolverImageTests {

    private let pngImage = ImageSource(
        kind: .base64,
        mediaType: "image/png",
        data: "iVBORw0KGgo="
    )

    private let jpegImage = ImageSource(
        kind: .base64,
        mediaType: "image/jpeg",
        data: "/9j/4AAQ"
    )

    @Test("User-paste image at section index 0 → imageSource populated, body empty")
    func userImageOnly() {
        let userId = EntryID.fromJSONL("u-image")
        let user = UserEntry(
            id: userId,
            header: Header(),
            body: Body(sections: [.image(pngImage)])
        )
        let entry = Entry.user(user)
        let request = DetailRequest.bodySection(
            targetID: userId.stableString,
            sectionIndex: 0
        )

        let content = DetailContent.resolve(request: request, entry: entry)

        #expect(content != nil)
        #expect(content?.imageSource == pngImage)
        #expect(content?.imageSectionIndex == 0)
        #expect(content?.body == "")
        #expect(content?.sourceEntryID == userId.stableString)
    }

    @Test("User text + image — clicking the image section returns image content")
    func userMixedTextAndImage() {
        let userId = EntryID.fromJSONL("u-mixed")
        let user = UserEntry(
            id: userId,
            header: Header(),
            body: Body(sections: [
                .text(["see this"], style: .normal),
                .image(jpegImage),
            ])
        )
        let entry = Entry.user(user)
        let request = DetailRequest.bodySection(
            targetID: userId.stableString,
            sectionIndex: 1
        )

        let content = DetailContent.resolve(request: request, entry: entry)

        #expect(content?.imageSource == jpegImage)
        #expect(content?.imageSectionIndex == 1)
        #expect(content?.body == "")
    }

    @Test("User text-only — text path still works (regression guard)")
    func userTextOnlyNoImageCarrier() {
        let userId = EntryID.fromJSONL("u-text")
        let user = UserEntry(
            id: userId,
            header: Header(),
            body: Body(sections: [.text(["hello"], style: .normal)])
        )
        let entry = Entry.user(user)
        let request = DetailRequest.bodySection(
            targetID: userId.stableString,
            sectionIndex: 0
        )

        let content = DetailContent.resolve(request: request, entry: entry)

        #expect(content?.imageSource == nil)
        #expect(content?.imageSectionIndex == nil)
        #expect(content?.body == "hello")
    }

    @Test("Tool result image — imageSource populated, body empty")
    func toolImageResult() {
        let parentID = EntryID.fromJSONL("agent-1")
        let toolID = EntryID.fromJSONL("tool-shot")
        let tool = ToolEntry(
            id: toolID,
            parentEntryID: parentID,
            header: Header(name: "browser_take_screenshot"),
            body: Body(sections: [
                .text(["{\"fullPage\":true}"], style: .normal),
                .image(pngImage),
            ]),
            status: .ok
        )
        let agent = AgentEntry(
            id: parentID,
            header: Header(),
            body: Body(sections: [.subentries([])]),
            usage: .zero,
            subEntries: [.tool(tool)]
        )
        let entry = Entry.agent(agent)
        // Section 1 = the image section in the tool's body.
        let request = DetailRequest.bodySection(
            targetID: toolID.stableString,
            sectionIndex: 1
        )

        let content = DetailContent.resolve(request: request, entry: entry)

        #expect(content?.imageSource == pngImage)
        #expect(content?.imageSectionIndex == 1)
        #expect(content?.body == "")
        #expect(content?.sourceEntryID == toolID.stableString)
    }
}
