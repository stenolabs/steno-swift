import Foundation
import StenoDiarization
import StenoDomain
import StenoLibrary
import StenoPipeline
import StenoTranscription
import Synchronization
import Testing
@testable import Steno

@Suite("iOS model job recovery")
struct AppModelModelRecoveryTests {
    @Test("bootstrap requeues missing speech model jobs when the model is installed")
    @MainActor
    func bootstrapRequeuesInstalledSpeechModelFailure() async throws {
        let fixture = try ModelRecoveryFixture(speechModelInstalled: true)
        defer { fixture.cleanUp() }
        let job = try await fixture.enqueueMissingSpeechModelJob()

        await fixture.model.bootstrap()

        let runtime = try #require(fixture.model.runtime)
        #expect(try await runtime.jobStore.load(job.id).status == .queued)
    }

    @Test("bootstrap leaves missing speech model jobs failed while the model is absent")
    @MainActor
    func bootstrapLeavesMissingSpeechModelFailureAlone() async throws {
        let fixture = try ModelRecoveryFixture(speechModelInstalled: false)
        defer { fixture.cleanUp() }
        let job = try await fixture.enqueueMissingSpeechModelJob()

        await fixture.model.bootstrap()

        let runtime = try #require(fixture.model.runtime)
        let unchanged = try await runtime.jobStore.load(job.id)
        #expect(unchanged.status == .failed)
        #expect(unchanged.attemptCount == 1)
    }

    @Test("recording idle executes a deferred speech model requeue")
    @MainActor
    func recordingIdleRequeuesDeferredSpeechFailure() async throws {
        let fixture = try ModelRecoveryFixture(speechModelInstalled: false)
        defer { fixture.cleanUp() }
        await fixture.model.bootstrap()
        let runtime = try #require(fixture.model.runtime)
        let job = try await fixture.enqueueMissingSpeechModelJob(in: runtime)

        fixture.model.scheduleModelJobRecoveryAfterRecording(
            .speech(locale: fixture.locale)
        )
        await fixture.model.recordingDidBecomeIdle()

        let restarted = try #require(fixture.model.runtime)
        #expect(try await restarted.jobStore.load(job.id).status == .queued)
    }

    @Test("recording idle executes a deferred diarization model requeue")
    @MainActor
    func recordingIdleRequeuesDeferredDiarizationFailure() async throws {
        let fixture = try ModelRecoveryFixture(speechModelInstalled: false)
        defer { fixture.cleanUp() }
        await fixture.model.bootstrap()
        let runtime = try #require(fixture.model.runtime)
        let meeting = try await runtime.library.createMeeting(
            title: "Missing speaker separation",
            status: .ready
        )
        let job = Job(
            kind: .diarization,
            meetingID: meeting.id,
            status: .failed,
            failureReason: .diarizationModelsNotInstalled
        )
        try await runtime.jobStore.enqueue(job)

        fixture.model.scheduleModelJobRecoveryAfterRecording(.diarization)
        await fixture.model.recordingDidBecomeIdle()

        let restarted = try #require(fixture.model.runtime)
        #expect(try await restarted.jobStore.load(job.id).status == .queued)
    }

    @Test("a speaker model download does not block a recording start")
    @MainActor
    func recordingStartsDuringDiarizationDownload() async throws {
        let installer = SuspendedModelInstaller()
        let starts = Mutex(0)
        let fixture = try ModelRecoveryFixture(
            speechModelInstalled: false,
            diarizationInstaller: installer,
            recordingStarter: { _, _, _ in
                starts.withLock { $0 += 1 }
            }
        )
        defer { fixture.cleanUp() }
        await fixture.model.bootstrap()

        let install = Task { await fixture.model.allowAndInstallDiarizationModels() }
        await installer.waitUntilStarted()

        #expect(fixture.model.canStartRecording)
        #expect(await fixture.model.startRecording())
        #expect(starts.withLock { $0 } == 1)

        await installer.finish()
        await install.value
    }
}

@MainActor
private struct ModelRecoveryFixture {
    let root: URL
    let model: AppModel
    private let defaults: UserDefaults
    private let suite: String

    var locale: Locale { model.language.locale }

