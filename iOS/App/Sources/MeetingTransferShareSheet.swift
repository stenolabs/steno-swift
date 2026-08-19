import SwiftUI
import UIKit

@MainActor
final class MeetingTransferShareLifecycle {
    private var didFinish = false
    private let completion: @MainActor () -> Void

    init(completion: @escaping @MainActor () -> Void) {
        self.completion = completion
    }

    func activityDidFinish(completed _: Bool) {
        finish()
    }

    func presentationEnded() {
        finish()
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        completion()
    }
}

struct MeetingTransferShareSheet: UIViewControllerRepresentable {
    let packageURL: URL
    let completion: @MainActor () -> Void

    @MainActor
    final class Coordinator {
        let lifecycle: MeetingTransferShareLifecycle

        init(completion: @escaping @MainActor () -> Void) {
            lifecycle = MeetingTransferShareLifecycle(completion: completion)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: Self.activityItems(packageURL: packageURL),
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { [weak coordinator = context.coordinator]
            _, completed, _, _ in
            Task { @MainActor in
                coordinator?.lifecycle.activityDidFinish(completed: completed)
            }
        }
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}

    static func dismantleUIViewController(
        _: UIActivityViewController,
        coordinator: Coordinator
    ) {
        coordinator.lifecycle.presentationEnded()
    }

    static func activityItems(packageURL: URL) -> [Any] {
        [packageURL]
    }
}
