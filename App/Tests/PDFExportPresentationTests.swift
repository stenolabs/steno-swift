import AppKit
import StenoDomain
import Testing
@testable import steno_macos

/// Structure mapping of the Markdown export onto PDF type styles. The fixture
/// mirrors the exact shape `MeetingMarkdown.render` emits (one construct per
/// line), so a renderer drift would fail here before it reaches a printed
/// document.
@Suite("PDF export presentation")
struct PDFExportPresentationTests {
    private static let sampleMarkdown = """
    # Quarterly Planning

    **Author:** Grace Hopper

    *2026-08-26 10:00*

    **Participants:** Ada, Grace

    ## Notes

    Discussed the roadmap with **clear priorities** and `one snippet`.

    ## Action Items

    - Send the summary
    - Book the room

    ## Transcript

    **[00:15] Ada:** Welcome everyone.

    **[01:02:03] Grace:** Thanks for coming.
    """

    private struct Paragraph {
        let text: String
        let attributes: [NSAttributedString.Key: Any]
        let content: NSAttributedString
    }

    /// Splits an attributed document into its newline-terminated paragraphs.
    private func paragraphs(of document: NSAttributedString) -> [Paragraph] {
        let plain = document.string as NSString
        var result: [Paragraph] = []
        var location = 0
        while location < plain.length {
            let searchRange = NSRange(
                location: location,
                length: plain.length - location
            )
            let found = plain.range(of: "\n", range: searchRange)
            let end = found.location == NSNotFound ? plain.length : found.location + 1
            guard end > location else { break }
            let range = NSRange(location: location, length: end - location)
            var full = NSRange(location: 0, length: 0)
            let attributes = document.attributes(
                at: location,
                longestEffectiveRange: &full,
                in: range
            )
            // Slice by the PARAGRAPH range: multi-run paragraphs (per-run
            // fonts for bold speaker labels) make longestEffectiveRange
            // stop at the first styled run.
            result.append(Paragraph(
                text: plain.substring(with: range),
                attributes: attributes,
                content: document.attributedSubstring(from: range)
            ))
            location = end
        }
        return result
    }

    private func trimmed(_ paragraph: Paragraph) -> String {
        paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func font(_ paragraph: Paragraph) -> NSFont? {
        paragraph.attributes[.font] as? NSFont
    }

    @Test("the title maps to the largest bold style")
    func titleMapsToTitleStyle() throws {
        let document = PDFExportPresentation.attributedDocument(
            fromMarkdown: Self.sampleMarkdown
        )
        let first = try #require(paragraphs(of: document).first)
        #expect(trimmed(first) == "Quarterly Planning")
        let titleFont = try #require(font(first))
        #expect(titleFont.pointSize == PDFExportPresentation.titleFontSize)
        #expect(titleFont != NSFont.systemFont(ofSize: PDFExportPresentation.bodyFontSize))
    }

    @Test("section headings map to their own style")
    func sectionHeadingsMapToSectionStyle() throws {
        let document = PDFExportPresentation.attributedDocument(
            fromMarkdown: Self.sampleMarkdown
        )
        let headings = paragraphs(of: document).filter {
            ["Notes", "Action Items", "Transcript"].contains(trimmed($0))
        }
        #expect(headings.count == 3)
        let expectedSize = PDFExportPresentation.sectionHeadingFontSize
        for heading in headings {
            #expect(font(heading)?.pointSize == expectedSize)
        }
    }

    @Test("date line renders as quiet metadata without literal markers")
    func dateLineRendersAsMeta() throws {
        let document = PDFExportPresentation.attributedDocument(
            fromMarkdown: Self.sampleMarkdown
        )
        let meta = try #require(
            paragraphs(of: document).first { $0.text.contains("2026-08-26 10:00") }
        )
        #expect(font(meta)?.pointSize == PDFExportPresentation.metaFontSize)
        #expect(!meta.text.contains("*"))
    }

