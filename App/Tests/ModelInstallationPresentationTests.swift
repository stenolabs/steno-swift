import Foundation
import StenoDomain
import StenoPipeline
import Testing
@testable import steno_macos

@Suite("Mac model installation presentation", .serialized)
struct ModelInstallationPresentationTests {
    @Test("install progress is indeterminate until the first real callback")
    @MainActor
    func progressStartsIndeterminate() {
        #expect(
            MacModelInstallProgressPresentation.make(
                isInstalling: false,
                cancellationState: .idle,
                progress: nil
            ) == nil
        )
        #expect(
            MacModelInstallProgressPresentation.make(
                isInstalling: true,
                cancellationState: .idle,
                progress: nil
            ) == .indeterminate(title: "Preparing")
        )
        #expect(
            MacModelInstallProgressPresentation.make(
                isInstalling: true,
                cancellationState: .idle,
                progress: ModelInstallProgress(fraction: .nan, title: "Downloading")
            ) == .indeterminate(title: "Preparing")
        )
    }

    @Test("real install progress is determinate and clamped")
    @MainActor
    func realProgressIsClamped() {
        #expect(
            MacModelInstallProgressPresentation.make(
                isInstalling: true,
                cancellationState: .idle,
                progress: ModelInstallProgress(fraction: 0.4, title: "Downloading")
            ) == .determinate(title: "Downloading", fraction: 0.4)
        )
        #expect(
            MacModelInstallProgressPresentation.make(
                isInstalling: true,
                cancellationState: .idle,
                progress: ModelInstallProgress(fraction: 1.4, title: "Downloading")
            ) == .determinate(title: "Downloading", fraction: 1)
        )
        #expect(
            MacModelInstallProgressPresentation.make(
                isInstalling: true,
                cancellationState: .idle,
                progress: ModelInstallProgress(fraction: -0.4, title: "Downloading")
            ) == .determinate(title: "Downloading", fraction: 0)
        )
    }

    @Test("cancelling replaces progress with a localizable indeterminate phase")
    @MainActor
    func cancellingPresentationIsLocalized() {
        let presentation = MacModelInstallProgressPresentation.make(
            isInstalling: true,
            cancellationState: .cancelling,
            progress: ModelInstallProgress(fraction: 0.7, title: "Downloading")
        )
        guard case .indeterminate(let title) = presentation else {
            Issue.record("Expected an indeterminate cancellation phase")
            return
        }
        var localizedTitle: LocalizedStringResource = title
        localizedTitle.locale = Locale(identifier: "en")
        #expect(String(localized: localizedTitle) == "Cancelling")
        localizedTitle.locale = Locale(identifier: "de")
        #expect(String(localized: localizedTitle) == "Wird abgebrochen")
    }

    @Test("verified ready models expose no contradictory install action")
    @MainActor
    func readyModelsHideInstallAction() {
        #expect(
            MacModelInstallActionPresentation.make(
                isReady: true,
                isActiveInstallation: false,
                cancellationState: .idle,
                installTitle: "Allow and install"
            ) == nil
        )
        #expect(
            MacModelInstallActionPresentation.make(
                isReady: false,
                isActiveInstallation: false,
                cancellationState: .idle,
                installTitle: "Allow and install"
            ) == .install(title: "Allow and install")
        )
        #expect(
            MacModelInstallActionPresentation.make(
                isReady: false,
                isInstallingAny: true,
                isActiveInstallation: true,
                cancellationState: .idle,
                installTitle: "Allow and install"
            ) == .cancel(title: "Cancel")
        )
        #expect(
            MacModelInstallActionPresentation.make(
                isReady: false,
                isInstallingAny: true,
                isActiveInstallation: true,
                cancellationState: .cancelling,
                installTitle: "Allow and install"
            ) == .cancelling(title: "Cancelling")
        )
    }

    @Test("meeting transfer presents only its active baseline installation")
    @MainActor
    func meetingTransferTracksBaselineInstallation() {
        let idle = MacMeetingTransferModelInstallationPresentation.make(
            canInstall: true,
            isInstallingAny: false,
            isInstallingBaseline: false,
            showsCancellationAction: false,
            cancellationState: .idle,
            progress: nil
        )
        #expect(idle.progress == nil)
        #expect(idle.action == .install(title: "Install model and process"))

        let preparing = MacMeetingTransferModelInstallationPresentation.make(
            canInstall: false,
            isInstallingAny: true,
            isInstallingBaseline: true,
            showsCancellationAction: true,
            cancellationState: .idle,
            progress: nil
        )
        #expect(preparing.progress == .indeterminate(title: "Preparing"))
        #expect(preparing.action == .cancel(title: "Cancel"))

        let downloading = MacMeetingTransferModelInstallationPresentation.make(
            canInstall: false,
            isInstallingAny: true,
            isInstallingBaseline: true,
            showsCancellationAction: true,
            cancellationState: .idle,
            progress: ModelInstallProgress(fraction: 0.4, title: "Downloading")
        )
        #expect(
            downloading.progress
                == .determinate(title: "Downloading", fraction: 0.4)
        )

        let cancelling = MacMeetingTransferModelInstallationPresentation.make(
            canInstall: false,
            isInstallingAny: true,
            isInstallingBaseline: true,
            showsCancellationAction: true,
            cancellationState: .cancelling,
            progress: ModelInstallProgress(fraction: 0.4, title: "Downloading")
        )
        #expect(cancelling.progress == .indeterminate(title: "Cancelling"))
        #expect(cancelling.action == .cancelling(title: "Cancelling"))

        let unrelatedInstallation = MacMeetingTransferModelInstallationPresentation.make(
            canInstall: true,
            isInstallingAny: true,
            isInstallingBaseline: false,
            showsCancellationAction: true,
            cancellationState: .idle,
            progress: ModelInstallProgress(fraction: 0.4, title: "Downloading")
        )
        #expect(unrelatedInstallation.progress == nil)
        #expect(unrelatedInstallation.action == nil)
    }

    @Test("foreground cancellation waits for the exact install task and preserves consent")
    @MainActor
    func foregroundCancellationPreservesConsent() async {
        let defaultsKey = "org.steno.modelConsent"
        let defaults = UserDefaults.standard
        let previousConsent = defaults.object(forKey: defaultsKey)
        defaults.removeObject(forKey: defaultsKey)
        defer {
            if let previousConsent {
                defaults.set(previousConsent, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }

        let baseline = ReadinessInstaller(
            id: .appleSpeech,
            title: "Transcription language",
            source: .appleSystemAssets
        )
        let parakeet = DelayedCancellationInstaller()
        let coordinator = ModelInstallationCoordinator(installers: [baseline, parakeet])
        let app = AppModel(modelCoordinator: coordinator)
        let locale = app.transcriptionLocale

        await app.refreshModelReadiness()
        await app.refreshParakeetReadiness()
        #expect(app.modelReadiness?.isReady(for: locale) == false)
        #expect(app.parakeetReadiness?.isReady(for: locale) == false)
        #expect(await baseline.readinessCount == 1)
        #expect(await parakeet.readinessCount == 1)

        let install = Task { await app.installParakeet() }
        await parakeet.waitUntilStarted(run: 1)

        #expect(app.modelInstallProgress == nil)
        #expect(
            app.modelInstallProgressPresentation
                == .indeterminate(title: "Preparing")
        )

        let cancel = Task { await app.cancelModelInstallation() }
        await parakeet.waitUntilCancellationWasRequested(request: 1)

        #expect(app.modelInstallationCancellationState == .cancelling)
        #expect(
            app.modelInstallProgressPresentation
                == .indeterminate(title: "Cancelling")
        )
        #expect(!(await app.cancelModelInstallation()))
        #expect(app.modelConsent.isGranted)
        #expect(app.modelReadiness?.isReady(for: locale) == false)
        #expect(app.parakeetReadiness?.isReady(for: locale) == false)
        #expect(await baseline.readinessCount == 1)
        #expect(await parakeet.readinessCount == 1)

        await parakeet.finishCancellation(run: 1)
        #expect(await cancel.value)
        await install.value

        #expect(app.modelConsent.isGranted)
        #expect(app.modelError == nil)
        #expect(app.modelInstallationCancellationState == .idle)
        #expect(!app.isInstallingModels)
        #expect(app.modelReadiness?.isReady(for: locale) == false)
        #expect(app.parakeetReadiness?.isReady(for: locale) == false)
        #expect(await baseline.readinessCount == 2)
        #expect(await parakeet.readinessCount == 2)
    }

    @Test("a stale callback cannot update a later installation")
    @MainActor
    func staleCallbackIdentityIsRejected() async {
        let defaultsKey = "org.steno.modelConsent"
        let defaults = UserDefaults.standard
        let previousConsent = defaults.object(forKey: defaultsKey)
        defaults.removeObject(forKey: defaultsKey)
        defer {
            if let previousConsent {
                defaults.set(previousConsent, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }

        let baseline = ReadinessInstaller(
            id: .appleSpeech,
            title: "Transcription language",
            source: .appleSystemAssets
        )
        let parakeet = DelayedCancellationInstaller()
        let coordinator = ModelInstallationCoordinator(installers: [baseline, parakeet])
        let app = AppModel(modelCoordinator: coordinator)

        let firstInstall = Task { await app.installParakeet() }
        await parakeet.waitUntilStarted(run: 1)
        let firstCancel = Task { await app.cancelModelInstallation() }
        await parakeet.waitUntilCancellationWasRequested(request: 1)
        await parakeet.finishCancellation(run: 1)
        #expect(await firstCancel.value)
        await firstInstall.value

        let secondInstall = Task { await app.installParakeet() }
        await parakeet.waitUntilStarted(run: 2)
        await parakeet.emitProgress(run: 2, fraction: 0.2)
        await waitForProgress(0.2, in: app)

        await parakeet.emitProgress(run: 1, fraction: 0.9)
        await parakeet.emitProgress(run: 2, fraction: 0.3)
        await waitForProgress(0.3, in: app)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(app.modelInstallProgress?.fraction == 0.3)

        let secondCancel = Task { await app.cancelModelInstallation() }
        await parakeet.waitUntilCancellationWasRequested(request: 2)
        await parakeet.finishCancellation(run: 2)
        #expect(await secondCancel.value)
        await secondInstall.value
    }
}

@MainActor
private func waitForProgress(_ fraction: Double, in app: AppModel) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while app.modelInstallProgress?.fraction != fraction, clock.now < deadline {
        await Task.yield()
    }
    if app.modelInstallProgress?.fraction != fraction {
        Issue.record("Progress did not reach \(fraction) within five seconds")
    }
}

