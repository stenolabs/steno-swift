import AVFoundation
import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline
import Testing
@testable import Steno

@Suite("iOS transcript recalculation")
struct AppModelRetranscriptionTests {
    @Test("the runtime guard rejects only the meeting currently being recorded")
    func activeRecordingMeetingIsRejected() throws {
        let activeMeetingID = MeetingID()

        #expect(throws: MeetingRetranscriptionRequestError.activeRecording) {
            try MeetingRetranscriptionRuntimeGuard.requireRetranscriptionAllowed(
                meetingID: activeMeetingID,
                recordingIsActive: true,
                recordingMeetingID: activeMeetingID
            )
        }

        try MeetingRetranscriptionRuntimeGuard.requireRetranscriptionAllowed(
            meetingID: MeetingID(),
            recordingIsActive: true,
            recordingMeetingID: activeMeetingID
        )
    }

    @Test("a native meeting queues final ASR with its pinned transcription plan")
    @MainActor
    func nativeMeetingQueuesPinnedFinalASR() async throws {
        let fixture = try await RetranscriptionFixture.make(playableAudio: true)
        defer { fixture.remove() }

        try await fixture.app.requestRetranscription(meetingID: fixture.meeting.id)

        let jobs = try await fixture.jobStore.list()
        let job = try #require(jobs.only)
        #expect(job.kind == .finalASR)
        #expect(job.meetingID == fixture.meeting.id)
        #expect(job.status == .queued)
        #expect(job.localeIdentifier == "de-DE")
        #expect(job.transcriptionProviderID == .parakeetTDTv3)
        #expect(
            MeetingJobPresentation.make(jobs)
                == MeetingJobPresentation(
                    title: "Transcription queued",
                    message: "Step 1 of 3. Steno will transcribe the original audio on this device."
                )
        )
    }

    @Test("a demo meeting queues final ASR for its current installation generation")
    @MainActor
    func demoMeetingQueuesGenerationPinnedFinalASR() async throws {
        let generation = MeetingTransferGenerationID()
        let fixture = try await RetranscriptionFixture.make(
            playableAudio: true,
            metadata: MeetingMetadata(demoProvenance: DemoProvenance(
                datasetID: "steno-demo-v1",
                datasetVersion: "v2",
                itemID: "planning",
                installationGenerationID: generation
            ))
        )
        defer { fixture.remove() }

        try await fixture.app.requestRetranscription(meetingID: fixture.meeting.id)

        let job = try #require(try await fixture.jobStore.list().only)
        #expect(job.processingGenerationID == generation)
    }

    @Test("registered but unreadable audio cannot start retranscription")
    @MainActor
    func unreadableAudioIsRejected() async throws {
        let fixture = try await RetranscriptionFixture.make(
            playableAudio: false,
            registerUnreadableAudio: true
        )
        defer { fixture.remove() }

        await #expect(throws: MeetingRetranscriptionRequestError.noPlayableAudio) {
            try await fixture.app.requestRetranscription(meetingID: fixture.meeting.id)
        }
        #expect(try await fixture.jobStore.list().isEmpty)
    }

    @Test("readable zero-duration audio cannot start retranscription")
    @MainActor
    func zeroDurationAudioIsRejected() async throws {
        let fixture = try await RetranscriptionFixture.make(
            playableAudio: true,
            registeredDuration: 0
        )
        defer { fixture.remove() }

        await #expect(throws: MeetingRetranscriptionRequestError.noPlayableAudio) {
            try await fixture.app.requestRetranscription(meetingID: fixture.meeting.id)
        }
        #expect(try await fixture.jobStore.list().isEmpty)
    }

    @Test(
        "queued and running final ASR jobs block another retranscription",
        arguments: [Job.Status.queued, .running]
    )
    @MainActor
    func activeFinalASRIsNotDuplicated(status: Job.Status) async throws {
        let fixture = try await RetranscriptionFixture.make(playableAudio: true)
        defer { fixture.remove() }
        let active = Job(
            kind: .finalASR,
            meetingID: fixture.meeting.id,
            transcriptionProviderID: .apple,
            status: status
        )
        try await fixture.jobStore.enqueue(active)

        await #expect(throws: MeetingRetranscriptionRequestError.alreadyRunning) {
            try await fixture.app.requestRetranscription(meetingID: fixture.meeting.id)
        }

        #expect(try await fixture.jobStore.list().map(\.id) == [active.id])
    }

    @Test("a stale active job does not block retranscription for the current generation")
    @MainActor
    func staleActiveFinalASRIsIgnored() async throws {
        let currentGeneration = MeetingTransferGenerationID()
        let staleGeneration = MeetingTransferGenerationID()
        let fixture = try await RetranscriptionFixture.make(
            playableAudio: true,
            metadata: MeetingMetadata(demoProvenance: DemoProvenance(
                datasetID: "steno-demo-v1",
                datasetVersion: "v2",
                itemID: "planning",
                installationGenerationID: currentGeneration
            ))
        )
        defer { fixture.remove() }
        let stale = Job(
            kind: .finalASR,
            meetingID: fixture.meeting.id,
            importGenerationID: staleGeneration,
            transcriptionProviderID: .apple,
            status: .running
        )
        try await fixture.jobStore.enqueue(stale)

        try await fixture.app.requestRetranscription(meetingID: fixture.meeting.id)

        let jobs = try await fixture.jobStore.list()
        #expect(jobs.count == 2)
        #expect(jobs.contains {
            $0.id != stale.id && $0.processingGenerationID == currentGeneration
        })
    }

    @Test("a generation-pinned import must use its pinned retry path")
    @MainActor
    func importedMeetingIsRejectedBeforeEnqueue() async throws {
        let receipt = MeetingTransferReceipt(
            sourceMeetingID: MeetingID(),
            sourceRevisionID: nil,
            sourcePackageContentDigest: String(repeating: "a", count: 64),
            importedAt: Date(timeIntervalSinceReferenceDate: 123_456),
            sourceAppVersion: "1.0",
            includedCapabilities: [.audio],
            sourceLocaleIdentifier: "de-DE",
            sourceLocaleOrigin: .explicit,
            importGenerationID: MeetingTransferGenerationID()
        )
        let fixture = try await RetranscriptionFixture.make(
            playableAudio: true,
            metadata: MeetingMetadata(transferReceipt: receipt)
        )
        defer { fixture.remove() }

        await #expect(
            throws: MeetingProcessingRequestError.importedRetryRequired(
                fixture.meeting.id
            )
        ) {
            try await fixture.app.requestRetranscription(meetingID: fixture.meeting.id)
        }
        #expect(try await fixture.jobStore.list().isEmpty)
    }
}

