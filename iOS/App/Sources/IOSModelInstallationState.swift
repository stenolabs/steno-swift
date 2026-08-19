import Foundation
import Observation
import StenoDomain
import StenoPipeline

@MainActor
@Observable
final class IOSModelInstallationState {
    let bundleDescriptions: [ModelBundleDescription]
    let consent: ModelConsent
    private(set) var readiness: ModelReadiness?
    private(set) var progress: ModelInstallProgress?
    private(set) var isInstalling = false
    private(set) var errorMessage: String?

    private let coordinator: ModelInstallationCoordinator?
    private let setupErrorMessage: String?
    private var currentLocale: Locale?

    init(coordinator: ModelInstallationCoordinator, consent: ModelConsent) {
        self.coordinator = coordinator
        self.consent = consent
        bundleDescriptions = coordinator.bundleDescriptions
        setupErrorMessage = nil
    }

    init(
        unavailableBundle: ModelBundleDescription,
        consent: ModelConsent,
        errorMessage: String
    ) {
        coordinator = nil
        self.consent = consent
        bundleDescriptions = [unavailableBundle]
        setupErrorMessage = errorMessage
        self.errorMessage = errorMessage
    }

    func isReady(for locale: Locale) -> Bool? {
        guard currentLocale?.identifier == locale.identifier,
              let readiness else { return nil }
        return readiness.isReady(for: locale)
    }

    func refresh(for locale: Locale) async {
        currentLocale = locale
        guard let coordinator else {
            readiness = ModelReadiness(
                installed: [],
                missing: [locale: bundleDescriptions.map(\.title)]
            )
            errorMessage = setupErrorMessage
            return
        }
        let result = await coordinator.readiness(for: [locale])
        guard currentLocale?.identifier == locale.identifier else { return }
        readiness = result
    }

    @discardableResult
    func allowAndInstall(for locale: Locale, recordingIsActive: Bool) async -> Bool {
        guard !recordingIsActive, !isInstalling else { return false }
        guard let coordinator else {
            errorMessage = setupErrorMessage
            return false
        }
        isInstalling = true
        progress = ModelInstallProgress(fraction: 0, title: "Preparing")
        errorMessage = nil
        consent.grant(sources: uniqueSources())
        defer {
            isInstalling = false
            progress = nil
        }
        do {
            try await coordinator.installAll(
                for: locale,
                consentGranted: consent.isGranted
            ) { [weak self] update in
                Task { @MainActor in
                    self?.apply(update)
                }
            }
            await refresh(for: locale)
            return isReady(for: locale) == true
        } catch is CancellationError {
            return false
        } catch {
            if consent.isGranted {
                errorMessage = error.localizedDescription
            }
            await refresh(for: locale)
            return false
        }
    }

    func revoke() async {
        consent.revoke()
        await coordinator?.cancelAll()
        await refreshIfPossible()
    }

    /// Foreground-only installations stop when the app backgrounds, while
    /// retaining the user's consent so a later manual retry needs no fiction
    /// that the original choice was revoked.
    func cancelInstall() async {
        await coordinator?.cancelAll()
    }

    private func refreshIfPossible() async {
        if let currentLocale {
            await refresh(for: currentLocale)
        }
    }

    private func uniqueSources() -> [ModelSource] {
        var seen = Set<ModelSource>()
        return bundleDescriptions.map(\.source).filter { seen.insert($0).inserted }
    }

    private func apply(_ update: ModelInstallProgress) {
        guard update.supersedes(progress) else { return }
        progress = update
    }
}
