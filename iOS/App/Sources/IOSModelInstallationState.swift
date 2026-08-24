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
    private(set) var isCancelling = false
    private(set) var errorMessage: String?

    private let coordinator: ModelInstallationCoordinator?
    private let setupErrorMessage: String?
    private var currentLocale: Locale?
    private var activeInstallation: ActiveInstallation?
    private var completionOwner: InstallationIdentity?
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    var installProgressPresentation: IOSModelInstallProgressPresentation? {
        IOSModelInstallProgressPresentation.make(
            isInstalling: isInstalling,
            isCancelling: isCancelling,
            progress: progress
        )
    }

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
        // Readiness and its locale form one snapshot. An unrelated refresh
        // must not replace it while an install run still owns the UI state.
        // The run owner performs exactly one verified refresh after its exact
        // task exits; callers can request their locale again afterwards.
        guard activeInstallation == nil else { return }
        await performRefresh(for: locale)
    }

    private func performRefresh(
        for locale: Locale,
        owner: InstallationIdentity? = nil
    ) async {
        guard canApplyRefresh(owner: owner) else { return }
        currentLocale = locale
        guard let coordinator else {
            readiness = ModelReadiness(
                installed: [],
                missing: [locale: bundleDescriptions.map(\.title)]
            )
            errorMessage = setupErrorMessage
            return
        }
        let result = await coordinator.readiness(
            for: [locale],
            bundleIDs: managedBundleIDs
        )
        guard canApplyRefresh(owner: owner) else { return }
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
        isCancelling = false
        progress = nil
        errorMessage = nil
        consent.grant(sources: uniqueSources())
        let identity = InstallationIdentity()
        let bundleIDs = managedBundleIDs
        let consentGranted = consent.isGranted
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.runInstall(
                coordinator: coordinator,
                bundleIDs: bundleIDs,
                locale: locale,
                consentGranted: consentGranted,
                identity: identity
            )
        }
        let installation = ActiveInstallation(
            identity: identity,
            locale: locale,
            task: task
        )
        activeInstallation = installation
        completionOwner = nil

        let installed = await task.value
        guard isCurrent(installation) else { return false }
        // The cancellation path owns readiness refresh and final state while
        // it waits for this exact task. Letting both paths finish would make
        // Cancelling disappear before the verified readiness check ends.
        guard !isCancelling else { return false }
        guard claimCompletion(of: installation) else { return false }

        await performRefresh(
            for: installation.locale,
            owner: installation.identity
        )
        guard isCurrent(installation) else { return false }
        finishInstallation(installation)
        return installed && isReady(for: locale) == true
    }

    func revoke() async {
        consent.revoke()
        guard let installation = activeInstallation else {
            await coordinator?.cancelAll()
            await refreshIfPossible()
            return
        }

        if completionOwner != nil {
            await coordinator?.cancelAll()
            await waitForCompletion(of: installation)
            return
        }

        isCancelling = true
        guard claimCompletion(of: installation) else {
            await waitForCompletion(of: installation)
            return
        }
        await coordinator?.cancelAll()
        _ = await installation.task.value
        guard isCurrent(installation) else { return }
        await performRefresh(
            for: installation.locale,
            owner: installation.identity
        )
        guard isCurrent(installation) else { return }
        finishInstallation(installation)
    }

    /// Foreground-only installations stop when the app backgrounds, while
    /// retaining the user's consent so a later manual retry needs no fiction
    /// that the original choice was revoked.
    @discardableResult
    func cancelInstall() async -> Bool {
        guard isInstalling,
              !isCancelling,
              let installation = activeInstallation,
              completionOwner == nil else { return false }

        isCancelling = true
        guard claimCompletion(of: installation) else { return false }
        await coordinator?.cancelAll()
        _ = await installation.task.value
        guard isCurrent(installation) else { return true }
        await performRefresh(
            for: installation.locale,
            owner: installation.identity
        )
        guard isCurrent(installation) else { return true }
        finishInstallation(installation)
        return true
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

    // Nur die Bundles, die diese Instanz tatsaechlich verwaltet: die Sprach-
    // und die Diarisierungs-Instanz haben je einen eigenen Koordinator mit
    // genau einem Installer. Ein fest verdrahtetes .appleSpeech wuerde die
    // Diarisierungs-Installation stillschweigend nie starten.
    private var managedBundleIDs: Set<ModelBundleID> {
        Set(bundleDescriptions.map(\.id))
    }

    private func runInstall(
        coordinator: ModelInstallationCoordinator,
        bundleIDs: Set<ModelBundleID>,
        locale: Locale,
        consentGranted: Bool,
        identity: InstallationIdentity
    ) async -> Bool {
        do {
            try await coordinator.install(
                bundleIDs: bundleIDs,
                for: locale,
                consentGranted: consentGranted
            ) { [weak self] update in
                Task { @MainActor in
                    self?.apply(update, identity: identity)
                }
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if consent.isGranted, !isCancelling {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func isCurrent(_ installation: ActiveInstallation) -> Bool {
        activeInstallation?.identity === installation.identity
    }

    private func canApplyRefresh(owner: InstallationIdentity?) -> Bool {
        if let owner {
            return activeInstallation?.identity === owner
        }
        return activeInstallation == nil
    }

    private func claimCompletion(of installation: ActiveInstallation) -> Bool {
        guard isCurrent(installation), completionOwner == nil else { return false }
        completionOwner = installation.identity
        return true
    }

    private func waitForCompletion(of installation: ActiveInstallation) async {
        guard isCurrent(installation) else { return }
        await withCheckedContinuation { continuation in
            guard isCurrent(installation) else {
                continuation.resume()
                return
            }
            completionWaiters.append(continuation)
        }
    }

    private func finishInstallation(_ installation: ActiveInstallation) {
        guard isCurrent(installation), completionOwner === installation.identity else { return }
        activeInstallation = nil
        completionOwner = nil
        isInstalling = false
        isCancelling = false
        progress = nil
        let waiters = completionWaiters
        completionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func apply(
        _ update: ModelInstallProgress,
        identity: InstallationIdentity
    ) {
        guard activeInstallation?.identity === identity else { return }
        guard update.fraction.isFinite else { return }
        guard update.supersedes(progress) else { return }
        progress = update
    }

    private final class InstallationIdentity: @unchecked Sendable {}

    private struct ActiveInstallation {
        let identity: InstallationIdentity
        let locale: Locale
        let task: Task<Bool, Never>
    }
}

enum IOSModelInstallProgressPresentation: Equatable {
    case indeterminate(title: LocalizedStringResource)
    case determinate(title: String, fraction: Double)

    static func make(
        isInstalling: Bool,
        isCancelling: Bool,
        progress: ModelInstallProgress?
    ) -> Self? {
        guard isInstalling else { return nil }
        if isCancelling {
            return .indeterminate(title: "Cancelling")
        }
        guard let progress else {
            return .indeterminate(title: "Preparing")
        }
        guard progress.fraction.isFinite else {
            return .indeterminate(title: "Preparing")
        }
        return .determinate(
            title: progress.title,
            fraction: min(max(progress.fraction, 0), 1)
        )
    }
}
