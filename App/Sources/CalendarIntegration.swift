import CryptoKit
import EventKit
import Foundation
import os
import UserNotifications

// MARK: - Preferences

/// UserDefaults-backed settings for local calendar pre-meeting reminders.
///
/// Privacy design (see docs/PLAN-PRIVACY.md): events are read from the
/// on-device EventKit store and leave the machine only as far as the user's
/// own notification shade. No event content is logged, persisted outside the
/// app container, or sent anywhere.
struct CalendarPreMeetingPreferences {
    /// Default OFF - a deliberate, privacy-conservative divergence from
    /// legacy stenoai, where pre-meeting notifications defaulted to true.
    /// Reading the local calendar requires an explicit opt-in.
    static let isEnabledDefaultsKey = "steno.calendar.premeeting.enabled"
    /// Look-ahead window in minutes; values outside 5...60 are clamped.
    static let lookAheadMinutesDefaultsKey =
        "steno.calendar.premeeting.lookAheadMinutes"

    static let defaultLookAheadMinutes = 30
    static let lookAheadRange: ClosedRange<Int> = 5...60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Only an explicit `true` enables the feature; an absent key stays off.
    var isEnabled: Bool {
        guard defaults.object(forKey: Self.isEnabledDefaultsKey) != nil else {
            return false
        }
        return defaults.bool(forKey: Self.isEnabledDefaultsKey)
    }

    var lookAheadMinutes: Int {
        let raw = defaults.object(forKey: Self.lookAheadMinutesDefaultsKey) == nil
            ? Self.defaultLookAheadMinutes
            : defaults.integer(forKey: Self.lookAheadMinutesDefaultsKey)
        return min(max(raw, Self.lookAheadRange.lowerBound), Self.lookAheadRange.upperBound)
    }

    var lookAhead: TimeInterval {
        TimeInterval(lookAheadMinutes) * 60
    }
}

// MARK: - Pure decision logic

/// One upcoming calendar event reduced to what a reminder decision needs.
/// The title travels into the notification content only; it never reaches
/// logs or persisted state.
struct UpcomingCalendarEvent: Equatable, Sendable {
    let title: String
    let start: Date
    /// Stable per-occurrence identity used for deduplication and as the
    /// notification identifier suffix. A hash of the external identifier and
    /// start date keeps raw identifiers out of the notification center.
    let hash: String
}

/// Pure scheduling decision for pre-meeting reminders, extracted so the whole
/// contract is unit-testable without EventKit or the notification center.
enum PreMeetingSchedule {
    /// Boundary semantics:
    /// - Lower bound EXCLUSIVE: an event that has already started
    ///   (`start <= now`) never fires. A "starts soon" ping for a running
    ///   meeting is noise, not a reminder.
    /// - Upper bound INCLUSIVE: `start == now + lookAhead` still fires;
    ///   anything strictly later waits for a later poll.
    /// - Dedup: each event hash fires at most once per `alreadyFired` set;
    ///   the caller persists the set across polls and launches.
    static func dueReminders(
        events: [UpcomingCalendarEvent],
        now: Date,
        lookAhead: TimeInterval,
        alreadyFired: Set<String>
    ) -> [UpcomingCalendarEvent] {
        events
            .filter { event in
                guard !alreadyFired.contains(event.hash) else { return false }
                guard event.start > now else { return false }
                return event.start.timeIntervalSince(now) <= lookAhead
            }
            .sorted { $0.start < $1.start }
    }

