import Foundation
import StenoDomain

public enum MeetingTransferContractError: Error, Equatable, Sendable {
    case emptyPayload
    case audioRequiresReadyMeeting
    case unsupportedFormatMajor(Int)
    case manifestMustNotBeAnEntry
    case missingMeetingDocument
    case duplicateManifestEntryPath(String)
    case invalidManifestEntryPath(String)
    case invalidManifestEntryMediaType(String)
    case invalidManifestEntryByteCount(String)
    case unpairedAudioTrack(String)
    case noncanonicalAudioTrack(String)
    case fileCountExceedsLimit
    case totalBytesExceedLimit
    case inconsistentCapabilities
    case manifestExceedsLimit
    case meetingDocumentExceedsLimit
    case meetingTitleExceedsLimit
    case notesExceedsLimit
    case transcriptExceedsLimit
    case audioMetadataExceedsLimit
    case invalidAudioByteCount
    case audioBytesExceedLimit
    case invalidSpeakerLabel
    case speakerLabelExceedsLimit
    case tooManySpeakers
    case tooManyTurns
    case tooManyWords
    case invalidSourceLocale
    case inconsistentSourceLocale
}

public struct MeetingTransferManifest: Codable, Equatable, Sendable {
    public static let currentMajor = 1
    public static let currentMinor = 0

    public let formatMajor: Int
    public let formatMinor: Int
    public let sourceMeetingID: MeetingID
    public let sourceRevisionID: RevisionID?
    public let exportedAt: Date
    public let sourceAppVersion: String?
    public let capabilities: Set<MeetingTransferCapability>
    public let localeIdentifier: String?
    public let localeOrigin: MeetingTransferLocaleOrigin
    public let entries: [Entry]
    public let contentDigest: String

    private enum CodingKeys: String, CodingKey {
        case formatMajor
        case formatMinor
        case sourceMeetingID
        case sourceRevisionID
        case exportedAt
        case sourceAppVersion
        case capabilities
        case localeIdentifier
        case localeOrigin
        case entries
        case contentDigest
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let byteCount: Int64
        public let mediaType: String
        public let sha256: String

        public init(path: String, byteCount: Int64, mediaType: String, sha256: String) {
            self.path = path
            self.byteCount = byteCount
            self.mediaType = mediaType
            self.sha256 = sha256
        }
    }