private actor ReadinessInstaller: ModelInstalling {
    nonisolated let bundleDescription: ModelBundleDescription
    private(set) var readinessCount = 0

    init(id: ModelBundleID, title: String, source: ModelSource) {
        bundleDescription = ModelBundleDescription(
            id: id,
            title: title,
            source: source,
            approximateBytes: 1
        )
    }

    func readiness(for locales: [Locale]) -> ModelReadiness {
        readinessCount += 1
        return ModelReadiness(
            installed: [],
            missing: Dictionary(uniqueKeysWithValues: locales.map {
                ($0, [bundleDescription.title])
            })
        )
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {}

    func cancelInstall() {}
}

private actor DelayedCancellationInstaller: ModelInstalling {
    nonisolated let bundleDescription = ModelBundleDescription(
        id: .parakeetTDTv3,
        title: "FluidAudio Parakeet TDT",
        source: .huggingFace,
        approximateBytes: 1
    )

    private(set) var readinessCount = 0
    private var startedRunCount = 0
    private var cancellationRequestCount = 0
    private var runsAllowedToFinish: Set<Int> = []
    private var progressCallbacks: [Int: @Sendable (ModelInstallProgress) -> Void] = [:]

    func readiness(for locales: [Locale]) -> ModelReadiness {
        readinessCount += 1
        return ModelReadiness(
            installed: [],
            missing: Dictionary(uniqueKeysWithValues: locales.map {
                ($0, [bundleDescription.title])
            })
        )
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        startedRunCount += 1
        let run = startedRunCount
        progressCallbacks[run] = progress
        while !runsAllowedToFinish.contains(run) {
            await Task.yield()
        }
        throw DelayedInstallError.transportStopped
    }

    func cancelInstall() {
        cancellationRequestCount += 1
    }

    func finishCancellation(run: Int) {
        runsAllowedToFinish.insert(run)
    }

    func emitProgress(run: Int, fraction: Double) {
        progressCallbacks[run]?(
            ModelInstallProgress(fraction: fraction, title: "Downloading")
        )
    }

    func waitUntilStarted(run: Int) async {
        await wait(
            until: { startedRunCount >= run },
            failure: "Model installation run \(run) did not start"
        )
    }

    func waitUntilCancellationWasRequested(request: Int) async {
        await wait(
            until: { cancellationRequestCount >= request },
            failure: "The installer did not receive cancellation request \(request)"
        )
    }

    private func wait(
        until predicate: () -> Bool,
        failure: String
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline {
            await Task.yield()
        }
        if !predicate() {
            Issue.record("\(failure) within five seconds")
        }
    }
}

private enum DelayedInstallError: LocalizedError {
    case transportStopped

    var errorDescription: String? { "The transport stopped." }
}
