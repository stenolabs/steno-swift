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

    @Test("shows only the last volatile block from a cumulative snapshot")
    func projectsOnlyCurrentVolatileBlock() {
        var feed = LiveTranscriptFeed()
        let first = block(text: "final one", start: 0, end: 1)
        let second = block(text: "final two", start: 1, end: 2)
        let current = block(text: "current", start: 2, end: 3)

        feed.apply(
            .volatile(output([first, second, current])),
            for: .microphone
        )

        #expect(feed.rows.map(\.block.text) == [
            "final two", "current", "final one",
        ])
        #expect(feed.rows.map(\.kind) == [.final, .volatile, .final])
    }

    @Test("replaces cumulative finals instead of appending duplicates")
    func deduplicatesCumulativeFinals() {
        var feed = LiveTranscriptFeed()
        let first = block(text: "first", start: 0, end: 1)
        let second = block(text: "second", start: 1, end: 2)

        feed.apply(.final(output([first])), for: .microphone)
        feed.apply(.final(output([first, second])), for: .microphone)

        #expect(feed.rows.map(\.block.text) == ["second", "first"])
        #expect(feed.rows.allSatisfy { $0.kind == .final })
    }

    @Test("a later snapshot restores a final whose individual event was skipped")
    func restoresSkippedFinal() {
        var feed = LiveTranscriptFeed()
        let first = block(text: "first", start: 0, end: 1)
        let skipped = block(text: "skipped", start: 1, end: 2)
        let current = block(text: "current", start: 2, end: 3)

        feed.apply(.final(output([first])), for: .microphone)
        feed.apply(
            .volatile(output([first, skipped, current])),
            for: .microphone
        )

        #expect(feed.rows.map(\.block.text) == ["skipped", "current", "first"])
    }

    @Test("orders two channels newest first with volatile rows below the latest final")
    func ordersChannels() {
        var feed = LiveTranscriptFeed()
        let micFinal = block(
            text: "newest final",
            start: 3,
            end: 4,
            channel: .microphone
        )
        let micCurrent = block(
            text: "mic current",
            start: 4,
            end: 5,
            channel: .microphone
        )
        let systemFinal = block(
            text: "older final",
            start: 1,
            end: 2,
            channel: .system
        )
        let systemCurrent = block(
            text: "system current",
            start: 2,
            end: 3,
            channel: .system
        )

        feed.apply(
            .volatile(output([micFinal, micCurrent])),
            for: .microphone
        )
        feed.apply(
            .volatile(output([systemFinal, systemCurrent])),
            for: .system
        )

        #expect(feed.rows.map(\.block.text) == [
            "newest final", "mic current", "system current", "older final",
        ])
    }

    @Test("clearing volatile rows preserves every final row")
    func clearsOnlyVolatileRows() {
        var feed = LiveTranscriptFeed()
        let final = block(text: "final", start: 0, end: 1)
        let current = block(text: "current", start: 1, end: 2)
        feed.apply(.volatile(output([final, current])), for: .microphone)

        feed.clearVolatile()

        #expect(feed.rows.map(\.block.text) == ["final"])
        #expect(!feed.isEmpty)
    }

    @Test("an empty volatile snapshot clears only the current guess")
    func emptyVolatileSnapshotPreservesFinals() {
        var feed = LiveTranscriptFeed()
        let final = block(text: "final", start: 0, end: 1)
        let current = block(text: "current", start: 1, end: 2)
        feed.apply(.volatile(output([final, current])), for: .microphone)

        feed.apply(.volatile(output([])), for: .microphone)

        #expect(feed.rows.map(\.block.text) == ["final"])
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
        end: TimeInterval,
        channel: TranscriptionChannel = .microphone
    ) -> TranscriptionBlock {
        TranscriptionBlock(
            channel: channel,
            text: text,
            start: start,
            end: end,
            words: [TranscriptionWord(text: text, start: start, end: end)]
        )
    }

    private func output(_ blocks: [TranscriptionBlock]) -> TranscriptOutput {
        TranscriptOutput(localeIdentifier: "de-DE", blocks: blocks)
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

@Suite("Live transcript feed channel isolation")
struct LiveTranscriptFeedChannelTests {
    @Test("a capture gap clears only the volatile row of its own track")
    func clearingOneChannelKeepsTheOther() {
        var feed = LiveTranscriptFeed()
        feed.apply(.volatile(output([block("mic guess", channel: .microphone)])), for: .microphone)
        feed.apply(.volatile(output([block("system guess", channel: .system)])), for: .system)

        feed.clearVolatile(for: .microphone)

        #expect(feed.rows.map(\.block.text) == ["system guess"])
    }

    @Test("clearing a channel keeps its finalised rows")
    func clearingKeepsFinalRows() {
        var feed = LiveTranscriptFeed()
        // Ein volatiler Schnappschuss traegt den ganzen Stand: alles ausser
        // dem letzten Block gilt als fertig.
        feed.apply(
            .volatile(output([
                block("said", channel: .microphone, start: 0, end: 1),
                block("guessing", channel: .microphone, start: 1, end: 2),
            ])),
            for: .microphone
        )

        feed.clearVolatile(for: .microphone)

        #expect(feed.rows.map(\.block.text) == ["said"])
    }

    private func block(
        _ text: String,
        channel: TranscriptionChannel,
        start: TimeInterval = 0,
        end: TimeInterval = 1
    ) -> TranscriptionBlock {
        TranscriptionBlock(channel: channel, text: text, start: start, end: end, words: [])
    }

    private func output(_ blocks: [TranscriptionBlock]) -> TranscriptOutput {
        TranscriptOutput(localeIdentifier: "de-DE", blocks: blocks)
    }
}
}
