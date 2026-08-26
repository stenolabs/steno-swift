import Foundation
import Testing
@testable import StenoTranscription

@Suite("Cross-channel bleed deduplication")
struct BleedDeduplicationTests {
    // MARK: - Token multiset Jaccard

    @Test("normalises case and punctuation before comparing tokens")
    func normalizationIgnoresCaseAndPunctuation() {
        #expect(CrossChannelBleedFilter.multisetJaccard(
            "Hallo Welt! Wie geht es dir?",
            "hallo welt, wie GEHT es Dir"
        ) == 1.0)
    }

    @Test("counts token multiplicity instead of collapsing to a set")
    func multisetSemanticsRespectRepetitions() {
        // Same token set, but half the volume: intersection 3, union 6.
        let similarity = CrossChannelBleedFilter.multisetJaccard("a b c", "a b c a b c")
        #expect(similarity < 0.6)
        #expect(similarity > 0.4)
    }

    @Test("empty text scores zero similarity")
    func emptyTextScoresZero() {
        #expect(CrossChannelBleedFilter.multisetJaccard("", "anything at all") == 0.0)
        #expect(CrossChannelBleedFilter.multisetJaccard("!!! ???", "...") == 0.0)
    }

    // MARK: - Pair matching

    @Test("identical sentence on both channels suppresses the system segment")
    func identicalSentenceSuppressesSystem() {
        let filter = CrossChannelBleedFilter()
        let mic = block("Guten Morgen, koennen wir anfangen?", channel: .microphone, start: 10, end: 13)
        let system = block("guten Morgen, Koennen wir anfangen!", channel: .system, start: 10.2, end: 13.1)

        let matches = filter.matches(in: [mic, system])

        #expect(matches.count == 1)
        #expect(matches.first?.echo == system)
        #expect(matches.first?.direct == mic)
        #expect(filter.isBleedEcho(system, in: [mic, system]))
        #expect(!filter.isBleedEcho(mic, in: [mic, system]))
    }

    @Test("different content on both channels is kept")
    func differentContentIsKept() {
        let filter = CrossChannelBleedFilter()
        let mic = block("Ich habe die Zahlen gestern geprueft", channel: .microphone, start: 5, end: 8)
        let system = block("Der Kunde ruft gleich zurueck", channel: .system, start: 5.5, end: 8)

        #expect(filter.matches(in: [mic, system]).isEmpty)
    }

    @Test("partial overlap below the threshold is kept")
    func partialOverlapBelowThresholdIsKept() {
        let filter = CrossChannelBleedFilter()
        // Shared tokens "wir besprechen den vertrag" (4 of 9 union tokens in
        // the best pairing) stays below the 0.6 threshold.
        let mic = block("wir besprechen den vertrag heute ausfuehrlich", channel: .microphone, start: 0, end: 3)
        let system = block("spaeter wir besprechen den vertrag ganz ruhig", channel: .system, start: 0.4, end: 3.2)

        #expect(filter.matches(in: [mic, system]).isEmpty)
    }

    @Test("segments outside the time window are never paired")
    func timeWindowGuardsPairing() {
        let text = "dies ist ein gemeinsamer satz fuer den test"
        let filter = CrossChannelBleedFilter(timeWindow: 2.0)

        // Exactly at the window edge: still paired.
        let mic = block(text, channel: .microphone, start: 10.0, end: 13)
        let edgeSystem = block(text, channel: .system, start: 12.0, end: 15)
        #expect(filter.isBleedEcho(edgeSystem, in: [mic, edgeSystem]))

        // Just past it: no pair despite identical wording.
        let farSystem = block(text, channel: .system, start: 12.01, end: 15)
        #expect(!filter.isBleedEcho(farSystem, in: [mic, farSystem]))
    }

    @Test("short segments are skipped regardless of similarity")
    func shortSegmentsAreSkipped() {
        let filter = CrossChannelBleedFilter()
        let mic = block("ja genau", channel: .microphone, start: 0, end: 1)
        let system = block("ja genau", channel: .system, start: 0.1, end: 1)

        #expect(filter.matches(in: [mic, system]).isEmpty)
    }

    @Test("each system segment pairs with its most similar microphone match")
    func bestMatchWinsPerSystemSegment() {
        let filter = CrossChannelBleedFilter()
        let nearMic = block("der bericht ist fertig gestellt worden heute", channel: .microphone, start: 20, end: 23)
        let system = block("der bericht ist fertiggestellt worden heute", channel: .system, start: 20.3, end: 23)

        let farMic = block(
            "eine völlig andere besprechung notiz",
            channel: .microphone,
            start: 100,
            end: 103
        )
        let matches = filter.matches(in: [nearMic, farMic, system])

        #expect(matches.count == 1)
        #expect(matches.first?.direct == nearMic)
        #expect(matches.first?.echo == system)
    }

    // MARK: - Level evidence hook

    @Test("strictly louder system level flips suppression onto the mic segment")
    func louderSystemFlipsSuppressionToMic() {
        var filter = CrossChannelBleedFilter()
        filter.levelEvidence = { channel, _, _ in
            channel == .system ? 0.8 : 0.2
        }
        let mic = block("das meeting beginnt jetzt puenktlich", channel: .microphone, start: 0, end: 3)
        let system = block("das meeting beginnt jetzt pünktlich", channel: .system, start: 0.2, end: 3)

        let matches = filter.matches(in: [mic, system])

        #expect(matches.count == 1)
        #expect(matches.first?.echo == mic)
        #expect(matches.first?.direct == system)
    }

    @Test("ties and unreadable levels keep the conservative mic-wins default")
    func ambiguousEvidenceKeepsMicWins() {
        let mic = block("das meeting beginnt jetzt puenktlich", channel: .microphone, start: 0, end: 3)
        let system = block("das meeting beginnt jetzt pünktlich", channel: .system, start: 0.2, end: 3)

        // Genuine tie.
        var tieFilter = CrossChannelBleedFilter()
        tieFilter.levelEvidence = { _, _, _ in 0.5 }
        #expect(tieFilter.matches(in: [mic, system]).first?.echo == system)

        // Evidence unreadable for one channel.
        var unreadableFilter = CrossChannelBleedFilter()
        unreadableFilter.levelEvidence = { channel, _, _ in
            channel == .microphone ? nil : 0.9
        }
        #expect(unreadableFilter.matches(in: [mic, system]).first?.echo == system)
    }

    // MARK: - LiveTranscriptFeed integration

    @Test("feed marks the echoed system row without deleting either row")
    func feedMarksEchoWithoutDeleting() {
        var feed = LiveTranscriptFeed()
        let mic = block("Guten Morgen, koennen wir anfangen?", channel: .microphone, start: 10, end: 13)
        let system = block("guten morgen, Koennen wir anfangen", channel: .system, start: 10.2, end: 13.1)
        feed.apply(.final(output([mic], channel: .microphone)), for: .microphone)
        feed.apply(.final(output([system], channel: .system)), for: .system)

        let rows = feed.rows

        #expect(rows.count == 2)
        let flagged = rows.filter(\.excludedFromReports)
        #expect(flagged.map(\.block.channel) == [.system])
        #expect(flagged.map(\.block.text) == [system.text])
    }

    @Test("suppression follows live revision as channels finalise")
    func suppressionTracksLiveRevision() {
        var feed = LiveTranscriptFeed()
        let sentence = "wir sehen uns morgen im buero"

        // Only the system channel has spoken so far: nothing to duplicate.
        feed.apply(.volatile(output([
            block(sentence, channel: .system, start: 0, end: 2),
        ])), for: .system)
        #expect(feed.rows.allSatisfy { !$0.excludedFromReports })

        // The mic volatile echo arrives: the system volatile row gets flagged.
        feed.apply(.volatile(output([
            block(sentence, channel: .microphone, start: 0.1, end: 2),
        ])), for: .microphone)
        #expect(feed.rows.filter(\.excludedFromReports).map(\.block.channel) == [.system])
        #expect(feed.rows.filter { !$0.excludedFromReports }.map(\.block.channel) == [.microphone])

        // Mic finalises; the flag moves with the projection, originals stay.
        feed.apply(.final(output([
            block(sentence, channel: .microphone, start: 0.1, end: 2),
        ])), for: .microphone)
        let rows = feed.rows
        #expect(rows.map(\.block.channel).contains(.system))
        #expect(rows.filter(\.excludedFromReports).map(\.block.channel) == [.system])
    }

    @Test("excluded rows keep their identity stable across re-evaluation")
    func rowIdentityStaysStable() {
        var feed = LiveTranscriptFeed()
        feed.apply(.final(output([
            block("identischer satz zum blutungstest hier", channel: .microphone, start: 0, end: 2),
        ])), for: .microphone)
        feed.apply(.final(output([
            block("Identischer Satz zum Blutungstest hier", channel: .system, start: 0.3, end: 2),
        ])), for: .system)

        let before = feed.rows
        let after = feed.rows

        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.map(\.excludedFromReports) == after.map(\.excludedFromReports))
    }

    @Test("single-channel feeds never produce exclusions")
    func singleChannelNeverFlags() {
        var feed = LiveTranscriptFeed()
        feed.apply(.final(output([
            block("nur das mikrokanal hoert diesen satz heute", channel: .microphone, start: 0, end: 2),
            block("und ein zweiter satz vom selben kanal", channel: .microphone, start: 2, end: 4),
        ])), for: .microphone)

        #expect(feed.rows.allSatisfy { !$0.excludedFromReports })
    }

    // MARK: - Helpers

    private func block(
        _ text: String,
        channel: TranscriptionChannel,
        start: TimeInterval,
        end: TimeInterval
    ) -> TranscriptionBlock {
        TranscriptionBlock(channel: channel, text: text, start: start, end: end, words: [])
    }

    private func output(
        _ blocks: [TranscriptionBlock],
        channel: TranscriptionChannel = .microphone
    ) -> TranscriptOutput {
        TranscriptOutput(localeIdentifier: "de-DE", blocks: blocks)
    }
}
