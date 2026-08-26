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
    /// Revision of this definition. Locked built-ins stay at 1 forever;
    /// every saved edit of an override or custom template bumps it. The
    /// version travels inside every TemplateResult snapshot, so a stored
    /// report always shows exactly which definition produced it.
    public let version: Int
    public let sections: [TemplateSection]
    public let prompts: TemplatePromptComponents

    public init(
        id: String,
        name: String,
        description: String,
        version: Int = 1,
        sections: [TemplateSection],
        prompts: TemplatePromptComponents
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.sections = sections
        self.prompts = prompts
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, version, sections, prompts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        // Older stored results predate the version field.
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sections = try container.decode([TemplateSection].self, forKey: .sections)
        prompts = try container.decode(
            TemplatePromptComponents.self,
            forKey: .prompts
        )
    }

    /// The sections the model fills; data-based sections belong neither in
    /// prompt nor schema nor model answer.
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

/// Shared hallucination-guard sentences baked into every generated section of
/// every built-in (and appended to user-defined markdown prompts): what we
/// know for sure is never invented by the model, and areas nobody talked
/// about are left out instead of padded.
public extension Template {
    static let hallucinationGuard =
        "Only include information explicitly supported by the transcript or notes. Do not invent facts, names, decisions or tasks."

    /// The locked built-in definitions, in gallery order. These values are
    /// immutable originals; overrides live exclusively in TemplateCatalog.
    static let builtinTemplates: [Template] = [
        meetingMinutes,
        productDemo,
        salesCall,
        oneOnOne,
        standup,
    ]

    static func builtin(id: String) -> Template? {
        builtinTemplates.first { $0.id == id }
    }
}

public extension Template {
    static let productDemo = Template(
        id: "product-demo",
        name: "Product Demo",
        description: "Report of a product demonstration written for the evaluated audience.",
        sections: [
            TemplateSection(
                id: "demoed-solution",
                title: "What Was Demoed",
                prompt:
                    "Describe what was demonstrated and the problem it is meant to solve, as presented in the meeting. \(hallucinationGuard)"
            ),
            TemplateSection(
                id: "participants",
                title: "Participants",
                prompt: "Filled deterministically from the recognised speakers.",
                source: .speakerList
            ),
            TemplateSection(
                id: "features-shown",
                title: "Features Shown",
                prompt:
                    "List the key features or capabilities shown during the demo. List only features that were actually shown; omit anything not demonstrated."
            ),
            TemplateSection(
                id: "fit",
                title: "Fit for Stated Needs",
                prompt:
                    "Summarise how well the demo fits the needs the participants stated themselves. State only needs that were explicitly voiced."
            ),
            TemplateSection(
                id: "commercial",
                title: "Pricing and Terms",
                prompt:
                    "List pricing or commercial terms if they were mentioned. If none were mentioned, return an empty value instead of guessing."
            ),
            TemplateSection(
                id: "concerns",
                title: "Concerns and Open Questions",
                prompt:
                    "List concerns or open questions raised by the participants. Do not invent objections nobody raised."
            ),
            TemplateSection(
                id: "next-steps",
                title: "Next Steps",
                prompt:
                    "List agreed next steps with owners as far as they were stated. Do not propose steps nobody agreed to."
            ),
        ],
        prompts: TemplatePromptComponents(
            role: "You write factual product-demo reports strictly from the material provided.",
            mapInstructions: "Extract the facts relevant to each template section from this transcript excerpt. Keep feature names, statements and commitments precise.",
            reduceInstructions: "Merge the intermediate results without repetition. Preserve concrete names, statements and agreements. Omit any area that was not discussed. Do not add anything the material does not support."
        )
    )

    static let salesCall = Template(
        id: "sales-call",
        name: "Sales Call",
        description: "Call summary written for the person running the sales conversation.",
        sections: [
            TemplateSection(
                id: "prospect-needs",
                title: "Prospect Needs",
                prompt:
                    "Summarise the prospect's stated needs, pain points and priorities. Record only needs that were explicitly voiced."
            ),
            TemplateSection(
                id: "participants",
                title: "Participants",
                prompt: "Filled deterministically from the recognised speakers.",
                source: .speakerList
            ),
            TemplateSection(
                id: "objections",
                title: "Objections and Concerns",
                prompt:
                    "List objections or concerns raised during the call. Do not invent objections nobody raised."
            ),
            TemplateSection(
                id: "commercial-process",
                title: "Budget, Timeline and Decision Process",
                prompt:
                    "Capture budget, timeline or decision-process details if they were mentioned. If none were mentioned, return an empty value instead of guessing."
            ),
            TemplateSection(
                id: "competitors",
                title: "Competitors and Alternatives",
                prompt:
                    "List competitors or alternatives the prospect referenced. Name only alternatives that were actually mentioned."
            ),
            TemplateSection(
                id: "next-steps",
                title: "Agreed Next Steps",
                prompt:
                    "List agreed next steps with owners as far as they were stated. Do not propose steps nobody agreed to."
            ),
        ],
        prompts: TemplatePromptComponents(
            role: "You write factual sales-call summaries strictly from the material provided.",
            mapInstructions: "Extract the facts relevant to each template section from this transcript excerpt. Keep needs, objections and commitments attributed exactly as stated.",
            reduceInstructions: "Merge the intermediate results without repetition. Preserve concrete names, objections and agreements. Omit any area that was not discussed. Do not add anything the material does not support."
        )
    )

