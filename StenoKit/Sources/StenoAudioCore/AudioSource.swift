@preconcurrency import AVFAudio

public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
public typealias AudioSourceEventHandler = @Sendable (AudioSourceEvent) -> Void

public enum AudioSourceEvent: Equatable, Sendable {
    case unavailable(deviceName: String?)
    case available(deviceName: String?)
}

public protocol AudioSource: Sendable {
    var track: AudioTrack { get }
    func prepare() async throws -> AVAudioFormat
    func start(bufferHandler: @escaping AudioBufferHandler) async throws
    func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) async throws
    func stop() async
}

extension AudioSource {
    public func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) async throws {
        try await start(bufferHandler: bufferHandler)
    }
}

public protocol AudioTrackWriting: Sendable {
    var url: URL { get }
    func write(_ buffer: sending AVAudioPCMBuffer) async throws
    func close() async throws -> TrackWriteSummary
}

extension TrackWriter: AudioTrackWriting {}
