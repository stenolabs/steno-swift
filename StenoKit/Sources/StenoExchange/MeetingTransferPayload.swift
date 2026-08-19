import Foundation
import StenoDomain

public struct MeetingTransferMeetingDocument: Codable, Equatable, Sendable {
    public let sourceMeetingID: MeetingID
    public let title: String
    public let createdAt: Date
    public let sourceStatus: Meeting.Status

    public init(
        sourceMeetingID: MeetingID,
        title: String,
        createdAt: Date,
        sourceStatus: Meeting.Status
    ) throws {
        guard title.lengthOfBytes(using: .utf8) <= MeetingTransferLimits.maximumLabelBytes else {
            throw MeetingTransferContractError.meetingTitleExceedsLimit
        }
        self.sourceMeetingID = sourceMeetingID
        self.title = title
        self.createdAt = createdAt
        self.sourceStatus = sourceStatus
        _ = try encodedData()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceMeetingID: try container.decode(MeetingID.self, forKey: .sourceMeetingID),
            title: try container.decode(String.self, forKey: .title),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            sourceStatus: try container.decode(Meeting.Status.self, forKey: .sourceStatus)
        )
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try Self.validateEncodedByteCount(data.count)
        return data
    }

    static func validateEncodedByteCount(_ byteCount: Int) throws {
        guard byteCount >= 0, byteCount <= MeetingTransferLimits.maximumMeetingDocumentBytes else {
            throw MeetingTransferContractError.meetingDocumentExceedsLimit
        }
    }
}

public struct MeetingTransferTranscriptSnapshot: Codable, Equatable, Sendable {
    public let localeIdentifier: String?
    public let localeOrigin: MeetingTransferLocaleOrigin
    public let speakers: [Speaker]
    public let turns: [Turn]

    public init(
        localeIdentifier: String?,
        localeOrigin: MeetingTransferLocaleOrigin,
        speakers: [Speaker],
        turns: [Turn]
    ) throws {
        try MeetingTransferManifest.validateSourceLocale(
            localeIdentifier: localeIdentifier,
            localeOrigin: localeOrigin
        )
        guard speakers.count <= MeetingTransferLimits.maximumSpeakers else {
            throw MeetingTransferContractError.tooManySpeakers
        }
        guard turns.count <= MeetingTransferLimits.maximumTurns else {
            throw MeetingTransferContractError.tooManyTurns
        }
        var wordCount = 0
        for turn in turns {
            for segment in turn.segments {
                let (sum, overflow) = wordCount.addingReportingOverflow(segment.words.count)
                guard !overflow else {
                    throw MeetingTransferContractError.tooManyWords
                }
                wordCount = sum
            }
        }
        guard wordCount <= MeetingTransferLimits.maximumWords else {
            throw MeetingTransferContractError.tooManyWords
        }
        self.localeIdentifier = localeIdentifier
        self.localeOrigin = localeOrigin
        self.speakers = speakers
        self.turns = turns
        _ = try encodedData()
    }

    public var sourceLocale: MeetingSourceLocale? {
        guard let localeIdentifier else { return nil }
        return try? MeetingSourceLocale(
            localeIdentifier: localeIdentifier,
            origin: localeOrigin
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            localeIdentifier: try container.decodeIfPresent(String.self, forKey: .localeIdentifier),
            localeOrigin: try container.decode(MeetingTransferLocaleOrigin.self, forKey: .localeOrigin),
            speakers: try container.decode([Speaker].self, forKey: .speakers),
            turns: try container.decode([Turn].self, forKey: .turns)
        )
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try Self.validateEncodedByteCount(data.count)
        return data
    }

    static func validateEncodedByteCount(_ byteCount: Int) throws {
        guard byteCount >= 0, byteCount <= MeetingTransferLimits.maximumTranscriptBytes else {
            throw MeetingTransferContractError.transcriptExceedsLimit
        }
    }

    public struct Speaker: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Equatable, Sendable {
            case generic
            case confirmedDisplayName
        }

        public let id: String
        public let label: String
        public let kind: Kind

        public init(id: String, label: String, kind: Kind) throws {
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingTransferContractError.invalidSpeakerLabel
            }
            guard label.lengthOfBytes(using: .utf8) <= MeetingTransferLimits.maximumLabelBytes else {
                throw MeetingTransferContractError.speakerLabelExceedsLimit
            }
            self.id = id
            self.label = label
            self.kind = kind
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                id: try container.decode(String.self, forKey: .id),
                label: try container.decode(String.self, forKey: .label),
                kind: try container.decode(Kind.self, forKey: .kind)
            )
        }
    }

    public struct Turn: Codable, Equatable, Sendable {
        public let speakerID: String?
        public let start: TimeInterval
        public let end: TimeInterval
        public let segments: [Segment]

        public init(speakerID: String?, start: TimeInterval, end: TimeInterval, segments: [Segment]) {
            self.speakerID = speakerID
            self.start = start
            self.end = end
            self.segments = segments
        }
    }

    public struct Segment: Codable, Equatable, Sendable {
        public let text: String
        public let start: TimeInterval
        public let end: TimeInterval
        public let words: [Word]

        public init(text: String, start: TimeInterval, end: TimeInterval, words: [Word]) {
            self.text = text
            self.start = start
            self.end = end
            self.words = words
        }
    }

    public struct Word: Codable, Equatable, Sendable {
        public let text: String
        public let start: TimeInterval
        public let end: TimeInterval

        public init(text: String, start: TimeInterval, end: TimeInterval) {
            self.text = text
            self.start = start
            self.end = end
        }
    }
}