    static let oneOnOne = Template(
        id: "one-on-one",
        name: "1:1",
        description: "Summary of a one-on-one conversation with feedback and follow-ups.",
        sections: [
            TemplateSection(
                id: "topics-and-updates",
                title: "Topics and Updates",
                prompt:
                    "Summarise the topics discussed and any updates shared, including feedback given in either direction. Keep attributions exact."
            ),
            TemplateSection(
                id: "participants",
                title: "Participants",
                prompt: "Filled deterministically from the recognised speakers.",
                source: .speakerList
            ),
            TemplateSection(
                id: "concerns-and-blockers",
                title: "Concerns and Blockers",
                prompt:
                    "List concerns or blockers raised. Do not invent concerns nobody raised."
            ),
            TemplateSection(
                id: "decisions",
                title: "Decisions",
                prompt:
                    "List decisions that were explicitly made. Do not invent decisions."
            ),
            TemplateSection(
                id: "follow-ups",
                title: "Follow-Ups",
                prompt:
                    "List follow-up actions with who owns them, as far as they are stated. Do not assign owners nobody named."
            ),
        ],
        prompts: TemplatePromptComponents(
            role: "You write factual one-on-one summaries strictly from the material provided.",
            mapInstructions: "Extract the facts relevant to each template section from this transcript excerpt. Keep feedback, concerns and commitments attributed exactly as stated.",
            reduceInstructions: "Merge the intermediate results without repetition. Preserve concrete names, feedback and agreements. Omit any area that was not discussed. Do not add anything the material does not support."
        )
    )

    static let standup = Template(
        id: "standup",
        name: "Standup",
        description: "Brief status sync with per-person updates and blockers.",
        sections: [
            TemplateSection(
                id: "updates",
                title: "Updates",
                prompt:
                    "For each update capture what was done and what is planned next, grouped by person or topic. Keep each update to brief bullet points; this is a quick status sync, not a detailed report. Do not invent updates nobody gave."
            ),
            TemplateSection(
                id: "blockers",
                title: "Blockers",
                prompt:
                    "List blockers raised during the meeting. Do not invent a blocker nobody raised; return an empty value when none came up."
            ),
            TemplateSection(
                id: "participants",
                title: "Participants",
                prompt: "Filled deterministically from the recognised speakers.",
                source: .speakerList
            ),
        ],
        prompts: TemplatePromptComponents(
            role: "You write concise factual standup summaries strictly from the material provided.",
            mapInstructions: "Extract the facts relevant to each template section from this transcript excerpt. Attribute every update to the person who gave it.",
            reduceInstructions: "Merge the intermediate results without repetition. Preserve concrete names, progress statements and blockers. Keep it brief. Do not add anything the material does not support."
        )
    )
}

/// A user-defined markdown template. The markdown body is the free-form
/// generation instruction; it renders through the same structured pipeline
/// as a single generated section and therefore gets the same hallucination
/// guards injected automatically.
public struct CustomTemplate: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let body: String
    /// Bumped on every saved edit; travels in report provenance.
    public let version: Int

    public init(
        id: String,
        name: String,
        description: String,
        body: String,
        version: Int = 1
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.body = body
        self.version = version
    }

    /// Projects the markdown body onto the structured render pipeline.
    public func makeTemplate() -> Template {
        Template(
            id: id,
            name: name,
            description: description,
            version: version,
            sections: [
                TemplateSection(
                    id: "report",
                    title: name,
                    prompt: """
                    \(body.trimmingCharacters(in: .whitespacesAndNewlines))
                    \(Template.hallucinationGuard) Omit any area that was not discussed.
                    """
                )
            ],
            prompts: TemplatePromptComponents(
                role: "You write factual reports strictly from the material provided.",
                mapInstructions: Template.meetingMinutes.prompts.mapInstructions,
                reduceInstructions: Template.meetingMinutes.prompts.reduceInstructions
            )
        )
    }
}

/// How a resolved template entry came to be.
public enum ResolvedTemplateKind: Equatable, Sendable {
    /// Locked shipped definition, unmodified.
    case builtin
    /// User-edited copy shadowing the built-in with the given locked id.
    case override(builtinID: String)
    /// User-created markdown template.
    case custom
}

public struct ResolvedTemplateEntry: Equatable, Sendable {
    public let template: Template
    public let kind: ResolvedTemplateKind
    /// For overrides: the locked original this copy replaces.
    public let original: Template?

    public init(template: Template, kind: ResolvedTemplateKind, original: Template? = nil) {
        self.template = template
        self.kind = kind
        self.original = original
    }
}

