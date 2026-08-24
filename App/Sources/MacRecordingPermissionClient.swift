import StenoMacAudio

/// Isolates the two permission operations that can show system UI from the
/// status read that must remain prompt-free during launch.
struct MacRecordingPermissionClient {
    let microphoneStatus: @MainActor () -> AudioPermissionStatus
    let requestMicrophone: @MainActor () async -> AudioPermissionStatus
    let requestRecordingAccess:
        @MainActor () async -> RecordingAudioPermissionState

    static let live = MacRecordingPermissionClient(
        microphoneStatus: {
            AudioPermissions.microphoneStatus()
        },
        requestMicrophone: {
            await AudioPermissions.requestMicrophone()
        },
        requestRecordingAccess: {
            await AudioPermissions.requestRecordingAccess()
        }
    )
}
