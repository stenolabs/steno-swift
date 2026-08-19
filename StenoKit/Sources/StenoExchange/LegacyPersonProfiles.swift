import Foundation
import StenoDomain

public struct LegacySpeakerPrototype: Equatable, Sendable {
    public let prototypeID: String
    public let personID: String
    public let embeddingMean: [Float]
    public let sampleCount: Int
    public let qualityScore: Float
    public let recordingType: RecordingType
    public let meetingID: String
    public let diarizationSpeakerID: String
    public let channel: String?
    public let speechDurationSeconds: TimeInterval
    public let segmentCount: Int
    public let createdFrom: SpeakerEvidenceSource
    public let createdAt: Date

    init(object: [String: Any]) throws {
        guard let createdAt = legacyDouble(object, "created_at") else {
            throw LegacyExchangeError.invalidFormat("Missing prototype created_at")
        }
        prototypeID = legacyString(object, "prototype_id") ?? ""
        personID = legacyString(object, "person_id") ?? ""
        embeddingMean = (object["embedding_mean"] as? [NSNumber] ?? []).map(\.floatValue)
        sampleCount = legacyInt(object, "sample_count") ?? 0
        qualityScore = (object["quality_score"] as? NSNumber)?.floatValue ?? 0
        recordingType = legacyRecordingType(legacyString(object, "recording_type"))
        meetingID = legacyString(object, "meeting_id") ?? ""
        diarizationSpeakerID = legacyString(object, "diarization_speaker_id") ?? ""
        channel = legacyString(object, "channel")
        speechDurationSeconds = legacyDouble(object, "speech_duration_seconds") ?? 0
        segmentCount = legacyInt(object, "segment_count") ?? 0
        createdFrom = legacyEvidenceSource(legacyString(object, "created_from"))
        self.createdAt = Date(timeIntervalSince1970: createdAt)
    }
}

public struct LegacyPersonProfile: Equatable, Sendable {
    public let personID: String
    public let displayName: String
    public let createdAt: Date
    public let updatedAt: Date
    public let prototypes: [LegacySpeakerPrototype]
    public let hardNegatives: [LegacySpeakerPrototype]

    init(object: [String: Any]) throws {
        guard let createdAt = legacyDouble(object, "created_at"),
              let updatedAt = legacyDouble(object, "updated_at") else {
            throw LegacyExchangeError.invalidFormat("Missing person profile timestamp")
        }
        personID = legacyString(object, "person_id") ?? ""
        displayName = legacyString(object, "display_name") ?? ""
        self.createdAt = Date(timeIntervalSince1970: createdAt)
        self.updatedAt = Date(timeIntervalSince1970: updatedAt)
        prototypes = try (object["prototypes"] as? [[String: Any]] ?? [])
            .map(LegacySpeakerPrototype.init(object:))
        hardNegatives = try (object["hard_negatives"] as? [[String: Any]] ?? [])
            .map(LegacySpeakerPrototype.init(object:))
    }
}

public struct LegacyPersonProfiles: Equatable, Sendable {
    public let profiles: [LegacyPersonProfile]
    public let customTemplates: [LegacyCustomTemplate]

    public static func read(from url: URL) throws -> Self {
        let object = try legacyJSONObject(from: url)
        let profiles = try (object["person_profiles"] as? [[String: Any]] ?? [])
            .map(LegacyPersonProfile.init(object:))
        let customTemplates = (object["custom_templates"] as? [[String: Any]] ?? []).map {
            LegacyCustomTemplate(
                id: legacyString($0, "id") ?? "",
                name: legacyString($0, "name") ?? ""
            )
        }
        return Self(profiles: profiles, customTemplates: customTemplates)
    }
}

public struct LegacyCustomTemplate: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

private func legacyEvidenceSource(_ value: String?) -> SpeakerEvidenceSource {
    switch value {
    case "user_corrected": .userCorrected
    case "manual_enrollment": .manualEnrollment
    default: .userConfirmed
    }
}
