import Foundation

public enum AudioRecordingError: Error, Equatable, Sendable {
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case audioSourceUnavailable(String)
    case alreadyRecording
    case notRecording
    case writerFailed(track: AudioTrack, message: String)
    case ringBufferOverflow(track: AudioTrack)
    case diskSpaceMonitoringFailed(message: String)
    case systemAudioPermissionDenied
    case coreAudio(operation: String, status: Int32)
}

extension AudioRecordingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let required, let available):
            "Recording needs at least \(required) free bytes; only \(available) are available."
        case .audioSourceUnavailable(let reason):
            "The audio source is unavailable: \(reason)"
        case .alreadyRecording:
            "A recording is already running."
        case .notRecording:
            "No recording is running."
        case .writerFailed(let track, let message):
            "Writing the \(track.rawValue) track failed: \(message)"
        case .ringBufferOverflow(let track):
            "The \(track.rawValue) recording buffer could not keep up."
        case .diskSpaceMonitoringFailed(let message):
            "Free disk space could not be monitored continuously: \(message)"
        case .systemAudioPermissionDenied:
            "System audio capture is not permitted. Allow Audio Recording in System Settings, then try again."
        case .coreAudio(let operation, let status):
            "Core Audio operation \(operation) failed with status \(status)."
        }
    }
}

public enum AudioTrack: String, CaseIterable, Sendable {
    case microphone
    case system
}
