import AVFAudio
import StenoAudioCore
import UIKit

/// Makes the iOS microphone usable by the shared `RecordingSession`.
///
/// The capture already had the right shape - prepare, start with a buffer
/// handler, stop - so this is the conformance and nothing else. From here on
/// iOS records through exactly the same session, writer and crash recovery as
/// the Mac.
extension MicrophoneCapture: AudioSource {
    public nonisolated var track: AudioTrack { .microphone }
}

/// Keeps the screen awake while recording.
///
/// iOS has no `beginActivity` with sleep prevention; the equivalent is the
/// idle timer. Audio capture itself survives a locked screen through the
/// `audio` background mode, so this is about the person watching the level,
/// not about the recording continuing.
public actor ScreenAwakeManager: RecordingActivityManaging {
    private var depth = 0

    public init() {}

    public func begin() async {
        depth += 1
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
    }

    public func end() async {
        depth = max(0, depth - 1)
        guard depth == 0 else { return }
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
