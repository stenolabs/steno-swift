import Foundation
import StenoDomain
@testable import StenoLibrary
@testable import StenoPipeline
import StenoTranscription
import Synchronization
import Testing

/// Automatic one-shot engine fallback for failed final-ASR runs.
@Suite("Final ASR automatic fallback")
struct FinalASRFallbackTests {
    // MARK: - Classification units

    @Test("model-missing errors are classified as bypassed")
    func modelMissingClassification() {
        #expect(FinalASRFallback.isModelMissing(
            TranscriptionError.assetsNotInstalled(localeIdentifier: "de-DE")
        ))
        #expect(FinalASRFallback.isModelMissing(
            TranscriptionError.assetsUnsupported(localeIdentifier: "de-DE")
        ))
        #expect(FinalASRFallback.isModelMissing(
            TranscriptionError.assetInstallationUnavailable(localeIdentifier: "de-DE")
        ))
        #expect(FinalASRFallback.isModelMissing(
            TranscriptionError.noSupportedLocale
        ))
        #expect(FinalASRFallback.isModelMissing(
            TranscriptionError.speechTranscriberUnavailable
        ))
        // Genuine engine/provider errors are not model-missing.
        #expect(!FinalASRFallback.isModelMissing(FakeTranscriptionError.failed))
        #expect(!FinalASRFallback.isModelMissing(
            TranscriptionRegistryError.unknownProvider(.parakeetTDTv3)
        ))
    }

    @Test("cancellation and model-missing are ineligible for fallback")
    func ineligibleErrors() {
        #expect(!FinalASRFallback.isEngineProviderError(CancellationError()))
        #expect(!FinalASRFallback.isEngineProviderError(
            TranscriptionError.assetsNotInstalled(localeIdentifier: "en-US")
        ))
        #expect(FinalASRFallback.isEngineProviderError(FakeTranscriptionError.failed))
    }

    @Test("only the Apple side falls back, always to Parakeet")
    func alternativeDirection() {
        #expect(FinalASRFallback.alternativeProvider(for: nil) == .parakeetTDTv3)
        #expect(FinalASRFallback.alternativeProvider(for: .apple) == .parakeetTDTv3)
        // A failed Parakeet run keeps its explicit manual retry offer.
        #expect(FinalASRFallback.alternativeProvider(for: .parakeetTDTv3) == nil)
        #expect(FinalASRFallback.alternativeProvider(
            for: TranscriptionProviderID(rawValue: "unknown.engine")
        ) == nil)
    }

    @Test("fallback identity is deterministic and distinct per origin job")
    func deterministicIdentity() {
        let first = Job(kind: .finalASR, meetingID: MeetingID())
        let second = Job(kind: .finalASR, meetingID: MeetingID())

        #expect(FinalASRFallback.fallbackJobID(after: first)
            == FinalASRFallback.fallbackJobID(after: first))
        #expect(FinalASRFallback.fallbackJobID(after: first)
            != FinalASRFallback.fallbackJobID(after: second))
        #expect(FinalASRFallback.fallbackJobID(after: first) != first.id)

        // The fallback run ID matches what execution will derive from the
        // fallback job, so provenance can be written before it exists.
        let fallbackJob = FinalASRFallback.makeFallbackJob(
            for: first,
            alternative: .parakeetTDTv3
        )
        #expect(fallbackJob.id == FinalASRFallback.fallbackJobID(after: first))
        #expect(FinalASRFallback.fallbackRunID(forFallbackFrom: first)
            == StablePipelineIdentifiers.runID(for: fallbackJob))
    }

    @Test("a fallback job keeps pins of its origin")
    func fallbackJobCarriesPins() {
        let generation = MeetingTransferGenerationID()
        let origin = Job(
            kind: .finalASR,
            meetingID: MeetingID(),
            localeIdentifier: "de-DE",
            importGenerationID: generation,
            languageDetection: TranscriptionLanguageDetectionPin(
                startLocaleIdentifier: "de-DE",
                detectedLocaleIdentifier: "en-US"
            )
        )
        let fallback = FinalASRFallback.makeFallbackJob(
            for: origin,
            alternative: .parakeetTDTv3
        )
        #expect(fallback.kind == .finalASR)
        #expect(fallback.meetingID == origin.meetingID)
        #expect(fallback.localeIdentifier == "de-DE")
        #expect(fallback.processingGenerationID == generation)
        #expect(fallback.transcriptionProviderID == .parakeetTDTv3)
        #expect(fallback.languageDetection == origin.languageDetection)
        #expect(fallback.status == .queued)
    }

    @Test("chain detection recognizes derived fallback IDs")
    func chainDetection() {
        let origin = Job(kind: .finalASR, meetingID: MeetingID())
        let fallback = FinalASRFallback.makeFallbackJob(
            for: origin,
            alternative: .parakeetTDTv3
        )
        #expect(FinalASRFallback.isFallbackJob(fallback, among: [origin, fallback]))
        #expect(!FinalASRFallback.isFallbackJob(origin, among: [origin, fallback]))
        #expect(!FinalASRFallback.isFallbackJob(origin, among: []))
    }

    // MARK: - Provenance persistence units

    @Test("legacy run documents without provenance fields decode as nil")
    func legacyProcessingRunDecodesNilProvenance() throws {
        struct LegacyShape: Codable {
            let schemaVersion: Int
            let id: RunID
            let meetingID: MeetingID
            let kind: ProcessingRun.Kind
            let engine: EngineDescriptor
            let status: ProcessingRun.Status
            let createdAt: Date
        }
        let legacy = LegacyShape(
            schemaVersion: 1,
            id: RunID(),
            meetingID: MeetingID(),
            kind: .finalASR,
            engine: EngineDescriptor(name: "E", version: "1"),
            status: .failed,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(ProcessingRun.self, from: data)
        #expect(decoded.supersededBy == nil)
        #expect(decoded.originalRunID == nil)
    }

    @Test("provenance fields survive an encode-decode round trip")
    func provenanceRoundTrip() throws {
        var run = ProcessingRun(
            meetingID: MeetingID(),
            kind: .finalASR,
            engine: EngineDescriptor(name: "E", version: "1"),
            status: .failed
        )
        let other = RunID()
        run.supersededBy = other
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(ProcessingRun.self, from: data)
        #expect(decoded.supersededBy == other)
        #expect(decoded.originalRunID == nil)
    }

    @Test("generation provenance guard sees superseded same-generation runs")
    func generationProvenanceGuard() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Guard",
                status: .ready
            )
            let encoder = JSONEncoder()

            // Same-generation peer whose failed run records supersession.
            let supersededPeer = Job(kind: .finalASR, meetingID: meeting.id)
            let supersededRun = ProcessingRun(
                id: StablePipelineIdentifiers.runID(for: supersededPeer),
                meetingID: meeting.id,
                kind: .finalASR,
                engine: EngineDescriptor(name: "E", version: "1"),
                status: .failed,
                supersededBy: RunID()
            )
            try writeRunDocument(
                supersededRun,
                at: library.layout.runMetadata(
                    meeting.id,
                    runID: supersededRun.id
                ),
                encoder: encoder
            )

            let probedJob = Job(kind: .finalASR, meetingID: meeting.id)
            #expect(FinalASRFallback.generationHasSupersededRuns(
                for: probedJob,
                jobs: [supersededPeer, probedJob],
                layout: library.layout
            ))

            // A clean generation stays clean.
            #expect(!FinalASRFallback.generationHasSupersededRuns(
                for: probedJob,
                jobs: [probedJob],
                layout: library.layout
            ))
        }
    }

    // MARK: - Eligibility units

    @Test("eligibility gates fire in order")
    func eligibilityGates() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(
                title: "Eligibility",
                status: .ready
            )
            let job = Job(
                kind: .finalASR,
                meetingID: meeting.id,
                transcriptionProviderID: .apple
            )

            func decide(
                error: any Error,
                candidate: Job,
                jobs: [Job],
                alternativeReady: Bool
            ) -> FinalASRFallback.Eligibility {
                FinalASRFallback.eligibility(
                    error: error,
                    job: candidate,
                    jobs: jobs,
                    alternativeProviderIsReady: alternativeReady,
                    layout: library.layout
                )
            }

            #expect(decide(
                error: CancellationError(),
                candidate: job,
                jobs: [job],
                alternativeReady: true
            ) == .ineligibleError)
            #expect(decide(
                error: TranscriptionError.assetsNotInstalled(localeIdentifier: "de-DE"),
                candidate: job,
                jobs: [job],
                alternativeReady: true
            ) == .ineligibleError)
            #expect(decide(
                error: FakeTranscriptionError.failed,
                candidate: job,
                jobs: [job],
                alternativeReady: false
            ) == .alternativeNotReady)
            #expect(decide(
                error: FakeTranscriptionError.failed,
                candidate: job,
                jobs: [job],
                alternativeReady: true
            ) == .eligible(.parakeetTDTv3))

            // A Parakeet-pinned job has no automatic alternative.
            let parakeetJob = Job(
                kind: .finalASR,
                meetingID: meeting.id,
                transcriptionProviderID: .parakeetTDTv3
            )
            #expect(decide(
                error: FakeTranscriptionError.failed,
                candidate: parakeetJob,
                jobs: [parakeetJob],
                alternativeReady: true
            ) == .noAlternativeProvider)
        }
    }

    // MARK: - Integration

    @Test("an Apple engine failure requeues exactly once with Parakeet and links provenance")
    func fallbackTriggersOnceWithProvenance() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let apple = FakeTranscriptionProvider(behavior: .fail)
            let parakeet = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                transcriptionProviderResolver: dualResolver(apple: apple, parakeet: parakeet),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let finalJobs = try await fixture.jobStore.list()
                .filter { $0.kind == .finalASR }
            #expect(finalJobs.count == 2)
            #expect(finalJobs.contains {
                $0.id == fixture.job.id && $0.status == .failed
            })
            let fallbackJob = try #require(finalJobs.first {
                $0.id == FinalASRFallback.fallbackJobID(after: fixture.job)
            })
            #expect(fallbackJob.status == .finished)
            #expect(fallbackJob.transcriptionProviderID == .parakeetTDTv3)
            // Exactly one engine ran per side: Apple failed once per track,
            // Parakeet took over.
            #expect(await parakeet.callCount() >= 1)
            #expect(await apple.callCount() >= 1)

            // Distinct user-visible notice through the job-failure channel.
            let failedJob = try await fixture.jobStore.load(fixture.job.id)
            #expect(failedJob.errorMessage?.contains("automatic retry") == true)

            // Run-level provenance links the two runs in both directions.
            let runs = try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).filter { $0.kind == .finalASR }
            let failedRun = try #require(runs.first {
                $0.id == StablePipelineIdentifiers.runID(for: fixture.job)
            })
            let fallbackRun = try #require(runs.first {
                $0.id == StablePipelineIdentifiers.runID(for: fallbackJob)
            })
            #expect(failedRun.status == .failed)
            #expect(failedRun.supersededBy == fallbackRun.id)
            #expect(fallbackRun.originalRunID == failedRun.id)
            #expect(fallbackRun.supersededBy == nil)

            await coordinator.stop()
        }
    }

    @Test("the fallback never loops: a failed Parakeet fallback stays failed")
    func fallbackDoesNotLoop() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let apple = FakeTranscriptionProvider(behavior: .fail)
            let parakeet = FakeTranscriptionProvider(behavior: .fail)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                transcriptionProviderResolver: dualResolver(apple: apple, parakeet: parakeet),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()
            // A second drain proves no further work was enqueued afterwards.
            try await coordinator.waitUntilIdle()

            let finalJobs = try await fixture.jobStore.list()
                .filter { $0.kind == .finalASR }
            #expect(finalJobs.count == 2)
            #expect(finalJobs.allSatisfy { $0.status == .failed })

            let runs = try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).filter { $0.kind == .finalASR }
            let fallbackRun = try #require(runs.first {
                $0.id == StablePipelineIdentifiers.runID(
                    for: FinalASRFallback.fallbackJobID(after: fixture.job),
                    kind: .finalASR
                )
            })
            // The fallback run points back at its origin but supersedes nothing.
            #expect(fallbackRun.originalRunID != nil)
            #expect(fallbackRun.supersededBy == nil)

            await coordinator.stop()
        }
    }

    @Test("a Parakeet failure never switches engines automatically")
    func parakeetFailureRemainsManual() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(
                at: root,
                transcriptionProviderID: .parakeetTDTv3
            )
            let apple = FakeTranscriptionProvider(behavior: .succeed)
            let parakeet = FakeTranscriptionProvider(behavior: .fail)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                transcriptionProviderResolver: dualResolver(apple: apple, parakeet: parakeet),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let finalJobs = try await fixture.jobStore.list()
                .filter { $0.kind == .finalASR }
            #expect(finalJobs.count == 1)
            #expect(finalJobs.first?.status == .failed)
            #expect(await apple.callCount() == 0)

            await coordinator.stop()
        }
    }

    @Test("model-missing failures bypass the fallback entirely")
    func modelMissingBypassesFallback() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let apple = ModelMissingTranscriptionProvider()
            let parakeet = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                transcriptionProviderResolver: dualResolver(apple: apple, parakeet: parakeet),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let finalJobs = try await fixture.jobStore.list()
                .filter { $0.kind == .finalASR }
            #expect(finalJobs.count == 1)
            #expect(finalJobs.first?.status == .failed)
            #expect(await parakeet.callCount() == 0)

            await coordinator.stop()
        }
    }

    @Test("an unready alternative provider leaves the job failed")
    func unreadyAlternativeRemainsFailed() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let apple = FakeTranscriptionProvider(behavior: .fail)
            // Parakeet registered nowhere: resolution is the pipeline's
            // installed-and-ready gate, so it must refuse the fallback.
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                transcriptionProviderResolver: { providerID, _ in
                    guard providerID == .apple else {
                        throw TranscriptionRegistryError.unknownProvider(providerID)
                    }
                    return apple
                },
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let finalJobs = try await fixture.jobStore.list()
                .filter { $0.kind == .finalASR }
            #expect(finalJobs.count == 1)
            #expect(finalJobs.first?.status == .failed)
            // No fallback-flavored notice: the plain engine error stands.
            #expect(finalJobs.first?.errorMessage?.contains("automatic retry") != true)

            await coordinator.stop()
        }
    }

    @Test("cancellation is respected: a cancelled run does not fall back")
    func cancellationPreventsFallback() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let apple = FakeTranscriptionProvider(behavior: .block)
            let parakeet = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                transcriptionProviderResolver: dualResolver(apple: apple, parakeet: parakeet),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await eventually {
                try await fixture.jobStore.load(fixture.job.id).status == .running
            }
            try await coordinator.cancel(jobID: fixture.job.id)
            try await coordinator.waitUntilIdle()

            let finalJobs = try await fixture.jobStore.list()
                .filter { $0.kind == .finalASR }
            #expect(finalJobs.count == 1)
            #expect(finalJobs.first?.status == .cancelled)
            #expect(await parakeet.callCount() == 0)

            await coordinator.stop()
        }
    }
}

