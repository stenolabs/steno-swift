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

    @Test("native Gemma confirmation requires existing consent before source access")
    func nativeGemmaConfirmationRequiresConsent() async throws {
        let pin = try nativeGemmaTestPin()
        let coordinator = ModelInstallationCoordinator(
            installers: [],
            nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
        )
        let missingSource = URL(fileURLWithPath: "/definitely-not-a-steno-model-source")

        await #expect(throws: ModelInstallationError.consentMissing) {
            try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: missingSource,
                consentGranted: false
            )
        }
    }

    @Test("native Gemma production catalogue accepts no model")
    func nativeGemmaProductionCatalogIsEmpty() async throws {
        let coordinator = ModelInstallationCoordinator(installers: [])
        let pin = try nativeGemmaTestPin()
        let missingSource = URL(fileURLWithPath: "/definitely-not-a-steno-model-source")

        await #expect(throws: ModelInstallationError.nativeGemmaPinNotApproved) {
            try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: missingSource,
                consentGranted: true
            )
        }
    }

    @Test("native Gemma import forwards only the approved pin and source identity")
    func nativeGemmaImportForwardsApprovedPinAndSource() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let pin = try nativeGemmaTestPin()
            let coordinator = ModelInstallationCoordinator(
                installers: [],
                nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
            )
            let importer = NativeGemmaImporterSpy(result: pin.snapshot)
            let confirmation = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )

            let snapshot = try await coordinator.importNativeGemmaModel(
                using: confirmation,
                importer: importer
            )

            #expect(snapshot == pin.snapshot)
            let request = try #require(await importer.request)
            #expect(request.pin == pin)
            #expect(request.sourceRoot == source)
            #expect(request.sourceIdentity.deviceID != 0)
            #expect(request.sourceIdentity.inode != 0)
        }
    }

    @Test("native Gemma confirmation is consumed when import fails")
    func nativeGemmaConfirmationIsConsumedOnFailure() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let pin = try nativeGemmaTestPin()
            let coordinator = ModelInstallationCoordinator(
                installers: [],
                nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
            )
            let confirmation = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )
            let failingImporter = NativeGemmaImporterSpy(error: NativeGemmaImporterFailure.failed)

            await #expect(throws: NativeGemmaImporterFailure.failed) {
                try await coordinator.importNativeGemmaModel(
                    using: confirmation,
                    importer: failingImporter
                )
            }
            await #expect(throws: ModelInstallationError.nativeGemmaConfirmationInvalid) {
                try await coordinator.importNativeGemmaModel(
                    using: confirmation,
                    importer: failingImporter
                )
            }
            #expect(await failingImporter.importCount == 1)
        }
    }

    @Test("a new native Gemma confirmation replaces the previous one")
    func nativeGemmaConfirmationReplacementIsOneShot() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let pin = try nativeGemmaTestPin()
            let coordinator = ModelInstallationCoordinator(
                installers: [],
                nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
            )
            let replaced = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )
            let current = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )
            let importer = NativeGemmaImporterSpy(result: pin.snapshot)

            await #expect(throws: ModelInstallationError.nativeGemmaConfirmationInvalid) {
                try await coordinator.importNativeGemmaModel(
                    using: replaced,
                    importer: importer
                )
            }
            let imported = try await coordinator.importNativeGemmaModel(
                using: current,
                importer: importer
            )
            #expect(imported == pin.snapshot)
            #expect(await importer.importCount == 1)
        }
    }

    @Test("native Gemma consent can be minted after download cancellation")
    func nativeGemmaConsentDoesNotReuseDownloadCancellationState() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let pin = try nativeGemmaTestPin()
            let coordinator = ModelInstallationCoordinator(
                installers: [],
                nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
            )
            await coordinator.cancelAll()
            let confirmation = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )
            let importer = NativeGemmaImporterSpy(result: pin.snapshot)

            let snapshot = try await coordinator.importNativeGemmaModel(
                using: confirmation,
                importer: importer
            )
            #expect(snapshot == pin.snapshot)
        }
    }

    @Test("native Gemma importer may not substitute provenance")
    func nativeGemmaImporterMayNotSubstituteProvenance() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let pin = try nativeGemmaTestPin()
            let otherPin = try ApprovedNativeGemmaModelPin(
                modelIdentifier: "google/gemma-4-other",
                checkpointRevision: String(repeating: "d", count: 40),
                adapterRevision: String(repeating: "e", count: 40),
                licenseIdentifier: "Gemma-Terms",
                manifestSHA256: String(repeating: "f", count: 64)
            )
            let coordinator = ModelInstallationCoordinator(
                installers: [],
                nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
            )
            let confirmation = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )
            let importer = NativeGemmaImporterSpy(result: otherPin.snapshot)

            await #expect(throws: ModelInstallationError.nativeGemmaSnapshotMismatch) {
                try await coordinator.importNativeGemmaModel(
                    using: confirmation,
                    importer: importer
                )
            }
        }
    }

    @Test("native Gemma import rejects a replaced source before forwarding")
    func nativeGemmaImportRejectsReplacedSource() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let pin = try nativeGemmaTestPin()
            let coordinator = ModelInstallationCoordinator(
                installers: [],
                nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
            )
            let confirmation = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let importer = NativeGemmaImporterSpy(result: pin.snapshot)

            await #expect(throws: ModelInstallationError.nativeGemmaSourceInvalid) {
                try await coordinator.importNativeGemmaModel(
                    using: confirmation,
                    importer: importer
                )
            }
            #expect(await importer.importCount == 0)
        }
    }

    @Test("cancel all cancels the in-flight native Gemma importer and confirmation")
    func cancelAllCancelsNativeGemmaImport() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let pin = try nativeGemmaTestPin()
            let coordinator = ModelInstallationCoordinator(
                installers: [],
                nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
            )
            let confirmation = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )
            let importer = GatedNativeGemmaImporter()
            let run = Task {
                try await coordinator.importNativeGemmaModel(
                    using: confirmation,
                    importer: importer
                )
            }
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            while await !importer.started, ContinuousClock().now < deadline {
                await Task.yield()
            }
            #expect(await importer.started)

            await coordinator.cancelAll()
            let result = await run.result
            switch result {
            case .success:
                Issue.record("The cancelled native Gemma import unexpectedly completed")
            case .failure(let error):
                #expect(error is CancellationError)
            }
            #expect(await importer.finished)
            await #expect(throws: ModelInstallationError.nativeGemmaConfirmationInvalid) {
                try await coordinator.importNativeGemmaModel(
                    using: confirmation,
                    importer: importer
                )
            }
        }
    }

    @Test("caller cancellation reaches the native Gemma importer")
    func callerCancellationReachesNativeGemmaImporter() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let pin = try nativeGemmaTestPin()
            let coordinator = ModelInstallationCoordinator(
                installers: [],
                nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
            )
            let confirmation = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )
            let importer = CallerCancellationNativeGemmaImporter()
            let run = Task {
                try await coordinator.importNativeGemmaModel(
                    using: confirmation,
                    importer: importer
                )
            }
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            while await !importer.started, ContinuousClock().now < deadline {
                await Task.yield()
            }
            #expect(await importer.started)

            run.cancel()
            let result = await run.result
            switch result {
            case .success:
                Issue.record("The caller-cancelled native Gemma import unexpectedly completed")
            case .failure(let error):
                #expect(error is CancellationError)
            }
            #expect(await importer.observedCancellation)
        }
    }

    @Test("native Gemma cancellation excludes a concurrent new confirmation")
    func cancelAllExcludesConcurrentNativeGemmaConfirmation() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let pin = try nativeGemmaTestPin()
            let blockingInstaller = BlockingCancelInstaller()
            let coordinator = ModelInstallationCoordinator(
                installers: [blockingInstaller],
                nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
            )
            let cancellation = Task {
                await coordinator.cancelAll()
            }
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            while await !blockingInstaller.cancelStarted, ContinuousClock().now < deadline {
                await Task.yield()
            }
            #expect(await blockingInstaller.cancelStarted)

            await #expect(throws: ModelInstallationError.nativeGemmaCancellationInProgress) {
                try await coordinator.mintNativeGemmaImportConfirmation(
                    pin: pin,
                    sourceRoot: source,
                    consentGranted: true
                )
            }

            await blockingInstaller.releaseCancellation()
            await cancellation.value
            _ = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )
        }
    }

    @Test("overlapping cancellation keeps native Gemma confirmation closed until both calls finish")
    func overlappingCancelAllCallsRemainClosed() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let pin = try nativeGemmaTestPin()
            let installer = SequencedBlockingCancelInstaller()
            let coordinator = ModelInstallationCoordinator(
                installers: [installer],
                nativeGemmaCatalog: NativeGemmaTestCatalog.containing(pin)
            )

            let firstCancellation = Task {
                await coordinator.cancelAll()
            }
            let firstDeadline = ContinuousClock().now.advanced(by: .seconds(5))
            while await installer.cancelStartedCount < 1, ContinuousClock().now < firstDeadline {
                await Task.yield()
            }
            #expect(await installer.cancelStartedCount == 1)

            let secondCancellation = Task {
                await coordinator.cancelAll()
            }
            let secondDeadline = ContinuousClock().now.advanced(by: .seconds(5))
            while await installer.cancelStartedCount < 2, ContinuousClock().now < secondDeadline {
                await Task.yield()
            }
            #expect(await installer.cancelStartedCount == 2)

            await installer.releaseNextCancellation()
            await firstCancellation.value
            await #expect(throws: ModelInstallationError.nativeGemmaCancellationInProgress) {
                try await coordinator.mintNativeGemmaImportConfirmation(
                    pin: pin,
                    sourceRoot: source,
                    consentGranted: true
                )
            }

            await installer.releaseNextCancellation()
            await secondCancellation.value
            _ = try await coordinator.mintNativeGemmaImportConfirmation(
                pin: pin,
                sourceRoot: source,
                consentGranted: true
            )
        }
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

