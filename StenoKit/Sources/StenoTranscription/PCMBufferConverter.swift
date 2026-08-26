@preconcurrency import AVFAudio
import Foundation

final class PCMBufferConverter {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        if buffer.format == targetFormat {
            return [buffer]
        }
        let converter = try converter(for: buffer.format)
        let capacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)
        ) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            throw TranscriptionError.audioConversionFailed(
                "could not allocate the converted buffer"
            )
        }

        let suppliedInput = OneShotConverterInputGate()
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            let shouldSupply = suppliedInput.claim()
            if !shouldSupply {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            throw TranscriptionError.audioConversionFailed(
                conversionError.localizedDescription
            )
        }
        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength == 0 ? [] : [output]
        case .endOfStream:
            return []
        case .error:
            throw TranscriptionError.audioConversionFailed(
                "AVAudioConverter returned an unspecified error"
            )
        @unknown default:
            throw TranscriptionError.audioConversionFailed(
                "AVAudioConverter returned an unknown status"
            )
        }
    }

    func flush() throws -> [AVAudioPCMBuffer] {
        guard let converter, let sourceFormat else { return [] }
        let capacity = AVAudioFrameCount(
            ceil(4_096 * targetFormat.sampleRate / sourceFormat.sampleRate)
        ) + 64
        var outputs: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
            ) else {
                throw TranscriptionError.audioConversionFailed(
                    "could not allocate a flush buffer"
                )
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError {
                throw TranscriptionError.audioConversionFailed(
                    conversionError.localizedDescription
                )
            }
            if output.frameLength > 0 {
                outputs.append(output)
            }
            if status == .endOfStream || output.frameLength == 0 {
                return outputs
            }
            if status == .error {
                throw TranscriptionError.audioConversionFailed(
                    "AVAudioConverter could not flush pending audio"
                )
            }
        }
    }

    private func converter(for format: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, sourceFormat == format {
            return converter
        }
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw TranscriptionError.audioConversionFailed(
                "formats are incompatible"
            )
        }
        self.converter = converter
        sourceFormat = format
        return converter
    }
}

/// One-shot flag for an ``AVAudioConverter`` input block.
///
/// Works around a Swift 6.4 frontend crash ("copy of noncopyable typed
/// value") triggered by `Mutex.withLock` inside converter input closures;
/// semantics are identical to the previous `Mutex(false)`.
private final class OneShotConverterInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var supplied = false

    /// Returns true exactly once; every later call returns false.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if supplied { return false }
        supplied = true
        return true
    }
}
