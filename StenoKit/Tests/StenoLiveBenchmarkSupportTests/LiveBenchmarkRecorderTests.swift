import Foundation
import StenoLiveBenchmarkSupport
import Testing

@Suite("Live ASR benchmark recording")
struct LiveBenchmarkRecorderTests {
    @Test("records changed non-empty snapshots with audio and wall clocks")
    func recordsChangedSnapshots() async {
        let clock = TestClock()
        let recorder = LiveBenchmarkRecorder(now: { clock.now() })

        await recorder.setAudioSecondsFed(1.25)
        clock.advance(to: 0.4)
        await recorder.record(kind: .volatile, text: "  Hallo ")
        clock.advance(to: 0.6)
        await recorder.record(kind: .volatile, text: "Hallo")
        await recorder.setAudioSecondsFed(2.0)
        clock.advance(to: 0.9)
        await recorder.record(kind: .final, text: "Hallo Welt")

        let updates = await recorder.updates()

        #expect(updates == [
            LiveBenchmarkUpdate(
                kind: .volatile,
                wallSeconds: 0.4,
                audioSecondsFed: 1.25,
                text: "Hallo"
            ),
            LiveBenchmarkUpdate(
                kind: .final,
                wallSeconds: 0.9,
                audioSecondsFed: 2.0,
                text: "Hallo Welt"
            ),
        ])
    }

    @Test("builds scorer-compatible output and derives live latency")
    func buildsResult() async {
        let clock = TestClock()
        let recorder = LiveBenchmarkRecorder(now: { clock.now() })
        await recorder.setAudioSecondsFed(2.24)
        clock.advance(to: 2.5)
        await recorder.record(kind: .volatile, text: "Guten Tag")
        clock.advance(to: 4.0)

        let result = await recorder.result(
            engine: LiveBenchmarkEngine(
                id: "nemotron-multilingual",
                version: "667181a",
                model: "de/2240ms"
            ),
            locale: "de-DE",
            mode: .realtime,
            chunkMilliseconds: 20,
            audioDurationSeconds: 3.5,
            finalText: "Guten Tag"
        )

        #expect(result.schemaVersion == 1)
        #expect(result.locale == "de-DE")
        #expect(result.text == "Guten Tag")
        #expect(result.wallSeconds == 4.0)
        #expect(result.realTimeFactor == 4.0 / 3.5)
        #expect(result.metrics.timeToFirstTextSeconds == 2.5)
        #expect(result.metrics.firstTextAudioSecondsFed == 2.24)
        #expect(result.metrics.updateCount == 1)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.withLock { value }
    }

    func advance(to newValue: TimeInterval) {
        lock.withLock { value = newValue }
    }
}
