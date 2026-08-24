import Foundation
import StenoDomain
import Testing
@testable import StenoLibrary

@Suite("Transcription migration fixtures")
struct TranscriptionMigrationFixtureTests {
    @Test("Opening a legacy unpinned meeting document does not rewrite it")
    func legacyDocumentRemainsByteIdentical() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meetingID = MeetingID(
                rawValue: UUID(
                    uuidString: "018f22e2-7c00-7000-8000-000000000001"
                )!
            )
            let meetingData = Data(
                """
                {
                  "schemaVersion": 1,
                  "id": "\(meetingID)",
                  "title": "Legacy",
                  "createdAt": 0,
                  "status": "ready"
                }
                """.utf8
            )
            try FileManager.default.createDirectory(
                at: library.layout.meetingDirectory(meetingID),
                withIntermediateDirectories: true
            )
            let meetingURL = library.layout.meetingMetadata(meetingID)
            try meetingData.write(to: meetingURL)

            let meeting = try await library.loadMeeting(meetingID)

            #expect(meeting.transcriptionPlan == nil)
            #expect(try Data(contentsOf: meetingURL) == meetingData)
        }
    }

    @Test("A pinned transcription plan survives a reload")
    func pinnedPlanSurvivesReload() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let plan = TranscriptionPlan(
                liveProviderID: .apple,
                finalProviderID: .parakeetTDTv3
            )
            let meeting = try await library.createMeeting(
                title: "Pinned",
                status: .processing,
                transcriptionPlan: plan
            )

            let reloaded = try await library.loadMeeting(meeting.id)

            #expect(reloaded.transcriptionPlan == plan)
        }
    }

    @Test("Opening a legacy job document without a pinned provider does not rewrite it")
    func legacyJobDocumentRemainsByteIdentical() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try JobStore(layout: library.layout)
            let meeting = try await library.createMeeting(
                title: "Legacy",
                status: .processing
            )
            let jobID = JobID(
                rawValue: UUID(
                    uuidString: "018f22e2-7c00-7000-8000-000000000002"
                )!
            )
            let jobData = Data(
                """
                {
                  "schemaVersion": 1,
                  "id": "\(jobID)",
                  "kind": "finalASR",
                  "meetingID": "\(meeting.id)",
                  "status": "queued",
                  "attemptCount": 0,
                  "createdAt": 0
                }
                """.utf8
            )
            let jobURL = library.layout.job(jobID)
            try jobData.write(to: jobURL)

            let job = try await store.load(jobID)

            #expect(job.transcriptionProviderID == nil)
            #expect(try Data(contentsOf: jobURL) == jobData)
        }
    }

    @Test("A pinned final ASR job's provider survives a reload")
    func pinnedProviderSurvivesReload() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try JobStore(layout: library.layout)
            let plan = TranscriptionPlan(
                liveProviderID: .apple,
                finalProviderID: .parakeetTDTv3
            )
            let meeting = try await library.createMeeting(
                title: "Pinned",
                status: .processing,
                transcriptionPlan: plan
            )
            let job = Job.finalASR(for: meeting)
            try await store.enqueue(job)

            let reloaded = try await store.load(job.id)

            #expect(reloaded.transcriptionProviderID == .parakeetTDTv3)
        }
    }
}
