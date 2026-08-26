import Foundation
import Testing
@testable import StenoTranscription

@Suite("Automatic transcription language detection")
struct LanguageDetectionTests {
    private let english = """
        The meeting started on time and we did not have much time left, so they \
        asked what about the remaining budget. You know there will be more \
        questions about which team should take over, but from their point of \
        view it would just be more work than the last project.
        """

    private let german = """
        Die Besprechung hat begonnen und wir haben nicht viel Zeit, deshalb ist \
        es wichtig, dass jeder mit dem Team ueber den Plan spricht. Es war auch \
        schon immer so, dass wir mehr arbeiten mussten, aber heute kann das ein \
        anderer tun, weil der Kunde sehr geduldig war.
        """

    private let french = """
        La reunion a commence et nous n'avons pas beaucoup de temps, donc il \
        faut que chacun parle avec l'equipe du projet. C'est toujours comme ca, \
        elle dit que les autres ont plus de travail, mais ce serait bien que tu \
        viennes avec nous a la prochaine reunion pour le voir par toi-meme.
        """

    // MARK: - Classifier vectors

    @Test("classifier recognises English")
    func detectsEnglish() {
        #expect(
            TranscriptLanguageClassifier().detect(english) == "en"
        )
    }

    @Test("classifier recognises German")
    func detectsGerman() {
        #expect(
            TranscriptLanguageClassifier().detect(german) == "de"
        )
    }

    @Test("classifier recognises French")
    func detectsFrench() {
        #expect(
            TranscriptLanguageClassifier().detect(french) == "fr"
        )
    }

    @Test("diarisation markers and timestamps do not dilute the score")
    func ignoresMarkersAndTimestamps() {
        let marked = """
            [You] 00:12:34 Der [Others] Vorschlag [Together] 12:34 ist gut und \
            wir haben nicht mehr viel Zeit dafuer, dass der Kunde das auch \
            sieht. Die anderen sind schon informiert und der Termin wird sich \
            nicht mehr verschieben, weil das Haus dafuer zu ist.
            """
        #expect(TranscriptLanguageClassifier().detect(marked) == "de")
    }

    @Test("short or mixed text stays inconclusive")
    func inconclusiveTextReturnsNil() {
        let classifier = TranscriptLanguageClassifier()

        // Far below the hit floor.
        #expect(classifier.detect("der Hund ist hier") == nil)

        // Balanced evidence without a clear lead.
        let mixed = """
            The meeting und die agenda waren okay, but the team ist noch nicht \
            einverstanden und we should ask them again because der Termin sich \
            verschiebt und everyone must know that the room is not free.
            """
        #expect(classifier.detect(mixed) == nil)
    }

    @Test("only the leading sample window is scanned")
    func respectsSampleCap() {
        var text = Array(repeating: "12:34 ", count: 500).joined()
        text += " " + german
        let classifier = TranscriptLanguageClassifier()
        #expect(
            classifier.detect(
                text,
                thresholds: LanguageDetectionThresholds(
                    minimumDecidingCharacters: 200,
                    decisionWindow: 15,
                    minimumHits: 15,
                    leadRatio: 1.3,
                    maximumSampleCharacters: 500
                )
            ) == nil
        )
        #expect(classifier.detect(text) == "de")
    }

    @Test("equal scores resolve deterministically by code")
    func deterministicTieBreak() {
        let profiles = [
            "zz": Set(["alpha", "beta", "gamma"]),
            "aa": Set(["gamma", "beta", "alpha"]),
        ]
        let classifier = TranscriptLanguageClassifier(profiles: profiles)
        // Defeat the lead-ratio guard so the pure tie-break shows.
        let thresholds = LanguageDetectionThresholds(
            minimumHits: 1,
            leadRatio: 1.0
        )
        // All three tokens hit both profiles identically -> equal scores.
        let text = "alpha beta gamma"
        #expect(classifier.detect(text, thresholds: thresholds) == "aa")
    }

    // MARK: - Hysteresis

    private func makeSession(
        start: String = "en-US",
        supported: (@Sendable (String) -> Bool)? = nil,
        now: Date = Date(timeIntervalSinceReferenceDate: 0),
        thresholds: LanguageDetectionThresholds = .standard
    ) -> LanguageDetectionSession {
        LanguageDetectionSession(
            startLocaleIdentifier: start,
            thresholds: thresholds,
            isSupported: supported,
            now: now
        )
    }

    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    @Test("decisive text before either trigger stays pending")
    func holdsDecisionUntilTrigger() {
        var session = makeSession(now: epoch)
        // Stopword-dense but far below the 200-character trigger.
        let shortGerman = "der die das und ist nicht ein eine den dem mit auf für auch aber oder"
        #expect(shortGerman.count < 200)
        let outcome = session.appendFinalized(shortGerman, at: epoch.addingTimeInterval(5))
        #expect(outcome == .pending)
        #expect(!session.isDecided)
    }

    @Test("reaching the character trigger decides early")
    func characterTriggerDecides() {
        var session = makeSession(start: "en-US", now: epoch)
        // Standard threshold is 200 characters; the German vector clears it.
        #expect(german.count > 200)
        let outcome = session.appendFinalized(german, at: epoch.addingTimeInterval(2))
        #expect(outcome == .detected(localeIdentifier: "de"))
        #expect(session.isDecided)
    }

    @Test("elapsed window evaluates whatever evidence exists")
    func timeTriggerEvaluates() {
        var session = makeSession(start: "de-DE", now: epoch)
        let outcome = session.appendFinalized(english, at: epoch.addingTimeInterval(15))
        #expect(outcome == .detected(localeIdentifier: "en"))
    }

    @Test("inconclusive evidence keeps the start locale silently")
    func inconclusiveKeepsStart() {
        var session = makeSession(start: "en-US", now: epoch)
        let outcome = session.appendFinalized(
            "12:34 [You] hmm okay",
            at: epoch.addingTimeInterval(16)
        )
        #expect(outcome == .keptStart(localeIdentifier: "en-US"))
    }

    @Test("detection agreeing with the start locale keeps it silently")
    func agreeingDetectionKeepsStart() {
        var session = makeSession(start: "en-US", now: epoch)
        let outcome = session.appendFinalized(english, at: epoch.addingTimeInterval(3))
        #expect(outcome == .keptStart(localeIdentifier: "en-US"))
    }

    @Test("unsupported detection keeps the start locale")
    func unsupportedDetectionKeepsStart() {
        var session = makeSession(
            start: "en-US",
            supported: { $0 != "de" },
            now: epoch
        )
        let outcome = session.appendFinalized(german, at: epoch.addingTimeInterval(3))
        #expect(outcome == .keptStart(localeIdentifier: "en-US"))
    }

    @Test("decision freezes: further appends never flip the lane again")
    func restartOnceGuard() {
        var session = makeSession(start: "en-US", now: epoch)
        let first = session.appendFinalized(german, at: epoch.addingTimeInterval(2))
        #expect(first == .detected(localeIdentifier: "de"))

        // Even overwhelming counter-evidence cannot restart the lane.
        var later = epoch.addingTimeInterval(60)
        #expect(session.appendFinalized(french, at: later) == .detected(localeIdentifier: "de"))
        #expect(session.replaceVolatile(english, at: later) == .detected(localeIdentifier: "de"))
        later = later.addingTimeInterval(60)
        #expect(session.appendFinalized(french, at: later) == .detected(localeIdentifier: "de"))
        #expect(session.isDecided)
    }

    @Test("provisional revisions replace instead of accumulating")
    func volatileDoesNotAccumulate() {
        var session = makeSession(
            start: "en-US",
            now: epoch,
            // The German vector (~330 chars) alone stays below the trigger;
            // five accumulated revisions would blow past it many times over.
            thresholds: LanguageDetectionThresholds(minimumDecidingCharacters: 400)
        )
        for second in 1...5 {
            let outcome = session.replaceVolatile(german, at: epoch.addingTimeInterval(Double(second)))
            #expect(outcome == .pending)
        }
        session.clearVolatile()
        // Committed text alone crosses the trigger and decides.
        var committed = ""
        while committed.count < 400 {
            committed += " " + german
        }
        let outcome = session.appendFinalized(committed, at: epoch.addingTimeInterval(6))
        #expect(outcome == .detected(localeIdentifier: "de"))
    }

    @Test("volatile tail counts as evidence when the window fires")
    func volatileCountsAtEvaluation() {
        var session = makeSession(
            start: "en-US",
            now: epoch,
            // The provisional tail alone stays under the character trigger.
            thresholds: LanguageDetectionThresholds(minimumDecidingCharacters: 400)
        )
        #expect(session.replaceVolatile(german, at: epoch.addingTimeInterval(1)) == .pending)
        let outcome = session.replaceVolatile(german, at: epoch.addingTimeInterval(16))
        #expect(outcome == .detected(localeIdentifier: "de"))
    }
}
