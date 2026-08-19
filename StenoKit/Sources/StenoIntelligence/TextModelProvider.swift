import Foundation
import StenoDomain

public enum TextModelUnavailabilityReason: Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown
}

public enum TextModelAvailability: Equatable, Sendable {
    case available
    case unavailable(TextModelUnavailabilityReason)
}

public extension TextModelAvailability {
    var unavailabilityMessage: String? {
        switch self {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "Dieses Gerät unterstützt Apple Intelligence nicht."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence ist nicht aktiviert."
        case .unavailable(.modelNotReady):
            "Das Apple-Intelligence-Modell ist noch nicht verfügbar."
        case .unavailable(.unknown):
            "Das Textmodell ist derzeit nicht verfügbar."
        }
    }
}

public struct TranscriptChunkTurn: Equatable, Sendable {
    public let speakerName: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(
        speakerName: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) {
        self.speakerName = speakerName
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptChunk: Equatable, Sendable {
    public let turns: [TranscriptChunkTurn]

    public init(turns: [TranscriptChunkTurn]) {
        self.turns = turns
    }
}

public struct StructuredTemplateSection: Equatable, Sendable {
    public let sectionID: String
    public let markdown: String

    public init(sectionID: String, markdown: String) {
        self.sectionID = sectionID
        self.markdown = markdown
    }
}

public struct StructuredTemplateOutput: Equatable, Sendable {
    public let sections: [StructuredTemplateSection]

    public init(sections: [StructuredTemplateSection]) {
        self.sections = sections
    }
}

public enum TextModelRequest: Equatable, Sendable {
    case map(TranscriptChunk)
    case reduce([StructuredTemplateOutput])
}

public typealias SpeakerNameResolver = @Sendable (SpeakerReference) -> String?

public protocol TextModelProvider: Sendable {
    var descriptor: EngineDescriptor { get }
    var availability: TextModelAvailability { get }

    func render(
        template: Template,
        transcript: TranscriptRevision
    ) async throws -> TemplateResult

    /// Rendert mit einer verbindlichen, bereits kuratierten Teilnehmerliste
    /// für datenbasierte Sektionen (Reihenfolge = Anzeige-Reihenfolge).
    func render(
        template: Template,
        transcript: TranscriptRevision,
        participants: [String]
    ) async throws -> TemplateResult

    /// Zusätzlich mit dem Benutzerkontext dieses Meetings (Notizen).
    func render(
        template: Template,
        transcript: TranscriptRevision,
        participants: [String],
        context: RenderContext
    ) async throws -> TemplateResult
}

public extension TextModelProvider {
    func render(
        template: Template,
        transcript: TranscriptRevision,
        participants: [String]
    ) async throws -> TemplateResult {
        try await render(template: template, transcript: transcript)
    }

    /// Wer den Kontext nicht auswertet, rendert wie bisher; die Notiz geht
    /// dann verloren, statt dass der Lauf scheitert.
    func render(
        template: Template,
        transcript: TranscriptRevision,
        participants: [String],
        context: RenderContext
    ) async throws -> TemplateResult {
        try await render(
            template: template,
            transcript: transcript,
            participants: participants
        )
    }
}

/// Vom Benutzer beigesteuerter Kontext zu einem Lauf, getrennt vom
/// Transkript gehalten.
///
/// Notizen enthalten regelmaessig Namen und Begriffe, die im Gespraech nur
/// undeutlich fallen - genau deshalb sind sie wertvoll. Sie sind aber
/// Freitext des Benutzers und werden im Prompt derselben Haertung
/// unterworfen wie das Transkript: Quelldaten, keine Anweisungen.
public struct RenderContext: Equatable, Sendable {
    public let userNotes: String?
    /// Die Anwesenden, wie sie im Protokoll erscheinen sollen - mit Firma,
    /// wo eine hinterlegt ist.
    ///
    /// Die Liste wird ohnehin deterministisch in die Teilnehmersektion
    /// gerendert; damit das Modell einen Firmennamen im Fliesstext korrekt
    /// ausschreiben kann, muss es ihn aber auch im Prompt sehen. Ohne diesen
    /// Weg bliebe die Firma unsichtbar fuer das Modell.
    public let participants: [String]

    // Kein Verfasserfeld, und das ist eine Entscheidung: der Name fiel zwar
    // in die freigegebene Klasse "Teilnehmerliste, Namen und Firmen"
    // (PLAN-PRIVACY.md:52), aber keine Sektion von Template.meetingMinutes
    // fragt, wer das Protokoll schreibt. Wer sich selbst als Anwesenden
    // nennen will, tut das ueber die Teilnehmerliste - dort fuehrt der Name
    // eine Aufgabe. Der Exportkopf traegt ihn weiterhin, der entsteht lokal.

    public init(userNotes: String? = nil, participants: [String] = []) {
        let trimmedNotes = userNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userNotes = (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes
        self.participants = participants
    }

    public static let empty = RenderContext()

    public var isEmpty: Bool { userNotes == nil && participants.isEmpty }
}

public protocol StructuredTextModelProvider: TextModelProvider {
    func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput
}

public extension StructuredTextModelProvider {
    /// Ohne Benutzerkontext - der Normalfall fuer alles, was keine Notizen
    /// kennt.
    func generate(
        template: Template,
        request: TextModelRequest
    ) async throws -> StructuredTemplateOutput {
        try await generate(template: template, request: request, context: .empty)
    }

    func render(
        template: Template,
        transcript: TranscriptRevision
    ) async throws -> TemplateResult {
        try await TemplateRenderer(provider: self).render(
            template: template,
            transcript: transcript
        )
    }

    func render(
        template: Template,
        transcript: TranscriptRevision,
        participants: [String]
    ) async throws -> TemplateResult {
        try await TemplateRenderer(provider: self).render(
            template: template,
            transcript: transcript,
            participants: participants
        )
    }

    func render(
        template: Template,
        transcript: TranscriptRevision,
        resolvingSpeakerName resolver: SpeakerNameResolver
    ) async throws -> TemplateResult {
        try await TemplateRenderer(provider: self).render(
            template: template,
            transcript: transcript,
            resolvingSpeakerName: resolver
        )
    }

    func render(
        template: Template,
        transcript: TranscriptRevision,
        participants: [String],
        context: RenderContext
    ) async throws -> TemplateResult {
        try await TemplateRenderer(provider: self).render(
            template: template,
            transcript: transcript,
            participants: participants,
            context: context
        )
    }
}
