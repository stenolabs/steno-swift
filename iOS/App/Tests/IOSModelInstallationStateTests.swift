import Foundation
import StenoDomain
import StenoPipeline
import StenoTranscription
import Testing
@testable import Steno

@Suite("iOS model installation state")
struct IOSModelInstallationStateTests {
    @Test("static installation phases are localizable resources")
    @MainActor
    func staticProgressTitlesAreLocalizedResources() {
        let preparing = IOSModelInstallProgressPresentation.make(
            isInstalling: true,
            isCancelling: false,
            progress: nil
        )
        let cancelling = IOSModelInstallProgressPresentation.make(
            isInstalling: true,
            isCancelling: true,
            progress: nil
        )

        guard case .indeterminate(let preparingTitle) = preparing,
              case .indeterminate(let cancellingTitle) = cancelling else {
            Issue.record("Expected indeterminate static installation phases")
            return
        }
        let localizedTitles: [LocalizedStringResource] = [
            preparingTitle,
            cancellingTitle,
        ]
        #expect(localizedTitles.map(english) == ["Preparing", "Cancelling"])
    }

    private func english(_ resource: LocalizedStringResource) -> String {
        var englishResource = resource
        englishResource.locale = Locale(identifier: "en")
        return String(localized: englishResource)
    }

    @Test("install progress is hidden while idle and indeterminate before a callback")
    @MainActor
    func progressStartsIndeterminate() async throws {
        let fixture = try Fixture(installed: [])
        defer { fixture.cleanUp() }
        let locale = Locale(identifier: "de-DE")

        #expect(fixture.state.installProgressPresentation == nil)

        let install = Task {
            await fixture.state.allowAndInstall(for: locale, recordingIsActive: false)
        }
        await fixture.gateway.waitUntilStarted()

        #expect(fixture.state.progress == nil)
        #expect(
            fixture.state.installProgressPresentation
                == .indeterminate(title: "Preparing")
        )

