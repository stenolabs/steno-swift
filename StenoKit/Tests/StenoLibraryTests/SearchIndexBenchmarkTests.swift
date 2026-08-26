import Foundation
import StenoDomain
import Testing
@testable import StenoLibrary

/// Search-index perf harness (fills the PERF-BUDGETS.md rows
/// `search_query_ms_100_meetings` and `index_incremental_update_s_per_batch`).
///
/// Protocol: build a temp library of 100 synthetic meetings (deterministic
/// pseudo-random vocabulary seeded per meeting, ~200 transcript words plus a
/// note each), construct `MeetingSearchIndex`, `rebuild(library:)`, then:
///
/// - Query latency: run 30 representative queries (single terms, multi-term,
///   and accented forms that `MeetingSearch.normalized` folds) and take
///   nearest-rank p50/p95 wall times.
/// - Incremental update: append one fresh meeting's content and time
///   `update(meetingID:library:)`; repeat 10 cycles, take the worst.
///
/// Budgets (see docs/PERF-BUDGETS.md):
/// - p95 query latency < 50 ms at 100 meetings,
/// - incremental update < 2 s per meeting batch.
///
/// The suite prints machine-readable lines `SEARCH_QUERY_JSON: {...}` and
/// `INDEX_UPDATE_JSON: {...}` for `scripts/benchmark/perf_budgets.py`.
@Suite("SearchIndexBenchmark")
struct SearchIndexBenchmarkTests {
    private static let meetingCount = 100
    private static let wordsPerTranscript = 200
    private static let queryBudgetMilliseconds = 50.0
    private static let updateBudgetSeconds = 2.0
    private static let queryCount = 30
    private static let updateCycles = 10

    // MARK: - Deterministic randomness

    /// SplitMix64: tiny, stable across runs and platforms.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Meeting-flavored vocabulary. Accented entries exist so that plain-ASCII
    /// queries exercise the same diacritic folding the sidebar relies on;
    /// FTS5's unicode61 tokenizer strips diacritics at index time, matching
    /// `MeetingSearch.normalized` at query time.
    private static let vocabulary: [String] = [
        "roadmap", "budget", "quarterly", "review", "onboarding", "latency",
        "diarization", "transcript", "summary", "pricing", "rollout",
        "milestone", "headcount", "forecast", "backlog", "sprint",
        "stakeholder", "compliance", "retention", "encryption", "hotkey",
        "dictation", "playback", "export", "template", "workflow",
        "Müller", "café", "naïve", "Zürich", "crème",
        "façade", "résumé", "jalapeño",
    ]

    /// Builds a temp library with 100 synthetic meetings: each has a current
    /// transcript revision (~200 deterministic pseudo-random words), a short
    /// note, and deliberately NO report (keeps fixture writes cheap).
    private static func makeBenchmarkLibrary(
        in root: URL
    ) async throws -> Library {
        let library = try Library.open(at: root)
        let notes = MeetingNotesStore(layout: library.layout)

        for index in 0..<meetingCount {
            var rng = SeededGenerator(seed: 0x5EE0_BEEF &+ UInt64(index))

            let meeting = try await library.createMeeting(
                title: "Benchmark Meeting \(index)",
                status: .ready
            )

            // Distinct anchor terms so every meeting matches its own queries.
            let anchor = vocabulary[index % vocabulary.count]
            var words: [String] = []
            words.reserveCapacity(wordsPerTranscript)
            for wordIndex in 0..<wordsPerTranscript {
                if wordIndex == 0 || wordIndex == wordsPerTranscript / 2 {
                    words.append(anchor)
                } else {
                    words.append(vocabulary[Int(rng.next() % UInt64(vocabulary.count))])
                }
            }

            let revision = TranscriptRevision(
                meetingID: meeting.id,
                origin: .legacyImport,
                turns: [
                    TranscriptTurn(
                        speaker: nil,
                        start: 0,
                        end: Double(wordsPerTranscript),
                        segments: [
                            TranscriptSegment(
                                text: words.joined(separator: " "),
                                start: 0,
                                end: Double(wordsPerTranscript),
                                words: []
                            )
                        ]
                    )
                ]
            )
            _ = try await library.appendRevision(revision)
            try await notes.setNotes(
                meeting.id,
                to: "Follow up on \(anchor) with Müller about pricing."
            )
        }
        return library
    }

    // MARK: - Percentiles

    /// Nearest-rank percentile over an ascending-sorted sample.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    private static func milliseconds(_ duration: ContinuousClock.Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }

    // MARK: - Tests

