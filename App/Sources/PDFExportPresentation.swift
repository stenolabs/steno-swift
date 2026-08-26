import AppKit

/// Renders a meeting's Markdown export as a plain, print-quality PDF.
///
/// Parity notes (legacy `app/renderer/src/lib/notesPdf.ts`): the old app
/// assembled a branded HTML document with base64-embedded fonts and rendered
/// it through Chromium. This port is deliberately simpler - system fonts, no
/// embedded assets, one fixed ink color on white - because a PDF is a printed
/// artifact, not a themed UI surface. That is the one documented divergence
/// from the legacy renderer; everything about the *input* is shared: the
/// Markdown string handed here is exactly what `AppModel.exportMarkdown`
/// produces and what the Copy-notes action places on the clipboard, so all
/// three outputs can never drift apart.
///
/// Pure where it matters: `attributedDocument(fromMarkdown:)` maps structure
/// only and touches neither files nor windows, which keeps the markdown-to-
/// attributed-string mapping unit-testable. Rendering paginates with the stock
/// NSLayoutManager text system into a CoreGraphics PDF context - the same
/// typesetter the detail view uses, so nothing needs a second layout engine.
enum PDFExportPresentation {
    // MARK: Page geometry

    /// A4 in points at 72 dpi, matching the legacy `@page { size: A4 }`.
    static let pageSize = CGSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 56

    private static var contentRect: CGRect {
        CGRect(
            x: margin,
            y: margin,
            width: pageSize.width - 2 * margin,
            height: pageSize.height - 2 * margin
        )
    }

    // MARK: Type styles

    static let titleFontSize: CGFloat = 20
    static let sectionHeadingFontSize: CGFloat = 13
    static let subheadingFontSize: CGFloat = 11.5
    static let bodyFontSize: CGFloat = 11
    static let metaFontSize: CGFloat = 10
    static let ink = NSColor.black
    static let metaInk = NSColor.darkGray

    // MARK: Markdown to attributed document

    /// Maps the structure of a `MeetingMarkdown.render` document onto type
    /// styles. Line-based by design: the renderer emits one construct per line
    /// (# headings, ## sections, "- " bullets, "**[time] Speaker:**" turns),
    /// and inline emphasis inside a line is resolved through Foundation's own
    /// Markdown parser so bold/italic/code never leak as literal markers.
    static func attributedDocument(fromMarkdown markdown: String) -> NSAttributedString {
        let document = NSMutableAttributedString()
        for rawLine in markdown.components(separatedBy: "\n") {
            appendLine(rawLine, to: document)
        }
        return document
    }

    private enum LineStyle {
        case title(String)
        case sectionHeading(String)
        case subheading(String)
        case bullet(item: String)
        case transcriptTurn(String)
        case meta(String)
        case paragraph(String)
    }

