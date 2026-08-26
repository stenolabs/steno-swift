import Foundation
import Testing
@testable import StenoPipeline

@Suite("Transcript citations")
struct TranscriptCitationsTests {
    // MARK: - stripTranscriptPrefix

    @Test("strips range timestamps and speaker prefixes")
    func stripsPrefixes() {
        #expect(
            TranscriptCitations.stripTranscriptPrefix("[00:00 - 00:05] Speaker: Hello world")
                == "Hello world"
        )
        #expect(TranscriptCitations.stripTranscriptPrefix("[00:03] [You] We ship Friday.") == "We ship Friday.")
        #expect(TranscriptCitations.stripTranscriptPrefix("[Others] I will prep notes.") == "I will prep notes.")
        #expect(TranscriptCitations.stripTranscriptPrefix("Alice: We ship Friday.") == "We ship Friday.")
        #expect(
            TranscriptCitations.stripTranscriptPrefix("Plain text without prefix")
                == "Plain text without prefix"
        )
    }

    // MARK: - extractTokens

    @Test("extracts English words while filtering stopwords")
    func englishTokens() {
        let tokens = TranscriptCitations.extractTokens("The team agreed to ship on Friday")
        #expect(tokens.contains("team"))
        #expect(tokens.contains("agreed"))
        #expect(tokens.contains("ship"))
        #expect(tokens.contains("friday"))
        #expect(!tokens.contains("the"))
        #expect(!tokens.contains("to"))
        #expect(!tokens.contains("on"))
    }

    @Test("extracts CJK character bigrams for Traditional Chinese")
    func cjkBigrams() {
        let tokens = TranscriptCitations.extractTokens("團隊決定在週五發布新版本")
        for bigram in ["團隊", "隊決", "決定", "週五", "發布", "新版", "版本"] {
            #expect(tokens.contains(bigram), "missing bigram \(bigram)")
        }
    }

    @Test("single CJK character becomes a unigram token")
    func cjkUnigram() {
        #expect(TranscriptCitations.extractTokens("好") == ["好"])
    }

    // MARK: - findCitation

    private let sampleTranscript = [
        "Alice: We ship Friday.",
        "Bob: I will prep the release notes and update the website.",
        "Charlie: I will verify the database backups before the deploy.",
    ]

    @Test("exact-quote bullet matches the exact line with high score")
    func exactQuote() {
        let match = TranscriptCitations.findCitation(bullet: "We ship Friday.", transcript: sampleTranscript)
        #expect(match != nil)
        #expect(match?.lineIndex == 0)
        #expect((match?.score ?? 0) >= 0.8)
    }

    @Test("paraphrase sharing sufficient tokens matches the correct line")
    func paraphrase() {
        let match = TranscriptCitations.findCitation(
            bullet: "Bob will prepare release notes and update website",
            transcript: sampleTranscript
        )
        #expect(match != nil)
        #expect(match?.lineIndex == 1)
        #expect((match?.score ?? 0) >= 0.4)
    }

    @Test("evidence spanning two adjacent lines resolves to the start line index")
    func spanningWindow() {
        let multiTurn = [
            "[00:01] Alice: We are definitely targeting the Friday launch window.",
            "[00:08] Bob: Sounds good, I will finalize the release announcement.",
            "[00:15] Charlie: I will monitor the server logs during rollout.",
        ]
        let match = TranscriptCitations.findCitation(
            bullet: "Alice confirmed Friday launch window and Bob will finalize the release announcement",
            transcript: multiTurn
        )
        #expect(match != nil)
        #expect(match?.lineIndex == 0)
    }

    @Test("Traditional Chinese bullet against Traditional Chinese transcript")
    func traditionalChinese() {
        let zhTranscript = [
            "[00:01] [You] 我們預計在週五發布新版本。",
            "[00:15] [Others] 沒問題，我讓小明負責撰寫說明文件。",
            "[00:30] [Others] 資料庫備份已經完成確認。",
        ]

        let match = TranscriptCitations.findCitation(
            bullet: "團隊決定在週五發布新版本，並由小明負責撰寫說明文件。",
            transcript: zhTranscript
        )
        #expect(match != nil)
        // Spans lines 0 and 1.
        #expect(match?.lineIndex == 0)
        #expect((match?.score ?? 0) > 0.5)

        let backupMatch = TranscriptCitations.findCitation(bullet: "資料庫備份確認已完成", transcript: zhTranscript)
        #expect(backupMatch != nil)
        #expect(backupMatch?.lineIndex == 2)
    }

    @Test("bullet with NO evidence returns nil (anti-guessing property)")
    func noEvidence() {
        let match = TranscriptCitations.findCitation(
            bullet: "Discussed migrating the entire infrastructure to Kubernetes and PostgreSQL in Q4.",
            transcript: sampleTranscript
        )
        #expect(match == nil)
    }

    @Test("timestamp and speaker prefixes do not skew or artificially match scores")
    func prefixesDoNotSkew() {
        let prefixed = [
            "[00:00 - 00:05] Speaker 1: Good morning everyone.",
            "[00:06 - 00:12] Speaker 2: We need to fix the authentication security vulnerability immediately.",
        ]

        // A generic bullet mentioning "Speaker" or "morning" must not match line 1.
        let genericMatch = TranscriptCitations.findCitation(
            bullet: "Speaker 1 and Speaker 2 met for a discussion.",
            transcript: prefixed
        )
        #expect(genericMatch == nil)

        let authMatch = TranscriptCitations.findCitation(
            bullet: "Fix the authentication security vulnerability immediately",
            transcript: prefixed
        )
        #expect(authMatch != nil)
        #expect(authMatch?.lineIndex == 1)
    }

    // MARK: - Thresholds

    @Test("short bullets (<= 2 tokens) require a 100% match")
    func shortBulletRequiresFullMatch() {
        let transcript = ["We need the release notes soon.", "Unrelated chatter about lunch."]
        // Both content tokens present -> accepted.
        let full = TranscriptCitations.findCitation(bullet: "release notes", transcript: transcript)
        #expect(full?.lineIndex == 0)
        // Only one of two tokens present -> rejected despite any overlap.
        let partial = TranscriptCitations.findCitation(bullet: "release schedule", transcript: transcript)
        #expect(partial == nil)
    }

    @Test("longer bullets below the confidence threshold are rejected")
    func belowThresholdRejected() {
        let transcript = ["alpha beta gamma delta epsilon"]
        // 2 of 4 matched = 0.5 >= threshold -> accepted.
        let twoMatches = TranscriptCitations.findCitation(
            bullet: "alpha beta zeta eta",
            transcript: transcript
        )
        #expect(twoMatches != nil)
        // A lowered threshold would accept this 1-of-3 match (score 0.333),
        // but the at-least-2-distinct-matches gate still rejects it.
        let singleMatch = TranscriptCitations.findCitation(
            bullet: "alpha zeta eta",
            transcript: transcript,
            threshold: 0.3
        )
        #expect(singleMatch == nil)
    }

    // MARK: - Tie-breaking

    @Test("equal score and matches prefer the earlier line")
    func earlierLineWinsTie() {
        let transcript = ["alpha beta", "alpha beta"]
        let match = TranscriptCitations.findCitation(bullet: "alpha beta", transcript: transcript)
        #expect(match?.lineIndex == 0)
    }

    @Test("equal score prefers the smaller window (precision)")
    func smallerWindowWinsTie() {
        let transcript = ["gamma", "delta gamma"]
        // The 2-line window starting at 0 scores 1.0; so does the 1-line
        // window at 1. The smaller window must win even though it starts later.
        let match = TranscriptCitations.findCitation(bullet: "gamma delta", transcript: transcript)
        #expect(match?.lineIndex == 1)
    }

    @Test("higher score always beats tie-breakers")
    func scoreBeatsTieBreakers() {
        let transcript = ["alpha beta", "alpha beta gamma delta"]
        // Line 0 window: 1.0; line 1 window: 1.0 too — but with four matched
        // tokens vs two, the fuller line must win on matched count first.
        let match = TranscriptCitations.findCitation(
            bullet: "alpha beta gamma delta",
            transcript: transcript,
            threshold: 0.3
        )
        #expect(match?.lineIndex == 1)
        #expect(match?.score == 1.0)
    }

    // MARK: - Batch & preprocessing

    @Test("batch resolves multiple bullets over a large transcript in one pass")
    func batchResolution() {
        var lines: [String] = []
        for i in 0..<1500 {
            if i == 42 {
                lines.append("[01:00] Alice: Special key event \(i) deployed to staging server.")
            } else if i == 888 {
                lines.append("[15:00] Bob: Crucial milestone \(i) reached for customer onboarding.")
            } else {
                lines.append(String(format: "[00:%02d] Speaker: Routine status update item %d discussed.", i % 60, i))
            }
        }
        let bullets = [
            "Special key event deployed to staging server",
            "Crucial milestone reached for customer onboarding",
            "Completely non-existent discussion about Mars rover",
        ]
        let processed = TranscriptCitations.preprocess(lines)
        let results = TranscriptCitations.findCitationsBatch(bullets, transcript: processed)

        #expect(results.count == 3)
        #expect(results[0]?.lineIndex == 42)
        #expect(results[1]?.lineIndex == 888)
        #expect(results[2] == nil)
    }

    @Test("raw-text transcripts split into lines before resolution")
    func rawTextInput() {
        let raw = sampleTranscript.joined(separator: "\n")
        let match = TranscriptCitations.findCitation(bullet: "verify the database backups", transcript: raw)
        #expect(match?.lineIndex == 2)
        #expect(match?.lineText == sampleTranscript[2])
    }

    // MARK: - Jump notification round-trip

    @Test("cite-jump notification carries the cited line index")
    func jumpNotificationRoundTrip() {
        final class Box: @unchecked Sendable {
            var received: Int?
        }
        let box = Box()
        let center = NotificationCenter()
        let observer = center.addObserver(
            forName: TranscriptCitations.citeTranscriptLineNotification,
            object: nil,
            queue: nil
        ) { note in
            box.received = TranscriptCitations.citedLineIndex(from: note)
        }
        defer { center.removeObserver(observer) }
        TranscriptCitations.postCiteJump(lineIndex: 7, center: center)
        #expect(box.received == 7)
        // Unrelated notifications are ignored by the extractor.
        #expect(
            TranscriptCitations.citedLineIndex(from: Notification(name: Notification.Name("other")))
                == nil
        )
    }
}