/// User-owned template state: edits to built-ins (overrides) plus
/// user-created markdown templates plus the default choice. Persisted as a
/// single JSON document under `steno.templates.catalog`; built-in
/// definitions themselves stay locked in code so an upgrade always restores
/// them ("reset" simply deletes the override entry).
public struct TemplateCatalog: Codable, Equatable, Sendable {
    /// Edited copies keyed by the built-in id they replace.
    public var overrides: [String: Template]
    public var customTemplates: [CustomTemplate]
    /// Applied to new report runs when the UI does not pin a template.
    public var defaultTemplateID: String?

    public init(
        overrides: [String: Template] = [:],
        customTemplates: [CustomTemplate] = [],
        defaultTemplateID: String? = nil
    ) {
        self.overrides = overrides
        self.customTemplates = customTemplates
        self.defaultTemplateID = defaultTemplateID
    }

    // MARK: Resolution

    /// Built-ins first (override applied where present), then customs.
    public func resolvedEntries() -> [ResolvedTemplateEntry] {
        var entries = Template.builtinTemplates.map { builtin in
            if let override = overrides[builtin.id] {
                ResolvedTemplateEntry(
                    template: override,
                    kind: .override(builtinID: builtin.id),
                    original: builtin
                )
            } else {
                ResolvedTemplateEntry(template: builtin, kind: .builtin)
            }
        }
        entries.append(
            contentsOf: customTemplates.map { custom in
                ResolvedTemplateEntry(
                    template: custom.makeTemplate(),
                    kind: .custom
                )
            }
        )
        return entries
    }

    public func resolve(id: String) -> Template? {
        if let override = overrides[id] { return override }
        if let builtin = Template.builtin(id: id) { return builtin }
        return customTemplates.first { $0.id == id }?.makeTemplate()
    }

    /// The template new report runs should use: the stored default if still
    /// resolvable, otherwise Meeting Minutes.
    public func resolvedDefault() -> Template {
        defaultTemplateID.flatMap { resolve(id: $0) } ?? .meetingMinutes
    }

    // MARK: Mutations

    /// Editing a built-in stores an independent copy here; the locked
    /// original stays untouched until reset removes the entry.
    public mutating func upsertOverride(_ template: Template, forBuiltinID builtinID: String) {
        overrides[builtinID] = template
    }

    public mutating func removeOverride(forBuiltinID builtinID: String) {
        overrides.removeValue(forKey: builtinID)
    }

    public mutating func upsertCustom(_ template: CustomTemplate) {
        if let index = customTemplates.firstIndex(where: { $0.id == template.id }) {
            customTemplates[index] = template
        } else {
            customTemplates.append(template)
        }
    }

    /// Deleting a custom that is the default clears the default too, so a
    /// stale pointer can never break future runs.
    public mutating func removeCustom(id: String) {
        customTemplates.removeAll { $0.id == id }
        if defaultTemplateID == id {
            defaultTemplateID = nil
        }
    }

    /// Only resolvable ids are accepted as default.
    public mutating func setDefault(id: String?) {
        guard let id, resolve(id: id) != nil else {
            defaultTemplateID = nil
            return
        }
        defaultTemplateID = id
    }
}

/// Persistence adapter for TemplateCatalog over UserDefaults. Pure storage:
/// all semantics live in TemplateCatalog so tests can run without defaults.
public struct TemplateCatalogStore {
    public static let defaultsKey = "steno.templates.catalog"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> TemplateCatalog {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return TemplateCatalog()
        }
        do {
            return try JSONDecoder().decode(TemplateCatalog.self, from: data)
        } catch {
            // A corrupt document must never take the app's templates down;
            // fall back to the pristine catalog (locked built-ins only).
            return TemplateCatalog()
        }
    }

    public func save(_ catalog: TemplateCatalog) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Authoring rules ported from the legacy implementation: length limits and
/// stable slug ids de-duped against existing ones.
public enum TemplateAuthoring {
    public static let maxNameLength = 200
    public static let maxBodyLength = 8000

    /// Returns nil when the draft is acceptable, otherwise a user-facing
    /// error message.
    public static func validate(name: String, body: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "The template needs a name." }
        if trimmedName.count > maxNameLength {
            return "The name is too long (maximum \(maxNameLength) characters)."
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The template needs instructions."
        }
        if body.count > maxBodyLength {
            return "The instructions are too long (maximum \(maxBodyLength) characters)."
        }
        return nil
    }

    /// A stable slug id from a display name, de-duped against existing ids
    /// (`standup`, `standup-2`, ...).
    public static func newID(from name: String, existingIDs: Set<String>) -> String {
        let base = slug(of: name)
        var candidate = base
        var counter = 2
        while existingIDs.contains(candidate) || Template.builtin(id: candidate) != nil {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private static func slug(of name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var slug = String(
            name.lowercased()
                .map { $0 == " " ? "-" : $0 }
                .filter { allowed.contains($0) }
        )
        if slug.isEmpty { slug = "template" }
        return String(slug.prefix(64))
    }
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
