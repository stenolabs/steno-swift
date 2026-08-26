import Foundation

/// One aggregated person in the people directory: every meeting that lists
/// them as a participant (speaking or silently attending) collapses into a
/// single entry keyed by the normalized name.
public struct PersonDirectoryEntry: Equatable, Identifiable, Sendable {
    /// Normalized grouping key (see `PeopleDirectoryIndex.normalizePersonKey`).
    public let id: String
    /// Best-looking display variant seen across all meetings.
    public let displayName: String
    /// Number of distinct meetings mentioning this person.
    public let noteCount: Int
    /// Creation date of the most recent such meeting, if any.
    public let lastDate: Date?
    /// The person's meetings in input order (callers pass newest first).
    public let meetingIDs: [MeetingID]

    public init(
        id: String,
        displayName: String,
        noteCount: Int,
        lastDate: Date?,
        meetingIDs: [MeetingID]
    ) {
        self.id = id
        self.displayName = displayName
        self.noteCount = noteCount
        self.lastDate = lastDate
        self.meetingIDs = meetingIDs
    }
}

/// Pure cross-meeting people index derived from `Meeting`
/// participant/person names.
///
/// Port of the legacy renderer's `lib/peopleIndex.ts`: normalize attendee
/// strings for grouping (trim, collapse internal whitespace, case-fold;
/// CJK characters are preserved without space-delimited assumptions),
/// pick the best display variant per person, count each person once per
/// meeting and order deterministically.
public enum PeopleDirectoryIndex {
    /// Normalizes an attendee display name for grouping: trims, collapses
    /// internal whitespace runs to single spaces and case-folds. CJK names
    /// survive untouched apart from surrounding whitespace.
    public static func normalizePersonKey(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// Chooses the better display variant of a name. Prefers the variant
    /// carrying more uppercase letters ("Alice Smith" beats "alice smith");
    /// ties keep the current choice so the first-seen casing wins.
    static func pickBestDisplayName(current: String, candidate: String) -> String {
        let cleanedCandidate = candidate
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if current.isEmpty { return cleanedCandidate }
        if uppercaseCount(cleanedCandidate) > uppercaseCount(current) {
            return cleanedCandidate
        }
        return current
    }

    private static func uppercaseCount(_ name: String) -> Int {
        name.unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
    }

    private struct Accumulator {
        var displayName: String
        var noteCount: Int
        var lastDate: Date?
        var latestTime: TimeInterval
        var meetingIDs: [MeetingID]
    }

    /// Single-pass index over meetings. `displayNames` resolves participant
    /// identifiers to their current display names; participants without a
    /// resolvable, non-empty name are skipped. Each person counts at most
    /// once per meeting even if several of their variants (or two distinct
    /// person records normalizing to the same key) appear on it.
    ///
    /// Ordering: noteCount DESC, lastDate DESC, display name ASC
    /// (case-insensitive), normalized key ASC.
    public static func build(
        meetings: [Meeting],
        displayNames: [PersonID: String]
    ) -> [PersonDirectoryEntry] {
        guard !meetings.isEmpty else { return [] }

        var keysByPerson: [PersonID: String] = [:]
        var order: [String] = []
        var byKey: [String: Accumulator] = [:]

        for meeting in meetings {
            var seenInMeeting = Set<String>()
            for personID in meeting.participantIDs + meeting.additionalParticipantIDs {
                guard let rawName = displayNames[personID], !rawName.isEmpty else {
                    continue
                }
                let key = keysByPerson[personID] ?? normalizePersonKey(rawName)
                keysByPerson[personID] = key
                guard !key.isEmpty else { continue }
                // Counted once per meeting regardless of how many variants
                // or duplicate person records share this key.
                guard seenInMeeting.insert(key).inserted else { continue }

                let date = meeting.createdAt
                let time = date.timeIntervalSince1970
                if var existing = byKey[key] {
                    existing.displayName = pickBestDisplayName(
                        current: existing.displayName,
                        candidate: rawName
                    )
                    existing.noteCount += 1
                    if time > existing.latestTime {
                        existing.latestTime = time
                        existing.lastDate = date
                    }
                    byKey[key] = existing
                 } else {
                    byKey[key] = Accumulator(
                        displayName: pickBestDisplayName(current: "", candidate: rawName),
                        noteCount: 1,
                        lastDate: date,
                        latestTime: time,
                        meetingIDs: []
                    )
                    order.append(key)
                }
                byKey[key]?.meetingIDs.append(meeting.id)
            }
        }
        let entries = order.compactMap { key -> PersonDirectoryEntry? in
            guard let accumulator = byKey[key] else { return nil }
            return PersonDirectoryEntry(
                id: key,
                displayName: accumulator.displayName,
                noteCount: accumulator.noteCount,
                lastDate: accumulator.lastDate,
                meetingIDs: accumulator.meetingIDs
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.noteCount != rhs.noteCount {
                return lhs.noteCount > rhs.noteCount
            }
            let lhsTime = lhs.lastDate?.timeIntervalSince1970 ?? 0
            let rhsTime = rhs.lastDate?.timeIntervalSince1970 ?? 0
            if lhsTime != rhsTime {
                return lhsTime > rhsTime
            }
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    /// Case-insensitive substring search over the person's display name and
    /// normalized key; preserves the index ordering.
    public static func search(
        _ entries: [PersonDirectoryEntry],
        query: String
    ) -> [PersonDirectoryEntry] {
        let needle = normalizePersonKey(query)
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            entry.id.contains(needle)
                || normalizePersonKey(entry.displayName).contains(needle)
        }
    }
}
