import Foundation

/// Filtert die Meetingliste ueber den Titel.
///
/// Bewusst nur der Titel: eine Volltextsuche ueber Transkripte braucht einen
/// Index und ist eine eigene Entscheidung. Ein Filter, der so tut, als suche er
/// im Inhalt, waere schlimmer als keiner - er liefert nichts und sagt nicht,
/// warum.
public enum MeetingSearch {
    public static func matching(
        _ meetings: [Meeting],
        query: String
    ) -> [Meeting] {
        let needle = fold(query)
        guard !needle.isEmpty else { return meetings }
        return meetings.filter { fold($0.title).contains(needle) }
    }

    /// Gross- und Kleinschreibung sowie Diakritika fallen weg, damit "Muller"
    /// auch "Müller" findet. Ohne das sucht ein Mensch zweimal und glaubt beim
    /// zweiten Mal, es gebe die Aufnahme nicht.
    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}
