@preconcurrency import AVFAudio
import FluidAudio
import Foundation
import StenoDomain
import Testing
@testable import StenoTranscription

@Suite("Parakeet transcription provider")
struct ParakeetTranscriptionProviderTests {
    @Test("SentencePiece tokens become bounded monotonic words")
    func mapsWordTimings() async throws {
        let engine = FakeParakeetEngine(result: ParakeetRecognitionResult(
            text: "Guten Morgen",
            duration: 1.5,
            tokenTimings: [
                TokenTiming(token: "▁Guten", tokenId: 1, startTime: -0.2, endTime: 0.7, confidence: 1),
                TokenTiming(token: "▁Mor", tokenId: 2, startTime: 0.6, endTime: 1.0, confidence: 1),
                TokenTiming(token: "gen", tokenId: 3, startTime: 1.0, endTime: 2.0, confidence: 1),
            ]
        ))
        let provider = ParakeetTranscriptionProvider(channel: .system, engine: engine)

        let output = try await provider.transcribeFile(
            URL(fileURLWithPath: "/unused.caf"),
            locale: Locale(identifier: "de-DE")
        )

        let block = try #require(output.blocks.first)
        #expect(block.channel == .system)
        #expect(block.text == "Guten Morgen")
        #expect(block.words.map(\.text) == ["Guten", "Morgen"])
        #expect(block.words[0].start == 0)
        #expect(block.words[1].start >= block.words[0].end)
        #expect(block.words[1].end == 1.5)
    }

    @Test("valid token timings survive a missing engine duration")
    func preservesTimingsWhenEngineDurationIsZero() async throws {
        let engine = FakeParakeetEngine(result: ParakeetRecognitionResult(
            text: "Guten Morgen",
            duration: 0,
            tokenTimings: [
                TokenTiming(token: "▁Guten", tokenId: 1, startTime: 0.2, endTime: 0.8, confidence: 1),
                TokenTiming(token: "▁Morgen", tokenId: 2, startTime: 1.1, endTime: 2.0, confidence: 1),
            ]
        ))
        let provider = ParakeetTranscriptionProvider(channel: .system, engine: engine)

        let output = try await provider.transcribeFile(
            URL(fileURLWithPath: "/unused.caf"),
            locale: Locale(identifier: "de-DE")
        )

        let block = try #require(output.blocks.first)
        #expect(block.start == 0.2)
        #expect(block.end == 2.0)
        #expect(block.words.map(\.start) == [0.2, 1.1])
        #expect(block.words.map(\.end) == [0.8, 2.0])
    }

    @Test("text without timings is rejected")
    func rejectsMissingTimings() async {
        let provider = ParakeetTranscriptionProvider(
            channel: .microphone,
            engine: FakeParakeetEngine(result: ParakeetRecognitionResult(
                text: "Text",
                duration: 1,
                tokenTimings: nil
            ))
        )
        await #expect(throws: TranscriptionError.missingWordTimings) {
            try await provider.transcribeFile(
                URL(fileURLWithPath: "/unused.caf"),
                locale: Locale(identifier: "de-DE")
            )
        }
    }

    @Test("live mode remains gated")
    func liveModeIsUnavailable() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let provider = ParakeetTranscriptionProvider(
            channel: .microphone,
            engine: FakeParakeetEngine(result: ParakeetRecognitionResult(
                text: "", duration: 0, tokenTimings: []
            ))
        )
        await #expect(throws: TranscriptionError.liveModeNotEnabled) {
            try await provider.liveSession(
                format: AudioFormat(format),
                locale: Locale(identifier: "de-DE")
            )
        }
    }
}

private struct FakeParakeetEngine: ParakeetTranscriptionEngine {
    let result: ParakeetRecognitionResult
    func transcribe(_ url: URL, locale: Locale) async throws -> ParakeetRecognitionResult {
        result
    }
}
