import Foundation
import StenoDomain

enum MacModelInstallCancellationState: Equatable {
    case idle
    case cancelling
}

enum MacModelInstallProgressPresentation: Equatable {
    case indeterminate(title: LocalizedStringResource)
    case determinate(title: String, fraction: Double)

    static func make(
        isInstalling: Bool,
        cancellationState: MacModelInstallCancellationState,
        progress: ModelInstallProgress?
    ) -> Self? {
        guard isInstalling else { return nil }
        if cancellationState == .cancelling {
            return .indeterminate(title: "Cancelling")
        }
        guard let progress, progress.fraction.isFinite else {
            return .indeterminate(title: "Preparing")
        }
        return .determinate(
            title: progress.title,
            fraction: min(max(progress.fraction, 0), 1)
        )
    }
}

enum MacModelInstallActionPresentation: Equatable {
    case install(title: LocalizedStringResource)
    case cancel(title: LocalizedStringResource)
    case cancelling(title: LocalizedStringResource)

    static func make(
        isReady: Bool,
        isInstallingAny: Bool = false,
        isActiveInstallation: Bool,
        cancellationState: MacModelInstallCancellationState,
        installTitle: LocalizedStringResource
    ) -> Self? {
        if isActiveInstallation {
            return cancellationState == .cancelling
                ? .cancelling(title: "Cancelling")
                : .cancel(title: "Cancel")
        }
        guard !isReady, !isInstallingAny else { return nil }
        return .install(title: installTitle)
    }
}

struct MacMeetingTransferModelInstallationPresentation: Equatable {
    let progress: MacModelInstallProgressPresentation?
    let action: MacModelInstallActionPresentation?

    static func make(
        canInstall: Bool,
        isInstallingAny: Bool,
        isInstallingBaseline: Bool,
        showsCancellationAction: Bool,
        cancellationState: MacModelInstallCancellationState,
        progress: ModelInstallProgress?
    ) -> Self {
        let action: MacModelInstallActionPresentation?
        if canInstall || isInstallingBaseline {
            action = MacModelInstallActionPresentation.make(
                isReady: false,
                isInstallingAny: isInstallingAny,
                isActiveInstallation: isInstallingBaseline
                    && showsCancellationAction,
                cancellationState: cancellationState,
                installTitle: "Install model and process"
            )
        } else {
            action = nil
        }

        return Self(
            progress: MacModelInstallProgressPresentation.make(
                isInstalling: isInstallingBaseline,
                cancellationState: cancellationState,
                progress: progress
            ),
            action: action
        )
    }
}
