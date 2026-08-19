import Foundation
import Testing
@testable import StenoDomain

@Suite("Meeting grouping")
struct MeetingGroupingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// 2026-08-06, 14:00 Ortszeit.
    private var now: Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 6, hour: 14
        ))!
    }

    private func meeting(_ offsetDays: Int, hour: Int = 10) -> Meeting {
        let day = calendar.date(byAdding: .day, value: -offsetDays, to: now)!
        let stamped = calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: day
        )!
        return Meeting(title: "T-\(offsetDays)", createdAt: stamped, status: .ready)
    }

    @Test("splits the list into age buckets, newest first")
    func groupsByAge() {
        let meetings = [
            meeting(0),
            meeting(1),
            meeting(3),
            meeting(20),
            meeting(120),
        ]

        let sections = MeetingGrouping.sections(
            for: meetings,
            now: now,
            calendar: calendar
        )

        #expect(sections.map(\.title) == [
            "Today",
            "Yesterday",
            "Previous 7 Days",
            "Previous 30 Days",
            "April",
        ])
        #expect(sections.allSatisfy { $0.meetings.count == 1 })
    }

    @Test("every meeting lands in exactly one section")
    func sectionsPartitionTheList() {
        let meetings = (0...400).map { meeting($0) }

        let sections = MeetingGrouping.sections(
            for: meetings,
            now: now,
            calendar: calendar
        )

        // Eine doppelt gefuehrte Meeting-ID zerlegt die Auswahl in der Liste,
        // deshalb ist das keine Formalie.
        let ids = sections.flatMap { $0.meetings.map(\.id) }
        #expect(ids.count == meetings.count)
        #expect(Set(ids).count == meetings.count)
    }

    @Test("a month from an earlier year carries its year")
    func namesTheYearWhenItDiffers() {
        let sections = MeetingGrouping.sections(
            for: [meeting(120), meeting(400)],
            now: now,
            calendar: calendar
        )

        #expect(sections.map(\.title) == ["April", "July 2025"])
    }

    @Test("late yesterday stays yesterday, not 'previous 7 days'")
    func handlesTheDayBoundary() {
        // 23:59 gestern liegt weniger als 24 Stunden zurueck, aber die
        // Einteilung geht nach Kalendertagen, nicht nach Abstand.
        let sections = MeetingGrouping.sections(
            for: [meeting(1, hour: 23), meeting(6, hour: 23)],
            now: now,
            calendar: calendar
        )

        #expect(sections.map(\.title) == ["Yesterday", "Previous 7 Days"])
    }

    @Test("a draft for a future date is not filed under today")
    func separatesUpcomingDrafts() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let draft = Meeting(title: "Kickoff", createdAt: tomorrow, status: .draft)
        let laterToday = Meeting(
            title: "Standup",
            createdAt: calendar.date(byAdding: .hour, value: 3, to: now)!,
            status: .draft
        )

        let sections = MeetingGrouping.sections(
            for: [draft, laterToday, meeting(0)],
            now: now,
            calendar: calendar
        )

        #expect(sections.map(\.title) == ["Upcoming", "Today"])
        #expect(sections[1].meetings.count == 2)
    }

    /// Diese Einteilung darf die Systemuhr nicht anfassen. `isDateInToday` und
    /// `isDateInYesterday` tun genau das, und ein Test dagegen ist nur an dem
    /// Tag gruen, an dem er geschrieben wurde - hier real passiert, sichtbar
    /// erst beim Tageswechsel um Mitternacht.
    @Test("the buckets follow the given reference date, not the system clock")
    func ignoresTheSystemClock() {
        let reference = calendar.date(from: DateComponents(
            year: 2019, month: 3, day: 14, hour: 9
        ))!
        let sameDay = Meeting(
            title: "Then",
            createdAt: calendar.date(byAdding: .hour, value: -2, to: reference)!,
            status: .ready
        )
        let dayBefore = Meeting(
            title: "Before",
            createdAt: calendar.date(byAdding: .day, value: -1, to: reference)!,
            status: .ready
        )

        let sections = MeetingGrouping.sections(
            for: [sameDay, dayBefore],
            now: reference,
            calendar: calendar
        )

        #expect(sections.map(\.title) == ["Today", "Yesterday"])
    }

    @Test("an empty library has no sections")
    func handlesEmptyInput() {
        #expect(MeetingGrouping.sections(for: [], now: now, calendar: calendar).isEmpty)
    }

}
