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

    /// Case and diacritics are dropped so that "Muller" also finds "Müller".
    /// Without this a user searches twice and, on the second try, believes
    /// the recording does not exist.
    private static func fold(_ text: String) -> String {
        normalized(text)
    }

    /// Shared normalization for all search: the sidebar title filter and the
    /// full-text index in the StenoLibrary module both fold with exactly
    /// this function, so "Mueller" finds the same things everywhere.
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}