private enum NativeGemmaTestCatalog {
    static func containing(_ pin: ApprovedNativeGemmaModelPin) -> ApprovedNativeGemmaModelCatalog {
        ApprovedNativeGemmaModelCatalog(pins: [pin])
    }
}

private func nativeGemmaTestPin() throws -> ApprovedNativeGemmaModelPin {
    try ApprovedNativeGemmaModelPin(
        modelIdentifier: "google/gemma-4-test",
        checkpointRevision: String(repeating: "a", count: 40),
        adapterRevision: String(repeating: "b", count: 40),
        licenseIdentifier: "Gemma-Terms",
        manifestSHA256: String(repeating: "c", count: 64)
    )
}

private enum NativeGemmaImporterFailure: Error, Equatable {
    case failed
}

private actor NativeGemmaImporterSpy: NativeGemmaModelImporting {
    struct Request: Sendable {
        let pin: ApprovedNativeGemmaModelPin
        let sourceRoot: URL
        let sourceIdentity: NativeGemmaSourceIdentity
    }

    private let result: Result<NativeGemmaModelSnapshot, NativeGemmaImporterFailure>
    private(set) var request: Request?
    private(set) var importCount = 0

    init(result: NativeGemmaModelSnapshot) {
        self.result = .success(result)
    }

    init(error: NativeGemmaImporterFailure) {
        self.result = .failure(error)
    }

    func importApprovedNativeGemmaModel(
        pin: ApprovedNativeGemmaModelPin,
        sourceRoot: URL,
        sourceIdentity: NativeGemmaSourceIdentity
    ) throws -> NativeGemmaModelSnapshot {
        importCount += 1
        request = Request(pin: pin, sourceRoot: sourceRoot, sourceIdentity: sourceIdentity)
        return try result.get()
    }

}