    private static func classify(_ rawLine: String) -> LineStyle? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("# ") {
            return .title(trimmedBody(line, marker: "# "))
        }
        if line.hasPrefix("## ") {
            return .sectionHeading(trimmedBody(line, marker: "## "))
        }
        if line.hasPrefix("### ") || line.hasPrefix("#### ") {
            return .subheading(trimmedBody(line, marker: "### "))
        }
        if line.hasPrefix("- ") {
            return .bullet(item: String(line.dropFirst(2)))
        }
        // Transcript turns: **[00:15] Ada:** Welcome everyone.
        if line.hasPrefix("**[") { return .transcriptTurn(line) }
        // The date line (*2026-08-26 10:00*) and the empty-transcript note
        // (_No transcript yet._) are whole-line emphasized markers, not body
        // text - they render as quiet metadata.
        if isWholeLineEmphasis(line) { return .meta(line) }
        return .paragraph(line)
    }

    private static func trimmedBody(_ line: String, marker: String) -> String {
        String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func isWholeLineEmphasis(_ line: String) -> Bool {
        for marker in ["*", "_"] where line.hasPrefix(marker) && line.hasSuffix(marker) {
            let inner = line.dropFirst().dropLast()
            if inner.count > 0 && !inner.contains(marker) { return true }
        }
        return false
    }

    private static func appendLine(_ rawLine: String, to document: NSMutableAttributedString) {
        switch classify(rawLine) {
        case nil:
            // Blank lines carry no ink; vertical rhythm comes from the
            // paragraph spacing of the surrounding constructs.
            return
        case .title(let text):
            document.append(
                styledParagraph(
                    inlineMarkdown(text, size: titleFontSize, color: ink),
                    spacingBefore: 0,
                    spacingAfter: 12
                )
            )
        case .sectionHeading(let text):
            document.append(
                styledParagraph(
                    inlineMarkdown(text, size: sectionHeadingFontSize, weight: .semibold, color: ink),
                    spacingBefore: 18,
                    spacingAfter: 7
                )
            )
        case .subheading(let text):
            document.append(
                styledParagraph(
                    inlineMarkdown(text, size: subheadingFontSize, weight: .semibold, color: ink),
                    spacingBefore: 12,
                    spacingAfter: 5
                )
            )
        case .bullet(let item):
            let format = NSMutableParagraphStyle()
            format.paragraphSpacing = 4
            // Tab-stop indent so wrapped bullet lines align under their text.
            format.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
            format.headIndent = 14
            let content = NSMutableAttributedString(
                attributedString: inlineMarkdown("•", size: bodyFontSize, color: ink)
            )
            content.append(attributed("\t", font: .systemFont(ofSize: bodyFontSize), color: ink))
            content.append(inlineMarkdown(item, size: bodyFontSize, color: ink))
            document.append(finish(content, format: format))
        case .transcriptTurn(let line):
            document.append(
                styledParagraph(
                    inlineMarkdown(line, size: bodyFontSize, color: ink),
                    spacingBefore: 0,
                    spacingAfter: 8
                )
            )
        case .meta(let line):
            document.append(
                styledParagraph(
                    inlineMarkdown(line, size: metaFontSize, color: metaInk),
                    spacingBefore: 0,
                    spacingAfter: 4
                )
            )
        case .paragraph(let line):
            document.append(
                styledParagraph(
                    inlineMarkdown(line, size: bodyFontSize, color: ink),
                    spacingBefore: 0,
                    spacingAfter: 6
                )
            )
        }
    }

    /// Resolves inline Markdown (**bold**, _italic_, `code`) into fonts while
    /// keeping the plain characters intact. Falls back to the literal string
    /// when the snippet is not valid Markdown - exporting must never fail on
    /// meeting content.
    private static func inlineMarkdown(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor
    ) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
        let result = NSMutableAttributedString()
        var wroteAnyRun = false
        for run in parsed.runs {
            wroteAnyRun = true
            result.append(
                attributed(
                    String(parsed[run.range].characters),
                    font: font(for: run.inlinePresentationIntent, baseSize: size, baseWeight: weight),
                    color: color
                )
            )
        }
        if !wroteAnyRun, !text.isEmpty {
            result.append(attributed(text, font: .systemFont(ofSize: size, weight: weight), color: color))
        }
        return result
    }

    private static func font(
        for intent: InlinePresentationIntent?,
        baseSize: CGFloat,
        baseWeight: NSFont.Weight
    ) -> NSFont {
        guard let intent else { return .systemFont(ofSize: baseSize, weight: baseWeight) }
        if intent.contains(.code) {
            return .monospacedSystemFont(ofSize: baseSize, weight: baseWeight)
        }
        var weight = baseWeight
        if intent.contains(.stronglyEmphasized) {
            weight = baseWeight == .regular ? .semibold : .bold
        }
        // Only round-trip through a descriptor when there is a trait to
        // apply: withSymbolicTraits([]) drops the weight attribute on
        // current AppKit, silently degrading bold labels to regular.
        guard intent.contains(.emphasized) else {
            return .systemFont(ofSize: baseSize, weight: weight)
        }
        let descriptor = NSFont.systemFont(ofSize: baseSize, weight: weight)
            .fontDescriptor
            .withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: baseSize)
            ?? .systemFont(ofSize: baseSize, weight: weight)
    }

    // MARK: Paragraph assembly

    private struct ParagraphFormat {
        var spacingBefore: CGFloat = 0
        var spacingAfter: CGFloat = 6

        func make() -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = spacingAfter
            style.lineBreakMode = .byWordWrapping
            return style
        }
    }

    private static func paragraphFormat(
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat
    ) -> NSParagraphStyle {
        ParagraphFormat(spacingBefore: spacingBefore, spacingAfter: spacingAfter).make()
    }

    private static func styledParagraph(
        _ content: NSAttributedString,
        spacingBefore: CGFloat,
        spacingAfter: CGFloat
    ) -> NSAttributedString {
        finish(
            NSMutableAttributedString(attributedString: content),
            format: paragraphFormat(spacingBefore: spacingBefore, spacingAfter: spacingAfter)
        )
    }

    /// Applies the paragraph style and closes the paragraph with a newline so
    /// consecutive constructs stay separate paragraphs in the layout manager.
    private static func finish(
        _ content: NSMutableAttributedString,
        format: NSParagraphStyle
    ) -> NSMutableAttributedString {
        content.addAttribute(
            .paragraphStyle,
            value: format,
            range: NSRange(location: 0, length: content.length)
        )
        content.append(NSAttributedString("\n"))
        return content
    }

    private static func attributed(
        _ string: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    // MARK: PDF rendering

    enum RenderingError: Error {
        case consumerUnavailable
        case contextUnavailable
        case emptyDocument
    }

    /// Paginates the document into A4 pages and returns the PDF bytes.
    static func pdfData(document: NSAttributedString) throws -> Data {
        guard document.length > 0 else { throw RenderingError.emptyDocument }

        let bounds = contentRect
        let storage = NSTextStorage(attributedString: document)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw RenderingError.consumerUnavailable
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            throw RenderingError.contextUnavailable
        }

        var remaining = NSRange(location: 0, length: storage.length)
        // Defensive bound: a healthy layout never needs anywhere near this
        // many pages for a meeting, but a stalled loop must not hang the app.
        let maximumPages = 5000
        for _ in 0..<maximumPages {
            guard remaining.length > 0 else { break }
            context.beginPDFPage(nil)

            let container = NSTextContainer(containerSize: bounds.size)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(forCharacterRange: remaining)
            let glyphs = layoutManager.glyphRange(for: container)

            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            layoutManager.drawBackground(forGlyphRange: glyphs, at: bounds.origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: bounds.origin)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()

            guard glyphs.length > 0 else { break }
            remaining.location = NSMaxRange(glyphs)
            remaining.length = storage.length - remaining.location
        }
        context.closePDF()
        return output as Data
    }

    // MARK: Temporary share file

    /// Writes the rendered PDF next to nothing the user owns: an isolated
    /// temporary directory that the sharing service can read and that vanishes
    /// with the system temp cleanup. Stale exports from previous shares are
    /// swept opportunistically.
    @discardableResult
    static func writeTemporaryPDF(markdown: String, fileName: String, now: Date = Date()) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Steno-PDF-Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = (fileName as NSString).deletingPathExtension
        let url = directory.appendingPathComponent("\(stem).pdf")
        try pdfData(document: attributedDocument(fromMarkdown: markdown))
            .write(to: url, options: .atomic)
        removeStaleTemporaryExports(now: now)
        return url
    }

    private static func removeStaleTemporaryExports(now: Date, maxAge: TimeInterval = 60 * 60 * 24) {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("Steno-PDF-Export-") {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            if now.timeIntervalSince(created) > maxAge {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: Sharing

    /// Presents the system share menu for the rendered file. AppKit does not
    /// retain the picker while its menu tracks, and SwiftUI has no anchor view
    /// to offer here, so this owns exactly one live presenter at a time -
    /// sharing menus are exclusive anyway.
    @discardableResult
    @MainActor static func presentShareSheet(for fileURL: URL, anchoredTo anchor: NSView?) -> Bool {
        guard let anchor = anchor ?? NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else {
            return false
        }
        let picker = NSSharingServicePicker(items: [fileURL])
        let presenter = SharePresenter(picker: picker)
        Self.liveSharePresenter = presenter
        presenter.present(anchoredTo: anchor)
        return true
    }

    /// Keeps the picker alive for the lifetime of its open menu. Replaced on
    /// the next presentation or released once the user chose a service.
    nonisolated(unsafe) fileprivate static var liveSharePresenter: SharePresenter?

    // The delegate methods arrive on the main thread (AppKit UI). The
    // presenter is confined by usage to the main thread; the unsafe marker
    // documents that confinement for Swift 6 without fighting the
    // delegate protocol's nonisolated requirements.
    fileprivate final class SharePresenter: NSObject, NSSharingServicePickerDelegate, @unchecked Sendable {
        nonisolated(unsafe) private let picker: NSSharingServicePicker

        init(picker: NSSharingServicePicker) {
            self.picker = picker
        }

        func present(anchoredTo view: NSView) {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            PDFExportPresentation.liveSharePresenter = nil
        }
    }
}
