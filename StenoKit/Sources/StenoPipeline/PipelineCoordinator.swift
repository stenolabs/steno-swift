import CryptoKit
import Foundation
import StenoDiarization
import StenoDomain
import StenoIdentity
import StenoIntelligence
import StenoLibrary
import StenoTranscription

public struct TextModelProviderSelection: Equatable, Sendable {
    public let endpointID: String?
    public let endpointSnapshot: TextModelEndpointSnapshot?

    public init(
        endpointID: String?,
        endpointSnapshot: TextModelEndpointSnapshot? = nil
    ) {
        self.endpointID = endpointID
        self.endpointSnapshot = endpointSnapshot
    }
}

public typealias TextModelProviderResolver = @Sendable (TextModelProviderSelection) throws
    -> any TextModelProvider

public typealias TranscriptionProviderResolver = @Sendable (
    TranscriptionProviderID,
    MediaAsset.Kind
) throws -> any TranscriptionProvider

enum ImportedPipelineStateCheckpoint: Equatable, Sendable {
    case beforeImportedGenerationValidation(JobID)
    case afterImportedGenerationInputBinding(JobID)
    case afterTextProviderInputCapture(JobID)
    case beforeManualRetryTransition(JobID)
}

typealias ImportedPipelineStateAction = @Sendable (
    ImportedPipelineStateCheckpoint
) throws -> Void

/// Testhaken fuer den Abbruchpfad: laesst Tests einen Persistenzfehler an
/// einer definierten Stelle einschleusen, statt ihn ueber Dateirechte auf
/// dem `runsDirectory` zu erzwingen. Ein solcher Zwang ist ein Rennen gegen
/// den Koordinator, der zu diesem Zeitpunkt schon geschrieben haben kann.
enum PipelineCancellationPersistenceCheckpoint: Equatable, Sendable {
    case beforeRemoveTemporaryArtifacts(JobID)
}

typealias PipelineCancellationPersistenceAction = @Sendable (
    PipelineCancellationPersistenceCheckpoint
) throws -> Void

enum PipelineCompletionPolicy {
    private static let chainedJobKinds: Set<Job.Kind> = [
        .finalASR,
        .diarization,
        .identitySuggestion,
    ]

    static func shouldMarkMeetingReady(
        after job: Job,
        jobs: [Job]
    ) -> Bool {
        !jobs.contains {
            $0.meetingID == job.meetingID
                && $0.processingGenerationID == job.processingGenerationID
                && $0.id != job.id
                && chainedJobKinds.contains($0.kind)
                && ($0.status == .queued || $0.status == .running)
        }
    }

    static func meetingStatus(
        after job: Job,
        jobs: [Job],
        whenNoActiveJobs status: Meeting.Status
    ) -> Meeting.Status? {
        shouldMarkMeetingReady(after: job, jobs: jobs) ? status : nil
    }
}

