import Foundation
import SwiftUI

enum MarkdownLiteBlock: Equatable {
    case heading(String)
    case subheading(String)
    case bullet(String)
    case paragraph(String)
}

enum MarkdownLitePresentation {
    static func blocks(_ markdown: String) -> [MarkdownLiteBlock] {
        var result: [MarkdownLiteBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for rawLine in markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = String(rawLine)
            if line.hasPrefix("## ") {
                flushParagraph()
                result.append(.subheading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                result.append(.heading(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                result.append(.bullet(String(line.dropFirst(2))))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return result
    }
}

struct MarkdownLiteView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(
                Array(MarkdownLitePresentation.blocks(markdown).enumerated()),
                id: \.offset
            ) { _, block in
                switch block {
                case .heading(let text):
                    Text(inline(text))
                        .font(.title3.weight(.semibold))
                        .padding(.top, 4)
                case .subheading(let text):
                    Text(inline(text))
                        .font(.headline)
                        .padding(.top, 4)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .accessibilityHidden(true)
                        Text(inline(text))
                    }
                    .font(Steno.readingBody)
                case .paragraph(let text):
                    Text(inline(text))
                        .font(Steno.readingBody)
                        .lineSpacing(3)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