    init(
        speechModelInstalled: Bool,
        diarizationInstaller: (any ModelInstalling)? = nil,
        recordingStarter: @escaping @MainActor @Sendable (
            RecordingModel,
            Locale,
            Bool
        ) async -> Void = { _, _, _ in }
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "Steno-ModelRecoveryTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        suite = "ModelRecoveryTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        let speechState = IOSModelInstallationState(
            coordinator: ModelInstallationCoordinator(installers: [
                SpeechAssetInstaller(
                    assets: StaticSpeechAssets(installed: speechModelInstalled)
                ),
            ]),
            consent: ModelConsent(defaults: defaults, key: "speech-consent")
        )
        let diarizationState = IOSModelInstallationState(
            coordinator: ModelInstallationCoordinator(installers: [
                diarizationInstaller ?? StaticModelInstaller(installed: false),
            ]),
            consent: ModelConsent(defaults: defaults, key: "diarization-consent")
        )
        model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, pipelineLocale, _ in
                try Self.makeRuntime(at: libraryRoot, locale: pipelineLocale)
            },
            recordingStarter: recordingStarter,
            speechModels: speechState,
            diarizationModels: diarizationState,
            libraryURL: root
        )
    }

    func enqueueMissingSpeechModelJob() async throws -> Job {
        let runtime = try Self.makeRuntime(at: root, locale: locale)
        return try await enqueueMissingSpeechModelJob(in: runtime)
    }

    func enqueueMissingSpeechModelJob(in runtime: PipelineRuntime) async throws -> Job {
        let meeting = try await runtime.library.createMeeting(
            title: "Missing transcript",
            status: .ready
        )
        let job = Job(
            kind: .finalASR,
            meetingID: meeting.id,
            localeIdentifier: locale.identifier,
            status: .failed,
            attemptCount: 1,
            errorMessage: TranscriptionError.assetsNotInstalled(
                localeIdentifier: locale.identifier
            ).localizedDescription
        )
        try await runtime.jobStore.enqueue(job)
        return job
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeRuntime(at root: URL, locale: Locale) throws -> PipelineRuntime {
        let library = try Library.open(at: root)
        let jobStore = try JobStore(layout: library.layout)
        return PipelineRuntime(
            library: library,
            jobStore: jobStore,
            coordinator: PipelineCoordinator(
                library: library,
                jobStore: jobStore,
                providers: [:],
                locale: locale
            )
        )
    }
}

private actor StaticSpeechAssets: SpeechAssetGateway {
    let installed: Bool

    init(installed: Bool) {
        self.installed = installed
    }

    func isInstalled(locale: Locale) -> Bool {
        installed
    }

    func install(
        locale: Locale,
        progress: @Sendable @escaping (Double) -> Void
    ) {}
}

private actor StaticModelInstaller: ModelInstalling {
    nonisolated let bundleDescription = ModelBundleDescription(
        title: "Speaker separation",
        source: .huggingFace,
        approximateBytes: 1
    )
    let installed: Bool

    init(installed: Bool) {
        self.installed = installed
    }

    func readiness(for locales: [Locale]) -> ModelReadiness {
        installed
            ? ModelReadiness(installed: Set(locales), missing: [:])
            : ModelReadiness(
                installed: [],
                missing: Dictionary(uniqueKeysWithValues: locales.map {
                    ($0, [bundleDescription.title])
                })
            )
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) {}

    func cancelInstall() {}
}

private actor SuspendedModelInstaller: ModelInstalling {
    nonisolated let bundleDescription = ModelBundleDescription(
        title: "Speaker separation",
        source: .huggingFace,
        approximateBytes: 1
    )
    private var installed = false
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func readiness(for locales: [Locale]) -> ModelReadiness {
        installed
            ? ModelReadiness(installed: Set(locales), missing: [:])
            : ModelReadiness(
                installed: [],
                missing: Dictionary(uniqueKeysWithValues: locales.map {
                    ($0, [bundleDescription.title])
                })
            )
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async {
        started = true
        await withCheckedContinuation { continuation = $0 }
        installed = true
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }

    func cancelInstall() {
        finish()
    }
}