    @Test("bullets get an indented marker and keep their text")
    func bulletsGetIndentedMarker() throws {
        let document = PDFExportPresentation.attributedDocument(
            fromMarkdown: Self.sampleMarkdown
        )
        let bullets = paragraphs(of: document).filter { $0.text.contains("\u{2022}") }
        #expect(bullets.map(trimmed) == [
            "•\tSend the summary",
            "•\tBook the room",
        ])
        for bullet in bullets {
            let style = bullet.attributes[.paragraphStyle] as? NSParagraphStyle
            #expect(style?.headIndent == 14)
            // The Markdown list marker itself must not survive.
            #expect(!bullet.content.string.contains("- "))
        }
    }

    @Test("transcript turns keep speaker names heavier than their spoken text")
    func transcriptTurnsEmphasizeTheSpeaker() throws {
        let document = PDFExportPresentation.attributedDocument(
            fromMarkdown: Self.sampleMarkdown
        )
        let turn = try #require(
            paragraphs(of: document).first { $0.text.contains("Welcome everyone.") }
        )
        let content = turn.content
        // No literal Markdown markers survive.
        #expect(!content.string.contains("**"))

        let fullRange = NSRange(location: 0, length: content.length)
        let speakerRange = (content.string as NSString).range(of: "Ada:")
        #expect(speakerRange.location != NSNotFound)

        let spokenText = "Welcome everyone."
        let spokenRange = (content.string as NSString).range(of: spokenText)
        #expect(spokenRange.location != NSNotFound)

        // Font attributes span whole styled runs: match the range that
        // CONTAINS the speaker label, not one that starts exactly there.
        var speakerFont: NSFont?
        content.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard let candidate = value as? NSFont else { return }
            if NSLocationInRange(speakerRange.location, range) {
                speakerFont = candidate
            }
        }
        var spokenFont: NSFont?
        content.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard let candidate = value as? NSFont else { return }
            if NSLocationInRange(spokenRange.location, range) {
                spokenFont = candidate
            }
        }

        let regularBody = NSFont.systemFont(ofSize: PDFExportPresentation.bodyFontSize)
        // The speaker label stands out; the quoted words do not.
        #expect(speakerFont != nil && speakerFont != regularBody)
        #expect(spokenFont == regularBody)
    }

    @Test("inline emphasis inside body text resolves without leaking markers")
    func inlineEmphasisResolvesInsideBody() throws {
        let document = PDFExportPresentation.attributedDocument(
            fromMarkdown: Self.sampleMarkdown
        )
        let body = try #require(
            paragraphs(of: document).first { $0.text.contains("roadmap") }
        )
        #expect(!body.content.string.contains("**"))
        #expect(!body.content.string.contains("`"))
        #expect(body.content.string.contains("clear priorities"))
    }

    @Test("the rendered artifact is a real PDF file")
    func renderedOutputIsValidPDF() throws {
        // Enough transcript turns to force pagination beyond one page.
        let turns = (0..<160).map { index -> String in
            let timecode = String(format: "%02d:%02d", index / 60, index % 60)
            return "**[\(timecode)] Ada:** Point \(index) of the discussion, with enough prose to wrap onto a second line."
        }
        let markdown = "# Long Meeting\n\n*2026-08-26 10:00*\n\n## Transcript\n\n"
            + turns.joined(separator: "\n\n")

        let url = try PDFExportPresentation.writeTemporaryPDF(
            markdown: markdown,
            fileName: "2026-08-26 Long Meeting.md"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.lastPathComponent == "2026-08-26 Long Meeting.pdf")
        let data = try Data(contentsOf: url)
        #expect(data.count > 1_000)
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "%PDF-")
    }

    @Test("an empty document is rejected instead of written as a blank file")
    func emptyDocumentThrowsInsteadOfWriting() {
        #expect(throws: PDFExportPresentation.RenderingError.emptyDocument) {
            try PDFExportPresentation.pdfData(document: NSAttributedString())
        }
    }
}

/// Parity contract with legacy notesCopy.ts: the clipboard carries exactly the
/// text the individual meeting export writes to disk - one source of truth,
/// two surfaces.
@Suite("Meeting notes copy payload")
@MainActor
struct MeetingNotesCopyPayloadTests {
    @Test("copying notes places the markdown export output on the pasteboard")
    func copyPayloadEqualsMarkdownExport() async throws {
        try await withIsolatedModel { model, _ in
            let runtime = try #require(model.runtime)
            let meeting = try await runtime.library.createMeeting(
                title: "Sync",
                status: .ready
            )
            _ = try await runtime.library.appendRevision(TranscriptRevision(
                meetingID: meeting.id,
                origin: .legacyImport,
                turns: [
                    TranscriptTurn(
                        start: 0,
                        end: 4,
                        segments: [TranscriptSegment(
                            text: "We aligned on the plan.",
                            start: 0,
                            end: 2,
                            words: []
                        )]
                    ),
                    TranscriptTurn(
                        start: 4,
                        end: 8,
                        segments: [TranscriptSegment(
                            text: "Thanks everyone.",
                            start: 4,
                            end: 6,
                            words: []
                        )]
                    ),
                ]
            ))

            let exported = try #require(await model.exportMarkdown(for: meeting.id))
            let copied = try #require(await model.copyNotesToPasteboard(for: meeting.id))

            // The copy payload equals the markdown export output, byte for byte.
            #expect(copied == exported.text)
            #expect(NSPasteboard.general.string(forType: .string) == exported.text)
            // And the export really produced something worth copying.
            #expect(exported.name.hasSuffix(".md"))
            #expect(exported.text.contains("# Sync"))
            #expect(exported.text.contains("We aligned on the plan."))
        }
    }

    private func withIsolatedModel(
        _ operation: (AppModel, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Steno-MeetingNotesCopyPayloadTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        let modelURL = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(libraryURL: libraryURL, modelCacheDirectoryOverride: modelURL)
        await model.bootstrap()

        do {
            try await operation(model, libraryURL)
            await model.runtime?.coordinator.stop()
        } catch {
            await model.runtime?.coordinator.stop()
            throw error
        }
    }
}
