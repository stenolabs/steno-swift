import Foundation

/// Deterministic transcript citation resolver.
///
/// Given a bullet or summary point and a transcript (as raw text, lines, or a
/// preprocessed index), finds the best-matching transcript line, or returns
/// nil when nothing clears the confidence threshold — a bullet without real
/// evidence gets no citation (anti-guessing).
///
/// Features:
///  - English stopword filtering and case-folding (latin words >= 2 chars)
///  - CJK character-bigram overlap for Traditional Chinese
///  - Timestamp/speaker prefixes ([MM:SS - MM:SS] Speaker:) are stripped
///    before scoring so they cannot skew matches
///  - Sliding windows across 1-3 consecutive lines for multi-turn points
///  - Inverted-index preprocessing for fast lookup across long transcripts
public enum TranscriptCitations {
    /// Minimum score (matched / bullet tokens) required to accept a match.
    public static let defaultThreshold = 0.35

    /// A resolved citation pointing at a transcript line.
    public struct CitationMatch: Equatable {
        public let lineIndex: Int
        public let score: Double
        public let lineText: String

        init(lineIndex: Int, score: Double, lineText: String) {
            self.lineIndex = lineIndex
            self.score = score
            self.lineText = lineText
        }
    }

    /// A contiguous run of 1-3 transcript lines, reduced to its token set.
    public struct TranscriptWindow {
        public let startLineIndex: Int
        public let size: Int
        public let tokens: Set<String>
        public var tokenCount: Int { tokens.count }
    }

    /// One-pass preprocessing result reused across many bullets.
    public struct ProcessedTranscript {
        public let lines: [String]
        public let cleanLines: [String]
        public let windows: [TranscriptWindow]
        /// Token -> window indices containing it.
        let tokenToWindows: [String: [Int]]
    }

    /// Strips leading timestamps and speaker tags so they do not inflate or
    /// skew keyword scoring.
    ///
    /// Examples:
    ///   "[00:00 - 00:05] Alice: Hello" -> "Hello"
    ///   "[00:03] [You] We ship Friday." -> "We ship Friday."
    ///   "[Others] I will prep notes."  -> "I will prep notes."
    ///   "Alice: We ship Friday."       -> "We ship Friday."
    public static func stripTranscriptPrefix(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip [00:00 - 00:05] or [00:03] or [01:23:45].
        if let match = s.firstMatch(
            of: /^\[\d{1,3}:\d{2}(?::\d{2})?(?:\s*-\s*\d{1,3}:\d{2}(?::\d{2})?)?\]\s*/
        ) {
            s = String(s[match.range.upperBound...])
        }
        // Strip [You], [Others], [Speaker 1], etc.
        if let match = s.firstMatch(of: /^\[[^\]]+\]\s*/) {
            s = String(s[match.range.upperBound...])
        }
        // Strip "Speaker:" or "Alice:" name prefixes.
        if let match = s.firstMatch(of: /^[A-Za-z0-9_\u{4E00}-\u{9FFF}\s]{1,30}:\s*/) {
            s = String(s[match.range.upperBound...])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// English stopwords excluded from token scoring.
    public static let englishStopwords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and",
        "any", "are", "aren", "as", "at", "be", "because", "been", "before", "being",
        "below", "between", "both", "but", "by", "can", "cannot", "could", "did",
        "do", "does", "doing", "down", "during", "each", "few", "for", "from",
        "further", "had", "has", "have", "having", "he", "her", "here", "hers",
        "herself", "him", "himself", "his", "how", "i", "if", "in", "into", "is",
        "it", "its", "itself", "just", "me", "more", "most", "my", "myself", "no",
        "nor", "not", "now", "of", "off", "on", "once", "only", "or", "other",
        "our", "ours", "ourselves", "out", "over", "own", "same", "she", "should",
        "so", "some", "such", "than", "that", "the", "their", "theirs", "them",
        "themselves", "then", "there", "these", "they", "this", "those", "through",
        "to", "too", "under", "until", "up", "very", "was", "we", "were", "what",
        "when", "where", "which", "while", "who", "whom", "why", "will", "with",
        "would", "you", "your", "yours", "yourself", "yourselves",
    ]

