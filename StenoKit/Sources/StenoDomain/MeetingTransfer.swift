import Foundation

public enum MeetingTransferCapability: String, Codable, CaseIterable, Sendable {
    case notes
    case transcript
    case audio
}

public enum MeetingTransferLocaleOrigin: String, Codable, Sendable {
    case explicit
    case estimated
    case absent
}

public enum MeetingSourceLocaleError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidOrigin
}

/// A locale fact attached to one meeting, independent of any transcript.
///
/// Absence is represented by a nil `Meeting.sourceLocale`. A stored fact must
/// therefore name a nonempty locale and state whether it was explicitly
/// chosen or only estimated. Keeping the origin beside the identifier prevents
/// a later export from silently upgrading an estimate into a user choice.
public struct MeetingSourceLocale: Codable, Equatable, Sendable {
    public let localeIdentifier: String
    public let origin: MeetingTransferLocaleOrigin

    private enum CodingKeys: String, CodingKey {
        case localeIdentifier
        case origin
    }

    public init(
        localeIdentifier: String,
        origin: MeetingTransferLocaleOrigin
    ) throws {
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
        guard !localeIdentifier.isEmpty,
              !localeIdentifier.unicodeScalars.contains(where: forbidden.contains)
        else {
            throw MeetingSourceLocaleError.invalidIdentifier
        }
        guard origin != .absent else {
            throw MeetingSourceLocaleError.invalidOrigin
        }
        self.localeIdentifier = localeIdentifier
        self.origin = origin
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try container.decode(String.self, forKey: .localeIdentifier)
        let origin = try container.decode(MeetingTransferLocaleOrigin.self, forKey: .origin)
        do {
            try self.init(localeIdentifier: identifier, origin: origin)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .localeIdentifier,
                in: container,
                debugDescription: "Invalid persisted meeting source locale."
            )
        }
    }
}

public struct MeetingTransferReceipt: Codable, Equatable, Sendable {
    public let sourceMeetingID: MeetingID
    public let sourceRevisionID: RevisionID?
    public let sourcePackageContentDigest: String
    public let importedAt: Date
    public let sourceAppVersion: String?
    public let includedCapabilities: Set<MeetingTransferCapability>
    public let sourceLocaleIdentifier: String?
    public let sourceLocaleOrigin: MeetingTransferLocaleOrigin
    /// Local identity of this concrete imported meeting generation. It is
    /// never part of the transfer package and remains optional only so
    /// libraries written before generation pinning still decode.
    public let importGenerationID: MeetingTransferGenerationID?

    public init(
        sourceMeetingID: MeetingID,
        sourceRevisionID: RevisionID?,
        sourcePackageContentDigest: String,
        importedAt: Date,
        sourceAppVersion: String?,
        includedCapabilities: Set<MeetingTransferCapability>,
        sourceLocaleIdentifier: String?,
        sourceLocaleOrigin: MeetingTransferLocaleOrigin,
        importGenerationID: MeetingTransferGenerationID? = nil
    ) {
        self.sourceMeetingID = sourceMeetingID
        self.sourceRevisionID = sourceRevisionID
        self.sourcePackageContentDigest = sourcePackageContentDigest
        self.importedAt = importedAt
        self.sourceAppVersion = sourceAppVersion
        self.includedCapabilities = includedCapabilities
        self.sourceLocaleIdentifier = sourceLocaleIdentifier
        self.sourceLocaleOrigin = sourceLocaleOrigin
        self.importGenerationID = importGenerationID
    }
}

public struct ImportedSpeakerTextLabel: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let text: String
    public let wasConfirmedAtSource: Bool

    public init(id: UUID, text: String, wasConfirmedAtSource: Bool) {
        self.id = id
        self.text = text
        self.wasConfirmedAtSource = wasConfirmedAtSource
    }
}

public struct ImportedProcessingRequest: Codable, Equatable, Sendable {
    public let id: MeetingTransferRequestID
    public let jobID: JobID
    public let meetingID: MeetingID
    public let localeIdentifier: String
    public let createdAt: Date
    public let importGenerationID: MeetingTransferGenerationID?

    public init(
        id: MeetingTransferRequestID,
        jobID: JobID,
        meetingID: MeetingID,
        localeIdentifier: String,
        createdAt: Date,
        importGenerationID: MeetingTransferGenerationID? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.meetingID = meetingID
        self.localeIdentifier = localeIdentifier
        self.createdAt = createdAt
        self.importGenerationID = importGenerationID
    }
}

public enum ImportedMeetingProcessingState: Codable, Equatable, Sendable {
    case importedOnly
    case awaitingLanguageConfirmation
    case awaitingModel(localeIdentifier: String)
    case processingRequested(ImportedProcessingRequest)
    case jobEnqueued(jobID: JobID, localeIdentifier: String)
    case needsManualRetry(jobID: JobID, localeIdentifier: String, reason: String)
}
