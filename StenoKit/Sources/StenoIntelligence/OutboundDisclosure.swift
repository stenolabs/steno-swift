import StenoDomain

public enum PromptDataClass: String, CaseIterable, Codable, Sendable {
    case transcriptWithSpeakerNames
    case participants
    case userNotes

    public var displayName: String {
        switch self {
        case .transcriptWithSpeakerNames:
            "Transkript mit Sprechername"
        case .participants:
            "Teilnehmer"
        case .userNotes:
            "Eigene Notizen"
        }
    }
}

public struct OutboundDisclosure: Equatable, Sendable {
    public let classes: [PromptDataClass]

    public init(transcript: TranscriptRevision, context: RenderContext) {
        var classes: [PromptDataClass] = []
        if !transcript.turns.isEmpty {
            classes.append(.transcriptWithSpeakerNames)
        }
        if !context.participants.isEmpty {
            classes.append(.participants)
        }
        if context.userNotes != nil {
            classes.append(.userNotes)
        }
        self.classes = classes
    }
}
