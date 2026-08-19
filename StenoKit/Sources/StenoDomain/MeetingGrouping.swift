import Foundation

/// Ein Abschnitt der Meetingliste. Die Bibliothek waechst monoton, und eine
/// flache Liste wird damit schnell unbrauchbar - eine Aufnahme sucht man nach
/// "wann war das", nicht nach Position.
///
/// Bewusst hier und nicht in der Ansicht: die Einteilung hat Kanten
/// (Tageswechsel, Monatsanfang, Jahresende), die sich nur pruefen lassen, wenn
/// sie ohne Oberflaeche aufrufbar ist.
public struct MeetingSection: Identifiable, Equatable, Sendable {
    public let title: String
    /// Gesetzt, wenn dieser Abschnitt ein Ordner ist. Nur daran haengen
    /// Umbenennen, Loeschen und das Ablegen eines Meetings.
    public let folderID: FolderID?
    public let meetings: [Meeting]

    public var id: String {
        folderID.map { "folder:\($0.rawValue)" } ?? "date:\(title)"
    }

    public init(title: String, folderID: FolderID? = nil, meetings: [Meeting]) {
        self.title = title
        self.folderID = folderID
        self.meetings = meetings
    }
}

public enum MeetingGrouping {
    /// Gruppiert nach Alter, neueste zuerst. Die Reihenfolge innerhalb einer
    /// Gruppe bleibt, wie sie hereinkommt.
    ///
    /// Jedes Meeting erscheint in genau einem Abschnitt. Ueberlappende
    /// Abschnitte waeren nicht nur haesslich: eine Liste, in der dieselbe
    /// Kennung zweimal steht, zerlegt die Auswahl.
    public static func sections(
        for meetings: [Meeting],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingSection] {
        var buckets: [(title: String, meetings: [Meeting])] = []

        for meeting in meetings {
            let title = self.title(for: meeting.createdAt, now: now, calendar: calendar)
            if let index = buckets.firstIndex(where: { $0.title == title }) {
                buckets[index].meetings.append(meeting)
            } else {
                buckets.append((title, [meeting]))
            }
        }
        return buckets.map { MeetingSection(title: $0.title, meetings: $0.meetings) }
    }

    private static func title(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        // Alles wird gegen `now` gerechnet, nie gegen die Systemuhr.
        // `Calendar.isDateInToday` waere hier falsch: es fragt immer den echten
        // heutigen Tag, und ein Test dagegen ist nur an dem Tag gruen, an dem
        // er geschrieben wurde.
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents(
            [.day],
            from: startOfDay,
            to: startOfToday
        ).day ?? 0

        // Ein Meeting in der Zukunft ist kein Fehlerfall: ein Entwurf wird fuer
        // einen Termin angelegt, der noch bevorsteht.
        if days < 0 { return "Upcoming" }
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "Previous 7 Days" }
        if days < 30 { return "Previous 30 Days" }

        // Danach nach Monat, und sobald das Jahr wechselt mit Jahreszahl -
        // "March" allein ist in einer mehrjaehrigen Bibliothek mehrdeutig.
        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = sameYear ? "LLLL" : "LLLL yyyy"
        return formatter.string(from: date)
    }
}
