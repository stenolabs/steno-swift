import Foundation
import StenoDomain
import Testing
@testable import steno_macos

@Suite("Mac status presentation")
struct MacStatusPresentationTests {
    @Test("critical notices use the top surface and confirmations stay below")
    func globalNoticePlacement() {
        #expect(MacGlobalStatusSurface.notice(isError: true) == .top)
        #expect(MacGlobalStatusSurface.notice(isError: false) == .bottom)
        #expect(MacGlobalStatusSurface.startupFailure == .top)
        #expect(MacGlobalStatusSurface.audioExport == .bottom)
    }

    @Test("template and export jobs never become transcription status")
    func unrelatedJobsAreHidden() {
        let presentation = MeetingPipelineStatusPresentation.make(jobs: [
            job(kind: .templateRender, status: .running, seconds: 1),
            job(kind: .export, status: .failed, seconds: 2),
        ])

        #expect(presentation.state == .hidden)
    }

    @Test("a later successful job suppresses an older failure of the same kind")
    func laterSuccessSupersedesFailure() {
        let failed = job(kind: .finalASR, status: .failed, seconds: 1)
        let finished = job(kind: .finalASR, status: .finished, seconds: 2)

        let presentation = MeetingPipelineStatusPresentation.make(
            jobs: [failed, finished]
        )

        #expect(presentation.state == .hidden)
    }

    @Test("success in another pipeline stage does not hide a real failure")
    func unrelatedSuccessDoesNotSupersedeFailure() {
        let failed = job(kind: .finalASR, status: .failed, seconds: 1)
        let finished = job(kind: .diarization, status: .finished, seconds: 2)

        let presentation = MeetingPipelineStatusPresentation.make(
            jobs: [finished, failed]
        )

        #expect(presentation.state == .failed(failed))
    }

    @Test("running work takes precedence over queued work")
    func runningTakesPrecedence() {
        let queued = job(kind: .finalASR, status: .queued, seconds: 2)
        let running = job(kind: .diarization, status: .running, seconds: 1)

        let presentation = MeetingPipelineStatusPresentation.make(
            jobs: [queued, running]
        )

        #expect(presentation.state == .active(running))
        #expect(presentation.activeTitle != nil)
    }

    @Test("queued work follows coordinator kind priority and FIFO order")
    func queuedWorkMatchesCoordinatorOrder() {
        let olderASR = job(kind: .finalASR, status: .queued, seconds: 1)
        let newerASR = job(kind: .finalASR, status: .queued, seconds: 2)
        let oldestDiarization = job(
            kind: .diarization,
            status: .queued,
            seconds: 0
        )

        let presentation = MeetingPipelineStatusPresentation.make(
            jobs: [newerASR, oldestDiarization, olderASR]
        )

        #expect(presentation.state == .active(olderASR))
    }

    @Test("meeting transfer processing owns its duplicate pipeline status")
    func meetingTransferSuppressesDuplicateStatus() {
        #expect(MeetingPipelineStatusPresentation.transferOwnsStatus(.processing))
        #expect(MeetingPipelineStatusPresentation.transferOwnsStatus(
            .failed(localeIdentifier: "de-DE", reason: "fixture")
        ))
        #expect(!MeetingPipelineStatusPresentation.transferOwnsStatus(.completed))
    }

    @Test("legacy upgrade status owns the pipeline surface while active")
    func legacyUpgradeSuppressesDuplicateStatus() {
        let running = job(kind: .finalASR, status: .running, seconds: 1)

        let presentation = MeetingPipelineStatusPresentation.make(
            jobs: [running],
            isSuppressed: true
        )

        #expect(presentation.state == .hidden)
    }

    @Test("Reduce Motion removes positional status animation")
    func reduceMotionPolicy() {
        #expect(MacStatusMotionPolicy(reduceMotion: false) == .standard)
        #expect(MacStatusMotionPolicy(reduceMotion: true) == .reduced)
        #expect(MacStatusMotionPolicy.standard.usesPositionalMovement)
        #expect(!MacStatusMotionPolicy.reduced.usesPositionalMovement)
    }

    private func job(
        kind: Job.Kind,
        status: Job.Status,
        seconds: TimeInterval
    ) -> Job {
        Job(
            kind: kind,
            meetingID: Self.meetingID,
            status: status,
            createdAt: Date(timeIntervalSince1970: seconds),
            errorMessage: status == .failed ? "fixture failure" : nil
        )
    }

    private static let meetingID = MeetingID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )
}