public actor PipelineCoordinator {
    private static let supportedJobKinds: Set<Job.Kind> = [
        .finalASR,
        .diarization,
        .identitySuggestion,
        .templateRender,
    ]

    private let library: Library
    private let jobStore: JobStore
    private let transcriptionProviderResolver: TranscriptionProviderResolver
    private let diarizationProvider: any DiarizationProvider
    private let identityEngine: SpeakerSuggestionEngine
    private let textModelProviderResolver: TextModelProviderResolver
    private let locale: Locale
    private let runStore: RunArtifactStore
    private let templateResultStore: TemplateResultStore
    private let pollInterval: Duration
    private let importedStateAction: ImportedPipelineStateAction
    private let mediaCleanupAction: PipelineMediaCleanupAction
    private let cancellationPersistenceAction: PipelineCancellationPersistenceAction
    private let taskExecutorPreference: (any TaskExecutor)?

    private var queueTask: Task<Void, Never>?
    private var activeTask: Task<Void, Error>?
    private var activeClaim: JobExecutionClaim?
    private var activeJobID: JobID?
    private var cancellationRequests: Set<JobID> = []
    private var stopping = false
    private var activePhase: ActivePhase?
    private var runtimeFailure: PipelineError?

    private enum ActivePhase {
        case processing
        case committing
    }

    public init(
        library: Library,
        jobStore: JobStore,
        transcriptionProviderResolver: @escaping TranscriptionProviderResolver,
        diarizationProvider: any DiarizationProvider = FluidSortformerProvider(),
        identityEngine: SpeakerSuggestionEngine = SpeakerSuggestionEngine(),
        textModelProviderResolver: @escaping TextModelProviderResolver = { selection in
            if let endpointID = selection.endpointID {
                throw PipelineError.unknownTextModelEndpoint(endpointID)
            }
            return FoundationModelsProvider()
        },
        locale: Locale,
        pollInterval: Duration = .milliseconds(25)
    ) {
        self.library = library
        self.jobStore = jobStore
        self.transcriptionProviderResolver = transcriptionProviderResolver
        self.diarizationProvider = diarizationProvider
        self.identityEngine = identityEngine
        self.textModelProviderResolver = textModelProviderResolver
        self.locale = locale
        runStore = RunArtifactStore(layout: library.layout)
        templateResultStore = TemplateResultStore(layout: library.layout)
        self.pollInterval = pollInterval
        importedStateAction = { _ in }
        mediaCleanupAction = { _ in }
        cancellationPersistenceAction = { _ in }
        taskExecutorPreference = nil
    }

    /// Uebergangspfad fuer bestehende Apple-only Aufrufer. Ein gepinnter
    /// anderer Provider wird bewusst abgelehnt und niemals still auf Apple
    /// umgebogen.
    public init(
        library: Library,
        jobStore: JobStore,
        providers: [MediaAsset.Kind: any TranscriptionProvider],
        diarizationProvider: any DiarizationProvider = FluidSortformerProvider(),
        identityEngine: SpeakerSuggestionEngine = SpeakerSuggestionEngine(),
        textModelProviderResolver: @escaping TextModelProviderResolver = { selection in
            if let endpointID = selection.endpointID {
                throw PipelineError.unknownTextModelEndpoint(endpointID)
            }
            return FoundationModelsProvider()
        },
        locale: Locale,
        pollInterval: Duration = .milliseconds(25)
    ) {
        self.init(
            library: library,
            jobStore: jobStore,
            transcriptionProviderResolver: Self.appleOnlyResolver(providers),
            diarizationProvider: diarizationProvider,
            identityEngine: identityEngine,
            textModelProviderResolver: textModelProviderResolver,
            locale: locale,
            pollInterval: pollInterval
        )
    }

    init(
        library: Library,
        jobStore: JobStore,
        transcriptionProviderResolver: @escaping TranscriptionProviderResolver,
        diarizationProvider: any DiarizationProvider = FluidSortformerProvider(),
        identityEngine: SpeakerSuggestionEngine = SpeakerSuggestionEngine(),
        textModelProviderResolver: @escaping TextModelProviderResolver = { selection in
            if let endpointID = selection.endpointID {
                throw PipelineError.unknownTextModelEndpoint(endpointID)
            }
            return FoundationModelsProvider()
        },
        locale: Locale,
        pollInterval: Duration = .milliseconds(25),
        importedStateCheckpoint: @escaping ImportedPipelineStateAction,
        mediaCleanupCheckpoint: @escaping PipelineMediaCleanupAction = { _ in },
        cancellationPersistenceCheckpoint: @escaping PipelineCancellationPersistenceAction = { _ in },
        taskExecutorPreference: (any TaskExecutor)? = nil
    ) {
        self.library = library
        self.jobStore = jobStore
        self.transcriptionProviderResolver = transcriptionProviderResolver
        self.diarizationProvider = diarizationProvider
        self.identityEngine = identityEngine
        self.textModelProviderResolver = textModelProviderResolver
        self.locale = locale
        runStore = RunArtifactStore(layout: library.layout)
        templateResultStore = TemplateResultStore(layout: library.layout)
        self.pollInterval = pollInterval
        importedStateAction = importedStateCheckpoint
        mediaCleanupAction = mediaCleanupCheckpoint
        cancellationPersistenceAction = cancellationPersistenceCheckpoint
        self.taskExecutorPreference = taskExecutorPreference
    }

    init(
        library: Library,
        jobStore: JobStore,
        providers: [MediaAsset.Kind: any TranscriptionProvider],
        diarizationProvider: any DiarizationProvider = FluidSortformerProvider(),
        identityEngine: SpeakerSuggestionEngine = SpeakerSuggestionEngine(),
        textModelProviderResolver: @escaping TextModelProviderResolver = { selection in
            if let endpointID = selection.endpointID {
                throw PipelineError.unknownTextModelEndpoint(endpointID)
            }
            return FoundationModelsProvider()
        },
        locale: Locale,
        pollInterval: Duration = .milliseconds(25),
        importedStateCheckpoint: @escaping ImportedPipelineStateAction,
        mediaCleanupCheckpoint: @escaping PipelineMediaCleanupAction = { _ in },
        cancellationPersistenceCheckpoint: @escaping PipelineCancellationPersistenceAction = { _ in },
        taskExecutorPreference: (any TaskExecutor)? = nil
    ) {
        self.init(
            library: library,
            jobStore: jobStore,
            transcriptionProviderResolver: Self.appleOnlyResolver(providers),
            diarizationProvider: diarizationProvider,
            identityEngine: identityEngine,
            textModelProviderResolver: textModelProviderResolver,
            locale: locale,
            pollInterval: pollInterval,
            importedStateCheckpoint: importedStateCheckpoint,
            mediaCleanupCheckpoint: mediaCleanupCheckpoint,
            cancellationPersistenceCheckpoint: cancellationPersistenceCheckpoint,
            taskExecutorPreference: taskExecutorPreference
        )
    }

    private static func appleOnlyResolver(
        _ providers: [MediaAsset.Kind: any TranscriptionProvider]
    ) -> TranscriptionProviderResolver {
        { providerID, assetKind in
            guard providerID == .apple else {
                throw TranscriptionRegistryError.unknownProvider(providerID)
            }
            guard let provider = providers[assetKind] else {
                throw PipelineError.missingProvider(assetKind)
            }
            return provider
        }
    }

    public func start() {
        guard queueTask == nil else { return }
        do {
            try PipelineMediaSnapshotSession.sweepOrphans(
                layout: library.layout,
                cleanupAction: mediaCleanupAction
            )
        } catch {
            runtimeFailure = (error as? PipelineError)
                ?? .persistenceFailure(String(describing: error))
            return
        }
        stopping = false
        queueTask = Task(executorPreference: taskExecutorPreference) { [weak self] in
            await self?.consumeQueue()
        }
    }

    public func stop() async {
        stopping = true
        queueTask?.cancel()
        activeTask?.cancel()
        _ = await activeTask?.result
        _ = await queueTask?.result
        if let activeClaim {
            await jobStore.releaseExecutionLease(activeClaim)
        }
        activeClaim = nil
        activeTask = nil
        activeJobID = nil
        activePhase = nil
        queueTask = nil
    }

    public func cancel(jobID: JobID) async throws {
        while true {
            if activeJobID == jobID {
                guard activePhase != .committing else {
                    throw PipelineError.cancellationTooLate(jobID)
                }
                cancellationRequests.insert(jobID)
                activeTask?.cancel()
                while true {
                    if let runtimeFailure { throw runtimeFailure }
                    guard try await jobStore.load(jobID).status == .running else {
                        return
                    }
                    guard activeJobID == jobID else {
                        let failure = PipelineError.persistenceFailure(
                            "Cancellation handling ended while job \(jobID) remained running."
                        )
                        runtimeFailure = failure
                        throw failure
                    }
                    try await Task.sleep(for: pollInterval)
                }
            }
            guard let job = try await jobStore.cancelIfQueuedOrFailed(jobID) else {
                // A queue claim may have won while this actor was suspended in
                // JobStore. Yield once so consumeQueue can publish its active
                // phase, then make the cancellation decision from fresh state.
                await Task.yield()
                if activeJobID == jobID { continue }
                return
            }
            do {
                try withCurrentMeetingGeneration(for: job) { transaction in
                    try runStore.removeTemporaryArtifacts(
                        for: job,
                        transaction: transaction
                    )
                }
            } catch PipelineError.importedGenerationChanged {
                return
            }
            try await markImportedJobNeedsManualRetry(
                job,
                reason: "Processing was cancelled."
            )
            if job.kind != .templateRender {
                try await settleMeetingStatus(after: job, whenNoActiveJobs: .ready)
            }
            return
        }
    }

    public func waitUntilIdle() async throws {
        while true {
            if let runtimeFailure { throw runtimeFailure }
            let hasUnfinishedWork = try await jobStore.list().contains {
                Self.supportedJobKinds.contains($0.kind)
                    && ($0.status == .queued || $0.status == .running)
            }
            if activeJobID == nil && !hasUnfinishedWork { return }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func consumeQueue() async {
        while !Task.isCancelled {
            do {
                guard let claim = try await claimNextJob() else {
                    try await Task.sleep(for: pollInterval)
                    continue
                }
                activeClaim = claim
                try Task.checkCancellation()
                let job = claim.job
                try importedStateAction(.beforeImportedGenerationValidation(job.id))
                guard try importedGenerationIsCurrent(job) else {
                    await cancelJobForGenerationChange(job)
                    activeClaim = nil
                    continue
                }
                activeJobID = job.id
                activePhase = .processing
                let task = Task(executorPreference: taskExecutorPreference) {
                    try await self.execute(job)
                }
                activeTask = task
                do {
                    try await task.value
                } catch {
                    await handle(error, for: job)
                }
                activeTask = nil
                activeJobID = nil
                activePhase = nil
                if !stopping {
                    activeClaim = nil
                }
            } catch is CancellationError {
                break
            } catch {
                if let activeClaim {
                    await jobStore.releaseExecutionLease(activeClaim)
                    self.activeClaim = nil
                }
                runtimeFailure = .persistenceFailure(String(describing: error))
                break
            }
        }
    }

    private func claimNextJob() async throws -> JobExecutionClaim? {
        for kind in [
            Job.Kind.finalASR,
            .diarization,
            .identitySuggestion,
            .templateRender,
        ] {
            if let claim = try await jobStore.claimNextWithExecutionLease(kind: kind) {
                return claim
            }
        }
        return nil
    }

    private func execute(_ job: Job) async throws {
        switch job.kind {
        case .finalASR:
            try await executeFinalASR(job)
        case .diarization:
            try await executeDiarization(job)
        case .identitySuggestion:
            try await executeIdentitySuggestion(job)
        case .templateRender:
            try await executeTemplateRender(job)
        case .export:
            throw PipelineError.unsupportedJobKind(job.kind)
        }
    }

    private func importedGenerationIsCurrent(_ job: Job) throws -> Bool {
        do {
            return try withCurrentMeetingGeneration(for: job) { _ in true }
        } catch PipelineError.importedGenerationChanged {
            return false
        }
    }

    private func withCurrentMeetingGeneration<Result>(
        for job: Job,
        _ body: (LibraryMutationTransaction) throws -> Result
    ) throws -> Result {
        try LibraryMutationCoordination.withExclusiveTransaction(
            layout: library.layout
        ) { transaction in
            do {
                let meeting = try library.loadMeeting(
                    job.meetingID,
                    transaction: transaction
                )
                let stateStore = MeetingTransferStateStore(layout: library.layout)
                guard try !stateStore.requiresFreshImportRetry(
                    job.meetingID,
                    transaction: transaction
                ), meeting.processingGenerationID
                    == job.processingGenerationID else {
                    throw PipelineError.importedGenerationChanged(job.meetingID)
                }
                return try body(transaction)
            } catch LibraryError.meetingNotFound {
                throw PipelineError.importedGenerationChanged(job.meetingID)
            }
        }
    }

    private func setMeetingStatus(
        _ status: Meeting.Status,
        for job: Job
    ) async throws {
        _ = try withCurrentMeetingGeneration(for: job) { transaction in
            try library.updateMeetingStatus(
                job.meetingID,
                to: status,
                transaction: transaction
            )
        }
        await library.publishMeetingChange(job.meetingID)
    }

    private func executeTemplateRender(_ job: Job) async throws {
        try validateTemplateRenderPins(job)
        guard let templateID = job.templateID else {
            throw PipelineError.missingTemplateID(job.id)
        }
        guard let template = TemplateRenderRequest.template(for: templateID) else {
            throw PipelineError.unknownTemplate(templateID)
        }

        if let committed = try withCurrentMeetingGeneration(for: job, { transaction in
            try runStore.loadCommitted(
                for: job,
                expectedKind: .templateRender,
                artifactFileName: "template.json",
                artifactType: TemplateRenderArtifact.self,
                transaction: transaction,
                validate: {
                    PipelineArtifactValidator.templateRender(
                        $0,
                        expectedJobID: job.id,
                        expectedRunID: self.runStore.runID(for: job),
                        expectedTemplateID: templateID
                    )
                }
            )
        }) {
            guard committed.run.engine == committed.artifact.result.engine else {
                throw PipelineError.invalidRunArtifact(committed.run.id)
            }
            activePhase = .committing
            try withCurrentMeetingGeneration(for: job) { transaction in
                try templateResultStore.persist(
                    committed.artifact.result,
                    runID: committed.run.id,
                    meetingID: job.meetingID,
                    transaction: transaction
                )
            }
            await library.publishMeetingChange(job.meetingID)
            try await finish(job: job)
            return
        }

        let input = try withCurrentMeetingGeneration(for: job) { transaction in
            let input = try TemplateRenderInputAssembler.assemble(
                library: library,
                meetingID: job.meetingID,
                revisionID: job.revisionID,
                transaction: transaction
            )
            if let expectedFingerprint = job.templateRenderInputFingerprint,
               try TemplateRenderInputAssembler.fingerprint(for: input)
                    != expectedFingerprint {
                throw PipelineError.templateRenderInputChanged
            }
            return input
        }
        let textModelProvider = try textModelProviderResolver(
            TextModelProviderSelection(
                endpointID: job.textModelEndpointID,
                endpointSnapshot: job.textModelEndpointSnapshot
            )
        )
        if let message = textModelProvider.availability.unavailabilityMessage {
            throw PipelineError.textModelUnavailable(message)
        }
        let preparedRun = try withCurrentMeetingGeneration(for: job) { transaction in
            let run = ProcessingRun(
                id: runStore.runID(for: job),
                meetingID: job.meetingID,
                kind: .templateRender,
                engine: textModelProvider.descriptor,
                status: .running,
                createdAt: job.createdAt,
                startedAt: Date()
            )
            try runStore.prepare(run, for: job, transaction: transaction)
            return run
        }
        try importedStateAction(.afterTextProviderInputCapture(job.id))
        var run = preparedRun
        try Task.checkCancellation()
        let result = try await textModelProvider.render(
            template: template,
            transcript: input.transcript,
            participants: input.participants,
            context: input.context
        )
        try Task.checkCancellation()

        run.status = .finished
        run.finishedAt = Date()
        let artifact = TemplateRenderArtifact(
            jobID: job.id,
            templateID: templateID,
            result: result
        )
        activePhase = .committing
        try withCurrentMeetingGeneration(for: job) { transaction in
            try runStore.commit(
                run: run,
                artifact: artifact,
                artifactFileName: "template.json",
                for: job,
                transaction: transaction
            )
            try templateResultStore.persist(
                result,
                runID: run.id,
                meetingID: job.meetingID,
                transaction: transaction
            )
        }
        await library.publishMeetingChange(job.meetingID)
        try await finish(job: job)
    }

    private func validateTemplateRenderPins(_ job: Job) throws {
        guard job.textModelEndpointID != nil else { return }
        guard let endpointID = job.textModelEndpointID.flatMap(UUID.init(uuidString:)),
              let fingerprint = job.templateRenderInputFingerprint,
              Self.isSHA256Fingerprint(fingerprint),
              let snapshot = job.textModelEndpointSnapshot,
              snapshot.id == endpointID
        else {
            throw PipelineError.templateRenderPinsRequired
        }
        guard snapshot.configurationRevision != nil else {
            throw PipelineError.textModelEndpointConfigurationIncomplete(snapshot.name)
        }
    }

    private static func isSHA256Fingerprint(_ value: String) -> Bool {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix), value.count == prefix.count + 64 else {
            return false
        }
        return value.dropFirst(prefix.count).allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character)
        }
    }

    private func executeFinalASR(_ job: Job) async throws {
        try await setMeetingStatus(.processing, for: job)
        let effectiveLocale = job.localeIdentifier.map(Locale.init(identifier:)) ?? locale
        let providerID = job.transcriptionProviderID ?? .apple

        if let committed = try withCurrentMeetingGeneration(for: job, { transaction in
            try runStore.loadCommitted(
                for: job,
                expectedKind: .finalASR,
                artifactFileName: "transcript.json",
                artifactType: FinalASRArtifact.self,
                transaction: transaction,
                validate: {
                    PipelineArtifactValidator.finalASR(
                        $0,
                        expectedJobID: job.id,
                        expectedRunID: self.runStore.runID(for: job)
                    )
                }
            )
        }) {
            activePhase = .committing
            try await commitFinalASRRevision(for: job, committed: committed)
            return
        }

        let prepared = try withCurrentMeetingGeneration(for: job) { transaction in
            let assets = try library.listMediaAssets(
                meetingID: job.meetingID,
                transaction: transaction
            )
            guard !assets.isEmpty else {
                throw PipelineError.noMediaAssets(job.meetingID)
            }
            let processableAssets = assets.filter { $0.duration > 0 }
            guard !processableAssets.isEmpty else {
                throw PipelineError.noAudioSamples(job.meetingID)
            }
            let selectedProviders = try processableAssets.map { asset in
                try transcriptionProviderResolver(providerID, asset.kind)
            }
            let descriptor = selectedProviders[0].descriptor
            guard selectedProviders.allSatisfy({ $0.descriptor == descriptor }) else {
                throw PipelineError.inconsistentEngineDescriptors
            }
            let binding = try PipelineMediaBinder.bind(
                assets: processableAssets,
                meetingID: job.meetingID,
                layout: library.layout,
                transaction: transaction,
                cleanupAction: mediaCleanupAction
            )
            let trackProviders = zip(binding.inputs, selectedProviders).map {
                (input: $0.0, provider: $0.1)
            }
            let run = ProcessingRun(
                id: runStore.runID(for: job),
                meetingID: job.meetingID,
                kind: .finalASR,
                engine: descriptor,
                localeIdentifier: effectiveLocale.identifier,
                status: .running,
                createdAt: job.createdAt,
                startedAt: Date()
            )
            do {
                try runStore.prepare(run, for: job, transaction: transaction)
            } catch {
                let operationError = error
                try binding.close(transaction: transaction)
                throw operationError
            }
            return (run: run, trackProviders: trackProviders, binding: binding)
        }
        var run = prepared.run
        let trackProviders = prepared.trackProviders
        let binding = prepared.binding

        var tracks: [FinalASRTrackResult] = []
        var inferenceError: (any Error)?
        do {
            try importedStateAction(.afterImportedGenerationInputBinding(job.id))
            for (input, provider) in trackProviders {
                try Task.checkCancellation()
                let output = try await provider.transcribeFile(
                    input.lease.sourceURL,
                    locale: effectiveLocale
                )
                try input.lease.validate()
                tracks.append(FinalASRTrackResult(
                    assetID: input.asset.id,
                    assetKind: input.asset.kind,
                    output: output
                ))
            }
            try Task.checkCancellation()
        } catch {
            inferenceError = error
        }
        try binding.close()
        if let inferenceError { throw inferenceError }

        run.status = .finished
        run.finishedAt = Date()
        let artifact = FinalASRArtifact(
            jobID: job.id,
            revisionID: StablePipelineIdentifiers.revisionID(for: job),
            tracks: tracks
        )
        activePhase = .committing
        try withCurrentMeetingGeneration(for: job) { transaction in
            try runStore.commit(
                run: run,
                artifact: artifact,
                artifactFileName: "transcript.json",
                for: job,
                transaction: transaction
            )
        }
        try await commitFinalASRRevision(
            for: job,
            committed: CommittedRun(run: run, artifact: artifact)
        )
    }

    private func commitFinalASRRevision(
        for job: Job,
        committed: CommittedRun<FinalASRArtifact>
    ) async throws {
        let mapped = TranscriptMapper.revision(
            from: committed.artifact.tracks.map(\.output),
            meetingID: job.meetingID,
            origin: .finalRun(committed.run.id),
            createdAt: committed.run.finishedAt ?? committed.run.createdAt
        )
        let revision = TranscriptRevision(
            id: committed.artifact.revisionID,
            meetingID: mapped.meetingID,
            createdAt: mapped.createdAt,
            origin: mapped.origin,
            turns: mapped.turns
        )
        try await appendRevisionIfNeeded(
            for: job,
            revision,
            runID: committed.run.id
        )
        try await enqueueDownstreamJob(
            after: job,
            kind: .diarization,
            sourceRunID: committed.run.id
        )
        try await finish(job: job)
    }

    private func executeDiarization(_ job: Job) async throws {
        try await setMeetingStatus(.processing, for: job)
        let source = try loadFinalASRSource(for: job)

        if let committed = try withCurrentMeetingGeneration(for: job, { transaction in
            try runStore.loadCommitted(
                for: job,
                expectedKind: .diarization,
                artifactFileName: "diarization.json",
                artifactType: DiarizationArtifact.self,
                transaction: transaction,
                validate: {
                    PipelineArtifactValidator.diarization(
                        $0,
                        expectedJobID: job.id,
                        expectedRunID: self.runStore.runID(for: job),
                        expectedSourceRunID: source.run.id
                    )
                }
            )
        }) {
            activePhase = .committing
            try await commitDiarizationRevision(
                for: job,
                committed: committed,
                source: source.artifact
            )
            return
        }

        let prepared = try withCurrentMeetingGeneration(for: job) { transaction in
            let assets = try library.listMediaAssets(
                meetingID: job.meetingID,
                transaction: transaction
            )
            let binding = try PipelineMediaBinder.bind(
                assets: assets,
                meetingID: job.meetingID,
                layout: library.layout,
                transaction: transaction,
                cleanupAction: mediaCleanupAction
            )
            let assetsByID = Dictionary(uniqueKeysWithValues: binding.inputs.map {
                ($0.asset.id, $0)
            })
            let run = ProcessingRun(
                id: runStore.runID(for: job),
                meetingID: job.meetingID,
                kind: .diarization,
                engine: diarizationProvider.descriptor,
                status: .running,
                createdAt: job.createdAt,
                startedAt: Date()
            )
            do {
                try runStore.prepare(run, for: job, transaction: transaction)
            } catch {
                let operationError = error
                try binding.close(transaction: transaction)
                throw operationError
            }
            return (run: run, assetsByID: assetsByID, binding: binding)
        }
        var run = prepared.run
        let assetsByID = prepared.assetsByID
        let binding = prepared.binding

        var tracks: [DiarizationTrackResult] = []
        var inferenceError: (any Error)?
        do {
            for sourceTrack in source.artifact.tracks {
                try Task.checkCancellation()
                guard let input = assetsByID[sourceTrack.assetID],
                      input.asset.kind == sourceTrack.assetKind else {
                    throw PipelineError.missingSourceMediaAsset(sourceTrack.assetID)
                }
                let output = try await diarizationProvider.diarize(
                    input.lease.sourceURL,
                    hints: DiarizationHints()
                )
                try input.lease.validate()
                tracks.append(makeDiarizationTrack(asset: input.asset, output: output))
            }
            try Task.checkCancellation()
        } catch {
            inferenceError = error
        }
        try binding.close()
        if let inferenceError { throw inferenceError }

        run.status = .finished
        run.finishedAt = Date()
        let artifact = DiarizationArtifact(
            jobID: job.id,
            sourceRunID: source.run.id,
            revisionID: StablePipelineIdentifiers.revisionID(for: job),
            tracks: tracks
        )
        activePhase = .committing
        try withCurrentMeetingGeneration(for: job) { transaction in
            try runStore.commit(
                run: run,
                artifact: artifact,
                artifactFileName: "diarization.json",
                for: job,
                transaction: transaction
            )
        }
        try await commitDiarizationRevision(
            for: job,
            committed: CommittedRun(run: run, artifact: artifact),
            source: source.artifact
        )
    }

    private func loadFinalASRSource(
        for job: Job
    ) throws -> CommittedRun<FinalASRArtifact> {
        guard let sourceRunID = job.sourceRunID else {
            throw PipelineError.missingSourceRun(job.id)
        }
        guard let source = try withCurrentMeetingGeneration(for: job, { transaction in
            try runStore.loadFinished(
                runID: sourceRunID,
                meetingID: job.meetingID,
                expectedKind: .finalASR,
                artifactFileName: "transcript.json",
                artifactType: FinalASRArtifact.self,
                transaction: transaction,
                validate: { artifact in
                    PipelineArtifactValidator.finalASR(
                        artifact,
                        expectedJobID: artifact.jobID,
                        expectedRunID: sourceRunID
                    )
                }
            )
        }) else {
            throw PipelineError.missingSourceArtifact(sourceRunID)
        }
        return source
    }

    private func makeDiarizationTrack(
        asset: MediaAsset,
        output: DiarizationOutput
    ) -> DiarizationTrackResult {
        let namespace = "\(asset.id)/"
        let namespacedSegments = output.segments.map {
            DiarizationAlignmentSegment(
                clusterID: namespace + $0.clusterID,
                start: $0.start,
                end: $0.end
            )
        }
        let normalized = TranscriptDiarizationAligner.normalizedSegments(namespacedSegments)
        let grouped = Dictionary(grouping: normalized, by: \.clusterID)
        let clusters = grouped.map { clusterID, segments in
            let rawClusterID = String(clusterID.dropFirst(namespace.count))
            return DiarizationClusterResult(
                clusterID: clusterID,
                embedding: output.embeddings[rawClusterID] ?? [],
                speechDurationSeconds: segments.reduce(0) {
                    $0 + max(0, $1.end - $1.start)
                },
                segmentCount: segments.count
            )
        }.sorted { $0.clusterID < $1.clusterID }
        return DiarizationTrackResult(
            assetID: asset.id,
            assetKind: asset.kind,
            engine: output.engine,
            segments: normalized.map {
                DiarizationRunSegment(
                    clusterID: $0.clusterID,
                    start: $0.start,
                    end: $0.end
                )
            },
            clusters: clusters
        )
    }

    private func commitDiarizationRevision(
        for job: Job,
        committed: CommittedRun<DiarizationArtifact>,
        source: FinalASRArtifact
    ) async throws {
        let diarizationByAsset = Dictionary(
            uniqueKeysWithValues: committed.artifact.tracks.map { ($0.assetID, $0) }
        )
        var orderedTurns: [(trackOffset: Int, turnOffset: Int, turn: TranscriptTurn)] = []
        for (trackOffset, sourceTrack) in source.tracks.enumerated() {
            guard let diarization = diarizationByAsset[sourceTrack.assetID] else {
                throw PipelineError.missingDiarizationTrack(sourceTrack.assetID)
            }
            let segments = diarization.segments.map {
                DiarizationAlignmentSegment(
                    clusterID: $0.clusterID,
                    start: $0.start,
                    end: $0.end
                )
            }
            let turns = TranscriptDiarizationAligner.align(
                sourceTrack.output,
                to: segments,
                runID: committed.run.id
            )
            orderedTurns.append(contentsOf: turns.enumerated().map {
                (trackOffset, $0.offset, $0.element)
            })
        }
        let turns = orderedTurns.sorted { lhs, rhs in
            if lhs.turn.start != rhs.turn.start { return lhs.turn.start < rhs.turn.start }
            if lhs.trackOffset != rhs.trackOffset { return lhs.trackOffset < rhs.trackOffset }
            return lhs.turnOffset < rhs.turnOffset
        }.map(\.turn)
        let revision = TranscriptRevision(
            id: committed.artifact.revisionID,
            meetingID: job.meetingID,
            createdAt: committed.run.finishedAt ?? committed.run.createdAt,
            origin: .finalRun(committed.run.id),
            turns: turns
        )
        try await appendRevisionIfNeeded(
            for: job,
            revision,
            runID: committed.run.id
        )
        try await enqueueDownstreamJob(
            after: job,
            kind: .identitySuggestion,
            sourceRunID: committed.run.id
        )
        try await finish(job: job)
    }

    private func executeIdentitySuggestion(_ job: Job) async throws {
        try await setMeetingStatus(.processing, for: job)
        let source = try loadDiarizationSource(for: job)

        if try withCurrentMeetingGeneration(for: job, { transaction in
            try runStore.loadCommitted(
                for: job,
                expectedKind: .identitySuggestion,
                artifactFileName: "suggestions.json",
                artifactType: IdentitySuggestionArtifact.self,
                transaction: transaction,
                validate: {
                    PipelineArtifactValidator.identitySuggestion(
                        $0,
                        expectedJobID: job.id,
                        expectedRunID: self.runStore.runID(for: job),
                        expectedSourceRunID: source.run.id
                    )
                }
            )
        }) != nil {
            activePhase = .committing
            try await finish(job: job)
            return
        }

        var run = ProcessingRun(
            id: runStore.runID(for: job),
            meetingID: job.meetingID,
            kind: .identitySuggestion,
            engine: identityEngineDescriptor,
            status: .running,
            createdAt: job.createdAt,
            startedAt: Date()
        )
        try withCurrentMeetingGeneration(for: job) { transaction in
            try runStore.prepare(run, for: job, transaction: transaction)
        }
        try Task.checkCancellation()
        let clusters = StenoPipeline.identityClusters(
            from: source.artifact,
            meetingID: job.meetingID,
            runID: source.run.id
        )
        let mergeResult = identityEngine.mergeSameChannelFragments(clusters)
        let people = try await IdentityStore(layout: library.layout).listPersons()
        let suggestions = identityEngine.suggestions(
            for: mergeResult.clusters,
            people: people
        )
        let resolutions = mergeResult.resolution.map { source, primary in
            IdentityClusterResolution(
                channel: source.channel,
                sourceClusterID: source.clusterID,
                primaryClusterID: primary.clusterID
            )
        }.sorted {
            if $0.channel != $1.channel { return $0.channel < $1.channel }
            return $0.sourceClusterID < $1.sourceClusterID
        }
        try Task.checkCancellation()

        run.status = .finished
        run.finishedAt = Date()
        let artifact = IdentitySuggestionArtifact(
            jobID: job.id,
            sourceRunID: source.run.id,
            clusterResolutions: resolutions,
            identityEvidenceFingerprint: try identityEvidenceFingerprint(people),
            suggestions: suggestions
        )
        activePhase = .committing
        try withCurrentMeetingGeneration(for: job) { transaction in
            try runStore.commit(
                run: run,
                artifact: artifact,
                artifactFileName: "suggestions.json",
                for: job,
                transaction: transaction
            )
        }
        try await finish(job: job)
    }

    private func loadDiarizationSource(
        for job: Job
    ) throws -> CommittedRun<DiarizationArtifact> {
        guard let sourceRunID = job.sourceRunID else {
            throw PipelineError.missingSourceRun(job.id)
        }
        guard let source = try withCurrentMeetingGeneration(for: job, { transaction in
            try runStore.loadFinished(
                runID: sourceRunID,
                meetingID: job.meetingID,
                expectedKind: .diarization,
                artifactFileName: "diarization.json",
                artifactType: DiarizationArtifact.self,
                transaction: transaction,
                validate: { artifact in
                    PipelineArtifactValidator.diarization(
                        artifact,
                        expectedJobID: artifact.jobID,
                        expectedRunID: sourceRunID,
                        expectedSourceRunID: artifact.sourceRunID
                    )
                }
            )
        }) else {
            throw PipelineError.missingSourceArtifact(sourceRunID)
        }
        return source
    }

    private func identityEvidenceFingerprint(_ people: [Person]) throws -> String {
        let ordered = people.sorted { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(ordered))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func appendRevisionIfNeeded(
        for job: Job,
        _ revision: TranscriptRevision,
        runID: RunID
    ) async throws {
        try withCurrentMeetingGeneration(for: job) { transaction in
            let revisionURL = library.layout.revision(
                revision.meetingID,
                revisionID: revision.id
            )
            if FileManager.default.fileExists(atPath: revisionURL.path) {
                let existing = try library.loadRevision(
                    revision.id,
                    meetingID: revision.meetingID,
                    transaction: transaction
                )
                guard existing == revision else {
                    throw PipelineError.invalidRunArtifact(runID)
                }
            } else {
                _ = try library.appendRevision(revision, transaction: transaction)
            }
        }
    }

    private func enqueueDownstreamJob(
        after job: Job,
        kind: Job.Kind,
        sourceRunID: RunID
    ) async throws {
        let downstream = Job(
            id: StablePipelineIdentifiers.downstreamJobID(after: job.id, kind: kind),
            kind: kind,
            meetingID: job.meetingID,
            sourceRunID: sourceRunID,
            importGenerationID: job.processingGenerationID,
            createdAt: Date()
        )
        try withCurrentMeetingGeneration(for: job) { transaction in
            if FileManager.default.fileExists(
                atPath: jobStore.layout.job(downstream.id).path
            ) {
                let existing = try jobStore.load(
                    downstream.id,
                    transaction: transaction
                )
                guard existing.kind == downstream.kind,
                      existing.meetingID == downstream.meetingID,
                      existing.sourceRunID == downstream.sourceRunID,
                      existing.processingGenerationID
                        == downstream.processingGenerationID else {
                    throw PipelineError.invalidDownstreamJob(existing.id)
                }
                return
            }
            _ = try jobStore.ensureEnqueued(
                downstream,
                transaction: transaction
            )
        }
    }

    private func finish(job: Job) async throws {
        let meetingChanged = try LibraryMutationCoordination.withExclusiveTransaction(
            layout: library.layout
        ) { transaction in
            let meeting = try library.loadMeeting(
                job.meetingID,
                transaction: transaction
            )
            guard meeting.processingGenerationID == job.processingGenerationID else {
                throw PipelineError.importedGenerationChanged(job.meetingID)
            }
            let jobs = try jobStore.list(transaction: transaction)
            let targetStatus = job.kind == .templateRender ? nil
                : PipelineCompletionPolicy.meetingStatus(
                    after: job,
                    jobs: jobs,
                    whenNoActiveJobs: .ready
                )
            let changed = targetStatus != nil && meeting.status != targetStatus
            if let targetStatus {
                _ = try library.updateMeetingStatus(
                    job.meetingID,
                    to: targetStatus,
                    transaction: transaction
                )
            }
            _ = try jobStore.transition(
                job.id,
                to: .finished,
                transaction: transaction
            )
            return changed
        }
        if let activeClaim, activeClaim.job.id == job.id {
            await jobStore.releaseExecutionLease(activeClaim)
        }
        if meetingChanged {
            await library.publishMeetingChange(job.meetingID)
        }
    }

    private func settleMeetingStatus(
        after job: Job,
        whenNoActiveJobs status: Meeting.Status
    ) async throws {
        let jobs = try await jobStore.list()
        guard let status = PipelineCompletionPolicy.meetingStatus(
            after: job,
            jobs: jobs,
            whenNoActiveJobs: status
        ) else { return }
        try await setMeetingStatus(status, for: job)
    }

    private func handle(_ error: any Error, for job: Job) async {
        if case PipelineError.importedGenerationChanged = error {
            await cancelJobForGenerationChange(job)
            return
        }
        if error is CancellationError {
            if cancellationRequests.remove(job.id) != nil {
                do {
                    try cancellationPersistenceAction(
                        .beforeRemoveTemporaryArtifacts(job.id)
                    )
                    try withCurrentMeetingGeneration(for: job) { transaction in
                        try runStore.removeTemporaryArtifacts(
                            for: job,
                            transaction: transaction
                        )
                    }
                    await library.publishMeetingChange(job.meetingID)
                    _ = try await jobStore.transition(job.id, to: .cancelled)
                    try await markImportedJobNeedsManualRetry(
                        job,
                        reason: "Processing was cancelled."
                    )
                    if job.kind != .templateRender {
                        try await settleMeetingStatus(after: job, whenNoActiveJobs: .ready)
                    }
                } catch PipelineError.importedGenerationChanged {
                    await cancelJobForGenerationChange(job)
                } catch {
                    let cancellationFailure = PipelineError.persistenceFailure(
                        String(describing: error)
                    )
                    await persistFailure(error, for: job)
                    if runtimeFailure == nil {
                        runtimeFailure = cancellationFailure
                    }
                }
            } else {
                await persistFailure(error, for: job)
            }
            return
        }
        await persistFailure(error, for: job)
    }

    private func persistFailure(_ error: any Error, for job: Job) async {
        do {
            guard try importedGenerationIsCurrent(job) else {
                await cancelJobForGenerationChange(job)
                return
            }
        } catch {
            runtimeFailure = .persistenceFailure(String(describing: error))
            return
        }
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        let runID = runStore.runID(for: job)
        var failedRun = ProcessingRun(
            id: runID,
            meetingID: job.meetingID,
            kind: processingRunKind(for: job.kind),
            engine: defaultEngineDescriptor(for: job),
            localeIdentifier: job.kind == .finalASR
                ? (job.localeIdentifier ?? locale.identifier)
                : nil,
            status: .failed,
            createdAt: job.createdAt,
            startedAt: Date(),
            finishedAt: Date(),
            errorMessage: message,
            textModelDiagnostic: (error as? any TextModelDiagnosticProviding)?
                .textModelDiagnostic
        )
        if let data = try? Data(contentsOf: runStore.temporaryDirectory(for: job)
            .appendingPathComponent("run.json")),
           let running = try? JSONDecoder().decode(ProcessingRun.self, from: data) {
            failedRun = running
            failedRun.status = .failed
            failedRun.finishedAt = Date()
            failedRun.errorMessage = message
            failedRun.textModelDiagnostic = (error as? any TextModelDiagnosticProviding)?
                .textModelDiagnostic
        }
        var persistenceErrors: [String] = []
        do {
            try withCurrentMeetingGeneration(for: job) { transaction in
                let temporary = runStore.temporaryDirectory(for: job)
                if !FileManager.default.fileExists(atPath: temporary.path) {
                    try runStore.prepare(
                        failedRun,
                        for: job,
                        transaction: transaction
                    )
                }
                try runStore.commitFailure(
                    run: failedRun,
                    for: job,
                    transaction: transaction
                )
            }
            await library.publishMeetingChange(job.meetingID)
        } catch PipelineError.importedGenerationChanged {
            await cancelJobForGenerationChange(job)
            return
        } catch {
            persistenceErrors.append("run: \(error)")
        }
        if job.kind != .templateRender {
            do {
                let hasAssets = try withCurrentMeetingGeneration(for: job) { transaction in
                    try !library.listMediaAssets(
                        meetingID: job.meetingID,
                        transaction: transaction
                    ).isEmpty
                }
                try await settleMeetingStatus(
                    after: job,
                    whenNoActiveJobs: hasAssets ? .ready : .interrupted
                )
            } catch PipelineError.importedGenerationChanged {
                await cancelJobForGenerationChange(job)
                return
            } catch {
                persistenceErrors.append("meeting: \(error)")
            }
        }
        do {
            _ = try await jobStore.transition(
                job.id,
                to: .failed,
                errorMessage: message,
                failureReason: failureReason(for: error, job: job)
            )
            try await markImportedJobNeedsManualRetry(
                job,
                reason: "Processing failed."
            )
        } catch PipelineError.importedGenerationChanged {
            await cancelJobForGenerationChange(job)
            return
        } catch {
            persistenceErrors.append("job: \(error)")
        }
        if !persistenceErrors.isEmpty {
            runtimeFailure = .persistenceFailure(persistenceErrors.joined(separator: "; "))
        }
    }

    private func failureReason(
        for error: any Error,
        job: Job
    ) -> Job.FailureReason? {
        if job.kind == .templateRender,
           case PipelineError.templateRenderInputChanged = error {
            return .templateRenderInputChanged
        }
        if job.kind == .templateRender,
           case PipelineError.templateRenderPinsRequired = error {
            return .templateRenderPinsRequired
        }
        if job.kind == .templateRender,
           case PipelineError.textModelEndpointConfigurationIncomplete = error {
            return .textModelEndpointConfigurationIncomplete
        }
        if job.kind == .diarization,
           let diarizationError = error as? DiarizationError,
           case .modelsNotInstalled = diarizationError {
            return .diarizationModelsNotInstalled
        }
        return nil
    }

    private func cancelJobForGenerationChange(_ job: Job) async {
        do {
            let current = try await jobStore.load(job.id)
            guard current.status == .queued
                    || current.status == .running
                    || current.status == .failed else { return }
            _ = try await jobStore.transition(
                job.id,
                to: .cancelled,
                errorMessage: "Imported meeting generation changed."
            )
        } catch {
            runtimeFailure = .persistenceFailure(String(describing: error))
        }
    }

    private func markImportedJobNeedsManualRetry(
        _ job: Job,
        reason: String
    ) async throws {
        guard job.kind == .finalASR,
              let localeIdentifier = job.localeIdentifier else { return }
        let stateStore = MeetingTransferStateStore(layout: library.layout)
        try importedStateAction(.beforeManualRetryTransition(job.id))
        try withCurrentMeetingGeneration(for: job) { transaction in
            guard let state = try stateStore.load(
                job.meetingID,
                transaction: transaction
            ), case .jobEnqueued(let stateJobID, let stateLocale) = state,
                stateJobID == job.id,
                stateLocale == localeIdentifier else { return }
            _ = try stateStore.compareAndSet(
                expected: state,
                newState: .needsManualRetry(
                    jobID: job.id,
                    localeIdentifier: localeIdentifier,
                    reason: reason
                ),
                for: job.meetingID,
                transaction: transaction
            )
        }
    }

    private func processingRunKind(for kind: Job.Kind) -> ProcessingRun.Kind {
        switch kind {
        case .finalASR: .finalASR
        case .diarization: .diarization
        case .identitySuggestion: .identitySuggestion
        case .templateRender: .templateRender
        case .export: .export
        }
    }

    private func defaultEngineDescriptor(for job: Job) -> EngineDescriptor {
        switch job.kind {
        case .finalASR:
            let providerID = job.transcriptionProviderID ?? .apple
            for assetKind in [MediaAsset.Kind.micTrack, .systemTrack, .imported] {
                if let descriptor = try? transcriptionProviderResolver(
                    providerID,
                    assetKind
                ).descriptor {
                    return descriptor
                }
            }
            return EngineDescriptor(name: "StenoPipeline", version: "1")
        case .diarization:
            return diarizationProvider.descriptor
        case .identitySuggestion:
            return identityEngineDescriptor
        case .templateRender:
            if job.textModelEndpointID == nil {
                return FoundationModelsProvider().descriptor
            }
            return EngineDescriptor(name: "TextModelProvider", version: "unresolved")
        case .export:
            return EngineDescriptor(name: "StenoPipeline", version: "1")
        }
    }

    private var identityEngineDescriptor: EngineDescriptor {
        EngineDescriptor(
            name: "StenoIdentity SpeakerSuggestionEngine",
            version: "1"
        )
    }
}