private struct RetranscriptionFixture {
    let root: URL
    let app: AppModel
    let meeting: Meeting
    let jobStore: JobStore

    @MainActor
    static func make(
        playableAudio: Bool,
        registerUnreadableAudio: Bool = false,
        registeredDuration: TimeInterval = 0.1,
        metadata: MeetingMetadata? = nil
    ) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Steno-RetranscriptionTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let libraryRoot = root.appending(path: "Library", directoryHint: .isDirectory)
        let library = try Library.open(at: libraryRoot)
        let meeting = try await library.createMeeting(
            title: "Planning",
            status: .ready,
            metadata: metadata,
            sourceLocale: MeetingSourceLocale(
                localeIdentifier: "de-DE",
                origin: .explicit
            ),
            transcriptionPlan: TranscriptionPlan(
                liveProviderID: .apple,
                finalProviderID: .parakeetTDTv3
            )
        )
        if playableAudio || registerUnreadableAudio {
            let source = root.appending(path: "source.caf")
            if playableAudio {
                try writeSilentCAF(to: source)
            } else {
                try Data("not audio".utf8).write(to: source)
            }
            _ = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: source,
                kind: .micTrack,
                sampleRate: 16_000,
                duration: registeredDuration
            )
        }
        let jobStore = try JobStore(layout: library.layout)
        let runtime = PipelineRuntime(
            library: library,
            jobStore: jobStore,
            coordinator: PipelineCoordinator(
                library: library,
                jobStore: jobStore,
                providers: [:],
                locale: Locale(identifier: "de-DE")
            )
        )
        let app = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, _, _ in runtime },
            libraryURL: libraryRoot
        )
        await app.bootstrap()
        return Self(root: root, app: app, meeting: meeting, jobStore: jobStore)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private func writeSilentCAF(to url: URL) throws {
    let sampleRate = 16_000.0
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ))
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let frameCount = AVAudioFrameCount(sampleRate / 10)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ))
    buffer.frameLength = frameCount
    try file.write(from: buffer)
}
