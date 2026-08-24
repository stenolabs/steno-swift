import Foundation
import StenoMacAudio
import Testing
@testable import steno_macos

@Suite("Onboarding permission presentation", .serialized)
@MainActor
struct OnboardingPermissionPresentationTests {
    @Test("authorized access is the only positive permission state")
    func highlightsOnlyAuthorizedAccessAsSuccessful() {
        let authorized = RecordingPermissionPresentation(
            status: .authorized
        )

        #expect(authorized.tone == .success)
        #expect(authorized.symbolName == "checkmark.circle.fill")
        #expect(authorized.text == "Allowed")

        for status in [
            AudioPermissionStatus.notDetermined,
            .restricted,
            .denied,
        ] {
            #expect(
                RecordingPermissionPresentation(status: status).tone
                    != .success
            )
        }
    }

    @Test("launch reads permission status without requesting access")
    func launchOnlyReadsPermissionStatus() async throws {
        let suiteName = "StenoTests.permissions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let calls = PermissionCallCounter()
        let client = MacRecordingPermissionClient(
            microphoneStatus: {
                calls.statusReads += 1
                return .denied
            },
            requestMicrophone: {
                calls.microphoneRequests += 1
                return .authorized
            },
            requestRecordingAccess: {
                calls.microphoneRequests += 1
                calls.systemAudioProbes += 1
                return RecordingAudioPermissionState(
                    microphone: .authorized,
                    systemAudio: .authorized
                )
            }
        )
        let model = AppModel(
            recordingPermissionClient: client,
            recordingPermissionDefaults: defaults,
            recordingPermissionIdentity: { "test-code-identity" }
        )

        model.refreshRecordingPermissionStatus()

        #expect(calls.statusReads == 1)
        #expect(calls.microphoneRequests == 0)
        #expect(calls.systemAudioProbes == 0)
        #expect(model.recordingPermissions.microphone == .denied)
        #expect(model.recordingPermissions.systemAudio == .notDetermined)

        await model.requestRecordingPermissions(forceSystemAudioProbe: true)

        #expect(calls.statusReads == 1)
        #expect(calls.microphoneRequests == 1)
        #expect(calls.systemAudioProbes == 1)
        #expect(model.recordingPermissions.microphone == .authorized)
        #expect(model.recordingPermissions.systemAudio == .authorized)
    }

    @Test(
        "launch reuses a definitive system audio decision for the same code identity",
        arguments: [
            AudioPermissionStatus.authorized,
            .denied,
        ]
    )
    func launchReusesSystemAudioCache(status: AudioPermissionStatus) throws {
        let suiteName = "StenoTests.permissions.cache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            status.rawValue,
            forKey: AppModel.systemAudioPermissionDefaultsKey
        )
        defaults.set(
            "same-code-identity",
            forKey: AppModel.systemAudioPermissionIdentityDefaultsKey
        )
        let calls = PermissionCallCounter()
        let model = AppModel(
            recordingPermissionClient: permissionClient(calls: calls),
            recordingPermissionDefaults: defaults,
            recordingPermissionIdentity: { "same-code-identity" }
        )

        model.refreshRecordingPermissionStatus()

        #expect(model.recordingPermissions.systemAudio == status)
        #expect(calls.statusReads == 1)
        #expect(calls.microphoneRequests == 0)
        #expect(calls.systemAudioProbes == 0)
    }

    @Test("launch ignores a system audio decision from another code identity")
    func launchRejectsStaleSystemAudioCache() throws {
        let suiteName = "StenoTests.permissions.stale.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            AudioPermissionStatus.authorized.rawValue,
            forKey: AppModel.systemAudioPermissionDefaultsKey
        )
        defaults.set(
            "old-code-identity",
            forKey: AppModel.systemAudioPermissionIdentityDefaultsKey
        )
        let calls = PermissionCallCounter()
        let model = AppModel(
            recordingPermissionClient: permissionClient(calls: calls),
            recordingPermissionDefaults: defaults,
            recordingPermissionIdentity: { "new-code-identity" }
        )

        model.refreshRecordingPermissionStatus()

        #expect(model.recordingPermissions.systemAudio == .notDetermined)
        #expect(calls.statusReads == 1)
        #expect(calls.microphoneRequests == 0)
        #expect(calls.systemAudioProbes == 0)
    }

    @Test("a permission request publishes a blocking state until it completes")
    func permissionRequestBlocksRecordingStart() async throws {
        let suiteName = "StenoTests.permissions.gate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gate = PermissionRequestGate()
        let calls = PermissionCallCounter()
        let client = MacRecordingPermissionClient(
            microphoneStatus: { .notDetermined },
            requestMicrophone: {
                calls.microphoneRequests += 1
                return .authorized
            },
            requestRecordingAccess: {
                calls.microphoneRequests += 1
                calls.systemAudioProbes += 1
                await gate.suspendUntilReleased()
                return RecordingAudioPermissionState(
                    microphone: .authorized,
                    systemAudio: .authorized
                )
            }
        )
        let model = AppModel(
            recordingPermissionClient: client,
            recordingPermissionDefaults: defaults,
            recordingPermissionIdentity: { "test-code-identity" }
        )
        let request = Task {
            await model.requestRecordingPermissions(
                forceSystemAudioProbe: true
            )
        }

        await gate.waitUntilStarted()

        #expect(model.isResolvingRecordingPermissions)
        #expect(!StenoCommandState(
            hasRuntime: true,
            isRecording: false,
            isStartingRecording: false,
            isResolvingRecordingPermissions:
                model.isResolvingRecordingPermissions
        ).canStartRecording)

        await gate.release()
        await request.value

        #expect(!model.isResolvingRecordingPermissions)
        #expect(calls.microphoneRequests == 1)
        #expect(calls.systemAudioProbes == 1)
    }

    private func permissionClient(
        calls: PermissionCallCounter
    ) -> MacRecordingPermissionClient {
        MacRecordingPermissionClient(
            microphoneStatus: {
                calls.statusReads += 1
                return .denied
            },
            requestMicrophone: {
                calls.microphoneRequests += 1
                return .authorized
            },
            requestRecordingAccess: {
                calls.microphoneRequests += 1
                calls.systemAudioProbes += 1
                return RecordingAudioPermissionState(
                    microphone: .authorized,
                    systemAudio: .authorized
                )
            }
        )
    }
}

@MainActor
private final class PermissionCallCounter {
    var statusReads = 0
    var microphoneRequests = 0
    var systemAudioProbes = 0
}

private actor PermissionRequestGate {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
