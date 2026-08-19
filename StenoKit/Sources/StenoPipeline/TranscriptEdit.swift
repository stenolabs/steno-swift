import Foundation
import StenoDomain

/// Benutzerkorrekturen am Transkript.
///
/// Eine Korrektur ersetzt nie eine gespeicherte Revision, sondern erzeugt eine
/// neue mit `origin: .userEdit(parent)`. Die alte bleibt vollstaendig stehen,
/// und der Anhaengepfad der Bibliothek prueft, dass die Korrektur wirklich auf
/// dem Stand aufsetzt, den der Benutzer vor sich hatte.
public enum TranscriptEdit {
    public enum Failure: Error, Equatable, Sendable {
        case turnOutOfRange
        case emptyText
        case unchanged
    }

    /// Ersetzt den Text genau eines Turns.
    ///
    /// Der Turn behaelt Sprecher, Anfang und Ende - die Zeitmarken stammen aus
    /// der Erkennung und bleiben wahr, auch wenn jemand ein Wort korrigiert.
    /// Die **Wortzeitmarken** des Turns fallen dagegen weg: fuer neu getippten
    /// Text gibt es keine, und alte weiterzuschleppen hiesse, Zeiten zu
    /// behaupten, die zu anderen Woertern gehoeren. Lieber keine Angabe als
    /// eine falsche - die Wiedergabe des Turns haengt ohnehin an Anfang und
    /// Ende, nicht am einzelnen Wort.
    public static func replacingText(
        in revision: TranscriptRevision,
        turnIndex: Int,
        with text: String,
        newRevisionID: RevisionID = RevisionID(),
        createdAt: Date = Date()
    ) throws -> TranscriptRevision {
        guard revision.turns.indices.contains(turnIndex) else {
            throw Failure.turnOutOfRange
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Einen Turn leeren ist Loeschen, nicht Korrigieren. Es waere die
        // einzige Bearbeitung, die Inhalt verschwinden laesst, und sie soll
        // nicht als Nebenwirkung eines geleerten Feldes passieren.
        guard !trimmed.isEmpty else { throw Failure.emptyText }

        let old = revision.turns[turnIndex]
        let existing = old.segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing != trimmed else { throw Failure.unchanged }

        var turns = revision.turns
        turns[turnIndex] = TranscriptTurn(
            speaker: old.speaker,
            start: old.start,
            end: old.end,
            segments: [TranscriptSegment(
                text: trimmed,
                start: old.start,
                end: old.end,
                words: []
            )]
        )
        return TranscriptRevision(
            id: newRevisionID,
            meetingID: revision.meetingID,
            createdAt: createdAt,
            origin: .userEdit(revision.id),
            turns: turns
        )
    }
}
