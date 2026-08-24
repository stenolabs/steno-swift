import Foundation
import StenoDomain
import SwiftUI
import UIKit

enum ReportShareDisclosurePresentation {
    static let title: LocalizedStringResource = "Share report text?"
    static let message: LocalizedStringResource =
        "The selected report text goes to your chosen app or service. Audio, voice evidence, and embeddings are not included."
    static let proceedLabel: LocalizedStringResource = "Choose App or Service"
    static let cancelLabel: LocalizedStringResource = "Cancel"
}

struct ReportShareDisclosureStore {
    static let defaultsKey = "steno.report-share-disclosure-seen.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasSeenDisclosure: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    func markSeen() {
        defaults.set(true, forKey: Self.defaultsKey)
    }
}

struct ReportShareDisclosureState: Equatable {
    struct Request: Equatable {
        let meetingID: MeetingID
        let payload: ReportSharePayload
    }

    private(set) var pendingRequest: Request?
    private(set) var activeRequest: Request?

    var pendingPayload: ReportSharePayload? { pendingRequest?.payload }
    var activePayload: ReportSharePayload? { activeRequest?.payload }

    mutating func request(
        _ payload: ReportSharePayload,
        meetingID: MeetingID,
        disclosureSeen: Bool
    ) {
        let request = Request(meetingID: meetingID, payload: payload)
        if disclosureSeen {
            pendingRequest = nil
            activeRequest = request
        } else {
            pendingRequest = request
            activeRequest = nil
        }
    }

    mutating func cancelDisclosure() {
        pendingRequest = nil
    }

    mutating func proceed(
        meetingID: MeetingID,
        store: ReportShareDisclosureStore
    ) {
        guard let pendingRequest,
              pendingRequest.meetingID == meetingID
        else {
            self.pendingRequest = nil
            return
        }
        store.markSeen()
        self.pendingRequest = nil
        activeRequest = pendingRequest
    }

    mutating func finishSharing() {
        activeRequest = nil
    }

    mutating func discardRequests(notMatching meetingID: MeetingID) {
        if pendingRequest?.meetingID != meetingID {
            pendingRequest = nil
        }
        if activeRequest?.meetingID != meetingID {
            activeRequest = nil
        }
    }

    func isDisclosurePresented(for meetingID: MeetingID) -> Bool {
        pendingRequest?.meetingID == meetingID
    }

    func isSharePresented(for meetingID: MeetingID) -> Bool {
        activeRequest?.meetingID == meetingID
    }
}

@MainActor
final class ReportShareLifecycle {
    private var didFinish = false
    private let completion: @MainActor () -> Void

    init(completion: @escaping @MainActor () -> Void) {
        self.completion = completion
    }

    func activityDidFinish() {
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

struct ReportShareSheet: UIViewControllerRepresentable {
    let text: String
    let completion: @MainActor () -> Void

    @MainActor
    final class Coordinator {
        let lifecycle: ReportShareLifecycle

        init(completion: @escaping @MainActor () -> Void) {
            lifecycle = ReportShareLifecycle(completion: completion)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: Self.activityItems(text: text),
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { [weak coordinator = context.coordinator]
            _, _, _, _ in
            Task { @MainActor in
                coordinator?.lifecycle.activityDidFinish()
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

    static func activityItems(text: String) -> [Any] {
        [text]
    }
}
