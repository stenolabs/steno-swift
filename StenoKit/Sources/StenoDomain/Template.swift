import Foundation

public struct TemplatePromptComponents: Codable, Equatable, Sendable {
    public let role: String
    public let mapInstructions: String
    public let reduceInstructions: String

    public init(
        role: String,
        mapInstructions: String,
        reduceInstructions: String
    ) {
        self.role = role
        self.mapInstructions = mapInstructions
        self.reduceInstructions = reduceInstructions
    }
}

/// Woher der Inhalt einer Sektion kommt: vom Modell generiert oder
/// deterministisch aus den Daten der Revision (z. B. Sprecherliste).
/// Datenbasierte Sektionen erreichen das Modell nie; was wir sicher
/// wissen, wird nicht generiert (Halluzinationsschutz).
public enum TemplateSectionSource: String, Codable, Equatable, Sendable {
    case generated
    case speakerList
}

public struct TemplateSection: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let prompt: String
    public let source: TemplateSectionSource

    public init(
        id: String,
        title: String,
        prompt: String,
        source: TemplateSectionSource = .generated
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        // Ältere gespeicherte Ergebnisse kennen das Feld nicht.
        source = try container.decodeIfPresent(
            TemplateSectionSource.self,
            forKey: .source
        ) ?? .generated
    }
}

public struct Template: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let sections: [TemplateSection]
    public let prompts: TemplatePromptComponents

    public init(
        id: String,
        name: String,
        description: String,
        sections: [TemplateSection],
        prompts: TemplatePromptComponents
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.sections = sections
        self.prompts = prompts
    }

    /// Die Sektionen, die das Modell füllen soll; datenbasierte Sektionen
    /// gehören weder in Prompt noch Schema noch Modellantwort.
    public var generatedSections: [TemplateSection] {
        sections.filter { $0.source == .generated }
    }
}

public extension Template {
    static let meetingMinutes = Template(
        id: "meeting-minutes",
        name: "Meeting Minutes",
        description: "Structured minutes of a meeting with outcomes and follow-up steps.",
        sections: [
            TemplateSection(
                id: "summary",
                title: "Summary",
                prompt: "Briefly summarise the occasion, course and outcome of the meeting."
            ),
            TemplateSection(
                id: "participants",
                title: "Participants",
                prompt: "Filled deterministically from the recognised speakers.",
                source: .speakerList
            ),
            TemplateSection(
                id: "key-topics",
                title: "Key Topics",
                prompt: "List the essential topics discussed together with their most important statements."
            ),
            TemplateSection(
                id: "decisions",
                title: "Decisions",
                prompt: "List decisions that were explicitly made. Do not invent decisions."
            ),
            TemplateSection(
                id: "action-items",
                title: "Action Items",
                prompt: "List agreed tasks with the responsible person and due date, as far as they are stated."
            ),
        ],
        prompts: TemplatePromptComponents(
            role: "You write factual meeting minutes strictly from the material provided.",
            mapInstructions: "Extract the facts relevant to each template section from this transcript excerpt. Keep names, decisions and tasks precise.",
            reduceInstructions: "Merge the intermediate results without repetition. Preserve concrete names, decisions, tasks, responsibilities and deadlines. Do not add anything the material does not support."
        )
    )
}

public struct TemplateResult: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let markdown: String
    public let template: Template
    public let engine: EngineDescriptor
    public let revisionID: RevisionID
    public let createdAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        markdown: String,
        template: Template,
        engine: EngineDescriptor,
        revisionID: RevisionID,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.markdown = markdown
        self.template = template
        self.engine = engine
        self.revisionID = revisionID
        self.createdAt = createdAt
    }
}
