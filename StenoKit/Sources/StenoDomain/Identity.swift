import Foundation

public enum RecordingType: String, Codable, CaseIterable, Equatable, Sendable {
    case inPerson
    case remote
    case imported
    case unknown
}

public enum SpeakerEvidenceSource: String, Codable, Equatable, Sendable {
    case userConfirmed
    case userCorrected
    case manualEnrollment
}

public struct SpeakerPrototype: Codable, Equatable, Sendable {
    public let id: SpeakerEvidenceID
    /// Veraenderlich aus genau einem Grund: das Zusammenfuehren zweier
    /// Profile haengt die Evidenz an die ueberlebende Person um, ohne die
    /// Einbettung oder die Herkunft anzutasten.
    public var personID: PersonID
    public let embedding: [Float]
    public let sampleCount: Int?
    public let qualityScore: Float?
    public let recordingType: RecordingType
    public let channel: String?
    public let meetingID: MeetingID?
    public let runID: RunID?
    public let clusterID: String
    public let speechDurationSeconds: TimeInterval
    public let segmentCount: Int
    public let source: SpeakerEvidenceSource
    public let createdAt: Date
    /// Gesetzt, sobald ein Mensch diese Probe von der Erkennung ausgenommen
    /// hat. Sie bleibt gespeichert und bleibt echte Stimm-Evidenz - sie zaehlt
    /// nur nicht mehr. Loeschen waere der schlimmere Fehler, und die
    /// Entscheidung ist damit umkehrbar.
    public var excludedAt: Date?

    public init(
        id: SpeakerEvidenceID = SpeakerEvidenceID(),
        personID: PersonID,
        embedding: [Float],
        sampleCount: Int? = nil,
        qualityScore: Float? = nil,
        recordingType: RecordingType,
        channel: String?,
        meetingID: MeetingID?,
        runID: RunID?,
        clusterID: String,
        speechDurationSeconds: TimeInterval,
        segmentCount: Int,
        source: SpeakerEvidenceSource,
        createdAt: Date = Date(),
        excludedAt: Date? = nil
    ) {
        self.id = id
        self.personID = personID
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.qualityScore = qualityScore
        self.recordingType = recordingType
        self.channel = channel
        self.meetingID = meetingID
        self.runID = runID
        self.clusterID = clusterID
        self.speechDurationSeconds = speechDurationSeconds
        self.segmentCount = segmentCount
        self.source = source
        self.createdAt = createdAt
        self.excludedAt = excludedAt
    }
}

public struct HardNegative: Codable, Equatable, Sendable {
    public let id: SpeakerEvidenceID
    /// Veraenderlich aus genau einem Grund: das Zusammenfuehren zweier
    /// Profile haengt die Evidenz an die ueberlebende Person um, ohne die
    /// Einbettung oder die Herkunft anzutasten.
    public var personID: PersonID
    public let embedding: [Float]
    public let sampleCount: Int?
    public let qualityScore: Float?
    public let recordingType: RecordingType
    public let channel: String?
    public let meetingID: MeetingID?
    public let runID: RunID?
    public let clusterID: String
    public let speechDurationSeconds: TimeInterval
    public let segmentCount: Int
    public let source: SpeakerEvidenceSource
    public let createdAt: Date
    /// Wie beim Prototyp: ausgenommen statt geloescht. Hier ist das die
    /// wichtigere Richtung - ein falsch gesetztes Negativ unterdrueckt eine
    /// echte Erkennung dauerhaft, auch in Meetings, die damit nichts zu tun
    /// haben, und nichts im spaeteren Fehlverhalten zeigt auf die Ursache.
    public var excludedAt: Date?

    public init(
        id: SpeakerEvidenceID = SpeakerEvidenceID(),
        personID: PersonID,
        embedding: [Float],
        sampleCount: Int? = nil,
        qualityScore: Float? = nil,
        recordingType: RecordingType,
        channel: String?,
        meetingID: MeetingID?,
        runID: RunID?,
        clusterID: String,
        speechDurationSeconds: TimeInterval,
        segmentCount: Int,
        source: SpeakerEvidenceSource,
        createdAt: Date = Date(),
        excludedAt: Date? = nil
    ) {
        self.id = id
        self.personID = personID
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.qualityScore = qualityScore
        self.recordingType = recordingType
        self.channel = channel
        self.meetingID = meetingID
        self.runID = runID
        self.clusterID = clusterID
        self.speechDurationSeconds = speechDurationSeconds
        self.segmentCount = segmentCount
        self.source = source
        self.createdAt = createdAt
        self.excludedAt = excludedAt
    }
}

