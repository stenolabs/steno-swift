import Testing
@testable import Steno

@Suite("Markdown-lite presentation")
struct MarkdownLitePresentationTests {
    @Test("headings paragraphs and both bullet markers become stable blocks")
    func parsesSupportedBlocks() {
        let blocks = MarkdownLitePresentation.blocks(
            "# Summary\n\nParagraph one\ncontinues\n\n- First\n* Second\n\n## Detail"
        )

        #expect(blocks == [
            .heading("Summary"),
            .paragraph("Paragraph one continues"),
            .bullet("First"),
            .bullet("Second"),
            .subheading("Detail"),
        ])
    }

    @Test("blank input has no presentation blocks")
    func blankInput() {
        #expect(MarkdownLitePresentation.blocks(" \n\n") == [])
    }
}
