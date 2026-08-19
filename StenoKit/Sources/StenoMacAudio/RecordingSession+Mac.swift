import AVFAudio
import Foundation
import StenoAudioCore
import StenoDomain
import StenoLibrary

extension RecordingSession {
    /// The Mac's two-track recording: microphone plus system audio.
    ///
    /// Kept as its own initializer so that callers on this platform read the
    /// same as before the split, and so that the default activity manager can
    /// stay `RecordingActivityManager` - which is macOS-only and therefore
    /// cannot be a default in the shared core.
    public init(
        meetingID: MeetingID,
        library: Library,
        outputDirectory: URL,
        microphoneSource: any AudioSource,
        systemAudioSource: any AudioSource,
        activityManager: any RecordingActivityManaging = RecordingActivityManager(),
        ringCapacity: Int = 64,
        diskCheckInterval: Duration = .seconds(1),
        availableDiskBytes: @escaping @Sendable (URL) throws -> Int64 = {
            try DiskSpaceChecker().availableBytes(at: $0)
        },
        writerFactory: @escaping TrackWriterFactory = {
            try TrackWriter(url: $0, sourceFormat: $1)
        }
    ) {
        precondition(microphoneSource.track == .microphone)
        precondition(systemAudioSource.track == .system)
        self.init(
            meetingID: meetingID,
            library: library,
            outputDirectory: outputDirectory,
            sources: [
                .microphone: microphoneSource,
                .system: systemAudioSource,
            ],
            // Starting the process tap may show macOS' permission dialog and
            // rebuild Core Audio's device graph. Select and bind the physical
            // microphone only after that operation has fully completed.
            sourceOrder: [.system, .microphone],
            activityManager: activityManager,
            ringCapacity: ringCapacity,
            diskCheckInterval: diskCheckInterval,
            availableDiskBytes: availableDiskBytes,
            writerFactory: writerFactory
        )
    }
}
