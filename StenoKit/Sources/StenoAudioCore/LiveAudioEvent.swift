@preconcurrency import AVFAudio
import Foundation

public struct OwnedAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

public enum TrackGapReason: Equatable, Sendable {
    case deviceUnavailable
    case userPaused
    case sourceStalled
}

public enum LiveAudioEvent: Sendable {
    case buffer(OwnedAudioBuffer)
    case gapStarted(at: TimeInterval, reason: TrackGapReason)
    case gapEnded(at: TimeInterval)
}

public struct LiveAudioEventStream: Sendable {
    public let stream: AsyncStream<LiveAudioEvent>

    public init(stream: AsyncStream<LiveAudioEvent>) {
        self.stream = stream
    }
}

public struct RecordingTrackStatus: Equatable, Sendable {
    public var deviceAvailable: Bool
    public var userPaused: Bool
    public var sourceStalled: Bool
    public var deviceName: String?

    public init(
        deviceAvailable: Bool = true,
        userPaused: Bool = false,
        sourceStalled: Bool = false,
        deviceName: String? = nil
    ) {
        self.deviceAvailable = deviceAvailable
        self.userPaused = userPaused
        self.sourceStalled = sourceStalled
        self.deviceName = deviceName
    }

    public var isPassingRealAudio: Bool {
        deviceAvailable && !userPaused && !sourceStalled
    }
}
