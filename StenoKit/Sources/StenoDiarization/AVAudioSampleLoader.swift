@preconcurrency import AVFAudio
import Foundation
import Synchronization

enum AVAudioSampleLoader {
    static let sampleRate: Double = 16_000
    private static let inputChunkFrames: AVAudioFrameCount = 32_768

    static func load(from url: URL) throws -> [Float] {
        do {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(
                    forReading: url,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                throw DiarizationError.audioDecodingFailed(
                    "AVAudioFile could not open the input: \(error.localizedDescription)"
                )
            }
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw DiarizationError.audioDecodingFailed(
                    "AVAudioFormat rejected the target format"
                )
            }
            guard let sourceMonoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: file.processingFormat.sampleRate,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(
                from: sourceMonoFormat,
                to: targetFormat
            ) else {
                throw DiarizationError.audioDecodingFailed(
                    "the input format cannot be converted"
                )
            }

            var samples: [Float] = []
            if file.length > 0 {
                let estimatedCount = Double(file.length) * sampleRate
                    / file.processingFormat.sampleRate
                samples.reserveCapacity(max(0, Int(estimatedCount.rounded(.up))))
            }

            while file.framePosition < file.length {
                let remainingFrames = file.length - file.framePosition
                let capacity = AVAudioFrameCount(min(
                    AVAudioFramePosition(inputChunkFrames),
                    remainingFrames
                ))
                guard let input = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: capacity
                ) else {
                    throw DiarizationError.audioDecodingFailed(
                        "could not allocate an input buffer"
                    )
                }
                do {
                    try file.read(into: input)
                } catch {
                    throw DiarizationError.audioDecodingFailed(
                        "AVAudioFile could not read the input: \(error.localizedDescription)"
                    )
                }
                if input.frameLength == 0 { break }
                let monoInput = try downmix(input, to: sourceMonoFormat)

                let outputCapacity = AVAudioFrameCount(
                    ceil(Double(monoInput.frameLength) * sampleRate / file.processingFormat.sampleRate)
                ) + 64
                guard let output = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputCapacity
                ) else {
                    throw DiarizationError.audioDecodingFailed(
                        "could not allocate a converted buffer"
                    )
                }

                let suppliedInput = Mutex(false)
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) {
                    _, inputStatus in
                    let shouldSupply = suppliedInput.withLock { supplied in
                        if supplied { return false }
                        supplied = true
                        return true
                    }
                    if shouldSupply {
                        inputStatus.pointee = .haveData
                        return monoInput
                    }
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                if let conversionError {
                    throw DiarizationError.audioDecodingFailed(
                        "AVAudioConverter could not convert the input: \(conversionError.localizedDescription)"
                    )
                }
                guard status != .error else {
                    throw DiarizationError.audioDecodingFailed(
                        "AVAudioConverter returned an unspecified error"
                    )
                }
                append(output, to: &samples)
            }

            try flush(converter, targetFormat: targetFormat, into: &samples)
            guard !samples.isEmpty else { throw DiarizationError.emptyAudio }
            return samples
        } catch let error as DiarizationError {
            throw error
        } catch {
            throw DiarizationError.audioDecodingFailed(error.localizedDescription)
        }
    }

    private static func flush(
        _ converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        into samples: inout [Float]
    ) throws {
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: 4_096
            ) else {
                throw DiarizationError.audioDecodingFailed(
                    "could not allocate a flush buffer"
                )
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError {
                throw DiarizationError.audioDecodingFailed(
                    conversionError.localizedDescription
                )
            }
            if status == .error {
                throw DiarizationError.audioDecodingFailed(
                    "AVAudioConverter could not flush pending audio"
                )
            }
            append(output, to: &samples)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
    }

    private static func append(
        _ buffer: AVAudioPCMBuffer,
        to samples: inout [Float]
    ) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return
        }
        samples.append(contentsOf: UnsafeBufferPointer(
            start: channel,
            count: Int(buffer.frameLength)
        ))
    }

    private static func downmix(
        _ input: AVAudioPCMBuffer,
        to monoFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard input.format.channelCount > 1 else { return input }
        guard
            let sourceChannels = input.floatChannelData,
            let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: input.frameLength
            ),
            let destination = mono.floatChannelData?[0]
        else {
            throw DiarizationError.audioDecodingFailed(
                "could not allocate a mono mixdown buffer"
            )
        }
        mono.frameLength = input.frameLength
        let channelCount = Int(input.format.channelCount)
        let scale = Float(1) / Float(channelCount)
        for frame in 0..<Int(input.frameLength) {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += sourceChannels[channel][frame]
            }
            destination[frame] = sum * scale
        }
        return mono
    }
}
