import AVFAudio
import Foundation
import Testing
@testable import StenoAudioCore

@Suite("TrackWriter")
struct TrackWriterTests {
    @Test("writes synthetic native buffers as readable 16-bit linear PCM CAF")
    func writesCAF() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("track.caf")
        let first = syntheticBuffer()
        let second = syntheticBuffer()
        let writer = try TrackWriter(url: url, sourceFormat: first.format)

        try await writer.write(first)
        try await writer.write(second)
        let summary = try await writer.close()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(file.fileFormat.sampleRate == 8_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 8_000)
        #expect(summary.frameCount == 8_000)
        #expect(summary.duration == 1)
    }

    @Test("synchronizes an incrementally written prefix after about one second")
    func synchronizesPrefix() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("prefix.caf")
        let buffer = syntheticBuffer(frames: 16_000)
        let writer = try TrackWriter(url: url, sourceFormat: buffer.format)

        try await writer.write(buffer)

        let prefix = try AVAudioFile(forReading: url)
        #expect(prefix.length >= 8_000)
        _ = try await writer.close()
    }

    @Test("rejects a buffer whose native format changes mid-track")
    func rejectsFormatChange() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("format-change.caf")
        let first = syntheticBuffer(sampleRate: 8_000)
        let writer = try TrackWriter(url: url, sourceFormat: first.format)

        await #expect(throws: TrackWriterError.self) {
            try await writer.write(syntheticBuffer(sampleRate: 16_000))
        }
        _ = try await writer.close()
    }
}
