import Foundation
import os

/// Gates the "Meeting detected" notification (stenoai parity, F4).
///
/// The `MicrophoneActivityMonitor` in StenoMacAudio detects the raw episodes;
/// this controller decides whether a notification is actually posted:
///
/// - The feature respects `steno.meetingDetection.enabled` (default on).
/// - Episodes that begin while Steno itself is recording are suppressed —
///   the user already knows a meeting is happening.
/// - At most one notification fires per external-capture episode; the
///   controller re-arms when the monitor reports the episode ended.
@MainActor
final class MeetingDetectionController {
    private let postMeetingDetected: () -> Void
    private let isRecordingProvider: () -> Bool
    private let defaults: UserDefaults

    /// True while an external capture episode is in flight; guarantees at
    /// most one notification per episode and re-arms on end.
    private var isInExternalEpisode = false

    init(
        postMeetingDetected: @escaping () -> Void,
        isRecordingProvider: @escaping () -> Bool,
        defaults: UserDefaults = .standard
    ) {
        self.postMeetingDetected = postMeetingDetected
        self.isRecordingProvider = isRecordingProvider
        self.defaults = defaults
    }

    static let isEnabledDefaultsKey = "steno.meetingDetection.enabled"

    /// On by default; only an explicit `false` turns detection off.
    var isEnabled: Bool {
        if defaults.object(forKey: Self.isEnabledDefaultsKey) == nil { return true }
        return defaults.bool(forKey: Self.isEnabledDefaultsKey)
    }

    /// Call from `MicrophoneActivityMonitor.onExternalCaptureStart`.
    func externalCaptureStarted() {
        isInExternalEpisode = true
        guard isEnabled else {
            Self.log.debug("Meeting detected but feature disabled")
            return
        }
        guard !isRecordingProvider() else {
            Self.log.debug("Meeting detected while recording; suppressed")
            return
        }
        Self.log.notice("Meeting detected")
        postMeetingDetected()
    }

    /// Call from `MicrophoneActivityMonitor.onExternalCaptureEnd`; re-arms
    /// for the next episode.
    func externalCaptureEnded() {
        isInExternalEpisode = false
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.steno",
        category: "meeting-detection"
    )
}