    /// Tokenises text into a set of lowercased content words and CJK
    /// character bigrams (unigrams for single-character segments).
    public static func extractTokens(_ text: String) -> Set<String> {
        guard !text.isEmpty else { return [] }
        let clean = stripTranscriptPrefix(text).lowercased()

        var words: [String] = []
        var cjkSegments: [String] = []
        var wordBuffer = String()
        var cjkBuffer = String()

        func flushWord() {
            if !wordBuffer.isEmpty {
                words.append(wordBuffer)
                wordBuffer = ""
            }
        }
        func flushCJK() {
            if !cjkBuffer.isEmpty {
                cjkSegments.append(cjkBuffer)
                cjkBuffer = ""
            }
        }

        for scalar in clean.unicodeScalars {
            let value = scalar.value
            if (value >= 0x61 && value <= 0x7A) || (value >= 0x30 && value <= 0x39) {
                // ASCII letter or digit.
                flushCJK()
                wordBuffer.unicodeScalars.append(scalar)
            } else if isCJKScalarValue(value) {
                flushWord()
                cjkBuffer.unicodeScalars.append(scalar)
            } else {
                flushWord()
                flushCJK()
            }
        }
        flushWord()
        flushCJK()

        var tokens = Set<String>()
        for word in words where word.count >= 2 && !englishStopwords.contains(word) {
            tokens.insert(word)
        }
        for segment in cjkSegments {
            let scalars = Array(segment.unicodeScalars)
            if scalars.count == 1 {
                tokens.insert(segment)
            } else {
                for i in 0..<(scalars.count - 1) {
                    tokens.insert(String(String.UnicodeScalarView([scalars[i], scalars[i + 1]])))
                }
            }
        }
        return tokens
    }

