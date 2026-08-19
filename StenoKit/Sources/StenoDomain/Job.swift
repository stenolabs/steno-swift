import Foundation

public struct Job: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: JobID
    public let kind: Kind
    public let meetingID: MeetingID
    public let sourceRunID: RunID?
    public let templateID: String?
    /// Pinnt bei templateRender die Revision, über der gerendert wird:
    /// das Ergebnis bleibt seiner Textgrundlage zuordenbar, auch wenn
    /// später neue Revisionen entstehen.
    public let revisionID: RevisionID?
    /// Pinnt bei templateRender den ausdrücklich gewählten Textmodell-Endpunkt.
    /// nil bezeichnet weiterhin Foundation Models.
    public let textModelEndpointID: String?
    /// Secret-free endpoint configuration shown when the job was queued.
    /// Legacy schema-one jobs decode this optional value as `nil`.
    public let textModelEndpointSnapshot: TextModelEndpointSnapshot?
    /// Bindet einen Template-Render an genau die Eingabe, deren Offenlegung
    /// der Nutzer gesehen hat. Jobs vor dieser Erweiterung bleiben nil.
    public let templateRenderInputFingerprint: String?
    /// Pinnt die ausdrücklich gewählte Transkriptionssprache für den Job.
    public let localeIdentifier: String?
    /// Pinnt importierte Jobs an genau eine lokale Transfergeneration.
    /// Normale und vor dieser Erweiterung persistierte Jobs bleiben nil.
    public let importGenerationID: MeetingTransferGenerationID?
    public var status: Status
    public var attemptCount: Int
    public let createdAt: Date
    public var errorMessage: String?
    /// Machine-readable reason for the narrow failures that have a deliberate
    /// recovery action. Older jobs decode this optional field as `nil`.
    public var failureReason: FailureReason?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: JobID = JobID(),
        kind: Kind,
        meetingID: MeetingID,
        sourceRunID: RunID? = nil,
        templateID: String? = nil,
        revisionID: RevisionID? = nil,
        textModelEndpointID: String? = nil,
        textModelEndpointSnapshot: TextModelEndpointSnapshot? = nil,
        templateRenderInputFingerprint: String? = nil,
        localeIdentifier: String? = nil,
        importGenerationID: MeetingTransferGenerationID? = nil,
        status: Status = .queued,
        attemptCount: Int = 0,
        createdAt: Date = Date(),
        errorMessage: String? = nil,
        failureReason: FailureReason? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.meetingID = meetingID
        self.sourceRunID = sourceRunID
        self.templateID = templateID
        self.revisionID = revisionID
        self.textModelEndpointID = textModelEndpointID
        self.textModelEndpointSnapshot = textModelEndpointSnapshot
        self.templateRenderInputFingerprint = templateRenderInputFingerprint
        self.localeIdentifier = localeIdentifier
        self.importGenerationID = importGenerationID
        self.status = status
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.errorMessage = errorMessage
        self.failureReason = failureReason
    }

    public enum Kind: String, Codable, Equatable, Sendable {
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

    public enum FailureReason: String, Codable, Equatable, Sendable {
        case diarizationModelsNotInstalled
        case templateRenderInputChanged
        case templateRenderPinsRequired
    }
}
