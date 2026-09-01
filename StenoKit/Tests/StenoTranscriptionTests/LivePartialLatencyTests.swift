import Testing
import Foundation
@testable import StenoTranscription
import StenoDomain

/// Live partial-latency perf harness (fills the PERF-BUDGETS.md row
/// `live_partial_latency_ms`, legacy philosophy from
/// `e2e/specs/live-transcript-perf.t1.spec.ts`).
///
/// Protocol: drive `LiveTranscriptFeed` with paced synthetic volatile/final
/// events (a cumulative snapshot per tick, matching the streaming-native
/// SpeechAnalyzer contract) at final-count sizes 0/250/750/1500 and measure
/// the wall time of `apply()` + `rows` projection per burst of 10 ticks.
///
/// Budgets (see docs/PERF-BUDGETS.md):
/// - every burst < 150 ms,
/// - projection must not approach quadratic growth: the 1500-final burst < 3x
///   the 750-final burst (linear growth is 2x, quadratic growth is 4x).
///
/// The suite prints one machine-readable line
/// `LIVE_PARTIAL_LATENCY_JSON: {...}` for `scripts/benchmark/perf_budgets.py`.
///
/// Heavy-case gating: `STENO_PERF_FULL=0` skips the 1500-final size for weak
/// machines / quick local runs. On the reference machine (M5 Max) the flag is
/// NOT required — all sizes run by default, total runtime stays well under
/// 60 s.
@Suite("Live partial latency")
struct LivePartialLatencyTests {
    private static let sizes = [0, 250, 750, 1500]
    private static let ticksPerBurst = 10
    private static let budgetMilliseconds = 150.0

    @Test("Projection cost per tick burst stays inside budget and scales sub-quadratically")
    func burstLatencyWithinBudget() async throws {
        let clock = ContinuousClock()
        // Warm up once so allocator/first-touch costs do not pollute size 0.
        _ = await Self.runBurst(finalCount: 0, clock: clock)

        var results: [(size: Int, ms: Double)] = []
        for size in Self.sizes where Self.isSizeEnabled(size) {
            // Best-of-3 keeps the regression signal while absorbing scheduler
            // noise from sibling load; the budget itself stays strict.
            var best = Double.infinity
            for _ in 0..<3 {
                let ms = await Self.runBurst(finalCount: size, clock: clock)
                best = min(best, ms)
            }
            results.append((size, best))
            #expect(
                best < Self.budgetMilliseconds,
                "\(size)-final burst took \(best) ms (budget \(Self.budgetMilliseconds) ms)"
            )
        }

        guard let base = results.first(where: { $0.size == 750 }),
              let heavy = results.first(where: { $0.size == 1500 }) else {
            // Heavy case skipped via STENO_PERF_FULL=0; scaling check needs it.
            if !Self.isSizeEnabled(1500) {
                #expect(Bool(false), "STENO_PERF_FULL=0: scaling check skipped (no 1500 measurement)")
            }
            Self.emitSummary(results)
            return
        }
        // Use the larger adjacent sample as the baseline. Comparing against
        // the much faster 250-final burst lets millisecond-level runner noise
        // dominate the ratio. Doubling from 750 to 1500 should cost about 2x;
        // a 3x ceiling retains headroom while still rejecting quadratic 4x
        // growth.
        #expect(
            heavy.ms < 3 * base.ms,
            "near-quadratic scaling: 1500-final burst \(heavy.ms) ms >= 3x the 750-final burst \(base.ms) ms"
        )

        Self.emitSummary(results)
    }

    // MARK: - Helpers

    /// Runs one paced burst of 10 ticks at the given final count and returns
    /// the summed wall time of `apply()` + `rows` across the burst. Pacing
    /// sleeps are NOT counted — the budget covers projection cost only.
    private static func runBurst(finalCount: Int, clock: ContinuousClock) async -> Double {
        var feed = LiveTranscriptFeed()
        var elapsed = 0.0
        for tick in 0..<ticksPerBurst {
            let event = makeEvent(finalCount: finalCount, tick: tick)
            let start = clock.now
            feed.apply(event, for: .microphone)
            _ = feed.rows
            let end = clock.now
            elapsed += Self.milliseconds(end - start)

            // Pace ticks like real speech cadence (~20 Hz provisional rate);
            // ContinuousClock-based sleep keeps this off the measured path.
            if tick < ticksPerBurst - 1 {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return elapsed
    }

    /// Cumulative snapshot contract: a `.volatile` output carrying every
    /// finalized block plus one trailing provisional block, ending in a
    /// `.final` commit on the last tick.
    private static func makeEvent(finalCount: Int, tick: Int) -> TranscriptionEvent {
        var blocks: [TranscriptionBlock] = []
        blocks.reserveCapacity(finalCount + 1)
        for index in 0..<finalCount {
            let start = Double(index) * 2.0
            blocks.append(makeBlock(index: index, text: "final segment \(index)", start: start, end: start + 2.0))
        }
        if finalCount == 0 && tick % 2 == 1 || tick == ticksPerBurst - 1 {
            return .final(TranscriptOutput(localeIdentifier: "en_US", blocks: blocks))
        }
        blocks.append(
            makeBlock(
                index: finalCount,
                text: "volatile partial update tick \(tick)",
                start: Double(finalCount) * 2.0,
                end: Double(finalCount) * 2.0 + 1.5
            )
        )
        return .volatile(TranscriptOutput(localeIdentifier: "en_US", blocks: blocks))
    }

    private static func makeBlock(index: Int, text: String, start: TimeInterval, end: TimeInterval) -> TranscriptionBlock {
        let words = text.split(separator: " ").enumerated().map { wordIndex, word in
            TranscriptionWord(
                text: String(word),
                start: start + Double(wordIndex) * 0.3,
                end: start + Double(wordIndex) * 0.3 + 0.25
            )
        }
        return TranscriptionBlock(channel: .microphone, text: text, start: start, end: end, words: words)
    }

    /// The heavy 1500-final case is marked behind `STENO_PERF_FULL`; the
    /// default on the reference machine is to run ALL sizes (`STENO_PERF_FULL`
    /// unset or `1`). Only an explicit `STENO_PERF_FULL=0` drops it.
    private static func isSizeEnabled(_ size: Int) -> Bool {
        guard size == 1500 else { return true }
        return ProcessInfo.processInfo.environment["STENO_PERF_FULL"] != "0"
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    /// Machine-readable summary consumed later by
    /// `scripts/benchmark/perf_budgets.py --json`.
    private static func emitSummary(_ results: [(size: Int, ms: Double)]) {
        let worst = results.map(\.ms).max() ?? 0
        let sizesJSON = results.map { "\($0.size)" }.joined(separator: ",")
        print(
            "LIVE_PARTIAL_LATENCY_JSON: {\"live_partial_latency_ms\": \(String(format: "%.2f", worst)), \"sizes\": [\(sizesJSON)], \"burst_ms_by_size\": {\(results.map { "\"\($0.size)\": \(String(format: "%.2f", $0.ms))" }.joined(separator: ", "))}}"
        )
    }
}
