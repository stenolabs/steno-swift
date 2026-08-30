import Foundation
import StenoDomain

enum StructuredTemplateCodecError: Error, Equatable, Sendable {
    case invalidOutput
}

/// Das JSON-Schema fuer die strukturierte Ausgabe und ihr Decoder, geteilt
/// von allen OpenAI-kompatiblen Providern. Ein Provider baut daraus seinen
/// eigenen response_format-Block und ruft decode auf den Inhalt der
/// Modellantwort.
enum StructuredTemplateCodec {
    static func schema(for template: Template) -> [String: Any] {
        let sectionIDs = uniqueSectionIDs(template)
        let sectionProperties: [String: Any] = Dictionary(
            uniqueKeysWithValues: sectionIDs.map { ($0, ["type": "string"]) }
        )
        return [
            "type": "object",
            "properties": [
                "sections": [
                    "type": "object",
                    "properties": sectionProperties,
                    "required": sectionIDs,
                    "additionalProperties": false,
                ],
            ],
            "required": ["sections"],
            "additionalProperties": false,
        ]
    }

    static func openAIResponseFormat(for template: Template) -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "template_sections",
                "strict": true,
                // Feste Objektschluessel erzwingen Vollstaendigkeit und
                // Eindeutigkeit ohne minItems/maxItems/uniqueItems. Diese
                // Array-Schluesselwoerter lehnt LM Studio (MLX) ab.
                "schema": schema(for: template),
            ],
        ]
    }

    /// A concrete instance of the strict output shape whose non-empty values
    /// make every JSON type unambiguous to runtimes that ignore JSON Schema.
    /// `decode` remains the authority that rejects missing or extra fields.
    static func stringJSONShapeExample(for template: Template) -> String {
        let sections = Dictionary(
            uniqueKeysWithValues: uniqueSectionIDs(template).map {
                ($0, "Example \($0) content as one string")
            }
        )
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["sections": sections],
            options: [.sortedKeys]
        ), let result = String(data: data, encoding: .utf8) else {
            return #"{"sections":{}}"#
        }
        return result
    }

    static func decode(
        _ data: Data,
        template: Template,
        allowsOuterJSONCodeFence: Bool = false
    ) throws -> StructuredTemplateOutput {
        let decodedData: Data
        if allowsOuterJSONCodeFence,
           let text = String(data: data, encoding: .utf8),
           let unwrapped = unwrapOuterJSONCodeFence(text)
        {
            decodedData = Data(unwrapped.utf8)
        } else {
            decodedData = data
        }

        guard let object = try? JSONSerialization.jsonObject(with: decodedData),
              let output = object as? [String: Any],
              Set(output.keys) == ["sections"]
        else {
            throw StructuredTemplateCodecError.invalidOutput
        }
        let expectedIDs = uniqueSectionIDs(template)
        if let keyedSections = output["sections"] as? [String: Any] {
            guard Set(keyedSections.keys) == Set(expectedIDs) else {
                throw StructuredTemplateCodecError.invalidOutput
            }
            return StructuredTemplateOutput(sections: try expectedIDs.map { sectionID in
                guard let markdown = keyedSections[sectionID] as? String else {
                    throw StructuredTemplateCodecError.invalidOutput
                }
                return StructuredTemplateSection(
                    sectionID: sectionID,
                    markdown: markdown
                )
            })
        }

        // Kompatibilitaet fuer Endpunkte ohne json_schema-Unterstuetzung,
        // die noch das fruehere Arrayformat liefern.
        guard let rawSections = output["sections"] as? [[String: Any]] else {
            throw StructuredTemplateCodecError.invalidOutput
        }
        let sections = try rawSections.map { section -> StructuredTemplateSection in
            guard Set(section.keys) == ["sectionID", "markdown"],
                  let sectionID = section["sectionID"] as? String,
                  let markdown = section["markdown"] as? String
            else {
                throw StructuredTemplateCodecError.invalidOutput
            }
            return StructuredTemplateSection(
                sectionID: sectionID,
                markdown: markdown
            )
        }
        let actualIDs = sections.map(\.sectionID)
        guard actualIDs.count == expectedIDs.count,
              Set(actualIDs).count == actualIDs.count,
              Set(actualIDs) == Set(expectedIDs)
        else {
            throw StructuredTemplateCodecError.invalidOutput
        }
        // Auch das Altformat liefert in Vorlagenreihenfolge zurueck, statt
        // in der Reihenfolge des Arrays: der Aufrufer soll sich auf eine
        // Reihenfolge verlassen koennen, unabhaengig vom Antwortformat.
        let sectionsByID = Dictionary(
            uniqueKeysWithValues: sections.map { ($0.sectionID, $0) }
        )
        return StructuredTemplateOutput(sections: try expectedIDs.map { sectionID in
            guard let section = sectionsByID[sectionID] else {
                throw StructuredTemplateCodecError.invalidOutput
            }
            return section
        })
    }

    private static func uniqueSectionIDs(_ template: Template) -> [String] {
        var seen = Set<String>()
        return template.generatedSections.compactMap { section in
            seen.insert(section.id).inserted ? section.id : nil
        }
    }

    private static func unwrapOuterJSONCodeFence(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```json"), trimmed.hasSuffix("```") else {
            return nil
        }
        let start = trimmed.index(trimmed.startIndex, offsetBy: 7)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -3)
        return String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