    @Test("Query latency p95 stays under 50 ms at 100 meetings")
    func queryLatencyWithinBudget() async throws {
        try await withTemporaryDirectory { root in
            let library = try await Self.makeBenchmarkLibrary(in: root)
            let index = try MeetingSearchIndex(layout: library.layout)
            try await index.rebuild(library: library)

            // 30 representative queries: 10 single terms (plain ASCII or
            // accent-stripped forms of accented vocabulary), 10 two-term
            // conjunctions, 10 three-term conjunctions. Deterministic picks.
            var queries: [String] = []
            for i in 0..<10 {
                let term = Self.vocabulary[(i * 7) % Self.vocabulary.count]
                queries.append(term.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil))
            }
            for i in 0..<10 {
                let a = Self.vocabulary[(i * 3) % Self.vocabulary.count]
                let b = Self.vocabulary[(i * 11 + 5) % Self.vocabulary.count]
                queries.append("\(a) \(b)")
            }
            for i in 0..<10 {
                let a = Self.vocabulary[(i * 13 + 2) % Self.vocabulary.count]
                let b = Self.vocabulary[(i * 17 + 9) % Self.vocabulary.count]
                let c = Self.vocabulary[(i * 23 + 4) % Self.vocabulary.count]
                queries.append("\(a) \(b) \(c)")
            }
            #expect(queries.count == Self.queryCount)

            let clock = ContinuousClock()
            var timings: [Double] = []
            for query in queries {
                let start = clock.now
                _ = try await index.search(query)
                let end = clock.now
                timings.append(Self.milliseconds(end - start))
            }

            // Guard against a vacuous benchmark: queries must actually hit
            // indexed content, otherwise the timings measure nothing.
            var totalGroups = 0
            for query in queries {
                totalGroups += (try await index.search(query)).count
            }
            #expect(totalGroups > 0, "no query matched any indexed content")
            timings.sort()
            let p50 = Self.percentile(timings, 0.50)
            let p95 = Self.percentile(timings, 0.95)
            #expect(
                p95 < Self.queryBudgetMilliseconds,
                "query p95 \(String(format: "%.2f", p95)) ms exceeds budget \(Self.queryBudgetMilliseconds) ms at \(Self.meetingCount) meetings"
            )
            print(
                "SEARCH_QUERY_JSON: {\"p50_ms\": \(String(format: "%.2f", p50)), \"p95_ms\": \(String(format: "%.2f", p95))}"
            )
        }
    }

    @Test("Incremental update worst case stays under 2 s per meeting batch")
    func incrementalUpdateWithinBudget() async throws {
        try await withTemporaryDirectory { root in
            let library = try await Self.makeBenchmarkLibrary(in: root)
            let notes = MeetingNotesStore(layout: library.layout)
            let index = try MeetingSearchIndex(layout: library.layout)
            try await index.rebuild(library: library)

            let clock = ContinuousClock()
            var worst: Double = 0
            for cycle in 0..<Self.updateCycles {
                // Append one fresh meeting's worth of content, then pay the
                // incremental update cost for it.
                var rng = Self.SeededGenerator(seed: 0xADD1_C7E &+ UInt64(cycle))
                let words = (0..<Self.wordsPerTranscript).map { _ in
                    Self.vocabulary[Int(rng.next() % UInt64(Self.vocabulary.count))]
                }
                let meeting = try await library.createMeeting(
                    title: "Benchmark Update Cycle \(cycle)",
                    status: .ready
                )
                let revision = TranscriptRevision(
                    meetingID: meeting.id,
                    origin: .legacyImport,
                    turns: [
                        TranscriptTurn(
                            speaker: nil,
                            start: 0,
                            end: Double(Self.wordsPerTranscript),
                            segments: [
                                TranscriptSegment(
                                    text: words.joined(separator: " "),
                                    start: 0,
                                    end: Double(Self.wordsPerTranscript),
                                    words: []
                                )
                            ]
                        )
                    ]
                )
                _ = try await library.appendRevision(revision)
                try await notes.setNotes(meeting.id, to: "Cycle \(cycle): follow up with Müller.")

                let start = clock.now
                try await index.update(meetingID: meeting.id, library: library)
                let elapsed = Self.milliseconds(clock.now - start) / 1000
                worst = max(worst, elapsed)
            }

            #expect(
                worst < Self.updateBudgetSeconds,
                "worst incremental update \(String(format: "%.3f", worst)) s exceeds budget \(Self.updateBudgetSeconds) s"
            )
            print("INDEX_UPDATE_JSON: {\"worst_update_s\": \(String(format: "%.4f", worst))}")
        }
    }
}
