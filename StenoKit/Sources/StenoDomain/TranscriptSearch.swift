import Foundation

/// Suche innerhalb eines Transkripts.
///
/// Liefert **Positionen**, keine gefilterte Kopie: Eine Trefferliste, die die
/// Turns neu durchnummeriert, waere die perfekte Falle fuer jede Aktion, die
/// sich auf einen Index bezieht - eine Korrektur an "Treffer 2" landete dann
/// an Turn 2 des ganzen Transkripts.
public enum TranscriptSearch {
    /// Die Indizes der Turns, deren Text die Suche enthaelt, in
    /// Transkriptreihenfolge.
    public static func matchingTurnIndices(
        in revision: TranscriptRevision,
        query: String
    ) -> [Int] {
        let needle = fold(query)
        guard !needle.isEmpty else { return Array(revision.turns.indices) }
        return revision.turns.indices.filter { index in
            fold(text(of: revision.turns[index])).contains(needle)
        }
    }

    public static func text(of turn: TranscriptTurn) -> String {
        turn.segments.map(\.text).joined(separator: " ")
    }

    /// Gross- und Kleinschreibung sowie Diakritika fallen weg. Wer "Muller"
    /// tippt, sucht auch "Müller"; die Erkennung schreibt beides.
    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}