        await fixture.gateway.finish()
        _ = await install.value
    }

    @Test("real progress is determinate and clamped to its valid range")
    @MainActor
    func realProgressIsClamped() async throws {
        let fixture = try Fixture(installed: [])
        defer { fixture.cleanUp() }
        let locale = Locale(identifier: "de-DE")
        let install = Task {
            await fixture.state.allowAndInstall(for: locale, recordingIsActive: false)
        }
        await fixture.gateway.waitUntilStarted()

        await fixture.gateway.emitProgress(.nan)
        await Task.yield()
        #expect(fixture.state.progress == nil)
        #expect(
            fixture.state.installProgressPresentation
                == .indeterminate(title: "Preparing")
        )

        await fixture.gateway.emitProgress(0.4)
        await Task.yield()
        #expect(
            fixture.state.installProgressPresentation
                == .determinate(title: "Transcription language", fraction: 0.4)
        )

        await fixture.gateway.emitProgress(1.4)
        await Task.yield()
        #expect(
            fixture.state.installProgressPresentation
                == .determinate(title: "Transcription language", fraction: 1)
        )
        #expect(
            IOSModelInstallProgressPresentation.make(
                isInstalling: true,
                isCancelling: false,
                progress: ModelInstallProgress(fraction: -0.4, title: "Downloading")
            ) == .determinate(title: "Downloading", fraction: 0)
        )
        await fixture.gateway.finish()
        _ = await install.value
    }

    @Test("refresh distinguishes installed and missing locales")
    @MainActor
    func readinessIsPerLocale() async throws {
        let fixture = try Fixture(installed: ["de-DE"])
        defer { fixture.cleanUp() }

        await fixture.state.refresh(for: Locale(identifier: "de-DE"))
        #expect(fixture.state.isReady(for: Locale(identifier: "de-DE")) == true)

        await fixture.state.refresh(for: Locale(identifier: "en-US"))
        #expect(fixture.state.isReady(for: Locale(identifier: "en-US")) == false)
        #expect(await fixture.gateway.installCount == 0)
    }

    @Test("one approved click starts one install and keeps progress monotonic")
    @MainActor
    func approvedInstallRunsOnce() async throws {
        let fixture = try Fixture(installed: [])
        defer { fixture.cleanUp() }
        let locale = Locale(identifier: "de-DE")

        let first = Task {
            await fixture.state.allowAndInstall(for: locale, recordingIsActive: false)
        }
        await fixture.gateway.waitUntilStarted()
        let second = await fixture.state.allowAndInstall(
            for: locale,
            recordingIsActive: false
        )
        await fixture.gateway.emitProgress(0.8)
        await Task.yield()
        #expect(fixture.state.progress?.fraction == 0.8)
        await fixture.gateway.emitProgress(0.3)
        await Task.yield()
        #expect(fixture.state.progress?.fraction == 0.8)
        await fixture.gateway.finish()

        #expect(await first.value)
        #expect(!second)
        #expect(await fixture.gateway.installCount == 1)
        #expect(fixture.consent.isGranted)
        #expect(fixture.state.isReady(for: locale) == true)
    }

    @Test("recording blocks installation but not readiness checks")
    @MainActor
    func recordingBlocksInstall() async throws {
        let fixture = try Fixture(installed: [])
        defer { fixture.cleanUp() }

        let installed = await fixture.state.allowAndInstall(
            for: Locale(identifier: "de-DE"),
            recordingIsActive: true
        )

        #expect(!installed)
        #expect(await fixture.gateway.installCount == 0)
    }

    @Test("revoke cancels a running install and hides cancellation as a user action")
    @MainActor
    func revokeCancels() async throws {
        let installer = DelayedCancellationInstaller()
        let fixture = try Fixture(installer: installer)
        defer { fixture.cleanUp() }
        let runLocale = Locale(identifier: "de-DE")
        let oldLocale = Locale(identifier: "en-US")

        await fixture.state.refresh(for: oldLocale)
        let run = Task {
            await fixture.state.allowAndInstall(
                for: runLocale,
                recordingIsActive: false
            )
        }
        await installer.waitUntilStarted()

        let revoke = Task { await fixture.state.revoke() }
        await installer.waitUntilCancellationWasRequested()
        #expect(!fixture.consent.isGranted)
        await installer.finishCancellation()

        await revoke.value

        #expect(!(await run.value))
        #expect(!fixture.consent.isGranted)
        #expect(fixture.state.errorMessage == nil)
        #expect(await installer.readinessCount == 2)
        #expect(await installer.lastReadinessLocaleIdentifier == runLocale.identifier)
        #expect(fixture.state.isReady(for: runLocale) == false)
        #expect(fixture.state.isReady(for: oldLocale) == nil)
    }

    @Test("foreground cancellation waits for the exact install task and preserves consent")
    @MainActor
    func foregroundCancellationPreservesConsent() async throws {
        let installer = DelayedCancellationInstaller()
        let fixture = try Fixture(installer: installer)
        defer { fixture.cleanUp() }
        let locale = Locale(identifier: "de-DE")

        let run = Task {
            await fixture.state.allowAndInstall(
                for: locale,
                recordingIsActive: false
            )
        }
        await installer.waitUntilStarted()

        let cancel = Task { await fixture.state.cancelInstall() }
        await installer.waitUntilCancellationWasRequested()

        #expect(fixture.state.isCancelling)
        #expect(
            fixture.state.installProgressPresentation
                == .indeterminate(title: "Cancelling")
        )
        #expect(fixture.state.isReady(for: locale) == nil)
        #expect(await installer.readinessCount == 0)
        #expect(await fixture.state.cancelInstall() == false)
        #expect(fixture.consent.isGranted)

        await installer.finishCancellation()

        #expect(await cancel.value)

        #expect(!(await run.value))
        #expect(fixture.consent.isGranted)
        #expect(fixture.state.errorMessage == nil)
        #expect(!fixture.state.isCancelling)
        #expect(!fixture.state.isInstalling)
        #expect(fixture.state.isReady(for: locale) == false)
        #expect(await installer.readinessCount == 1)
        #expect(await installer.lastReadinessLocaleIdentifier == locale.identifier)
    }

    @Test("cancellation refreshes the run locale instead of an older locale")
    @MainActor
    func cancellationRefreshesRunLocale() async throws {
        let installer = DelayedCancellationInstaller()
        let fixture = try Fixture(installer: installer)
        defer { fixture.cleanUp() }
        let runLocale = Locale(identifier: "de-DE")
        let oldLocale = Locale(identifier: "en-US")

        await fixture.state.refresh(for: oldLocale)
        #expect(await installer.readinessCount == 1)

        let run = Task {
            await fixture.state.allowAndInstall(
                for: runLocale,
                recordingIsActive: false
            )
        }
        await installer.waitUntilStarted()
        let cancel = Task { await fixture.state.cancelInstall() }
        await installer.waitUntilCancellationWasRequested()
        await installer.finishCancellation()

        #expect(await cancel.value)
        #expect(!(await run.value))
        #expect(await installer.readinessCount == 2)
        #expect(await installer.lastReadinessLocaleIdentifier == runLocale.identifier)
        #expect(fixture.state.isReady(for: runLocale) == false)
        #expect(fixture.state.isReady(for: oldLocale) == nil)
    }

    @Test("public refresh is dropped while the retained install task is active")
    @MainActor
    func activeInstallDropsExternalRefresh() async throws {
        let installer = DelayedCancellationInstaller()
        let fixture = try Fixture(installer: installer)
        defer { fixture.cleanUp() }
        let runLocale = Locale(identifier: "de-DE")

        let run = Task {
            await fixture.state.allowAndInstall(
                for: runLocale,
                recordingIsActive: false
            )
        }
        await installer.waitUntilStarted()

        await fixture.state.refresh(for: Locale(identifier: "fr-FR"))

        #expect(await installer.readinessCount == 0)
        #expect(fixture.state.isInstalling)
        #expect(
            fixture.state.installProgressPresentation
                == .indeterminate(title: "Preparing")
        )

        let cancel = Task { await fixture.state.cancelInstall() }
        await installer.waitUntilCancellationWasRequested()
        await installer.finishCancellation()

        #expect(await cancel.value)
        #expect(!(await run.value))
        #expect(await installer.readinessCount == 1)
        #expect(await installer.lastReadinessLocaleIdentifier == runLocale.identifier)
        #expect(fixture.state.isReady(for: runLocale) == false)
    }

    @Test("installation errors remain visible and permit a deliberate retry")
    @MainActor
    func installationFailureIsVisible() async throws {
        let fixture = try Fixture(installed: [])
        defer { fixture.cleanUp() }
        let run = Task {
            await fixture.state.allowAndInstall(
                for: Locale(identifier: "de-DE"),
                recordingIsActive: false
            )
        }
        await fixture.gateway.waitUntilStarted()
        await fixture.gateway.finish(throwing: ModelInstallFixtureError.downloadFailed)

        #expect(!(await run.value))
        #expect(fixture.consent.isGranted)
        #expect(fixture.state.errorMessage == "The model download failed.")
        #expect(!fixture.state.isInstalling)
    }
}

