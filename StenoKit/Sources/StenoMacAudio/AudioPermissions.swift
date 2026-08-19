@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import StenoAudioCore
import StenoDomain

public enum AudioPermissionStatus: String, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
}

public struct RecordingAudioPermissionState: Equatable, Sendable {
    public let microphone: AudioPermissionStatus
    public let systemAudio: AudioPermissionStatus
    public let systemAudioError: String?

    public init(
        microphone: AudioPermissionStatus = .notDetermined,
        systemAudio: AudioPermissionStatus = .notDetermined,
        systemAudioError: String? = nil
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.systemAudioError = systemAudioError
    }
}

enum SystemAudioPermissionAttempt: Equatable, Sendable {
    case status(AudioPermissionStatus)
    case failed(String)
}

public enum AudioPermissions {
    public static func microphoneStatus() -> AudioPermissionStatus {
        microphoneStatus(
            from: AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }

    public static func requestMicrophone() async -> AudioPermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if granted { return .authorized }
        return microphoneStatus()
    }

    static func microphoneStatus(
        from status: AVAuthorizationStatus
    ) -> AudioPermissionStatus {
        switch status {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorized:
            .authorized
        @unknown default:
            .denied
        }
    }

    public static func systemAudioStatus(
        forCaptureStatus status: OSStatus?
    ) -> AudioPermissionStatus {
        guard let status else { return .notDetermined }
        if status == noErr { return .authorized }
        if status == kAudioDevicePermissionsError { return .denied }
        return .notDetermined
    }

    public static func requestRecordingAccess() async -> RecordingAudioPermissionState {
        await requestRecordingAccess(
            microphone: { await requestMicrophone() },
            systemAudio: { await requestSystemAudio() }
        )
    }

    static func requestRecordingAccess(
        microphone: @Sendable () async -> AudioPermissionStatus,
        systemAudio: @Sendable () async -> SystemAudioPermissionAttempt
    ) async -> RecordingAudioPermissionState {
        let microphoneStatus = await microphone()
        switch await systemAudio() {
        case .status(let systemAudioStatus):
            return RecordingAudioPermissionState(
                microphone: microphoneStatus,
                systemAudio: systemAudioStatus
            )
        case .failed(let message):
            return RecordingAudioPermissionState(
                microphone: microphoneStatus,
                systemAudioError: message
            )
        }
    }

    static func requestSystemAudio(
        using recorder: any AudioSource = SystemAudioRecorder()
    ) async -> SystemAudioPermissionAttempt {
        do {
            _ = try await recorder.prepare()
            try await recorder.start(bufferHandler: { _ in })
            await recorder.stop()
            return .status(.authorized)
        } catch AudioRecordingError.systemAudioPermissionDenied {
            await recorder.stop()
            return .status(.denied)
        } catch {
            await recorder.stop()
            return .failed(error.localizedDescription)
        }
    }
}
