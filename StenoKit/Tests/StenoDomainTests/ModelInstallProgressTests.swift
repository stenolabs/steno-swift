import Testing
import Foundation
@testable import StenoDomain

/// Die Regel lag frueher als `if`-Kette in der App-Schicht, die kein
/// Testziel hat. Zwei Fehler sind dort unentdeckt durchgegangen, deshalb
/// steht sie jetzt hier.
@Suite("Model install progress")
struct ModelInstallProgressTests {
    private func progress(_ fraction: Double, attempt: Int = 0) -> ModelInstallProgress {
        ModelInstallProgress(fraction: fraction, title: "Speaker separation", attempt: attempt)
    }

    @Test("the first message always gets through")
    func firstMessageWins() {
        #expect(progress(0).supersedes(nil))
    }

    @Test("within one attempt the bar only moves forward")
    func forwardOnlyWithinAnAttempt() {
        #expect(progress(0.6).supersedes(progress(0.4)))
        #expect(!progress(0.4).supersedes(progress(0.6)))
    }

    @Test("a new attempt starts over, even though its fraction is lower")
    func newAttemptStartsOver() {
        // Der Reparaturdownload nach einer verfaelschten Datei. Ohne diese
        // Regel bliebe der Balken die ganze Zeit bei 95 Prozent stehen.
        #expect(progress(0, attempt: 1).supersedes(progress(0.95, attempt: 0)))
    }

    @Test("a late callback from an older attempt is dropped, however high it is")
    func lateCallbackFromOlderAttemptIsDropped() {
        // Der Fall, den die erste Fassung durchliess: der Rueckruf aus dem
        // alten Anlauf traf nach dem Neustart ein, war hoeher und
        // ueberschrieb den frischen Stand - der Balken sprang zurueck oder
        // sogar vorzeitig auf hundert Prozent.
        #expect(!progress(0.95, attempt: 0).supersedes(progress(0, attempt: 1)))
        #expect(!progress(1, attempt: 0).supersedes(progress(0.1, attempt: 1)))
    }

    @Test("a different bundle is never compared")
    func differentTitlesDoNotCompete() {
        let other = ModelInstallProgress(fraction: 0.9, title: "Transcription language")
        #expect(progress(0.1).supersedes(other))
    }
}