private enum ModelInstallFixtureError: LocalizedError {
    case downloadFailed

    var errorDescription: String? { "The model download failed." }
}

@MainActor
private struct Fixture {
    let consent: ModelConsent
    let gateway: ControllableSpeechAssets
    let state: IOSModelInstallationState
    private let defaults: UserDefaults
    private let suite: String

    init(installed: Set<String>) throws {
        suite = "IOSModelInstallationStateTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        consent = ModelConsent(defaults: defaults, key: "consent")
        gateway = ControllableSpeechAssets(installed: installed)
        let coordinator = ModelInstallationCoordinator(installers: [
            SpeechAssetInstaller(assets: gateway),
        ])
        state = IOSModelInstallationState(coordinator: coordinator, consent: consent)
    }

    init(installer: any ModelInstalling) throws {
        suite = "IOSModelInstallationStateTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        consent = ModelConsent(defaults: defaults, key: "consent")
        gateway = ControllableSpeechAssets(installed: [])
        state = IOSModelInstallationState(
            coordinator: ModelInstallationCoordinator(installers: [installer]),
            consent: consent
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor DelayedCancellationInstaller: ModelInstalling {
    nonisolated let bundleDescription = ModelBundleDescription(
        id: .appleSpeech,
        title: "Transcription language",
        source: .appleSystemAssets,
        approximateBytes: 1
    )

    private(set) var readinessCount = 0
    private var readinessLocaleIdentifiers: [String] = []
    private var isStarted = false
    private var cancellationWasRequested = false
    private var cancellationMayFinish = false

    func readiness(for locales: [Locale]) -> ModelReadiness {
        readinessCount += 1
        readinessLocaleIdentifiers.append(contentsOf: locales.map(\.identifier))
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
        isStarted = true
        while !cancellationMayFinish {
            await Task.yield()
        }
        throw CancellationError()
    }

    func cancelInstall() {
        cancellationWasRequested = true
    }

    func finishCancellation() {
        cancellationMayFinish = true
    }

    var lastReadinessLocaleIdentifier: String? {
        readinessLocaleIdentifiers.last
    }

    func waitUntilStarted() async {
        await wait(until: { isStarted }, failure: "The delayed installer did not start")
    }

    func waitUntilCancellationWasRequested() async {
        await wait(
            until: { cancellationWasRequested },
            failure: "The delayed installer did not receive cancellation"
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

private actor ControllableSpeechAssets: SpeechAssetGateway {
    private var installed: Set<String>
    private(set) var installCount = 0
    private var isStarted = false
    private var isReleased = false
    private var releaseError: (any Error & Sendable)?
    private var progress: (@Sendable (Double) -> Void)?

    init(installed: Set<String>) {
        self.installed = installed
    }

    func isInstalled(locale: Locale) -> Bool {
        installed.contains(locale.identifier)
    }

    func install(
        locale: Locale,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        installCount += 1
        self.progress = progress
        isStarted = true
        while !isReleased {
            try Task.checkCancellation()
            await Task.yield()
        }
        if let releaseError { throw releaseError }
        installed.insert(locale.identifier)
    }

    func emitProgress(_ fraction: Double) {
        progress?(fraction)
    }

    func finish(throwing error: (any Error & Sendable)? = nil) {
        releaseError = error
        isReleased = true
    }

    func waitUntilStarted() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !isStarted, clock.now < deadline {
            await Task.yield()
        }
        if !isStarted {
            Issue.record("The speech asset installation did not start within five seconds")
        }
    }
}
