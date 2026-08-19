import Foundation
import StenoPipeline
import StenoTranscription
import Testing
@testable import Steno

@Suite("iOS model installation state")
struct IOSModelInstallationStateTests {
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
        let fixture = try Fixture(installed: [])
        defer { fixture.cleanUp() }
        let run = Task {
            await fixture.state.allowAndInstall(
                for: Locale(identifier: "de-DE"),
                recordingIsActive: false
            )
        }
        await fixture.gateway.waitUntilStarted()

        await fixture.state.revoke()

        #expect(!(await run.value))
        #expect(!fixture.consent.isGranted)
        #expect(fixture.state.errorMessage == nil)
    }

    @Test("foreground cancellation stops installation without revoking consent")
    @MainActor
    func foregroundCancellationPreservesConsent() async throws {
        let fixture = try Fixture(installed: [])
        defer { fixture.cleanUp() }
        let run = Task {
            await fixture.state.allowAndInstall(
                for: Locale(identifier: "de-DE"),
                recordingIsActive: false
            )
        }
        await fixture.gateway.waitUntilStarted()

        await fixture.state.cancelInstall()

        #expect(!(await run.value))
        #expect(fixture.consent.isGranted)
        #expect(fixture.state.errorMessage == nil)
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

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
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
