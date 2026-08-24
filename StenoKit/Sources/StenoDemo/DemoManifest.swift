import Foundation
import StenoDomain

public struct DemoDatasetManifest: Codable, Equatable, Sendable {
    public static let requiredDatasetID = "synthetic-demo"
    public static let supportedSchemaVersion = 1
    private static let fixedMeetingCatalog: [String: FixedDemoMeeting] = [
        "projektauftakt": FixedDemoMeeting(
            id: MeetingID(rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000001")!),
            meeting: "2026-08-21T12:00:00Z",
            transcript: "2026-08-21T12:01:00Z"
        ),
        "wochenrunde": FixedDemoMeeting(
            id: MeetingID(rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000002")!),
            meeting: "2026-08-22T12:00:00Z",
            transcript: "2026-08-22T12:01:00Z"
        ),
        "produktinterview": FixedDemoMeeting(
            id: MeetingID(rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000003")!),
            meeting: "2026-08-23T12:00:00Z",
            transcript: "2026-08-23T12:01:00Z"
        ),
    ]

    public var schemaVersion: Int
    public var datasetID: String
    public var datasetVersion: String
    public var generator: DemoGeneratorProvenance
    public var meetings: [DemoMeetingManifest]
    public var resources: [DemoResourceDescriptor]

    public init(
        schemaVersion: Int,
        datasetID: String,
        datasetVersion: String,
        generator: DemoGeneratorProvenance,
        meetings: [DemoMeetingManifest],
        resources: [DemoResourceDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.datasetID = datasetID
        self.datasetVersion = datasetVersion
        self.generator = generator
        self.meetings = meetings
        self.resources = resources
    }

    public func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw DemoLibraryError.unsupportedSchemaVersion(schemaVersion)
        }
        guard datasetID == Self.requiredDatasetID else {
            throw DemoLibraryError.unexpectedDatasetID(datasetID)
        }
        guard !datasetVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DemoLibraryError.emptyDatasetVersion
        }
        guard meetings.count == 3 else {
            throw DemoLibraryError.invalidMeetingCount(meetings.count)
        }
        try generator.validate()
        try requireUnique(meetings.map(\.id.description), kind: "meeting")
        try requireUnique(meetings.map(\.itemID), kind: "item")
        try requireUnique(meetings.map { $0.transcript.id.description }, kind: "revision")
        try requireUnique(meetings.map { $0.audio.mediaAssetID.description }, kind: "media")
        try requireUnique(meetings.flatMap { $0.runs.map(\.id.description) }, kind: "run")
        try requireUnique(resources.map(\.id), kind: "resource")
        try requireUnique(resources.map(\.relativePath), kind: "resource-path")

        let resourcesByID = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        for resource in resources {
            try resource.validate()
        }
        for meeting in meetings {
            try validateUTCDate(meeting.createdAtUTC)
            try validateUTCDate(meeting.transcript.createdAtUTC)
            try validateFixedMeeting(for: meeting)
            guard meeting.title.hasPrefix("DEMO:") else {
                throw DemoLibraryError.invalidDemoTitle(meeting.title)
            }
            guard meeting.audio.sampleRate > 0 else {
                throw DemoLibraryError.invalidSampleRate(meeting.audio.mediaAssetID)
            }
            guard meeting.audio.duration > 0 else {
                throw DemoLibraryError.invalidDuration(meeting.audio.mediaAssetID)
            }
            try requireResource(
                meeting.transcript.resourceID,
                kind: .transcript,
                resources: resourcesByID
            )
            try requireResource(
                meeting.audio.resourceID,
                kind: .audio,
                resources: resourcesByID
            )
            for run in meeting.runs {
                for resourceID in run.resourceIDs {
                    guard resourcesByID[resourceID] != nil else {
                        throw DemoLibraryError.unknownResourceID(resourceID)
                    }
                }
            }
        }
        try validateResourceGraph(resources: resourcesByID)
    }

    private func validateResourceGraph(
        resources: [String: DemoResourceDescriptor]
    ) throws {
        var referencedResourceIDs = Set<String>()
        for meeting in meetings {
            referencedResourceIDs.insert(meeting.transcript.resourceID)
            referencedResourceIDs.insert(meeting.audio.resourceID)
            guard meeting.runs.count == 1 else {
                throw DemoLibraryError.invalidMeetingBlueprint(
                    itemID: meeting.itemID,
                    reason: "expected exactly one stable report run"
                )
            }
            let resourceIDs = meeting.runs[0].resourceIDs
            var uniqueResourceIDs = Set<String>()
            for resourceID in resourceIDs where !uniqueResourceIDs.insert(resourceID).inserted {
                throw DemoLibraryError.invalidMeetingBlueprint(
                    itemID: meeting.itemID,
                    reason: "duplicate run resource ID \(resourceID)"
                )
            }
            referencedResourceIDs.formUnion(resourceIDs)

            let kinds = resourceIDs.compactMap { resources[$0]?.kind }
            let expectedOptionalKinds: [DemoResourceKind: Int] = [
                .note: meeting.itemID == "produktinterview" ? 0 : 1,
                .report: meeting.itemID == "wochenrunde" ? 0 : 1,
            ]
            for (kind, count) in expectedOptionalKinds where kinds.filter({ $0 == kind }).count != count {
                throw DemoLibraryError.invalidMeetingBlueprint(
                    itemID: meeting.itemID,
                    reason: "expected exactly \(count) \(kind.rawValue) resource"
                )
            }
            for kind in [
                DemoResourceKind.referenceTranscript,
                .referenceTimeline,
                .attribution,
            ] where kinds.filter({ $0 == kind }).count != 1 {
                throw DemoLibraryError.invalidMeetingBlueprint(
                    itemID: meeting.itemID,
                    reason: "expected exactly one \(kind.rawValue) resource"
                )
            }
            let allowedKinds: Set<DemoResourceKind> = [
                .note, .report, .referenceTranscript, .referenceTimeline, .attribution,
            ]
            guard kinds.allSatisfy(allowedKinds.contains) else {
                throw DemoLibraryError.invalidMeetingBlueprint(
                    itemID: meeting.itemID,
                    reason: "run references a non-blueprint resource"
                )
            }
        }
        if let unreferenced = resources.keys.sorted().first(where: {
            !referencedResourceIDs.contains($0)
        }) {
            throw DemoLibraryError.unreferencedResource(id: unreferenced)
        }
    }

    private func requireUnique(_ values: [String], kind: String) throws {
        var known = Set<String>()
        for value in values where !known.insert(value).inserted {
            throw DemoLibraryError.duplicateIdentifier(kind: kind, value: value)
        }
    }

    private func validateUTCDate(_ value: String) throws {
        guard value.hasSuffix("Z"), ISO8601DateFormatter().date(from: value) != nil else {
            throw DemoLibraryError.invalidUTCDate(value)
        }
    }

    private func validateFixedMeeting(for meeting: DemoMeetingManifest) throws {
        guard let expected = Self.fixedMeetingCatalog[meeting.itemID] else {
            throw DemoLibraryError.unknownDemoItemID(meeting.itemID)
        }
        guard meeting.id == expected.id else {
            throw DemoLibraryError.unexpectedFixedMeetingID(
                itemID: meeting.itemID,
                actual: meeting.id
            )
        }
        guard meeting.createdAtUTC == expected.meeting else {
            throw DemoLibraryError.unexpectedFixedUTCDate(
                itemID: meeting.itemID,
                field: "meeting",
                actual: meeting.createdAtUTC
            )
        }
        guard meeting.transcript.createdAtUTC == expected.transcript else {
            throw DemoLibraryError.unexpectedFixedUTCDate(
                itemID: meeting.itemID,
                field: "transcript",
                actual: meeting.transcript.createdAtUTC
            )
        }
    }

    private func requireResource(
        _ id: String,
        kind: DemoResourceKind,
        resources: [String: DemoResourceDescriptor]
    ) throws {
        guard let resource = resources[id] else {
            throw DemoLibraryError.unknownResourceID(id)
        }
        guard resource.kind == kind else {
            throw DemoLibraryError.unexpectedResourceKind(
                id: id,
                expected: kind,
                actual: resource.kind
            )
        }
    }
}

private struct FixedDemoMeeting: Sendable {
    let id: MeetingID
    let meeting: String
    let transcript: String
}

public struct DemoGeneratorProvenance: Codable, Equatable, Sendable {
    public var generator: String
    public var generatorRevision: String
    public var model: String
    public var modelRevision: String
    public var speakerIDs: [String]
    public var inputScriptSHA256: String
    public var mixParameters: [String: Double]
    public var license: String
    public var modificationProvenance: String

