import Foundation
import StenoAudioCore

/// The Mac's way of staying awake for a recording: an activity assertion that
/// holds as long as the token does. The protocol lives in `StenoAudioCore`,
/// because every platform prevents sleep with a different API.
public actor RecordingActivityManager: RecordingActivityManaging {
    private var token: (any NSObjectProtocol)?

    public init() {}

    public func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording microphone and system audio"
        )
    }

    public func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