public struct MeetingTransferAudioDocument: Codable, Equatable, Sendable {
    public let logicalTrackID: String
    public let kind: MediaAsset.Kind
    public let byteCount: Int64
    public let sha256: String
    public let sampleRate: Double
    public let channelCount: Int
    public let duration: TimeInterval

    public init(
        logicalTrackID: String,
        kind: MediaAsset.Kind,
        byteCount: Int64,
        sha256: String,
        sampleRate: Double,
        channelCount: Int,
        duration: TimeInterval
    ) throws {
        guard byteCount > 0 else {
            throw MeetingTransferContractError.invalidAudioByteCount
        }
        guard byteCount <= MeetingTransferLimits.maximumAudioBytes else {
            throw MeetingTransferContractError.audioBytesExceedLimit
        }
        self.logicalTrackID = logicalTrackID
        self.kind = kind
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        _ = try encodedData()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            logicalTrackID: try container.decode(String.self, forKey: .logicalTrackID),
            kind: try container.decode(MediaAsset.Kind.self, forKey: .kind),
            byteCount: try container.decode(Int64.self, forKey: .byteCount),
            sha256: try container.decode(String.self, forKey: .sha256),
            sampleRate: try container.decode(Double.self, forKey: .sampleRate),
            channelCount: try container.decode(Int.self, forKey: .channelCount),
            duration: try container.decode(TimeInterval.self, forKey: .duration)
        )
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try Self.validateEncodedByteCount(data.count)
        return data
    }

    static func validateEncodedByteCount(_ byteCount: Int) throws {
        guard byteCount >= 0, byteCount <= MeetingTransferLimits.maximumAudioMetadataBytes else {
            throw MeetingTransferContractError.audioMetadataExceedsLimit
        }
    }
}

public struct MeetingTransferPackageContent: Codable, Equatable, Sendable {
    public let meeting: MeetingTransferMeetingDocument
    public let notes: String?
    public let transcript: MeetingTransferTranscriptSnapshot?
    public let audio: [MeetingTransferAudioDocument]
    public let sourceLocale: MeetingSourceLocale?

    public init(
        meeting: MeetingTransferMeetingDocument,
        notes: String?,
        transcript: MeetingTransferTranscriptSnapshot?,
        audio: [MeetingTransferAudioDocument],
        sourceLocale: MeetingSourceLocale? = nil
    ) throws {
        if let notes {
            guard notes.lengthOfBytes(using: .utf8) <= MeetingTransferLimits.maximumNotesBytes else {
                throw MeetingTransferContractError.notesExceedsLimit
            }
        }
        _ = try meeting.encodedData()
        if let transcript {
            _ = try transcript.encodedData()
        }
        var audioByteCount: Int64 = 0
        for document in audio {
            _ = try document.encodedData()
            let (sum, overflow) = audioByteCount.addingReportingOverflow(document.byteCount)
            guard !overflow, sum <= MeetingTransferLimits.maximumTotalBytes else {
                throw MeetingTransferContractError.audioBytesExceedLimit
            }
            audioByteCount = sum
        }
        guard notes != nil || transcript != nil || !audio.isEmpty else {
            throw MeetingTransferContractError.emptyPayload
        }
        guard audio.isEmpty || meeting.sourceStatus == .ready else {
            throw MeetingTransferContractError.audioRequiresReadyMeeting
        }
        let transcriptSourceLocale = transcript?.sourceLocale
        if transcript != nil,
           let sourceLocale,
           sourceLocale != transcriptSourceLocale {
            throw MeetingTransferContractError.inconsistentSourceLocale
        }
        self.meeting = meeting
        self.notes = notes
        self.transcript = transcript
        self.audio = audio
        self.sourceLocale = sourceLocale ?? transcriptSourceLocale
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            meeting: try container.decode(MeetingTransferMeetingDocument.self, forKey: .meeting),
            notes: try container.decodeIfPresent(String.self, forKey: .notes),
            transcript: try container.decodeIfPresent(MeetingTransferTranscriptSnapshot.self, forKey: .transcript),
            audio: try container.decode([MeetingTransferAudioDocument].self, forKey: .audio),
            sourceLocale: try container.decodeIfPresent(
                MeetingSourceLocale.self,
                forKey: .sourceLocale
            )
        )
    }

    public var capabilities: Set<MeetingTransferCapability> {
        var result: Set<MeetingTransferCapability> = []
        if notes != nil { result.insert(.notes) }
        if transcript != nil { result.insert(.transcript) }
        if !audio.isEmpty { result.insert(.audio) }
        return result
    }
}

public struct MeetingTransferProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case enumerating
        case hashing
        case readingArchive
        case validatingAudio
        case writing
    }

    public let phase: Phase
    public let processedBytes: Int64
    public let totalBytes: Int64

    public init(phase: Phase, processedBytes: Int64, totalBytes: Int64) {
        self.phase = phase
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
    }
}
