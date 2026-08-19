import AVFAudio

public struct AudioLevels: Equatable, Sendable {
    public let peak: Float
    public let rms: Float

    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }

    public static let silence = AudioLevels(peak: 0, rms: 0)
}

public enum AudioLevelMeter {
    public static func measure(_ buffer: AVAudioPCMBuffer) -> AudioLevels {
        let buffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        var peak: Double = 0
        var sumOfSquares: Double = 0
        var sampleCount = 0

        for audioBuffer in buffers {
            guard let data = audioBuffer.mData else { continue }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                accumulate(
                    data.assumingMemoryBound(to: Float.self),
                    count: Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size,
                    peak: &peak,
                    sumOfSquares: &sumOfSquares,
                    sampleCount: &sampleCount
                )
            case .pcmFormatFloat64:
                accumulate(
                    data.assumingMemoryBound(to: Double.self),
                    count: Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size,
                    peak: &peak,
                    sumOfSquares: &sumOfSquares,
                    sampleCount: &sampleCount
                )
            case .pcmFormatInt16:
                accumulateIntegers(
                    data.assumingMemoryBound(to: Int16.self),
                    count: Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size,
                    scale: Double(Int16.max),
                    peak: &peak,
                    sumOfSquares: &sumOfSquares,
                    sampleCount: &sampleCount
                )
            case .pcmFormatInt32:
                accumulateIntegers(
                    data.assumingMemoryBound(to: Int32.self),
                    count: Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size,
                    scale: Double(Int32.max),
                    peak: &peak,
                    sumOfSquares: &sumOfSquares,
                    sampleCount: &sampleCount
                )
            case .otherFormat:
                continue
            @unknown default:
                continue
            }
        }

        guard sampleCount > 0 else { return .silence }
        return AudioLevels(
            peak: Float(min(peak, 1)),
            rms: Float(min(sqrt(sumOfSquares / Double(sampleCount)), 1))
        )
    }

    private static func accumulate<Value: BinaryFloatingPoint>(
        _ values: UnsafePointer<Value>,
        count: Int,
        peak: inout Double,
        sumOfSquares: inout Double,
        sampleCount: inout Int
    ) {
        for index in 0..<count {
            let sample = Double(values[index])
            peak = max(peak, abs(sample))
            sumOfSquares += sample * sample
        }
        sampleCount += count
    }

    private static func accumulateIntegers<Value: FixedWidthInteger>(
        _ values: UnsafePointer<Value>,
        count: Int,
        scale: Double,
        peak: inout Double,
        sumOfSquares: inout Double,
        sampleCount: inout Int
    ) {
        for index in 0..<count {
            let sample = Double(Int64(values[index])) / scale
            peak = max(peak, abs(sample))
            sumOfSquares += sample * sample
        }
        sampleCount += count
    }
}