    public init(
        formatMajor: Int = Self.currentMajor,
        formatMinor: Int = Self.currentMinor,
        sourceMeetingID: MeetingID,
        sourceRevisionID: RevisionID?,
        exportedAt: Date,
        sourceAppVersion: String?,
        capabilities: Set<MeetingTransferCapability>,
        localeIdentifier: String?,
        localeOrigin: MeetingTransferLocaleOrigin,
        entries: [Entry],
        contentDigest: String
    ) throws {
        self.formatMajor = formatMajor
        self.formatMinor = formatMinor
        self.sourceMeetingID = sourceMeetingID
        self.sourceRevisionID = sourceRevisionID
        self.exportedAt = exportedAt
        self.sourceAppVersion = sourceAppVersion
        self.capabilities = capabilities
        self.localeIdentifier = localeIdentifier
        self.localeOrigin = localeOrigin
        self.entries = entries
        self.contentDigest = contentDigest
        try validate()
        _ = try encodedData()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            formatMajor: try container.decode(Int.self, forKey: .formatMajor),
            formatMinor: try container.decode(Int.self, forKey: .formatMinor),
            sourceMeetingID: try container.decode(MeetingID.self, forKey: .sourceMeetingID),
            sourceRevisionID: try container.decodeIfPresent(RevisionID.self, forKey: .sourceRevisionID),
            exportedAt: try container.decode(Date.self, forKey: .exportedAt),
            sourceAppVersion: try container.decodeIfPresent(String.self, forKey: .sourceAppVersion),
            capabilities: try container.decode(Set<MeetingTransferCapability>.self, forKey: .capabilities),
            localeIdentifier: try container.decodeIfPresent(String.self, forKey: .localeIdentifier),
            localeOrigin: try container.decode(MeetingTransferLocaleOrigin.self, forKey: .localeOrigin),
            entries: try container.decode([Entry].self, forKey: .entries),
            contentDigest: try container.decode(String.self, forKey: .contentDigest)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatMajor, forKey: .formatMajor)
        try container.encode(formatMinor, forKey: .formatMinor)
        try container.encode(sourceMeetingID, forKey: .sourceMeetingID)
        try container.encodeIfPresent(sourceRevisionID, forKey: .sourceRevisionID)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encodeIfPresent(sourceAppVersion, forKey: .sourceAppVersion)
        try container.encode(
            capabilities.sorted { $0.rawValue < $1.rawValue },
            forKey: .capabilities
        )
        try container.encodeIfPresent(localeIdentifier, forKey: .localeIdentifier)
        try container.encode(localeOrigin, forKey: .localeOrigin)
        try container.encode(entries, forKey: .entries)
        try container.encode(contentDigest, forKey: .contentDigest)
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= MeetingTransferLimits.maximumManifestBytes else {
            throw MeetingTransferContractError.manifestExceedsLimit
        }
        var entryBytes: Int64 = 0
        for entry in entries {
            let (sum, overflow) = entryBytes.addingReportingOverflow(entry.byteCount)
            guard entry.byteCount >= 0, !overflow else {
                throw MeetingTransferContractError.totalBytesExceedLimit
            }
            entryBytes = sum
        }
        guard entryBytes >= 0,
              entryBytes <= MeetingTransferLimits.maximumTotalBytes - Int64(data.count)
        else {
            throw MeetingTransferContractError.totalBytesExceedLimit
        }
        return data
    }

    public var sourceLocale: MeetingSourceLocale? {
        guard let localeIdentifier else { return nil }
        return try? MeetingSourceLocale(
            localeIdentifier: localeIdentifier,
            origin: localeOrigin
        )
    }

    private func validate() throws {
        guard formatMajor == Self.currentMajor else {
            throw MeetingTransferContractError.unsupportedFormatMajor(formatMajor)
        }
        guard !entries.contains(where: { $0.path == "manifest.json" }) else {
            throw MeetingTransferContractError.manifestMustNotBeAnEntry
        }
        guard entries.count + 1 <= MeetingTransferLimits.maximumFileCount else {
            throw MeetingTransferContractError.fileCountExceedsLimit
        }
        try Self.validateSourceLocale(
            localeIdentifier: localeIdentifier,
            localeOrigin: localeOrigin
        )

        var paths: Set<String> = []
        var audioTrackParts: [Int: Set<String>] = [:]
        var meetingDocumentCount = 0
        for entry in entries {
            guard entry.byteCount >= 0 else {
                throw MeetingTransferContractError.invalidManifestEntryByteCount(entry.path)
            }
            guard paths.insert(entry.path).inserted else {
                throw MeetingTransferContractError.duplicateManifestEntryPath(entry.path)
            }

            switch entry.path {
            case "meeting.json":
                meetingDocumentCount += 1
                try validate(entry, mediaType: "application/json", maximumBytes: Int64(MeetingTransferLimits.maximumMeetingDocumentBytes))
            case "notes.md":
                try validate(entry, mediaType: "text/markdown", maximumBytes: Int64(MeetingTransferLimits.maximumNotesBytes))
            case "transcript.json":
                try validate(entry, mediaType: "application/json", maximumBytes: Int64(MeetingTransferLimits.maximumTranscriptBytes))
            default:
                let (trackNumber, part) = try audioTrackPart(for: entry.path)
                let expectedMediaType = part == "caf" ? "audio/x-caf" : "application/json"
                let maximumBytes = part == "caf"
                    ? MeetingTransferLimits.maximumAudioBytes
                    : Int64(MeetingTransferLimits.maximumAudioMetadataBytes)
                try validate(entry, mediaType: expectedMediaType, maximumBytes: maximumBytes)
                audioTrackParts[trackNumber, default: []].insert(part)
            }
        }
        guard meetingDocumentCount == 1 else {
            throw MeetingTransferContractError.missingMeetingDocument
        }

        for (trackNumber, parts) in audioTrackParts {
            guard parts == ["caf", "json"] else {
                throw MeetingTransferContractError.unpairedAudioTrack("track-\(trackNumber)")
            }
        }
        for (offset, trackNumber) in audioTrackParts.keys.sorted().enumerated() {
            guard trackNumber == offset + 1 else {
                throw MeetingTransferContractError.noncanonicalAudioTrack("track-\(trackNumber)")
            }
        }

        let includesNotes = paths.contains("notes.md")
        let includesTranscript = paths.contains("transcript.json")
        let includesAudio = !audioTrackParts.isEmpty
        guard capabilities.contains(.notes) == includesNotes,
              capabilities.contains(.transcript) == includesTranscript,
              capabilities.contains(.audio) == includesAudio
        else {
            throw MeetingTransferContractError.inconsistentCapabilities
        }
    }

    static func validateSourceLocale(
        localeIdentifier: String?,
        localeOrigin: MeetingTransferLocaleOrigin
    ) throws {
        switch (localeIdentifier, localeOrigin) {
        case (nil, .absent):
            return
        case (.some(let identifier), .explicit), (.some(let identifier), .estimated):
            do {
                _ = try MeetingSourceLocale(
                    localeIdentifier: identifier,
                    origin: localeOrigin
                )
            } catch {
                throw MeetingTransferContractError.invalidSourceLocale
            }
        default:
            throw MeetingTransferContractError.invalidSourceLocale
        }
    }

    private func validate(_ entry: Entry, mediaType: String, maximumBytes: Int64) throws {
        guard entry.mediaType == mediaType else {
            throw MeetingTransferContractError.invalidManifestEntryMediaType(entry.path)
        }
        guard entry.byteCount <= maximumBytes else {
            throw MeetingTransferContractError.totalBytesExceedLimit
        }
    }

    private func audioTrackPart(for path: String) throws -> (Int, String) {
        guard path.hasPrefix("audio/track-") else {
            throw MeetingTransferContractError.invalidManifestEntryPath(path)
        }
        let filename = String(path.dropFirst("audio/".count))
        let components = filename.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].hasPrefix("track-")
        else {
            throw MeetingTransferContractError.invalidManifestEntryPath(path)
        }
        let trackString = components[0].dropFirst("track-".count)
        guard !trackString.isEmpty,
              trackString.first != "0",
              trackString.allSatisfy(\.isNumber),
              let trackNumber = Int(trackString),
              trackNumber > 0,
              components[1] == "caf" || components[1] == "json"
        else {
            throw MeetingTransferContractError.invalidManifestEntryPath(path)
        }
        return (trackNumber, String(components[1]))
    }
}