    public init(
        generator: String,
        generatorRevision: String,
        model: String,
        modelRevision: String,
        speakerIDs: [String],
        inputScriptSHA256: String,
        mixParameters: [String: Double],
        license: String,
        modificationProvenance: String
    ) {
        self.generator = generator
        self.generatorRevision = generatorRevision
        self.model = model
        self.modelRevision = modelRevision
        self.speakerIDs = speakerIDs
        self.inputScriptSHA256 = inputScriptSHA256
        self.mixParameters = mixParameters
        self.license = license
        self.modificationProvenance = modificationProvenance
    }

    fileprivate func validate() throws {
        guard !generator.isEmpty,
              !generatorRevision.isEmpty,
              !model.isEmpty,
              !modelRevision.isEmpty,
              !speakerIDs.isEmpty,
              speakerIDs.allSatisfy({ !$0.isEmpty }),
              !mixParameters.isEmpty,
              !license.isEmpty,
              !modificationProvenance.isEmpty else {
            throw DemoLibraryError.invalidGeneratorProvenance
        }
        guard Self.isSHA256(inputScriptSHA256) else {
            throw DemoLibraryError.invalidSHA256(id: "input-script")
        }
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }
}

public struct DemoMeetingManifest: Codable, Equatable, Sendable {
    public var id: MeetingID
    public var itemID: String
    public var title: String
    public var createdAtUTC: String
    public var transcript: DemoTranscriptManifest
    public var audio: DemoAudioManifest
    public var runs: [DemoRunManifest]

