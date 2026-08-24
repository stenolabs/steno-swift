import Testing
import Foundation
import StenoDomain
@testable import StenoPipeline

@Suite("Model installation coordinator")
struct ModelInstallationCoordinatorTests {
    @Test("without consent nothing is requested")
    func withoutConsentNothingHappens() async throws {
        let installer = CountingInstaller(readyLocales: [])
        let coordinator = ModelInstallationCoordinator(installers: [installer])
        await #expect(throws: ModelInstallationError.self) {
            try await coordinator.installAll(
                for: Locale(identifier: "de-DE"),
                consentGranted: false
            ) { _ in }
        }
        #expect(await installer.installCount == 0)
    }

    @Test("with consent every installer runs exactly once")
    func withConsentEachRunsOnce() async throws {
        let first = CountingInstaller(readyLocales: [])
        let second = CountingInstaller(readyLocales: [])
        let coordinator = ModelInstallationCoordinator(installers: [first, second])
        try await coordinator.installAll(
            for: Locale(identifier: "de-DE"),
            consentGranted: true
        ) { _ in }
        #expect(await first.installCount == 1)
        #expect(await second.installCount == 1)
    }

    @Test("revoking during the first install stops the second one from starting")
    func cancelStopsTheNextInstaller() async throws {
        let gated = GatedInstaller()
        let second = CountingInstaller(readyLocales: [])
        let coordinator = ModelInstallationCoordinator(installers: [gated, second])
        let run = Task {
            try await coordinator.installAll(
                for: Locale(identifier: "de-DE"),
                consentGranted: true
            ) { _ in }
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while await !(gated.started), ContinuousClock().now < deadline {
            await Task.yield()
        }
        #expect(await gated.started)
        await coordinator.cancelAll()
        _ = await run.result
        #expect(await second.installCount == 0)
    }

    @Test("readiness is false as soon as one installer is missing something")
    func readinessNeedsEveryone() async {
        let ready = CountingInstaller(readyLocales: [Locale(identifier: "de-DE")])
        let notReady = CountingInstaller(readyLocales: [])
        let coordinator = ModelInstallationCoordinator(installers: [ready, notReady])
        let readiness = await coordinator.readiness(for: [Locale(identifier: "de-DE")])
        #expect(!readiness.isReady(for: Locale(identifier: "de-DE")))
    }

    @Test("optional bundles do not change baseline readiness or installation")
    func optionalBundlesAreExplicit() async throws {
        let required = CountingInstaller(
            id: .appleSpeech,
            readyLocales: [Locale(identifier: "de-DE")]
        )
        let optional = CountingInstaller(id: .parakeetTDTv3, readyLocales: [])
        let coordinator = ModelInstallationCoordinator(installers: [required, optional])
        let locale = Locale(identifier: "de-DE")

        let baseline = await coordinator.readiness(
            for: [locale],
            bundleIDs: [.appleSpeech]
        )
        #expect(baseline.isReady(for: locale))

        try await coordinator.install(
            bundleIDs: [.parakeetTDTv3],
            for: locale,
            consentGranted: true
        ) { _ in }
        #expect(await required.installCount == 0)
        #expect(await optional.installCount == 1)
    }
}

actor CountingInstaller: ModelInstalling {
    nonisolated let bundleDescription: ModelBundleDescription
    private var ready: Set<String>
    private(set) var installCount = 0
    private(set) var cancelCount = 0

    init(id: ModelBundleID = .legacy, readyLocales: [Locale]) {
        bundleDescription = ModelBundleDescription(
            id: id,
            title: "Test bundle",
            source: .huggingFace,
            approximateBytes: 1
        )
        ready = Set(readyLocales.map(\.identifier))
    }

    func readiness(for locales: [Locale]) async -> ModelReadiness {
        var installed: Set<Locale> = []
        var missing: [Locale: [String]] = [:]
        for locale in locales {
            if ready.contains(locale.identifier) { installed.insert(locale) }
            else { missing[locale] = ["test"] }
        }
        return ModelReadiness(installed: installed, missing: missing)
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        installCount += 1
        ready.insert(locale.identifier)
        progress(ModelInstallProgress(fraction: 1, title: "Test bundle"))
    }

    /// Ueber den Brief hinaus: `ModelInstalling` verlangt seit Aufgabe 5
    /// `cancelInstall()`, ohne die Methode uebersetzt der Doppelgaenger nicht.
    func cancelInstall() {
        cancelCount += 1
    }
}

/// Bleibt in `install` stehen, bis abgebrochen wird. Damit laesst sich die
/// Luecke zwischen zwei Installern treffen, ohne auf eine Wartezeit zu wetten.
actor GatedInstaller: ModelInstalling {
    nonisolated let bundleDescription = ModelBundleDescription(
        title: "Gated bundle",
        source: .huggingFace,
        approximateBytes: 1
    )
    private(set) var started = false
    private var released = false

    func readiness(for locales: [Locale]) async -> ModelReadiness {
        ModelReadiness(installed: Set(locales), missing: [:])
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        started = true
        while !released {
            await Task.yield()
        }
    }

    func cancelInstall() {
        released = true
    }
}
