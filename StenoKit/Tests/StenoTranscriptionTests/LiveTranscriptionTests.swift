@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import StenoTranscription

@Suite("Live transcription support")
struct LiveTranscriptionTests {
    @Test("accumulates only final blocks while emitting both event kinds")
    func accumulatesFinalResults() {
        var accumulator = TranscriptionAccumulator(localeIdentifier: "de-DE")
        let volatile = block(text: "Hal", start: 0, end: 0.4)
        let final = block(text: "Hallo", start: 0, end: 0.7)

        #expect(accumulator.record(volatile, isFinal: false) == .volatile(
            TranscriptOutput(localeIdentifier: "de-DE", blocks: [volatile])
        ))
        #expect(accumulator.record(final, isFinal: true) == .final(
            TranscriptOutput(localeIdentifier: "de-DE", blocks: [final])
        ))
        #expect(accumulator.output == TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: [final]
        ))
    }

    @Test("feeds every RecordingSession-style AsyncStream buffer into a live session")
    func feedsAudioStream() async throws {
        let session = FakeLiveSession()
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let first = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        first.frameLength = 160
        let second = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        second.frameLength = 320
        let pair = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        pair.continuation.yield(first)
        pair.continuation.yield(second)
        pair.continuation.finish()

        try await session.append(pair.stream)

        #expect(await session.receivedFrameLengths() == [160, 320])
    }

    @Test("bounded analyzer input reports overload instead of growing without limit")
    func boundsAnalyzerInput() {
        let input = BoundedAsyncBuffer<Int>(capacity: 2)

        #expect(input.yield(1))
        #expect(input.yield(2))
        #expect(!input.yield(3))
        input.finish()
    }

    @Test("public audio values own a copy instead of exposing mutable AV buffers")
    func ownsAudioAtContractBoundary() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let source = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 160
        ))
        source.frameLength = 160
        source.floatChannelData?[0][0] = 0.25

        let owned = try StenoTranscription.AudioBuffer(copying: source)
        let valueFormat = StenoTranscription.AudioFormat(format)
        source.floatChannelData?[0][0] = 0.75

        #expect(owned.frameLength == 160)
        #expect(owned.avAudioPCMBuffer.floatChannelData?[0][0] == 0.25)
        #expect(valueFormat.sampleRate == 16_000)
        #expect(valueFormat.channelCount == 1)
    }

    @Test("shifts every transcript timestamp onto the meeting timeline")
    func shiftsTranscriptOutput() {
        let output = TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: [
                TranscriptionBlock(
                    channel: .system,
                    text: "Hallo Welt",
                    start: 0.5,
                    end: 1.5,
                    words: [
                        TranscriptionWord(text: "Hallo", start: 0.5, end: 1),
                        TranscriptionWord(text: "Welt", start: 1, end: 1.5),
                    ]
                ),
            ]
        )

        let shifted = output.shifted(by: 20)

        #expect(shifted.localeIdentifier == "de-DE")
        #expect(shifted.blocks.first?.channel == .system)
        #expect(shifted.blocks.first?.text == "Hallo Welt")
        #expect(shifted.blocks.first?.start == 20.5)
        #expect(shifted.blocks.first?.end == 21.5)
        #expect(shifted.blocks.first?.words.map(\.start) == [20.5, 21])
        #expect(shifted.blocks.first?.words.map(\.end) == [21, 21.5])
    }

    private func block(
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptionBlock {
        TranscriptionBlock(
            channel: .microphone,
            text: text,
            start: start,
            end: end,
            words: [TranscriptionWord(text: text, start: start, end: end)]
        )
    }
}

private actor FakeLiveSession: LiveTranscriptionSession {
    nonisolated let events = AsyncStream<TranscriptionEvent> { $0.finish() }
    private var frameLengths: [AVAudioFrameCount] = []

    func append(_ buffer: StenoTranscription.AudioBuffer) {
        frameLengths.append(buffer.frameLength)
    }

    func finish() -> TranscriptOutput {
        TranscriptOutput(localeIdentifier: "de-DE", blocks: [])
    }

    func receivedFrameLengths() -> [AVAudioFrameCount] {
        frameLengths
    }
}
