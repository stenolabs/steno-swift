import Foundation
import StenoDomain
import StenoLibrary
import StenoTranscription
import Testing
@testable import Steno

@Suite("Retry missing speech model jobs")
struct MissingSpeechModelJobRetrierTests {
    @Test("only final ASR jobs missing the current locale model are requeued")
    func retriesOnlyExactMissingModelFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
        let store = try JobStore(layout: library.layout)
        let locale = Locale(identifier: "de-DE")
        let exactMessage = TranscriptionError.assetsNotInstalled(
            localeIdentifier: locale.identifier
        ).localizedDescription
        let exact = Job(
            kind: .finalASR,
            meetingID: meeting.id,
            status: .failed,
            attemptCount: 1,
            errorMessage: exactMessage
        )
        let otherLocale = Job(
            kind: .finalASR,
            meetingID: meeting.id,
            status: .failed,
            attemptCount: 1,
            errorMessage: TranscriptionError.assetsNotInstalled(
                localeIdentifier: "en-US"
            ).localizedDescription
        )
        let otherFailure = Job(
            kind: .finalASR,
            meetingID: meeting.id,
            status: .failed,
            attemptCount: 1,
            errorMessage: "Audio file is corrupt"
        )
        for job in [exact, otherLocale, otherFailure] {
            try await store.enqueue(job)
        }

        let requeued = try await MissingSpeechModelJobRetrier.requeue(
            jobStore: store,
            locale: locale
        )

        #expect(requeued == [exact.id])
        #expect(try await store.load(exact.id).status == .queued)
        #expect(try await store.load(otherLocale.id).status == .failed)
        #expect(try await store.load(otherFailure.id).status == .failed)
    }
}
