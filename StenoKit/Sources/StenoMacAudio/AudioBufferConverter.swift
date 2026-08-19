@preconcurrency import AVFAudio
import Foundation
import StenoAudioCore

final class AudioBufferConverter: @unchecked Sendable {
    private let lock = NSLock()
    private let targetFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) throws {
        self.targetFormat = targetFormat
        self.sourceFormat = sourceFormat
        if sourceFormat == targetFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(
                from: sourceFormat,
                to: targetFormat
            ) else {
                throw AudioRecordingError.audioSourceUnavailable(
                    "cannot convert rebuilt audio format"
                )
            }
            converter.primeMethod = .none
            self.converter = converter
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.withLock {
            if buffer.format != sourceFormat {
                sourceFormat = buffer.format
                if buffer.format == targetFormat {
                    converter = nil
                } else {
                    guard let replacement = AVAudioConverter(
                        from: buffer.format,
                        to: targetFormat
                    ) else { return nil }
                    replacement.primeMethod = .none
                    converter = replacement
                }
            }
            return convertLocked(buffer)
        }
    }

    private func convertLocked(
        _ buffer: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard let converter else {
            return AudioBufferTransfer.copy(buffer)
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up) + 16
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(capacity, buffer.frameLength, 1)
        ) else {
            return nil
        }
        final class FeedState: @unchecked Sendable { var fed = false }
        let state = FeedState()
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, outStatus in
            if state.fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              status != .error,
              output.frameLength > 0 else { return nil }
        return output
    }
}
