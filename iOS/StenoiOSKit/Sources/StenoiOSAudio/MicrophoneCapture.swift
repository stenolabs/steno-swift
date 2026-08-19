@preconcurrency import AVFAudio
import Foundation
import StenoAudioCore

public enum MicrophoneCaptureError: Error, Equatable, Sendable {
    case alreadyRunning
    case noUsableInputFormat
}

/// Pulls microphone buffers off `AVAudioEngine`.
///
/// The Mac counterpart is `StenoMacAudio.MicRecorder`, and this deliberately
/// mirrors its shape (prepare, start with a buffer handler, stop) so that both
/// can conform to one `AudioSource` protocol once `StenoAudioCore` exists.
/// It stops at the buffer boundary: writing tracks to disk, recovery and the
/// recording session itself are not reimplemented here.
public actor MicrophoneCapture {
    private let engine: AVAudioEngine
    private var format: AVAudioFormat?
    private var isRunning = false

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    /// The format the hardware will actually deliver.
    ///
    /// Taken from the input node rather than requested, so a USB interface
    /// running at 96 kHz is recorded at 96 kHz instead of being resampled
    /// behind the user's back.
    public func prepare() throws -> AVAudioFormat {
        guard !isRunning else { throw MicrophoneCaptureError.alreadyRunning }
        let nativeFormat = engine.inputNode.outputFormat(forBus: 0)
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
    public func start(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        guard !isRunning else { throw MicrophoneCaptureError.alreadyRunning }
        let nativeFormat = try format ?? prepare()
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: nativeFormat
        ) { buffer, _ in
            guard let ownedBuffer = AudioBufferTransfer.copy(buffer) else { return }
            bufferHandler(ownedBuffer)
        }
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    public var running: Bool { isRunning }
}
