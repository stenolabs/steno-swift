import Foundation

/// Detects cross-channel bleed (echo) between microphone and system audio.
///
/// Port of the legacy transcriber's per-segment bleed correction
/// (`transcriber.py:_drop_per_segment_bleed`): when the microphone channel and
/// the system-audio channel produce near-simultaneous segments containing
/// nearly the same words, both capture paths heard the same audio and one side
/// is an attenuated echo of the other. Similarity is measured as a Jaccard
/// index over normalised word tokens (order- and whitespace-insensitive).
///
/// The filter is pure logic: it never touches audio, and the optional
/// `levelEvidence` hook keeps it free of any real RMS dependency — callers can
/// inject amplitude evidence to identify which side carries the direct signal,
/// mirroring the legacy per-segment RMS comparison.
public struct CrossChannelBleedFilter: Sendable {
    /// Segments whose start times differ by more than this window are never
    /// paired. Legacy used ±3 s; live lanes drift less, so this port starts at
    /// ±2 s.
    public var timeWindow: TimeInterval

    /// Token-multiset Jaccard similarity a pair must reach before it counts as
    /// bleed. 0.6 keeps genuinely different utterances apart while catching
    /// echo copies with recognizer-level wording differences. (Legacy shipped
    /// 0.5 over whole-transcript sets; per-segment matching is stricter, hence
    /// the higher start.)
    public var similarityThreshold: Double

    /// Segments shorter than this many characters are skipped entirely: too
    /// little text for a reliable similarity decision (legacy
    /// `PER_SEGMENT_BLEED_MIN_CHARS`).
    public var minimumCharacterCount: Int

    /// Amplitude evidence for one channel over a time range, in any monotonic
    /// loudness unit (legacy used mean 16-bit PCM RMS). Returning `nil` models
    /// an unreadable measurement and falls back to the conservative decision.
    ///
    /// When provided and the SYSTEM channel measures strictly louder than the
    /// microphone channel over the matched pair's ranges, the microphone
    /// segment is identified as the echo instead of the system segment — the
    /// headphone-less case where the mic picks up speaker echo of other
    /// people's speech. Any tie or unreadable value keeps the conservative
    /// default so real user mic content is never suppressed on ambiguous
    /// evidence.
    public typealias LevelEvidence = @Sendable (
        _ channel: TranscriptionChannel,
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> Double?

    public var levelEvidence: LevelEvidence?

    public init(
        timeWindow: TimeInterval = 2.0,
        similarityThreshold: Double = 0.6,
        minimumCharacterCount: Int = 15,
        levelEvidence: LevelEvidence? = nil
    ) {
        self.timeWindow = timeWindow
        self.similarityThreshold = similarityThreshold
        self.minimumCharacterCount = minimumCharacterCount
        self.levelEvidence = levelEvidence
    }

    /// One confirmed bleed pair: `echo` repeats `direct` through the other
    /// capture path.
    public struct BleedMatch: Equatable, Sendable {
        public let direct: TranscriptionBlock
        public let echo: TranscriptionBlock
        public let similarity: Double

        fileprivate init(direct: TranscriptionBlock, echo: TranscriptionBlock, similarity: Double) {
            self.direct = direct
            self.echo = echo
            self.similarity = similarity
        }
    }

    /// Evaluates all cross-channel pairs among `segments` and returns the
    /// confirmed bleed matches.
    ///
    /// Each system segment is paired with its most similar in-window
    /// microphone segment; pairs below `similarityThreshold` are discarded.
    /// Suppression decisions never remove anything here — callers mark the
    /// echoed side (see `LiveTranscriptFeed.Row.excludedFromReports`) while
    /// the original text stays intact.
    public func matches(in segments: [TranscriptionBlock]) -> [BleedMatch] {
        let micSegments = segments.filter { $0.channel == .microphone }
        guard !micSegments.isEmpty else { return [] }

        var results: [BleedMatch] = []
        for systemSegment in segments where systemSegment.channel == .system {
            guard passesMinimumLength(systemSegment) else { continue }

            var bestSimilarity = 0.0
            var bestMic: TranscriptionBlock?
            for micSegment in micSegments {
                guard passesMinimumLength(micSegment) else { continue }
                guard abs(systemSegment.start - micSegment.start) <= timeWindow else { continue }
                let similarity = Self.multisetJaccard(systemSegment.text, micSegment.text)
                if similarity > bestSimilarity {
                    bestSimilarity = similarity
                    bestMic = micSegment
                }
            }
            guard bestSimilarity >= similarityThreshold, let micSegment = bestMic else { continue }

            if let echo = echoSide(of: micSegment, versus: systemSegment) {
                results.append(BleedMatch(direct: echo.direct, echo: echo.echo, similarity: bestSimilarity))
            } else {
                results.append(BleedMatch(direct: micSegment, echo: systemSegment, similarity: bestSimilarity))
            }
        }
        return results
    }

    /// Convenience predicate: whether `segment` is the echoed side of some
    /// bleed pair within `segments`.
    public func isBleedEcho(_ segment: TranscriptionBlock, in segments: [TranscriptionBlock]) -> Bool {
        matches(in: segments).contains { $0.echo == segment }
    }

    private func passesMinimumLength(_ block: TranscriptionBlock) -> Bool {
        block.text.count >= minimumCharacterCount
    }

    /// Decides which side of a confirmed pair is the attenuated echo.
    ///
    /// Returns `nil` when no level evidence is available; the caller then
    /// applies the historical default (the system segment echoes the mic).
    private func echoSide(
        of micSegment: TranscriptionBlock,
        versus systemSegment: TranscriptionBlock
    ) -> (direct: TranscriptionBlock, echo: TranscriptionBlock)? {
        guard let levelEvidence else { return nil }
        guard
            let micLevel = levelEvidence(.microphone, micSegment.start, micSegment.end),
            let systemLevel = levelEvidence(.system, systemSegment.start, systemSegment.end)
        else { return nil }
        // Strictly greater: ties and unreadable (zero) measurements keep mic.
        guard systemLevel > micLevel else { return nil }
        return (direct: systemSegment, echo: micSegment)
    }

    /// Jaccard index over normalised token multisets: shared tokens counted
    /// with their minimum multiplicity, union with their maximum multiplicity.
    ///
    /// Multiset counting matters for echo detection because a stutters-and-
    /// repeats copy ("ha ha ha") of the same single word should not score as a
    /// perfect match the way plain set intersection would report.
    static func multisetJaccard(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = normalizedTokenCounts(lhs)
        let rhsTokens = normalizedTokenCounts(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0.0 }

        var intersection = 0
        var union = 0
        // Iterate the key UNION explicitly: merging tuples loses which side
        // a count came from, which let rhs-only tokens leak into the
        // intersection.
        for token in Set(lhsTokens.keys).union(rhsTokens.keys) {
            let lhsCount = lhsTokens[token] ?? 0
            let rhsCount = rhsTokens[token] ?? 0
            intersection += min(lhsCount, rhsCount)
            union += max(lhsCount, rhsCount)
        }
        guard union > 0 else { return 0.0 }
        return Double(intersection) / Double(union)
    }

    /// Lowercases and splits into alphanumeric word tokens, counting each
    /// occurrence. Punctuation, whitespace, and case never affect similarity.
    static func normalizedTokenCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                counts[current, default: 0] += 1
                current = ""
            }
        }
        if !current.isEmpty {
            counts[current, default: 0] += 1
        }
        return counts
    }
}