/// Das eine gemeinsame Praedikat, das entscheidet, ob eine Stimm-Evidenz
/// zaehlt. Lese- und Schreibpfad rufen dasselbe auf; zwei Kopien der Regel
/// driften auseinander, und die Abweichung faellt erst auf, wenn eine
/// Erkennung ohne sichtbaren Grund ausbleibt.
public protocol SpeakerEvidence {
    var excludedAt: Date? { get }
}

extension SpeakerEvidence {
    public var isActive: Bool { excludedAt == nil }
}

extension SpeakerPrototype: SpeakerEvidence {}
extension HardNegative: SpeakerEvidence {}

public struct Person: Codable, Equatable, Identifiable, Sendable {
    public let id: PersonID
    public var displayName: String
    /// Unterscheidungsmerkmal in einer wachsenden Stimmdatenbank: Zwei
    /// Menschen gleichen Namens sind dort der Normalfall, und beim Zuordnen
    /// eines Sprechers muss erkennbar sein, welcher gemeint ist. Ein
    /// Protokollversand an diese Adresse ist denkbar, aber nicht ihr Zweck.
    ///
    /// Sie ist reine Bibliotheksdatei und darf niemals in eine
    /// Prompt-Zusammenstellung oder in eine Teilnehmerliste geraten, die ein
    /// Modell zu sehen bekommt; Teilnehmer bleiben dort namensbasiert.
    public var email: String?
    /// Firma oder Organisation. Wie die Adresse ein Ordnungsmerkmal fuer die
    /// wachsende Stimmdatenbank - nicht mehr. Damit ein Firmenname der
    /// Erkennung hilft, muesste er in den Kontext des Transkriptionslaufs
    /// gelangen (docs/PLAN-CONTEXT.md, Schritt 3); das ist weder gebaut noch
    /// gemessen.
    public var organization: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var prototypes: [SpeakerPrototype]
    public var hardNegatives: [HardNegative]

    public init(
        id: PersonID = PersonID(),
        displayName: String,
        email: String? = nil,
        organization: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        prototypes: [SpeakerPrototype] = [],
        hardNegatives: [HardNegative] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.organization = organization
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.prototypes = prototypes
        self.hardNegatives = hardNegatives
    }
}

public struct SpeakerCandidate: Codable, Equatable, Sendable {
    public let personID: PersonID
    public let displayName: String
    public let distance: Float
    public let hardNegativeConflict: Bool
    public let confirmedMeetingCount: Int
    public let negativeDistance: Float?

    public init(
        personID: PersonID,
        displayName: String,
        distance: Float,
        hardNegativeConflict: Bool,
        confirmedMeetingCount: Int,
        negativeDistance: Float?
    ) {
        self.personID = personID
        self.displayName = displayName
        self.distance = distance
        self.hardNegativeConflict = hardNegativeConflict
        self.confirmedMeetingCount = confirmedMeetingCount
        self.negativeDistance = negativeDistance
    }
}

public struct ClusterSuggestion: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case confirmed
        case possible
        case none
    }

    public let meetingID: MeetingID
    public let runID: RunID
    public let channel: String
    public let clusterID: String
    public let status: Status
    public let suggestedPersonID: PersonID?
    public let suggestedName: String?
    public let candidates: [SpeakerCandidate]
    public let reasons: [String]

    public init(
        meetingID: MeetingID,
        runID: RunID,
        channel: String,
        clusterID: String,
        status: Status,
        suggestedPersonID: PersonID?,
        suggestedName: String?,
        candidates: [SpeakerCandidate] = [],
        reasons: [String] = []
    ) {
        self.meetingID = meetingID
        self.runID = runID
        self.channel = channel
        self.clusterID = clusterID
        self.status = status
        self.suggestedPersonID = suggestedPersonID
        self.suggestedName = suggestedName
        self.candidates = candidates
        self.reasons = reasons
    }
}
