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
    /// Immutable path-free provenance for an explicitly selected native Gemma
    /// model. Native jobs persist `NativeGemmaModelSnapshot.reservedTextModelEndpointID`
    /// in `textModelEndpointID` so older readers do not mistake them for Apple.
    public let nativeGemmaModelSnapshot: NativeGemmaModelSnapshot?
    /// Bindet einen Template-Render an genau die Eingabe, deren Offenlegung
    /// der Nutzer gesehen hat. Jobs vor dieser Erweiterung bleiben nil.
    public let templateRenderInputFingerprint: String?
    /// Pinnt die ausdrücklich gewählte Transkriptionssprache für den Job.
    public let localeIdentifier: String?
    /// Pinnt importierte Jobs an genau eine lokale Transfergeneration.
    /// Normale und vor dieser Erweiterung persistierte Jobs bleiben nil.
    public let importGenerationID: MeetingTransferGenerationID?
    /// Allgemeiner Name für dieselbe persistierte Generation. Codable nutzt
    /// weiterhin ausschließlich `importGenerationID`, damit keine Migration
    /// bestehender Job-Dokumente nötig ist.
    public var processingGenerationID: MeetingTransferGenerationID? {
        importGenerationID
    }
    /// Pinnt bei finalASR den ausdrücklich gewählten ASR-Provider. Nil
    /// bezeichnet ein ungepinntes (insbesondere ein altes) Meeting; die
    /// Ausführungsgrenze liest das als Apple, ein gepinnter, aber nicht
    /// registrierter Provider führt zum Job-Fehlschlag statt stillem
    /// Zurückfallen auf Apple.
    public let transcriptionProviderID: TranscriptionProviderID?
    public var status: Status
    public var attemptCount: Int
    public let createdAt: Date
    public var errorMessage: String?
    /// Machine-readable reason for the narrow failures that have a deliberate
    /// recovery action. Older jobs decode this optional field as `nil`.
    public var failureReason: FailureReason?
    /// Pinnt bei finalASR das Ergebnis der automatischen Spracherkennung:
    /// Start-Sprache der Live-Lane plus entschiedene Erkennung. Aeltere Jobs
    /// und ausdrueckliche Sprachwahlen decodieren dieses Feld als `nil`.
    public let languageDetection: TranscriptionLanguageDetectionPin?

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
        nativeGemmaModelSnapshot: NativeGemmaModelSnapshot? = nil,
        templateRenderInputFingerprint: String? = nil,
        localeIdentifier: String? = nil,
        importGenerationID: MeetingTransferGenerationID? = nil,
        transcriptionProviderID: TranscriptionProviderID? = nil,
        status: Status = .queued,
        attemptCount: Int = 0,
        createdAt: Date = Date(),
        errorMessage: String? = nil,
        failureReason: FailureReason? = nil,
        languageDetection: TranscriptionLanguageDetectionPin? = nil
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
        self.nativeGemmaModelSnapshot = nativeGemmaModelSnapshot
        self.templateRenderInputFingerprint = templateRenderInputFingerprint
        self.localeIdentifier = localeIdentifier
        self.importGenerationID = importGenerationID
        self.transcriptionProviderID = transcriptionProviderID
        self.status = status
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.errorMessage = errorMessage
        self.failureReason = failureReason
        self.languageDetection = languageDetection
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
        case textModelEndpointConfigurationIncomplete
    }
}

public extension Job {
    /// Reiht einen Final-ASR-Job für dieses Meeting ein und übernimmt dabei
    /// dessen gepinnte Wahl: den Provider aus `transcriptionPlan`, und die
    /// Sprache aus `sourceLocale`, aber nur, wenn diese ausdrücklich gewählt
    /// wurde (`origin == .explicit`). Eine nur geschätzte Sprache bleibt
    /// ungepinnt und fällt auf den Koordinator-Fallback zurück.
    static func finalASR(for meeting: Meeting) -> Job {
        let localeIdentifier: String? = if meeting.sourceLocale?.origin == .explicit {
            meeting.sourceLocale?.localeIdentifier
        } else {
            nil
        }
        return Job(
            kind: .finalASR,
            meetingID: meeting.id,
            localeIdentifier: localeIdentifier,
            importGenerationID: meeting.processingGenerationID,
            transcriptionProviderID: meeting.transcriptionPlan?.finalProviderID
        )
    }

    /// Für bewusste Wiederholungsläufe mit ausdrücklich angegebenem Provider
    /// und ausdrücklich angegebener Sprache, unabhängig vom gepinnten Plan
    /// des Meetings. Ein übergebener Erkennungs-Pin dokumentiert, dass die
    /// Sprache automatisch geschätzt (niemals ausdrücklich gewählt) wurde,
    /// und bewahrt Start- und erkannte Sprache für den Lauf.
    static func finalASR(
        meetingID: MeetingID,
        providerID: TranscriptionProviderID,
        localeIdentifier: String,
        processingGenerationID: MeetingTransferGenerationID? = nil,
        languageDetection: TranscriptionLanguageDetectionPin? = nil
    ) -> Job {
        Job(
            kind: .finalASR,
            meetingID: meetingID,
            localeIdentifier: localeIdentifier,
            importGenerationID: processingGenerationID,
            transcriptionProviderID: providerID,
            languageDetection: languageDetection
        )
    }
}
