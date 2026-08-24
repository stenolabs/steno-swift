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
    public var status: Status
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var errorMessage: String?
    public var textModelDiagnostic: TextModelRunDiagnostic?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: RunID = RunID(),
        meetingID: MeetingID,
        kind: Kind,
        engine: EngineDescriptor,
        localeIdentifier: String? = nil,
        status: Status,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        errorMessage: String? = nil,
        textModelDiagnostic: TextModelRunDiagnostic? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.engine = engine
        self.localeIdentifier = localeIdentifier
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.textModelDiagnostic = textModelDiagnostic
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
