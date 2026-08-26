import Foundation

/// Pure stopword-profile language classifier for live transcripts.
///
/// Port of the Electron predecessor's `src/language_detect.py`: ASR backends
/// that never report a detected language (Apple Speech pins a caller-supplied
/// locale, exactly like the legacy Parakeet providers) leave a meeting recorded
/// in an unconfirmed language without evidence. This module scores candidate
/// languages by high-frequency function-word hits over normalized transcript
/// text and stays dependency-free.
///
/// The profile set covers the European languages Speech transcribes well
/// (`en`, `fr`, `de`, `es`, `nl`, `pt`). Cross-language collisions ("die" in
/// de/nl/en, "de" in fr/es/pt/nl) are acceptable because the aggregate count
/// decides: every profile carries enough distinctive words for the true
/// language to lead. The classifier is pure and never touches user content
/// beyond counting; no text is logged anywhere in this file.
public struct TranscriptLanguageClassifier: Equatable, Sendable {
    /// Function-word profiles, keyed by BCP-47 language code.
    public let profiles: [String: Set<String>]

    public init(profiles: [String: Set<String>] = TranscriptLanguageClassifier.defaultProfiles) {
        self.profiles = profiles
    }

    /// Best-effort language of `text`, or `nil` when inconclusive.
    ///
    /// Returns a language code only when the winner clears
    /// ``LanguageDetectionThresholds/minimumHits`` stopword matches and leads
    /// the runner-up by at least ``LanguageDetectionThresholds/leadRatio``.
    /// Diarisation markers (`[You]`), bracketed and bare clock timestamps are
    /// ignored, and only the first `maximumSampleCharacters` are scanned so a
    /// multi-megabyte transcript cannot dominate the cost.
    public func detect(
        _ text: String,
        thresholds: LanguageDetectionThresholds = .standard
    ) -> String? {
        guard !text.isEmpty else { return nil }
        let sample = Self.stripMarkers(String(text.prefix(thresholds.maximumSampleCharacters)))

        var tokenCounts: [String: Int] = [:]
        for token in Self.tokens(in: sample) {
            tokenCounts[token, default: 0] += 1
        }
        guard !tokenCounts.isEmpty else { return nil }

        // Deterministic order: score descending, code ascending as tie-break,
        // so equal scores always name the same winner.
        let ranked = profiles
            .map { code, words -> (code: String, score: Int) in
                (code, words.reduce(0) { $0 + (tokenCounts[$1.lowercased()] ?? 0) })
            }
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.code < rhs.code
            }