private actor GatedNativeGemmaImporter: NativeGemmaModelImporting {
    private(set) var started = false
    private(set) var finished = false

    func importApprovedNativeGemmaModel(
        pin: ApprovedNativeGemmaModelPin,
        sourceRoot: URL,
        sourceIdentity: NativeGemmaSourceIdentity
    ) async throws -> NativeGemmaModelSnapshot {
        started = true
        defer { finished = true }
        while true {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

private actor CallerCancellationNativeGemmaImporter: NativeGemmaModelImporting {
    private(set) var started = false
    private(set) var observedCancellation = false

    func importApprovedNativeGemmaModel(
        pin: ApprovedNativeGemmaModelPin,
        sourceRoot: URL,
        sourceIdentity: NativeGemmaSourceIdentity
    ) async throws -> NativeGemmaModelSnapshot {
        started = true
        while !Task.isCancelled {
            await Task.yield()
        }
        observedCancellation = true
        throw CancellationError()
    }
}

private actor BlockingCancelInstaller: ModelInstalling {
    nonisolated let bundleDescription = ModelBundleDescription(
        title: "Blocking cancellation bundle",
        source: .huggingFace,
        approximateBytes: 1
    )
    private(set) var cancelStarted = false
    private var cancellationReleased = false

    func readiness(for locales: [Locale]) -> ModelReadiness {
        ModelReadiness(installed: Set(locales), missing: [:])
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) {}

    func cancelInstall() async {
        cancelStarted = true
        while !cancellationReleased {
            await Task.yield()
        }
    }

    func releaseCancellation() {
        cancellationReleased = true
    }
}

private actor SequencedBlockingCancelInstaller: ModelInstalling {
    nonisolated let bundleDescription = ModelBundleDescription(
        title: "Sequenced cancellation bundle",
        source: .huggingFace,
        approximateBytes: 1
    )
    private(set) var cancelStartedCount = 0
    private var releasedCancellationCount = 0

    func readiness(for locales: [Locale]) -> ModelReadiness {
        ModelReadiness(installed: Set(locales), missing: [:])
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) {}

    func cancelInstall() async {
        cancelStartedCount += 1
        let sequence = cancelStartedCount
        while releasedCancellationCount < sequence {
            await Task.yield()
        }
    }

    func releaseNextCancellation() {
        releasedCancellationCount += 1
    }
}
