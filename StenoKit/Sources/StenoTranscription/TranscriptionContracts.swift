@preconcurrency import AVFAudio
import Darwin
import Foundation
import StenoDomain

public struct AudioFormat: Equatable, Sendable {
    public let commonFormat: AVAudioCommonFormat
    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    public let isInterleaved: Bool

    public init(_ format: AVAudioFormat) {
        commonFormat = format.commonFormat
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        isInterleaved = format.isInterleaved
    }

    var avAudioFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: isInterleaved
        )
    }
}

public struct AudioBuffer: @unchecked Sendable {
    let avAudioPCMBuffer: AVAudioPCMBuffer

    public var frameLength: AVAudioFrameCount {
        avAudioPCMBuffer.frameLength
    }

    public init(copying source: AVAudioPCMBuffer) throws {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            throw TranscriptionError.audioConversionFailed(
                "could not allocate an owned audio buffer"
            )
        }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            throw TranscriptionError.audioConversionFailed(
                "the copied audio buffer layout changed"
            )
        }
        for index in sourceBuffers.indices {
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            guard byteCount == 0 || (
                sourceBuffers[index].mData != nil
                    && destinationBuffers[index].mData != nil
            ) else {
                throw TranscriptionError.audioConversionFailed(
                    "the copied audio buffer contains inaccessible data"
                )
            }
            if byteCount > 0 {
                memcpy(
                    destinationBuffers[index].mData!,
                    sourceBuffers[index].mData!,
                    byteCount
                )
                destinationBuffers[index].mDataByteSize = UInt32(byteCount)
            }
        }
        avAudioPCMBuffer = destination
    }

}

public protocol TranscriptionProvider: Sendable {
    var descriptor: EngineDescriptor { get }

    func liveSession(
        format: AudioFormat,
        locale: Locale
    ) async throws -> any LiveTranscriptionSession

    func transcribeFile(
        _ url: URL,
        locale: Locale
    ) async throws -> TranscriptOutput
}

public protocol LiveTranscriptionSession: Sendable {
    func append(_ buffer: AudioBuffer) async
    var events: AsyncStream<TranscriptionEvent> { get }
    func finish() async throws -> TranscriptOutput
}

public extension LiveTranscriptionSession {
    func append(_ buffers: AsyncStream<AVAudioPCMBuffer>) async throws {
        for await buffer in buffers {
            await append(try AudioBuffer(copying: buffer))
        }
    }
}
