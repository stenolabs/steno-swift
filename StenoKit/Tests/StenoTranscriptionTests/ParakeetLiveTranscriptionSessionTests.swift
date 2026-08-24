@preconcurrency import AVFAudio
import FluidAudio
import Foundation
import StenoDomain
import Testing
@testable import StenoTranscription

@Suite("Parakeet live adapter")
struct ParakeetLiveTranscriptionSessionTests {
    @Test("buffers are forwarded once and confirmed ranges are not duplicated")
    func forwardsAndAccumulates() async throws {
        let engine = FakeLiveEngine()
        let session = await ParakeetLiveTranscriptionSession(
            engine: engine,
            channel: .microphone,
            locale: Locale(identifier: "de-DE")
        )
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        pcm.frameLength = 32
        await session.append(try StenoTranscription.AudioBuffer(copying: pcm))
        #expect(await engine.appendCount == 1)

        await engine.send(update("▁Guten", confirmed: true, start: 0, end: 0.5))
        await engine.send(update("▁Guten", confirmed: true, start: 0, end: 0.5))
        await engine.send(update("▁Morgen", confirmed: false, start: 0.5, end: 1))
        await engine.end()
        let result = try await session.finish()

        #expect(await engine.finishCount == 1)
        #expect(result.blocks.first?.words.map(\.text) == ["Guten", "Morgen"])
    }

    @Test("production gate stays closed")
    func productionGateIsClosed() {
        #expect(!TranscriptionExperimentalFeatures.production.parakeetLiveEnabled)
        #expect(!TranscriptionModelCatalog.standard.supports(
            .parakeetTDTv3,
            use: .live,
            locale: Locale(identifier: "de-DE"),
            experimentalLiveEnabled: false
        ))
    }

    @Test("finish returns even when FluidAudio leaves its update stream open")
    func finishDoesNotWaitForUpdateStreamTermination() async throws {
        let engine = FakeLiveEngine(finishText: "Guten Tag")
        let session = await ParakeetLiveTranscriptionSession(
            engine: engine,
            channel: .system,
            locale: Locale(identifier: "de-DE")
        )
        await engine.send(update("▁Guten", confirmed: true, start: 0, end: 0.5))
        await engine.send(update("▁Tag", confirmed: false, start: 0.5, end: 1.0))
        try await Task.sleep(for: .milliseconds(10))
        let completion = CompletionFlag()
        let finishTask = Task {
            let output = try await session.finish()
            await completion.markFinished()
            return output
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await completion.isFinished), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finishedWithoutClosingUpdates = await completion.isFinished
        #expect(finishedWithoutClosingUpdates)

        if !finishedWithoutClosingUpdates {
            await engine.end()
        }
        let output = try await finishTask.value
        #expect(output.blocks.first?.text == "Guten Tag")
    }

    private func update(
        _ token: String,
        confirmed: Bool,
        start: TimeInterval,
        end: TimeInterval
    ) -> ParakeetLiveUpdate {
        ParakeetLiveUpdate(
            text: token,
            isConfirmed: confirmed,
            tokenTimings: [TokenTiming(
                token: token,
                tokenId: 1,
                startTime: start,
                endTime: end,
                confidence: 1
            )]
        )
    }
}

private actor FakeLiveEngine: ParakeetLiveEngine {
    private let stream: AsyncStream<ParakeetLiveUpdate>
    private let continuation: AsyncStream<ParakeetLiveUpdate>.Continuation
    private(set) var appendCount = 0
    private(set) var finishCount = 0
    private let finishText: String

    init(finishText: String = "") {
        (stream, continuation) = AsyncStream.makeStream()
        self.finishText = finishText
    }

    var updates: AsyncStream<ParakeetLiveUpdate> { stream }
    func append(_ buffer: StenoTranscription.AudioBuffer) { appendCount += 1 }
    func finish() -> String {
        finishCount += 1
        return finishText
    }
    func send(_ update: ParakeetLiveUpdate) { continuation.yield(update) }
    func end() { continuation.finish() }
}

private actor CompletionFlag {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}