        guard let top = ranked.first else { return nil }
        let runnerUpScore = ranked.dropFirst().first?.score ?? 0
        if top.score < thresholds.minimumHits { return nil }
        if runnerUpScore > 0,
           Double(top.score) < Double(runnerUpScore) * thresholds.leadRatio {
            return nil
        }
        return top.code
    }

    /// Removes diarisation markers (`[You]`, `[Others]`, `[Together]`) and
    /// bracketed or bare clock timestamps so they do not dilute word counts.
    static func stripMarkers(_ text: String) -> String {
        var sample = Self.replaceMatches(in: text, pattern: Self.bracketRegex, with: " ")
        sample = Self.replaceMatches(in: sample, pattern: Self.timestampRegex, with: " ")
        return sample
    }
    /// Lowercase Unicode letter runs; digits and underscores never join a token.
    static func tokens(in text: String) -> [String] {
        // The pattern matches the wanted letter runs, so enumerate the
        // matches themselves; replacing them would keep the separators.
        let lowered = text.lowercased()
        let range = NSRange(lowered.startIndex..., in: lowered)
        var collected: [String] = []
        Self.wordRegex.enumerateMatches(in: lowered, range: range) { match, _, _ in
            guard let match,
                  let matchRange = Range(match.range, in: lowered) else { return }
            collected.append(String(lowered[matchRange]))
        }
        return collected
    }

    private static func replaceMatches(
        in text: String,
        pattern: NSRegularExpression,
        with replacement: String
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: replacement
        )
    }

    // NSRegularExpression matching is thread-safe; compiled once per process.
    private static let bracketRegex = try! NSRegularExpression(pattern: bracketPattern)
    private static let timestampRegex = try! NSRegularExpression(pattern: timestampPattern)
    private static let wordRegex = try! NSRegularExpression(pattern: wordPattern)

    private static let bracketPattern = "\\[[^\\]]*\\]"
    private static let timestampPattern = "\\b\\d{1,2}:\\d{2}(?::\\d{2})?\\b"
    private static let wordPattern = "[^\\W\\d_]+"

    /// High-frequency function words per language, curated for distinctiveness
    /// (ported verbatim from `language_detect.py`).
    public static let defaultProfiles: [String: Set<String>] = [
        "en": [
            "the", "and", "that", "have", "for", "not", "with", "you", "this",
            "but", "from", "they", "his", "her", "she", "will", "would", "there",
            "their", "what", "about", "which", "when", "can", "like", "just",
            "know", "your", "some", "could", "them", "than", "then", "only",
            "also", "been", "has", "had", "were", "are", "our", "how", "who",
            "why", "where", "into", "over", "these", "those", "being", "does",
            "did", "because", "should", "very", "here", "much", "more",
        ],
        "fr": [
            "le", "la", "les", "un", "une", "des", "du", "de", "et", "est",
            "que", "qui", "dans", "pour", "pas", "plus", "avec", "sur", "ce",
            "cette", "ces", "mais", "ou", "donc", "il", "elle", "ils", "elles",
            "nous", "vous", "je", "son", "sa", "ses", "leur", "leurs", "être",
            "avoir", "fait", "faire", "très", "bien", "aussi", "comme", "tout",
            "tous", "alors", "parce", "quand", "peut", "cela", "notre", "votre",
            "sont", "était", "ont",
        ],
        "de": [
            "der", "die", "das", "und", "ist", "nicht", "ein", "eine", "einen",
            "einem", "einer", "den", "dem", "mit", "auf", "für", "auch", "aber",
            "oder", "wir", "ich", "sie", "wenn", "dann", "weil", "dass", "doch",
            "noch", "schon", "immer", "sehr", "mehr", "viel", "hier", "jetzt",
            "was", "wie", "warum", "wer", "haben", "hat", "hatte", "sein", "sind",
            "war", "waren", "wird", "werden", "würde", "kann", "können", "muss",
            "über", "durch", "nach", "diese", "dieser", "dieses",
        ],
        "es": [
            "el", "la", "los", "las", "un", "una", "unos", "unas", "del", "en",
            "que", "por", "para", "con", "se", "su", "sus", "lo", "le", "como",
            "más", "pero", "este", "esta", "esto", "estos", "ese", "esa", "muy",
            "también", "porque", "cuando", "donde", "hay", "ser", "estar",
            "tiene", "tienen", "tener", "son", "era", "eran", "fue", "fueron",
            "está", "están", "puede", "pueden", "todo", "todos", "nosotros",
            "ellos", "ellas", "usted", "ustedes", "ahora", "entonces",
        ],
        "nl": [
            "de", "het", "een", "en", "van", "dat", "die", "in", "is", "ik",
            "je", "niet", "met", "op", "te", "zijn", "voor", "maar", "ook",
            "aan", "om", "dan", "wat", "wij", "jij", "hij", "zij", "deze", "dit",
            "daar", "hier", "naar", "door", "over", "worden", "wordt", "heeft",
            "hebben", "heb", "kan", "kunnen", "moet", "moeten", "zou", "zal",
            "nog", "wel", "heel", "veel", "meer", "waarom", "wie", "waar", "hoe",
            "omdat", "wanneer", "alle", "alles",
        ],
        "pt": [
            "os", "as", "um", "uma", "do", "da", "dos", "das", "em", "no", "na",
            "nos", "nas", "que", "por", "para", "com", "não", "se", "seu", "sua",
            "como", "mais", "mas", "este", "esta", "isto", "esse", "essa", "isso",
            "muito", "também", "porque", "quando", "onde", "ser", "estar", "tem",
            "têm", "ter", "são", "era", "eram", "foi", "foram", "está", "estão",
            "pode", "podem", "tudo", "nós", "eles", "elas", "você", "vocês",
            "agora", "então",
        ],
    ]
}

/// Evidence and commitment bounds of automatic language detection.
///
/// All values mirror the legacy detector plus the wave-2 hysteresis contract:
/// a decision happens once at least 200 characters have accumulated or 15 s
/// have elapsed (whichever comes first), needs 15 function-word hits with a
/// 1.3x lead over the runner-up, and scans at most the first 8000 characters.
public struct LanguageDetectionThresholds: Equatable, Sendable {
    /// Accumulated finalized characters required before deciding early.
    public var minimumDecidingCharacters: Int
    /// Elapsed seconds after which detection evaluates whatever exists.
    public var decisionWindow: TimeInterval
    /// Stopword hits the winner must clear.
    public var minimumHits: Int
    /// Required multiplier over the runner-up's score.
    public var leadRatio: Double
    /// Sample cap fed to the classifier.
    public var maximumSampleCharacters: Int

    public init(
        minimumDecidingCharacters: Int = 200,
        decisionWindow: TimeInterval = 15,
        minimumHits: Int = 15,
        leadRatio: Double = 1.3,
        maximumSampleCharacters: Int = 8000
    ) {
        self.minimumDecidingCharacters = minimumDecidingCharacters
        self.decisionWindow = decisionWindow
        self.minimumHits = minimumHits
        self.leadRatio = leadRatio
        self.maximumSampleCharacters = maximumSampleCharacters
    }

    public static let standard = LanguageDetectionThresholds()
}

