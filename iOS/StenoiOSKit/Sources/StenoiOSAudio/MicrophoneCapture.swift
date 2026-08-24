@preconcurrency import AVFAudio
import Foundation
import StenoAudioCore

public enum MicrophoneCaptureError: Error, Equatable, Sendable {
    case alreadyRunning
    case noUsableInputFormat
    case inputFormatChanged
}

protocol MicrophoneCaptureBackend: Sendable {
    func inputFormat() -> AVAudioFormat
    func installTap(
        bufferHandler: @escaping AudioBufferHandler
    )
    func removeTap()
    func prepare()
    func start() throws
    func stop()
}

private final class AVAudioEngineMicrophoneCaptureBackend:
    MicrophoneCaptureBackend, @unchecked Sendable
{
    let engine: AVAudioEngine

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    func inputFormat() -> AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func installTap(
        bufferHandler: @escaping AudioBufferHandler
    ) {
        // Let the input node choose its current format. Supplying a format
        // read immediately before a route change can raise an Objective-C
        // exception before the configuration notification reaches the actor.
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: nil
        ) { buffer, _ in
            guard let ownedBuffer = AudioBufferTransfer.copy(buffer) else { return }
            bufferHandler(ownedBuffer)
        }
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}

enum MicrophoneConfigurationChangeResult: Equatable, Sendable {
    case ignored
    case restarted
    case failed
}

/// Pulls microphone buffers off `AVAudioEngine`.
///
/// The Mac counterpart is `StenoMacAudio.MicRecorder`, and this deliberately
/// mirrors its shape (prepare, start with a buffer handler, stop) so that both
/// can conform to one `AudioSource` protocol once `StenoAudioCore` exists.
/// It stops at the buffer boundary: writing tracks to disk, recovery and the
/// recording session itself are not reimplemented here.
public actor MicrophoneCapture {
    private let backend: any MicrophoneCaptureBackend
    private let notificationObject: AnyObject?
    private var format: AVAudioFormat?
    private var activeFormat: AVAudioFormat?
    private var isRunning = false
    private var tapInstalled = false
    private var bufferHandler: AudioBufferHandler?
    private var eventHandler: AudioSourceEventHandler?
    private var configurationObserver: NSObjectProtocol?

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        backend = AVAudioEngineMicrophoneCaptureBackend(engine: engine)
        notificationObject = engine
    }

    init(backend: any MicrophoneCaptureBackend) {
        self.backend = backend
        notificationObject = nil
    }

    /// The format the hardware will actually deliver.
    ///
    /// Taken from the input node rather than requested, so a USB interface
    /// running at 96 kHz is recorded at 96 kHz instead of being resampled
    /// behind the user's back.
    public func prepare() throws -> AVAudioFormat {
        guard !isRunning else { throw MicrophoneCaptureError.alreadyRunning }
        startObservingConfigurationChangesIfNeeded()
        let nativeFormat = backend.inputFormat()
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw MicrophoneCaptureError.noUsableInputFormat
        }
        format = nativeFormat
        return nativeFormat
    }

    /// Starts the tap.
    ///
    /// - Important: `bufferHandler` receives a copy it owns, so it may hand the
    ///   buffer to another task. The buffer the engine passes in is only valid
    ///   for the duration of the call; forwarding *that* one would be a
    ///   use-after-free, and `RecordingSession` does forward it, into a stream
    ///   that is consumed asynchronously. The copy happens here rather than at
    ///   every call site because getting it wrong corrupts the original track,
    ///   and a corrupted original cannot be recovered from anywhere.
    /// - Note: The handler runs on a real-time audio thread. Anything slow in
    ///   it drops samples. `AudioBufferTransfer.copy` is a single allocation
    ///   plus a memcpy, the same cost the Mac side pays.
    /// Both overloads must stay explicitly async even though actor isolation
    /// already requires await. Otherwise a concrete call can silently select
    /// the `AudioSource` default and discard its event handler.
    public func start(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        try await start(bufferHandler: bufferHandler, eventHandler: { _ in })
    }

    public func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) async throws {
        guard !isRunning else { throw MicrophoneCaptureError.alreadyRunning }
        self.bufferHandler = bufferHandler
        self.eventHandler = eventHandler
        startObservingConfigurationChangesIfNeeded()
        do {
            try startEngine()
        } catch {
            cleanUpEngine()
            format = nil
            activeFormat = nil
            self.bufferHandler = nil
            self.eventHandler = nil
            throw error
        }
    }

    public func stop() {
        cleanUpEngine()
        format = nil
        activeFormat = nil
        bufferHandler = nil
        eventHandler = nil
    }

    public var running: Bool { isRunning }

    @discardableResult
    func handleConfigurationChange() -> MicrophoneConfigurationChangeResult {
        format = nil
        guard isRunning else { return .ignored }

        isRunning = false
        eventHandler?(.unavailable(deviceName: nil))
        cleanUpEngine()

        do {
            try startEngine()
            eventHandler?(.available(deviceName: nil))
            return .restarted
        } catch {
            cleanUpEngine()
            return .failed
        }
    }

    private func startEngine() throws {
        guard let bufferHandler else {
            throw MicrophoneCaptureError.noUsableInputFormat
        }
        let nativeFormat = try format ?? prepare()
        if let activeFormat, !Self.formatsMatch(nativeFormat, activeFormat) {
            // TrackWriter cannot change the format of an existing original.
            // Stopping preserves that original instead of feeding it buffers
            // that it cannot write or silently pretending to continue.
            throw MicrophoneCaptureError.inputFormatChanged
        }
        if activeFormat == nil {
            activeFormat = nativeFormat
        }
        backend.installTap(bufferHandler: bufferHandler)
        tapInstalled = true
        do {
            backend.prepare()
            try backend.start()
            isRunning = true
        } catch {
            cleanUpEngine()
            throw error
        }
    }

    private func cleanUpEngine() {
        if tapInstalled {
            backend.removeTap()
            tapInstalled = false
        }
        backend.stop()
        isRunning = false
    }

    private func startObservingConfigurationChangesIfNeeded() {
        guard configurationObserver == nil, let notificationObject else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: notificationObject,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleConfigurationChange() }
        }
    }

    private static func formatsMatch(
        _ lhs: AVAudioFormat,
        _ rhs: AVAudioFormat
    ) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }
}