    /// Splits raw transcript text into lines (\r\n tolerated).
    public static func splitTranscriptLines(_ transcript: String) -> [String] {
        transcript.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Pre-processes a transcript in a single pass: per-line tokens,
    /// sliding windows of size 1-3, and a token inverted index.
    public static func preprocess(_ lines: [String]) -> ProcessedTranscript {
        let cleanLines = lines.map(stripTranscriptPrefix)
        let lineTokens = cleanLines.map(extractTokens)

        var windows: [TranscriptWindow] = []
        var tokenToWindows: [String: [Int]] = [:]

        func push(_ window: TranscriptWindow, at index: Int) {
            windows.append(window)
            for token in window.tokens {
                tokenToWindows[token, default: []].append(index)
            }
        }

        let n = lines.count
        for i in 0..<n {
            let win1 = TranscriptWindow(
                startLineIndex: i,
                size: 1,
                tokens: lineTokens[i]
            )
            push(win1, at: windows.count)

            if i + 1 < n {
                var win2Tokens = lineTokens[i]
                win2Tokens.formUnion(lineTokens[i + 1])
                push(
                    TranscriptWindow(startLineIndex: i, size: 2, tokens: win2Tokens),
                    at: windows.count
                )
            }
            if i + 2 < n {
                var win3Tokens = lineTokens[i]
                win3Tokens.formUnion(lineTokens[i + 1])
                win3Tokens.formUnion(lineTokens[i + 2])
                push(
                    TranscriptWindow(startLineIndex: i, size: 3, tokens: win3Tokens),
                    at: windows.count
                )
            }
        }

        return ProcessedTranscript(
            lines: lines,
            cleanLines: cleanLines,
            windows: windows,
            tokenToWindows: tokenToWindows
        )
    }

    public static func preprocess(_ transcript: String) -> ProcessedTranscript {
        preprocess(splitTranscriptLines(transcript))
    }

    /// Finds the best-matching citation for a single bullet string, or nil
    /// when no window clears the confidence gate.
    public static func findCitation(
        bullet: String,
        transcript: ProcessedTranscript,
        threshold: Double = defaultThreshold
    ) -> CitationMatch? {
        let bulletTokens = extractTokens(bullet)
        if bulletTokens.isEmpty || transcript.windows.isEmpty {
            return nil
        }

        // Count matching tokens per window via the inverted index.
        var matchCounts: [Int: Int] = [:]
        for token in bulletTokens {
            for windowIndex in transcript.tokenToWindows[token] ?? [] {
                matchCounts[windowIndex, default: 0] += 1
            }
        }
        if matchCounts.isEmpty {
            return nil
        }

        // Confidence gating: short bullets (<= 2 tokens) must match fully;
        // longer bullets need at least 2 distinct matching tokens and a
        // score at or above the threshold.
        struct Best {
            var windowIndex: Int
            var score: Double
            var matched: Int
            var size: Int
            var startLine: Int
        }
        var best: Best?

        for (windowIndex, matched) in matchCounts {
            let window = transcript.windows[windowIndex]
            let score = Double(matched) / Double(bulletTokens.count)

            if bulletTokens.count <= 2 {
                if matched < bulletTokens.count { continue }
            } else if matched < 2 {
                continue
            }
            if score < threshold { continue }

            // Tie-breaking: higher score, more matched tokens, smaller
            // window (precision), earlier line. Fully deterministic.
            let replaces: Bool
            if let current = best {
                if score > current.score + 1e-6 {
                    replaces = true
                } else if abs(score - current.score) <= 1e-6 {
                    if matched != current.matched {
                        replaces = matched > current.matched
                    } else if window.size != current.size {
                        replaces = window.size < current.size
                    } else {
                        replaces = window.startLineIndex < current.startLine
                    }
                } else {
                    replaces = false
                }
            } else {
                replaces = true
            }
            if replaces {
                best = Best(
                    windowIndex: windowIndex,
                    score: score,
                    matched: matched,
                    size: window.size,
                    startLine: window.startLineIndex
                )
            }
        }

        guard let winner = best else { return nil }
        return CitationMatch(
            lineIndex: winner.startLine,
            score: winner.score,
            lineText: transcript.lines[winner.startLine]
        )
    }

    public static func findCitation(
        bullet: String,
        transcript: [String],
        threshold: Double = defaultThreshold
    ) -> CitationMatch? {
        findCitation(bullet: bullet, transcript: preprocess(transcript), threshold: threshold)
    }

    public static func findCitation(
        bullet: String,
        transcript: String,
        threshold: Double = defaultThreshold
    ) -> CitationMatch? {
        findCitation(bullet: bullet, transcript: preprocess(transcript), threshold: threshold)
    }

    /// Resolves citations for multiple bullets in one pass over the transcript.
    public static func findCitationsBatch(
        _ bullets: [String],
        transcript: ProcessedTranscript,
        threshold: Double = defaultThreshold
    ) -> [CitationMatch?] {
        bullets.map { findCitation(bullet: $0, transcript: transcript, threshold: threshold) }
    }

    public static func findCitationsBatch(
        _ bullets: [String],
        transcript: [String],
        threshold: Double = defaultThreshold
    ) -> [CitationMatch?] {
        findCitationsBatch(bullets, transcript: preprocess(transcript), threshold: threshold)
    }

    // MARK: - Jump mechanism

    /// Posted when the reader activates a citation button; `userInfo` carries
    /// the cited transcript line under ``lineIndexKey``. The meeting detail's
    /// transcript view observes this to scroll the cited turn into view and
    /// highlight it briefly.
    public static let citeTranscriptLineNotification = Notification.Name("steno.cite.transcript.line")

    public static let lineIndexKey = "lineIndex"

    public static func postCiteJump(lineIndex: Int, center: NotificationCenter = .default) {
        center.post(name: citeTranscriptLineNotification, object: nil, userInfo: [lineIndexKey: lineIndex])
    }

    public static func citedLineIndex(from notification: Notification) -> Int? {
        notification.name == citeTranscriptLineNotification
            ? notification.userInfo?[lineIndexKey] as? Int
            : nil
    }

    // MARK: - Internals

    private static func isCJKScalarValue(_ value: UInt32) -> Bool {
        switch value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
