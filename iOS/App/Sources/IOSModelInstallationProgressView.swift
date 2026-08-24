import SwiftUI

enum IOSModelInstallationProgressLayout {
    static func axis(for dynamicTypeSize: DynamicTypeSize) -> Axis {
        dynamicTypeSize.isAccessibilitySize ? .vertical : .horizontal
    }
}

/// One truthful installation surface shared by speech, speaker separation,
/// and Parakeet. Until an installer reports actual progress, the native
/// indicator remains indeterminate rather than inventing zero percent.
struct IOSModelInstallationProgressView: View {
    let presentation: IOSModelInstallProgressPresentation
    let isCancelling: Bool
    let cancel: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout: AnyLayout = switch IOSModelInstallationProgressLayout.axis(
            for: dynamicTypeSize
        ) {
        case .horizontal:
            AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        case .vertical:
            AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        }

        layout {
            progressView
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .cancel) {
                cancel()
            } label: {
                Text(cancelTitle)
            }
            .buttonStyle(.bordered)
            .disabled(isCancelling)
            .accessibilityIdentifier("model-install-cancel")
        }
    }

    @ViewBuilder
    private var progressView: some View {
        switch presentation {
        case .indeterminate(let title):
            ProgressView {
                Text(title)
            }
        case .determinate(let title, let fraction):
            ProgressView(value: fraction) {
                // Installer titles are runtime values from StenoKit. Treat
                // them as localization keys here instead of freezing them as
                // already rendered strings in the pure presentation model.
                Text(LocalizedStringKey(title))
            }
        }
    }

    private var cancelTitle: LocalizedStringResource {
        isCancelling ? "Cancelling…" : "Cancel"
    }
}
