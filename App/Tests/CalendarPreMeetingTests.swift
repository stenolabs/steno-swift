import Foundation
import Testing
@testable import steno_macos

@Suite("Calendar pre-meeting scheduling")
struct CalendarPreMeetingTests {
    /// Fixed epoch so window boundaries are exact; no wall-clock dependency.
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func event(
        _ title: String,
        startsIn interval: TimeInterval,
        hash: String? = nil
    ) -> UpcomingCalendarEvent {
        let start = now.addingTimeInterval(interval)
        return UpcomingCalendarEvent(
            title: title,
            start: start,
            hash: hash ?? PreMeetingSchedule.eventHash(
                externalIdentifier: title,
                start: start
            )
        )
    }

    // MARK: - Window boundaries

    @Test("an event starting inside the look-ahead window fires")
    @MainActor
    func withinWindowFires() {
        let due = PreMeetingSchedule.dueReminders(
            events: [event("Standup", startsIn: 10 * 60)],
            now: now,
            lookAhead: 30 * 60,
            alreadyFired: []
        )
        #expect(due.count == 1)
        #expect(due.first?.title == "Standup")
    }

    @Test("lower bound is exclusive: an event that already started never fires")
    @MainActor
    func alreadyStartedDoesNotFire() {
        let due = PreMeetingSchedule.dueReminders(
            events: [
                event("Started exactly now", startsIn: 0),
                event("Started a minute ago", startsIn: -60),
            ],
            now: now,
            lookAhead: 30 * 60,
            alreadyFired: []
        )
        #expect(due.isEmpty)
    }

    @Test("upper bound is inclusive at the horizon, exclusive one second later")
    @MainActor
    func horizonBoundary() {
        let inclusive = PreMeetingSchedule.dueReminders(
            events: [event("Edge", startsIn: 30 * 60)],
            now: now,
            lookAhead: 30 * 60,
            alreadyFired: []
        )
        #expect(inclusive.count == 1)

        let pastHorizon = PreMeetingSchedule.dueReminders(
            events: [event("Beyond", startsIn: 30 * 60 + 1)],
            now: now,
            lookAhead: 30 * 60,
            alreadyFired: []
        )
        #expect(pastHorizon.isEmpty)
    }

    // MARK: - Deduplication

    @Test("a hash in the fired set is skipped; other events still fire")
    @MainActor
    func dedupByHash() {
        let first = event("First", startsIn: 5 * 60)
        let second = event("Second", startsIn: 20 * 60)
        let due = PreMeetingSchedule.dueReminders(
            events: [first, second],
            now: now,
            lookAhead: 30 * 60,
            alreadyFired: [first.hash]
        )
        #expect(due.map(\.hash) == [second.hash])
    }

    @Test("due reminders come back ordered by start time")
    @MainActor
    func sortedByStart() {
        let late = event("Late", startsIn: 25 * 60)
        let early = event("Early", startsIn: 3 * 60)
        let due = PreMeetingSchedule.dueReminders(
            events: [late, early],
            now: now,
            lookAhead: 30 * 60,
            alreadyFired: []
        )
        #expect(due.map(\.title) == ["Early", "Late"])
    }

    // MARK: - Event hashing

    @Test("event hash is deterministic and distinguishes identifier and start")
    @MainActor
    func eventHashStability() {
        let start = Date(timeIntervalSinceReferenceDate: 123_456)
        let a = PreMeetingSchedule.eventHash(externalIdentifier: "cal-1", start: start)
        #expect(a == PreMeetingSchedule.eventHash(externalIdentifier: "cal-1", start: start))
        #expect(a != PreMeetingSchedule.eventHash(externalIdentifier: "cal-2", start: start))
        #expect(
            a != PreMeetingSchedule.eventHash(
                externalIdentifier: "cal-1",
                start: start.addingTimeInterval(1)
            )
        )
        // Fixed 16 hex chars from an 8-byte digest prefix.
        #expect(a.count == 16)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Fired-record persistence

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "CalendarPreMeetingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("fired records round-trip through defaults")
    @MainActor
    func firedRecordsRoundTrip() throws {
        let defaults = try makeDefaults()
        #expect(CalendarPreMeetingScheduler.loadFiredRecords(from: defaults).isEmpty)

        let records = ["abc": now, "def": now.addingTimeInterval(-60)]
        CalendarPreMeetingScheduler.saveFiredRecords(records, to: defaults)
        #expect(CalendarPreMeetingScheduler.loadFiredRecords(from: defaults) == records)
    }

    @Test("pruning drops entries older than retention and keeps fresh ones")
    @MainActor
    func pruningKeepsRetentionWindow() {
        let records = [
            "fresh": now.addingTimeInterval(-47 * 60 * 60),
            "boundary": now.addingTimeInterval(-48 * 60 * 60),
            "stale": now.addingTimeInterval(-49 * 60 * 60),
        ]
        let pruned = CalendarPreMeetingScheduler.prune(records: records, now: now)
        #expect(Array(pruned.keys) == ["fresh"])
    }

    // MARK: - Preferences

    @Test("enable gate defaults to false even when the key is absent")
    @MainActor
    func disabledByDefault() throws {
        let defaults = try makeDefaults()
        let preferences = CalendarPreMeetingPreferences(defaults: defaults)
        #expect(preferences.isEnabled == false)

        defaults.set(true, forKey: CalendarPreMeetingPreferences.isEnabledDefaultsKey)
        #expect(preferences.isEnabled == true)
    }

    @Test("look-ahead defaults to 30 minutes and clamps into 5...60")
    @MainActor
    func lookAheadClamp() throws {
        let defaults = try makeDefaults()
        let preferences = CalendarPreMeetingPreferences(defaults: defaults)
        #expect(preferences.lookAheadMinutes == 30)
        #expect(preferences.lookAhead == 30 * 60)

        defaults.set(90, forKey: CalendarPreMeetingPreferences.lookAheadMinutesDefaultsKey)
        #expect(preferences.lookAheadMinutes == 60)
        #expect(preferences.lookAhead == 60 * 60)

        defaults.set(1, forKey: CalendarPreMeetingPreferences.lookAheadMinutesDefaultsKey)
        #expect(preferences.lookAheadMinutes == 5)
    }
}
