import Foundation
import StenoLibrary
import StenoPipeline
import StenoiOSAudio
import Testing
import UIKit
@testable import Steno

@Suite("Microphone permission presentation")
struct MicrophonePermissionPresentationTests {
    @Test("permission status maps to one recoverable action", arguments: [
        (
            RecordPermissionStatus.notDetermined,
            Optional(MicrophonePermissionAction.request)
        ),
        (.denied, Optional(.openSettings)),
        (.authorized, Optional<MicrophonePermissionAction>.none),
    ])
    func permissionAction(
        status: RecordPermissionStatus,
        expected: MicrophonePermissionAction?
    ) {
        #expect(MicrophonePermissionPresentation.action(for: status) == expected)
    }

    @Test("settings action uses the system app-settings URL")
    func settingsURLIsSystemURL() {
        #expect(
            MicrophonePermissionPresentation.settingsURL.absoluteString
                == UIApplication.openSettingsURLString
        )
    }

    @Test("recording permission refresh is read-only and observable")
    @MainActor
    func recordingPermissionRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoPermissionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root)
        let jobStore = try JobStore(layout: library.layout)
        let coordinator = PipelineCoordinator(
            library: library,
            jobStore: jobStore,
            providers: [:],
            locale: Locale(identifier: "de-DE")
        )
        let systemStatus = PermissionStatusSource(.denied)
        let model = RecordingModel(
            session: AudioSessionController(),
            microphonePermissionStatus: { systemStatus.value }
        )
        model.attach(
            runtime: PipelineRuntime(
                library: library,
                jobStore: jobStore,
                coordinator: coordinator
            ),
            notesSessions: MeetingNotesSessionPool(
                store: MeetingNotesStore(layout: library.layout)
            )
        )

        await model.start(
            locale: Locale(identifier: "de-DE"),
            languageWasChosenExplicitly: true
        )

        #expect(model.microphonePermission == .denied)
        #expect(model.state == .failed(RecordingModel.microphoneDeniedMessage))

        systemStatus.value = .authorized
        model.refreshMicrophonePermission()

        #expect(model.microphonePermission == .authorized)
        #expect(model.state == .idle)
    }

    @Test("readiness permission refresh is read-only and observable")
    @MainActor
    func readinessPermissionRefresh() {
        let systemStatus = PermissionStatusSource(.denied)
        let model = AudioReadinessModel(
            session: AudioSessionController(),
            microphonePermissionStatus: { systemStatus.value }
        )

        #expect(model.permission == .denied)

        systemStatus.value = .authorized
        model.refreshMicrophonePermission()

        #expect(model.permission == .authorized)
    }
}

@MainActor
private final class PermissionStatusSource {
    var value: RecordPermissionStatus

    init(_ value: RecordPermissionStatus) {
        self.value = value
    }
}
