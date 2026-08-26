import Foundation
import StenoDomain
import Testing
@testable import StenoDiarization

@Suite("Diarization progress heartbeat")
struct DiarizationProgressTests {
    /// Fake monotonic clock: ticks are advanced explicitly, never by the wall.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0

        var now: TimeInterval {
            lock.withLock { time }
        }

        func advance(_ interval: TimeInterval) {
            lock.withLock { time += interval }
        }
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DiarizationProgress] = []

        func record(_ event: DiarizationProgress) {
            lock.withLock { events.append(event) }
        }

        var snapshot: [DiarizationProgress] {
            lock.withLock { events }
        }
    }

    private static let phaseRank: [DiarizationProgressPhase: Int] = [
        .loadingAudio: 0,
        .segmenting: 1,
        .clustering: 2,
        .writing: 3,
    ]

    @Test("fake ticks produce ordered phases and at least one segmenting heartbeat")
    func orderedPhasesWithHeartbeats() async throws {
        let clock = FakeClock()
        let recorder = ProgressRecorder()
        let emitter = DiarizationProgressEmitter(
            handler: { recorder.record($0) },
            now: { clock.now },
            // A fake tick advances the clock and yields so the heartbeat
            // task actually runs its iteration.
            sleep: { interval in
                clock.advance(interval)
                await Task.yield()
            },
            heartbeatInterval: 2.0
        )

        emitter.emit(.loadingAudio)
        await emitter.withSegmentingHeartbeats {
            // Simulated opaque segmentation: three 2 s fake ticks.
            for _ in 0..<3 {
                clock.advance(2.0)
                await Task.yield()
            }
        }
        emitter.emit(.clustering)
        emitter.emit(.writing, fraction: 1.0)

        let events = recorder.snapshot
        #expect(events.first?.phase == .loadingAudio)
        #expect(events.last?.phase == .writing)

        // Phases appear in strictly non-decreasing rank order and all four
        // phases occur exactly as an ordered run.
        let ranks = events.compactMap { Self.phaseRank[$0.phase] }
        #expect(ranks == ranks.sorted())
        #expect(Set(ranks) == Set(0...3))

        let segmentingEvents = events.filter { $0.phase == .segmenting }
        // Initial .segmenting event plus at least one time-based heartbeat.
        #expect(segmentingEvents.count >= 2)
        #expect(segmentingEvents.first?.elapsed == 0)
        #expect(segmentingEvents.dropFirst().contains { $0.elapsed >= 2.0 })
        #expect(segmentingEvents.allSatisfy { $0.fraction == nil })

        let elapsedValues = events.map(\.elapsed)
        #expect(elapsedValues == elapsedValues.sorted())
    }

    @Test("without a handler no heartbeat machinery runs and the body result is preserved")
    func nilHandlerSkipsHeartbeats() async throws {
        var ranBody = false
        let emitter = DiarizationProgressEmitter(handler: nil)
        await emitter.withSegmentingHeartbeats {
            ranBody = true
        }
        #expect(ranBody)
    }

    @Test("provider emits loadingAudio before failing on unreadable audio")
    func providerEmitsLoadingAudioFirst() async throws {
        let recorder = ProgressRecorder()
        let provider = FluidSortformerProvider(modelCacheDirectory: nil)

        await #expect(throws: (any Error).self) {
            try await provider.diarize(
                URL(fileURLWithPath: "/nonexistent/diarization-progress-test.wav"),
                hints: DiarizationHints(),
                progress: { recorder.record($0) }
            )
        }

        #expect(recorder.snapshot.first?.phase == .loadingAudio)
        #expect(!recorder.snapshot.contains { $0.phase == .writing })
    }

    @Test("legacy-only conformers keep working through the progress overload")
    func defaultBridgeDelegatesWithoutProgress() async throws {
        let provider = LegacyOnlyProvider()
        let output = try await provider.diarize(
            URL(fileURLWithPath: "/unused"),
            hints: DiarizationHints(),
            progress: { _ in }
        )
        #expect(output.segments.isEmpty)
    }

    private struct LegacyOnlyProvider: DiarizationProvider {
        nonisolated let descriptor = EngineDescriptor(name: "legacy", version: "1")

        func diarize(_ url: URL, hints: DiarizationHints) async throws -> DiarizationOutput {
            DiarizationOutput(segments: [], embeddings: [:], engine: descriptor)
        }
    }
}
