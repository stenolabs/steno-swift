import Foundation

public struct EngineDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let modelVersion: String?

    public init(name: String, version: String, modelVersion: String? = nil) {
        self.name = name
        self.version = version
        self.modelVersion = modelVersion
    }
}

public struct ProcessingRun: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: RunID
    public let meetingID: MeetingID
    public let kind: Kind
    public let engine: EngineDescriptor
    /// Die für diesen Lauf verwendete, ausdrücklich gewählte Sprache.
    public let localeIdentifier: String?
    /// Ergebnis der automatischen Spracherkennung (Start- und erkannte
    /// Sprache) bei finalASR-Laeufen mit Automatic-Option. Laeufe ohne
    /// Erkennung decodieren dieses Feld als `nil`.
    public let languageDetection: TranscriptionLanguageDetectionPin?
    public var status: Status
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var errorMessage: String?
    public var textModelDiagnostic: TextModelRunDiagnostic?
    /// Provenenz des automatischen Final-ASR-Fallbacks: steht auf dem
    /// gescheiterten Ursprungslauf, wenn ein Fallback-Lauf seine Nachfolge
    /// angetreten hat. Aeltere Laeufe decodieren dieses Feld als `nil`.
    public var supersededBy: RunID?
    /// Gegenstueck zu `supersededBy`: steht auf dem Fallback-Lauf und zeigt
    /// auf den gescheiterten Ursprungslauf. Aeltere Laeufe decodieren `nil`.
    public var originalRunID: RunID?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: RunID = RunID(),
        meetingID: MeetingID,
        kind: Kind,
        engine: EngineDescriptor,
        localeIdentifier: String? = nil,
        languageDetection: TranscriptionLanguageDetectionPin? = nil,
        status: Status,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        errorMessage: String? = nil,
        textModelDiagnostic: TextModelRunDiagnostic? = nil,
        supersededBy: RunID? = nil,
        originalRunID: RunID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.engine = engine
        self.localeIdentifier = localeIdentifier
        self.languageDetection = languageDetection
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.textModelDiagnostic = textModelDiagnostic
        self.supersededBy = supersededBy
        self.originalRunID = originalRunID
    }

    public enum Kind: String, Codable, Equatable, Sendable {
        case liveASR
        case finalASR
        case diarization
        case identitySuggestion
        case templateRender
        case export
    }

    public enum Status: String, Codable, Equatable, Sendable {
        case queued
        case running
        case finished
        case failed
        case cancelled
    }
}