    public init(
        id: MeetingID,
        itemID: String,
        title: String,
        createdAtUTC: String,
        transcript: DemoTranscriptManifest,
        audio: DemoAudioManifest,
        runs: [DemoRunManifest]
    ) {
        self.id = id
        self.itemID = itemID
        self.title = title
        self.createdAtUTC = createdAtUTC
        self.transcript = transcript
        self.audio = audio
        self.runs = runs
    }
}

public struct DemoTranscriptManifest: Codable, Equatable, Sendable {
    public var id: RevisionID
    public var resourceID: String
    public var createdAtUTC: String

    public init(id: RevisionID, resourceID: String, createdAtUTC: String) {
        self.id = id
        self.resourceID = resourceID
        self.createdAtUTC = createdAtUTC
    }
}

public struct DemoAudioManifest: Codable, Equatable, Sendable {
    public var mediaAssetID: MediaAssetID
    public var resourceID: String
    public var sampleRate: Double
    public var duration: TimeInterval

    public init(
        mediaAssetID: MediaAssetID,
        resourceID: String,
        sampleRate: Double,
        duration: TimeInterval
    ) {
        self.mediaAssetID = mediaAssetID
        self.resourceID = resourceID
        self.sampleRate = sampleRate
        self.duration = duration
    }
}

public struct DemoRunManifest: Codable, Equatable, Sendable {
    public var id: RunID
    public var resourceIDs: [String]

    public init(id: RunID, resourceIDs: [String]) {
        self.id = id
        self.resourceIDs = resourceIDs
    }
}

public enum DemoResourceKind: String, Codable, Equatable, Hashable, Sendable {
    case audio
    case transcript
    case note
    case report
    case referenceTranscript
    case referenceTimeline
    case attribution
}

public struct DemoResourceDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var kind: DemoResourceKind
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String

    public init(
        id: String,
        kind: DemoResourceKind,
        relativePath: String,
        byteCount: Int64,
        sha256: String
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    fileprivate func validate() throws {
        guard !id.isEmpty, byteCount >= 0 else {
            throw DemoLibraryError.invalidResourceDescriptor(id)
        }
        guard DemoGeneratorProvenance.isSHA256(sha256) else {
            throw DemoLibraryError.invalidSHA256(id: id)
        }
    }
}
