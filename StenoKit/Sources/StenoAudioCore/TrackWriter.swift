@preconcurrency import AVFAudio
import Foundation

public struct TrackWriteSummary: Equatable, Sendable {
    public let frameCount: AVAudioFramePosition
    public let sampleRate: Double

    public init(frameCount: AVAudioFramePosition, sampleRate: Double) {
        self.frameCount = frameCount
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }
}

public enum TrackWriterError: Error, Equatable, Sendable {
    case closed
    case formatChanged
}

public actor TrackWriter {
    public nonisolated let url: URL
    public nonisolated let sourceFormat: AVAudioFormat

    private var file: AVAudioFile?
    private var frameCount: AVAudioFramePosition = 0
    private var framesSinceSynchronization: AVAudioFramePosition = 0

    public init(url: URL, sourceFormat: AVAudioFormat) throws {
        self.url = url
        self.sourceFormat = sourceFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: Int(sourceFormat.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: sourceFormat.commonFormat,
            interleaved: sourceFormat.isInterleaved
        )
    }

    public func write(_ buffer: sending AVAudioPCMBuffer) throws {
        guard let file else { throw TrackWriterError.closed }
        guard formatsMatch(buffer.format, sourceFormat) else {
            throw TrackWriterError.formatChanged
        }
        try file.write(from: buffer)
        let writtenFrames = AVAudioFramePosition(buffer.frameLength)
        frameCount += writtenFrames
        framesSinceSynchronization += writtenFrames
        if framesSinceSynchronization >= AVAudioFramePosition(sourceFormat.sampleRate) {
            try synchronize()
            framesSinceSynchronization = 0
        }
    }

    @discardableResult
    public func close() throws -> TrackWriteSummary {
        if file != nil {
            file = nil
            try synchronize()
        }
        return TrackWriteSummary(
            frameCount: frameCount,
            sampleRate: sourceFormat.sampleRate
        )
    }

    private func synchronize() throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }
}