/// Hysteresis state machine over accumulated live transcript text.
///
/// A recording started with the Automatic language option opens its live lane
/// with the last used explicit locale. This session consumes that lane's rows
/// and decides exactly once:
///
/// - Before either trigger fires (200 accumulated characters or 15 s), the
///   outcome stays `.pending`.
/// - On the first trigger the classifier runs over everything accumulated so
///   far. A decisive winner that differs from the start locale and is
///   supported by the recognizer yields `.detected`; the consumer restarts the
///   live lane once. Anything inconclusive — too few hits, an unclear margin,
///   or agreement with the start locale — yields `.keptStart`, which keeps the
///   start locale silently.
/// - After the single evaluation every further append returns the frozen
///   outcome: the restart-once guard lives here, so a lane can never flip
///   languages twice within one recording.
///
/// Finalized text accumulates; volatile (provisional) text is replaced on
/// every revision rather than appended, so repeated provisional updates cannot
/// inflate function-word counts.
public struct LanguageDetectionSession: Sendable {
    public enum Outcome: Equatable, Sendable {
        case pending
        /// Detected language differs from the start locale and is supported.
        case detected(localeIdentifier: String)
        /// Inconclusive or agreeing with the start locale: keep it silently.
        case keptStart(localeIdentifier: String)
    }

    public let startLocaleIdentifier: String
    public private(set) var outcome: Outcome

    private let thresholds: LanguageDetectionThresholds
    private let classifier: TranscriptLanguageClassifier
    private let isSupported: @Sendable (String) -> Bool
    private let startedAt: Date
    private var committedText = ""
    private var volatileText = ""
    private var hasEvaluated = false

    /// - Parameters:
    ///   - startLocaleIdentifier: Locale identifier the live lane started with.
    ///   - thresholds: Hysteresis bounds; `.standard` mirrors the spec.
    ///   - classifier: Stopword-profile classifier; injectable for tests.
    ///   - isSupported: Recognizer support predicate; a detected language the
    ///     recognizer cannot transcribe keeps the start locale instead.
    ///   - now: Window anchor; pass the recording's start date in production.
    public init(
        startLocaleIdentifier: String,
        thresholds: LanguageDetectionThresholds = .standard,
        classifier: TranscriptLanguageClassifier = .init(),
        isSupported: (@Sendable (String) -> Bool)? = nil,
        now: Date = Date()
    ) {
        self.startLocaleIdentifier = startLocaleIdentifier
        self.thresholds = thresholds
        self.classifier = classifier
        self.isSupported = isSupported ?? { _ in true }
        self.startedAt = now
        self.outcome = .pending
    }

    public var isDecided: Bool {
        hasEvaluated
    }

    /// Adds finalized transcript text and re-evaluates once a trigger fired.
    ///
    /// - Parameters:
    ///   - text: New finalized block text (append-only).
    ///   - date: Arrival time; drives the 15 s window trigger.
    @discardableResult
    public mutating func appendFinalized(_ text: String, at date: Date = Date()) -> Outcome {
        guard !hasEvaluated else { return outcome }
        committedText += Self.separator + text
        if committedText.count >= thresholds.minimumDecidingCharacters
            || date.timeIntervalSince(startedAt) >= thresholds.decisionWindow {
            evaluate()
        }
        return outcome
    }

    /// Replaces the provisional tail shown for the current segment.
    ///
    /// Volatile text counts toward the evidence at evaluation time but never
    /// accumulates: each call supersedes the previous provisional revision.
    @discardableResult
    public mutating func replaceVolatile(_ text: String, at date: Date = Date()) -> Outcome {
        guard !hasEvaluated else { return outcome }
        volatileText = text
        if totalCharacterCount >= thresholds.minimumDecidingCharacters
            || date.timeIntervalSince(startedAt) >= thresholds.decisionWindow {
            evaluate()
        }
        return outcome
    }

    /// Drops the provisional tail (for example on a capture gap).
    public mutating func clearVolatile() {
        volatileText = ""
    }

    private var totalCharacterCount: Int {
        committedText.count + volatileText.count
    }

    private mutating func evaluate() {
        hasEvaluated = true
        let keepStart = Outcome.keptStart(localeIdentifier: startLocaleIdentifier)
        guard let code = classifier.detect(
            committedText + volatileText,
            thresholds: thresholds
        ) else {
            outcome = keepStart
            return
        }
        // Detection yields bare language codes; agreement is judged at
        // language granularity, so "en" counts as agreement with "en-US".
        let startLanguageCode = Locale(identifier: startLocaleIdentifier)
            .language.languageCode?.identifier
            ?? startLocaleIdentifier
        guard code.caseInsensitiveCompare(startLanguageCode) != .orderedSame else {
            outcome = keepStart
            return
        }
        guard isSupported(code) else {
            outcome = keepStart
            return
        }
        outcome = .detected(localeIdentifier: code)
        // Bound retained memory after the decision; nothing reads the sample
        committedText = ""
        volatileText = ""
    }

    private static let separator = "\n"
}
