import Foundation
import Testing
@testable import StenoDomain

@Suite("Persisted domain documents")
struct DomainModelTests {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("all typed IDs preserve their UUID through Codable")
    func typedIDRoundTrips() throws {
        try expectRoundTrip(MeetingID())
        try expectRoundTrip(MediaAssetID())
        try expectRoundTrip(RunID())
        try expectRoundTrip(RevisionID())
        try expectRoundTrip(PersonID())
        try expectRoundTrip(JobID())
    }

    @Test("Meeting round-trips with its schema version")
    func meetingRoundTrip() throws {
        let meeting = Meeting(
            id: MeetingID(),
            title: "Planungsrunde",
            createdAt: timestamp,
            status: .recording,
            sourceLocale: try MeetingSourceLocale(
                localeIdentifier: "de-DE",
                origin: .explicit
            )
        )

        try expectRoundTrip(meeting)
        #expect(meeting.schemaVersion == 1)
        #expect(meeting.sourceLocale?.localeIdentifier == "de-DE")
        #expect(meeting.sourceLocale?.origin == .explicit)
    }

    @Test("schema-one meetings without a source locale remain decodable")
    func legacyMeetingDecoding() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "id": "018f22e2-7c00-7000-8000-000000000001",
              "title": "Alte Aufnahme",
              "createdAt": 0,
              "status": "ready"
            }
            """.utf8
        )

        let meeting = try JSONDecoder().decode(Meeting.self, from: data)

        #expect(meeting.sourceLocale == nil)
    }

    @Test("source locales reject absent origins and malformed identifiers")
    func invalidSourceLocalesFailClosed() {
        #expect(throws: MeetingSourceLocaleError.invalidOrigin) {
            try MeetingSourceLocale(localeIdentifier: "de-DE", origin: .absent)
        }
        #expect(throws: MeetingSourceLocaleError.invalidIdentifier) {
            try MeetingSourceLocale(localeIdentifier: " de-DE ", origin: .explicit)
        }

        let invalidJSON = Data(
            #"{"localeIdentifier":"de-DE","origin":"absent"}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MeetingSourceLocale.self, from: invalidJSON)
        }
    }

    @Test("MediaAsset round-trips with immutable media metadata")
    func mediaAssetRoundTrip() throws {
        let asset = MediaAsset(
            id: MediaAssetID(),
            meetingID: MeetingID(),
            kind: .imported,
            sampleRate: 48_000,
            duration: 12.5,
            provenanceKey: "0123456789abcdef",
            fileName: "audio.m4a"
        )

        try expectRoundTrip(asset)
        #expect(asset.schemaVersion == 1)
    }

    @Test("ProcessingRun round-trips engine, timing, status, and error details")
    func processingRunRoundTrip() throws {
        let run = ProcessingRun(
            id: RunID(),
            meetingID: MeetingID(),
            kind: .finalASR,
            engine: EngineDescriptor(
                name: "SpeechAnalyzer",
                version: "26.0",
                modelVersion: "de-DE-v1"
            ),
            status: .failed,
            createdAt: timestamp,
            startedAt: timestamp.addingTimeInterval(1),
            finishedAt: timestamp.addingTimeInterval(2),
            errorMessage: "Model unavailable"
        )

        try expectRoundTrip(run)
        #expect(run.schemaVersion == 1)
    }

    @Test("TranscriptRevision round-trips nested turns, segments, words, and origin")
    func transcriptRevisionRoundTrip() throws {
        let parentID = RevisionID()
        let revision = TranscriptRevision(
            id: RevisionID(),
            meetingID: MeetingID(),
            createdAt: timestamp,
            origin: .userEdit(parentID),
            turns: [
                TranscriptTurn(
                    speaker: .person(PersonID()),
                    start: 0,
                    end: 1.2,
                    segments: [
                        TranscriptSegment(
                            text: "Guten Morgen",
                            start: 0,
                            end: 1.2,
                            words: [
                                TranscriptWord(text: "Guten", start: 0, end: 0.5),
                                TranscriptWord(text: "Morgen", start: 0.6, end: 1.2),
                            ]
                        ),
                    ]
                ),
            ]
        )

        try expectRoundTrip(revision)
        #expect(revision.schemaVersion == 1)
    }

    @Test("Job round-trips queue state and attempt count")
    func jobRoundTrip() throws {
        let sourceRunID = RunID()
        let revisionID = RevisionID()
        let textModelEndpointID = "endpoint-local-gemma"
        let job = Job(
            id: JobID(),
            kind: .diarization,
            meetingID: MeetingID(),
            sourceRunID: sourceRunID,
            revisionID: revisionID,
            textModelEndpointID: textModelEndpointID,
            status: .running,
            attemptCount: 2,
            createdAt: timestamp,
            errorMessage: nil
        )

        try expectRoundTrip(job)
        #expect(job.schemaVersion == 1)
        #expect(job.sourceRunID == sourceRunID)
        #expect(job.revisionID == revisionID)
        #expect(job.textModelEndpointID == textModelEndpointID)
    }

    @Test("schema-one jobs without template provenance remain decodable")
    func legacyJobDecoding() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "id": "018f22e2-7c00-7000-8000-000000000001",
              "kind": "finalASR",
              "meetingID": "018f22e2-7c00-7000-8000-000000000002",
              "status": "queued",
              "attemptCount": 0,
              "createdAt": 0
            }
            """.utf8
        )

        let job = try JSONDecoder().decode(Job.self, from: data)

        #expect(job.sourceRunID == nil)
        #expect(job.templateID == nil)
        #expect(job.revisionID == nil)
        #expect(job.textModelEndpointID == nil)
        #expect(job.textModelEndpointSnapshot == nil)
    }

    @Test("Job persists a secret-free endpoint snapshot")
    func jobEndpointSnapshotRoundTrip() throws {
        let configurationRevision = UUID()
        let snapshot = TextModelEndpointSnapshot(
            id: UUID(),
            name: "Visible endpoint",
            baseURL: try #require(URL(string: "https://models.example.test/v1")),
            modelID: "model-v1",
            requiresAPIKey: true,
            configurationRevision: configurationRevision
        )
        let job = Job(
            kind: .templateRender,
            meetingID: MeetingID(),
            textModelEndpointID: snapshot.id.uuidString,
            textModelEndpointSnapshot: snapshot
        )

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedSnapshot = try #require(
            object["textModelEndpointSnapshot"] as? [String: Any]
        )

        #expect(decoded == job)
        #expect(encodedSnapshot["name"] as? String == "Visible endpoint")
        #expect(
            encodedSnapshot["configurationRevision"] as? String
                == configurationRevision.uuidString
        )
        #expect(object["apiKey"] == nil)
        #expect(object["secret"] == nil)
        #expect(encodedSnapshot["apiKey"] == nil)
        #expect(encodedSnapshot["secret"] == nil)
    }

    @Test("Legacy endpoint snapshots decode without a configuration revision")
    func legacyEndpointSnapshotDecoding() throws {
        let data = Data(
            """
            {
              "id": "018f22e2-7c00-7000-8000-000000000001",
              "name": "Legacy endpoint",
              "baseURL": "https://models.example.test/v1",
              "modelID": "legacy-model",
              "requiresAPIKey": true
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(TextModelEndpointSnapshot.self, from: data)

        #expect(snapshot.configurationRevision == nil)
    }

    @Test("SpeakerReference keeps the existing channel coding and supports cluster provenance")
    func speakerReferenceCoding() throws {
        let channel = SpeakerReference.channel("Ich")
        let runID = RunID()
        let cluster = SpeakerReference.cluster(runID: runID, clusterID: "mic/SPEAKER_0")

        try expectRoundTrip(channel)
        try expectRoundTrip(cluster)
    }

    private func expectRoundTrip<Value: Codable & Equatable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Value.self, from: data)
        #expect(decoded == value)
    }
}