// MARK: - Local support

private func dualResolver(
    apple: any TranscriptionProvider,
    parakeet: any TranscriptionProvider
) -> TranscriptionProviderResolver {
    { providerID, _ in
        switch providerID {
        case .apple: apple
        case .parakeetTDTv3: parakeet
        default:
            throw TranscriptionRegistryError.unknownProvider(providerID)
        }
    }
}
private func writeRunDocument(
    _ run: ProcessingRun,
    at url: URL,
    encoder: JSONEncoder
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try encoder.encode(run).write(to: url)
}

/// Provider whose file transcription always reports missing speech assets -
/// the model-missing family that must bypass the fallback.
private actor ModelMissingTranscriptionProvider: TranscriptionProvider {
    nonisolated let descriptor = EngineDescriptor(
        name: "ModelMissingASR",
        version: "1.0",
        modelVersion: "fixture"
    )

    func liveSession(
        format: AudioFormat,
        locale: Locale
    ) async throws -> any LiveTranscriptionSession {
        throw TranscriptionError.assetsNotInstalled(localeIdentifier: locale.identifier)
    }

    func transcribeFile(
        _ url: URL,
        locale: Locale
    ) async throws -> TranscriptOutput {
        throw TranscriptionError.assetsNotInstalled(localeIdentifier: locale.identifier)
    }
}