    /// Deterministic 16-hex-char digest of the external identifier plus the
    /// occurrence start, so recurring-event occurrences dedup individually.
    static func eventHash(externalIdentifier: String, start: Date) -> String {
        let material = "\(externalIdentifier)|\(start.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Scheduler

/// Polls the local EventKit calendars every 15 minutes while the app runs and
/// posts ONE user notification per event starting within the configured
/// look-ahead window.
///
/// - EventKit access (.event read scope) is requested lazily on the first
///   poll after the feature is enabled, or immediately when the Settings
///   toggle turns the feature on.
/// - Posts go straight through UNUserNotificationCenter under the identifier
///   `steno.preMeeting.<eventHash>`, so re-firing replaces instead of stacks.
/// - Logs carry counts and hashes only - never event titles.
@MainActor
final class CalendarPreMeetingScheduler {
    static let shared = CalendarPreMeetingScheduler()

    /// Poll cadence while the app runs.
    static let pollInterval: TimeInterval = 15 * 60
    /// Fired-record retention; older entries are pruned so the defaults
    /// payload stays bounded across long uptimes.
    static let firedRecordRetention: TimeInterval = 48 * 60 * 60
    private static let firedRecordsDefaultsKey = "steno.calendar.premeeting.fired"

    private let preferences: CalendarPreMeetingPreferences
    private let center: UNUserNotificationCenter

    private var pollTask: Task<Void, Never>?
    private var eventStore: EKEventStore?

    private enum AccessState { case notRequested, granted, denied }
    private var accessState: AccessState = .notRequested

    init(
        preferences: CalendarPreMeetingPreferences = CalendarPreMeetingPreferences(),
        center: UNUserNotificationCenter = .current()
    ) {
        self.preferences = preferences
        self.center = center
    }

    /// Starts the polling loop alongside the other platform integrations.
    /// Idempotent; every pass re-reads the enable gate, so disabling in
    /// Settings takes effect without a restart.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }

    /// Called from Settings when the toggle turns on, so the EventKit prompt
    /// appears with the enabling click instead of on the next poll.
    func prepare() {
        Task { await poll() }
    }

    // MARK: Poll pass

    private func poll() async {
        guard preferences.isEnabled else { return }
        // Honor the global notifications gate shared with StenoNotifications.
        guard StenoNotifications.isEnabled else { return }
        guard await ensureCalendarAccess(), let store = eventStore else { return }

        let now = Date()
        let horizon = now.addingTimeInterval(preferences.lookAhead)
        let predicate = store.predicateForEvents(
            withStart: now,
            end: horizon,
            calendars: nil
        )
        let ekEvents = store.events(matching: predicate)
        let events = ekEvents.map { event in
            UpcomingCalendarEvent(
                title: event.title ?? "",
                start: event.startDate,
                hash: PreMeetingSchedule.eventHash(
                    externalIdentifier: event.calendarItemExternalIdentifier,
                    start: event.startDate
                )
            )
        }

        var records = Self.loadFiredRecords(from: .standard)
        records = Self.prune(records: records, now: now)
        let due = PreMeetingSchedule.dueReminders(
            events: events,
            now: now,
            lookAhead: preferences.lookAhead,
            alreadyFired: Set(records.keys)
        )

        for event in due {
            await post(event)
            records[event.hash] = now
        }
        Self.saveFiredRecords(records, to: .standard)

        Self.log.notice(
            "Calendar poll: \(ekEvents.count, privacy: .public) upcoming, \(due.count, privacy: .public) reminders fired"
        )
    }


    /// Lazily requests read-only EventKit access on the first real need.
    private func ensureCalendarAccess() async -> Bool {
        switch accessState {
        case .granted:
            return true
        case .denied:
            return false
        case .notRequested:
            let store = EKEventStore()
            do {
                // macOS exposes only full-access request for reading; the
                // scheduler reads event metadata locally and never writes.
                let granted = try await store.requestFullAccessToEvents()
                accessState = granted ? .granted : .denied
                if granted {
                    eventStore = store
                } else {
                    Self.log.info("Calendar access denied by user")
                }
                return granted
            } catch {
                Self.log.error(
                    "EventKit authorization failed: \(error.localizedDescription, privacy: .public)"
                )
                accessState = .denied
                return false
            }
        }
    }

    // MARK: Notification posting

    private func post(_ event: UpcomingCalendarEvent) async {
        let content = UNMutableNotificationContent()
        content.title = event.title.isEmpty
            ? String(localized: "Upcoming meeting")
            : event.title
        content.body = String(localized: "Starts soon.")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "steno.preMeeting.\(event.hash)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Self.log.error(
                "Failed to add pre-meeting notification: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Fired-record persistence (testable statics)

    static func loadFiredRecords(from defaults: UserDefaults) -> [String: Date] {
        defaults.dictionary(forKey: firedRecordsDefaultsKey) as? [String: Date] ?? [:]
    }

    static func saveFiredRecords(_ records: [String: Date], to defaults: UserDefaults) {
        defaults.set(records, forKey: firedRecordsDefaultsKey)
    }

    /// Drops records older than the retention window so the set cannot grow
    /// without bound; hashes of long-gone occurrences are meaningless again.
    static func prune(
        records: [String: Date],
        now: Date,
        retention: TimeInterval = CalendarPreMeetingScheduler.firedRecordRetention
    ) -> [String: Date] {
        records.filter { now.timeIntervalSince($0.value) < retention }
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.steno",
        category: "calendar-premeeting"
    )
}
