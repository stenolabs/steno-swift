import Foundation
import StenoDomain
import StenoLibrary
import StenoTranscription
import Testing
@testable import StenoPipeline

@Suite("Missing speech model job retry")
struct MissingSpeechModelJobRetrierTests {
    @Test("installed locale requeues only its exact missing-model final ASR failures")
    func installedLocaleRetriesEligibleJobs() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let store = try JobStore(layout: library.layout)
            let locale = Locale(identifier: "de-DE")
            let eligible = Job(
                kind: .finalASR,
                meetingID: meeting.id,
                localeIdentifier: locale.identifier,
                status: .failed,
                attemptCount: 1,
                errorMessage: TranscriptionError.assetsNotInstalled(
                    localeIdentifier: locale.identifier
                ).localizedDescription
            )
            let otherLocale = Job(
                kind: .finalASR,
                meetingID: meeting.id,
                localeIdentifier: "en-US",
                status: .failed,
                errorMessage: TranscriptionError.assetsNotInstalled(
                    localeIdentifier: "en-US"
                ).localizedDescription
            )
            let otherFailure = Job(
                kind: .finalASR,
                meetingID: meeting.id,
                localeIdentifier: locale.identifier,
                status: .failed,
                errorMessage: "Audio file is corrupt"
            )
            let diarization = Job(
                kind: .diarization,
                meetingID: meeting.id,
                status: .failed,
                errorMessage: eligible.errorMessage
            )
            for job in [eligible, otherLocale, otherFailure, diarization] {
                try await store.enqueue(job)
            }

            let requeued = try await MissingSpeechModelJobRetrier.requeue(
                jobStore: store,
                locale: locale,
                modelIsReady: true
            )

            #expect(requeued == [eligible.id])
            #expect(try await store.load(eligible.id).status == .queued)
            #expect(try await store.load(eligible.id).attemptCount == 1)
            #expect(try await store.load(otherLocale.id).status == .failed)
            #expect(try await store.load(otherFailure.id).status == .failed)
            #expect(try await store.load(diarization.id).status == .failed)
        }
    }

    @Test("missing locale leaves matching failures untouched")
    func missingLocaleDoesNotRetry() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let store = try JobStore(layout: library.layout)
            let locale = Locale(identifier: "de-DE")
            let failed = Job(
                kind: .finalASR,
                meetingID: meeting.id,
                localeIdentifier: locale.identifier,
                status: .failed,
                attemptCount: 1,
                errorMessage: TranscriptionError.assetsNotInstalled(
                    localeIdentifier: locale.identifier
                ).localizedDescription
            )
            try await store.enqueue(failed)

            let requeued = try await MissingSpeechModelJobRetrier.requeue(
                jobStore: store,
                locale: locale,
                modelIsReady: false
            )

            #expect(requeued.isEmpty)
            #expect(try await store.load(failed.id).status == .failed)
            #expect(try await store.load(failed.id).attemptCount == 1)
        }
    }

    @Test("recovery skips a stale demo generation and keeps imported behavior")
    func recoveryUsesCurrentMeetingGeneration() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let currentGeneration = MeetingTransferGenerationID()
            let staleGeneration = MeetingTransferGenerationID()
            let demo = try await library.createMeeting(
                title: "Demo G2",
                status: .ready,
                metadata: MeetingMetadata(demoProvenance: DemoProvenance(
                    datasetID: "steno-demo-v1",
                    datasetVersion: "v2",
                    itemID: "demo",
                    installationGenerationID: currentGeneration
                ))
            )
            let importGeneration = MeetingTransferGenerationID()
            let imported = try await library.createMeeting(
                title: "Imported",
                status: .ready,
                metadata: MeetingMetadata(transferReceipt: MeetingTransferReceipt(
                    sourceMeetingID: MeetingID(),
                    sourceRevisionID: nil,
                    sourcePackageContentDigest: String(repeating: "a", count: 64),
                    importedAt: Date(timeIntervalSinceReferenceDate: 1),
                    sourceAppVersion: nil,
                    includedCapabilities: [.audio],
                    sourceLocaleIdentifier: "de-DE",
                    sourceLocaleOrigin: .explicit,
                    importGenerationID: importGeneration
                ))
            )
            let store = try JobStore(layout: library.layout)
            let locale = Locale(identifier: "de-DE")
            let missing = TranscriptionError.assetsNotInstalled(
                localeIdentifier: locale.identifier
            ).localizedDescription
            let stale = Job(
                kind: .finalASR,
                meetingID: demo.id,
                localeIdentifier: locale.identifier,
                importGenerationID: staleGeneration,
                status: .failed,
                errorMessage: missing
            )
            let current = Job(
                kind: .finalASR,
                meetingID: demo.id,
                localeIdentifier: locale.identifier,
                importGenerationID: currentGeneration,
                status: .failed,
                errorMessage: missing
            )
            let importedJob = Job(
                kind: .finalASR,
                meetingID: imported.id,
                localeIdentifier: locale.identifier,
                importGenerationID: importGeneration,
                status: .failed,
                errorMessage: missing
            )
            for job in [stale, current, importedJob] {
                try await store.enqueue(job)
            }

            let requeued = try await MissingSpeechModelJobRetrier.requeue(
                jobStore: store,
                locale: locale
            )

            #expect(Set(requeued) == [current.id, importedJob.id])
            #expect(try await store.load(stale.id).status == .failed)
            #expect(try await store.load(current.id).status == .queued)
            #expect(try await store.load(importedJob.id).status == .queued)
        }
    }
}
