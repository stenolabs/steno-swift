import Foundation
import StenoDomain
import StenoLibrary
import Testing
@testable import StenoPipeline

@Suite("Missing diarization model job retry")
struct MissingDiarizationModelJobRetrierTests {
    @Test("requeues typed and exact pre-upgrade missing-model failures only")
    func retriesOnlyEligibleJobs() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let store = try JobStore(layout: library.layout)
            let eligible = Job(
                kind: .diarization,
                meetingID: meeting.id,
                status: .failed,
                attemptCount: 1,
                errorMessage: "missing",
                failureReason: .diarizationModelsNotInstalled
            )
            let otherFailure = Job(
                kind: .diarization,
                meetingID: meeting.id,
                status: .failed,
                errorMessage: "inference failed"
            )
            let legacyMissingModels = Job(
                kind: .diarization,
                meetingID: meeting.id,
                status: .failed,
                attemptCount: 1,
                errorMessage: "The speaker separation models are not installed yet (missing: Sortformer_v2.1.mlmodelc). Install them in Steno's settings."
            )
            let legacyLookalike = Job(
                kind: .diarization,
                meetingID: meeting.id,
                status: .failed,
                errorMessage: "The speaker separation models are not installed yet, but loading also failed."
            )
            let failedFinalASR = Job(
                kind: .finalASR,
                meetingID: meeting.id,
                status: .failed,
                errorMessage: "missing",
                failureReason: .diarizationModelsNotInstalled
            )
            let alreadyQueued = Job(
                kind: .diarization,
                meetingID: meeting.id,
                status: .queued,
                failureReason: .diarizationModelsNotInstalled
            )
            for job in [
                eligible,
                legacyMissingModels,
                legacyLookalike,
                otherFailure,
                failedFinalASR,
                alreadyQueued,
            ] {
                try await store.enqueue(job)
            }

            let first = try await MissingDiarizationModelJobRetrier.requeue(jobStore: store)
            let second = try await MissingDiarizationModelJobRetrier.requeue(jobStore: store)

            #expect(Set(first) == [eligible.id, legacyMissingModels.id])
            #expect(second.isEmpty)
            #expect(try await store.load(eligible.id).status == .queued)
            #expect(try await store.load(eligible.id).failureReason == nil)
            #expect(try await store.load(legacyMissingModels.id).status == .queued)
            #expect(try await store.load(legacyMissingModels.id).failureReason == nil)
            #expect(try await store.load(legacyLookalike.id).status == .failed)
            #expect(try await store.load(otherFailure.id).status == .failed)
            #expect(try await store.load(failedFinalASR.id).status == .failed)
            #expect(try await store.load(alreadyQueued.id).status == .queued)
            #expect(try await store.list().filter { $0.kind == .finalASR }.count == 1)
        }
    }

    @Test("concurrent retries have one winner and never fail")
    func concurrentRetryIsIdempotent() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let store = try JobStore(layout: library.layout)
            let job = Job(
                kind: .diarization,
                meetingID: meeting.id,
                status: .failed,
                failureReason: .diarizationModelsNotInstalled
            )
            try await store.enqueue(job)

            async let first = MissingDiarizationModelJobRetrier.requeue(jobStore: store)
            async let second = MissingDiarizationModelJobRetrier.requeue(jobStore: store)
            let results = try await [first, second]

            #expect(results.flatMap { $0 } == [job.id])
            #expect(try await store.list().count == 1)
            #expect(try await store.load(job.id).status == .queued)
        }
    }
}
