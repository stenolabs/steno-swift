import AVFAudio

/// Microphone permission on iOS.
///
/// The Mac side asks `AVCaptureDevice`; on iOS the audio-only entry point is
/// `AVAudioApplication`, which is what the system settings pane reflects.
/// The case names match `StenoMacAudio.AudioPermissionStatus` so that the two
/// platforms can share one UI vocabulary once `StenoAudioCore` exists.
public enum RecordPermissionStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

public enum RecordPermission {
    public static func status() -> RecordPermissionStatus {
        status(from: AVAudioApplication.shared.recordPermission)
    }

    /// Asks the user once. Returns the resulting status rather than a bare
    /// `Bool`, because "denied" and "still undecided" need different UI.
    public static func request() async -> RecordPermissionStatus {
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? .authorized : status()
    }

    static func status(
        from permission: AVAudioApplication.recordPermission
    ) -> RecordPermissionStatus {
        switch permission {
        case .undetermined:
            .notDetermined
        case .denied:
            .denied
        case .granted:
            .authorized
        @unknown default:
            .denied
        }
    }
}
