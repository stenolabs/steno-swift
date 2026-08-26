import Foundation
import Testing
@testable import StenoDomain

@Suite("People directory index")
struct PeopleDirectoryIndexTests {
    // MARK: Helpers

    private func meeting(
        _ title: String,
        createdAt: Date,
        participants: [PersonID] = [],
        additional: [PersonID] = []
    ) -> Meeting {
        Meeting(
            title: title,
            createdAt: createdAt,
            status: .ready,
            participantIDs: participants,
            additionalParticipantIDs: additional
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 10
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    /// Builds a displayNames dictionary from (key, name) pairs with a fresh
    /// PersonID each, mirroring IdentityStore-provided persons.
    private func people(_ pairs: (String, String)...) -> ([PersonID], [PersonID: String]) {
        var ids: [PersonID] = []
        var names: [PersonID: String] = [:]
        for (key, name) in pairs {
            let id = PersonID(rawValue: UUID())
            ids.append(id)
            names[id] = name
        }
        return (ids, names)
    }

    private func merged(_ dictionaries: [[PersonID: String]]) -> [PersonID: String] {
        var result: [PersonID: String] = [:]
        for dictionary in dictionaries {
            result.merge(dictionary) { current, _ in current }
        }
        return result
    }

    // MARK: normalizePersonKey

    @Test("normalization trims, collapses whitespace, and lowercases")
    func normalization() {
        #expect(PeopleDirectoryIndex.normalizePersonKey("  Alice   Smith  ") == "alice smith")
        #expect(PeopleDirectoryIndex.normalizePersonKey("BOB JONES") == "bob jones")
        #expect(PeopleDirectoryIndex.normalizePersonKey("\tDana\nScully ") == "dana scully")
    }

    @Test("normalization handles zh-Hant and CJK names without splitting")
    func cjkNormalization() {
        #expect(PeopleDirectoryIndex.normalizePersonKey("唐鳳") == "唐鳳")
        #expect(PeopleDirectoryIndex.normalizePersonKey("  唐 鳳  ") == "唐 鳳")
        #expect(PeopleDirectoryIndex.normalizePersonKey("黃 欽 勇") == "黃 欽 勇")
    }

    // MARK: Display variant selection

    @Test("display variant prefers the name with more uppercase letters")
    func picksBestDisplayVariant() {
        let (ids, names) = people(("a", "alice smith"), ("b", "Alice Smith"))
        let meetings = [
            meeting("M1", createdAt: date(2026, 8, 1), additional: [ids[0]]),
            meeting("M2", createdAt: date(2026, 8, 2), additional: [ids[1]]),
        ]

        let index = PeopleDirectoryIndex.build(meetings: meetings, displayNames: names)

        #expect(index.count == 1)
        #expect(index[0].displayName == "Alice Smith")
        #expect(index[0].noteCount == 2)
    }

    @Test("display variant keeps the first-seen casing on ties")
    func keepsFirstVariantOnTie() {
        let (ids, names) = people(("a", "ALICE"), ("b", "alice"))
        let meetings = [
            meeting("M1", createdAt: date(2026, 8, 1), additional: [ids[0], ids[1]]),
        ]

        let index = PeopleDirectoryIndex.build(meetings: meetings, displayNames: names)

        // Same key within one meeting: counted once, first variant kept.
        #expect(index.count == 1)
        #expect(index[0].displayName == "ALICE")
        #expect(index[0].noteCount == 1)
    }

    // MARK: build

    @Test("build returns empty for empty input")
    func emptyInput() {
        #expect(PeopleDirectoryIndex.build(meetings: [], displayNames: [:]) == [])
    }

    @Test("indexes per-person counts across multiple notes")
    func countsAcrossNotes() {
        let (aliceBob, names1) = people(("a", "Alice Smith"), ("b", "Bob Jones"))
        let (charlie, names2) = people(("c", "Charlie Brown"))
        let names = merged([names1, names2])

        let meetings = [
            meeting("M3", createdAt: date(2026, 8, 3), additional: [aliceBob[0]]),
            meeting("M2", createdAt: date(2026, 8, 2), additional: [aliceBob[0]] + charlie),
            meeting("M1", createdAt: date(2026, 8, 1), additional: aliceBob),
        ]

        let index = PeopleDirectoryIndex.build(meetings: meetings, displayNames: names)

        #expect(index.count == 3)

        // Alice attended 3 notes; lastDate is the newest meeting.
        #expect(index[0].displayName == "Alice Smith")
        #expect(index[0].noteCount == 3)
        #expect(index[0].lastDate == date(2026, 8, 3))
        #expect(index[0].meetingIDs.count == 3)

        // Bob and Charlie attended 1 note each; Charlie is more recent.
        #expect(index[1].displayName == "Charlie Brown")
        #expect(index[1].noteCount == 1)
        #expect(index[1].lastDate == date(2026, 8, 2))

        #expect(index[2].displayName == "Bob Jones")
        #expect(index[2].noteCount == 1)
        #expect(index[2].lastDate == date(2026, 8, 1))
    }

    @Test("counts an attendee only once per note even if duplicated in the list")
    func deduplicatesWithinMeeting() {
        let (ids, names) = people(
            ("a", "Alice Smith"),
            ("b", "alice smith"),
            ("c", "  Alice   Smith  ")
        )
        let meetings = [
            meeting("M1", createdAt: date(2026, 8, 1), participants: ids),
        ]

        let index = PeopleDirectoryIndex.build(meetings: meetings, displayNames: names)

        #expect(index.count == 1)
        #expect(index[0].displayName == "Alice Smith")
        #expect(index[0].noteCount == 1)
        #expect(index[0].meetingIDs.count == 1)
    }

    @Test("handles zh-Hant names correctly")
    func zhHantNames() {
        let (tang, names1) = people(("t", "唐鳳"))
        let (huang, names2) = people(("h", "黃欽勇"))
        let (lee, names3) = people(("l", "李開復"))
        let names = merged([names1, names2, names3])

        let meetings = [
            meeting("M1", createdAt: date(2026, 8, 10), additional: tang + huang),
            meeting("M2", createdAt: date(2026, 8, 12), additional: tang + lee),
        ]

        let index = PeopleDirectoryIndex.build(meetings: meetings, displayNames: names)

        #expect(index.count == 3)
        #expect(index[0].displayName == "唐鳳")
        #expect(index[0].noteCount == 2)
        #expect(index[0].lastDate == date(2026, 8, 12))
    }

    @Test("safely skips meetings whose participants have no resolvable names")
    func skipsUnresolvedAndBlankNames() {
        var names: [PersonID: String] = [:]
        let dana = PersonID(rawValue: UUID())
        names[dana] = "Dana Scully"
        let blank = PersonID(rawValue: UUID())
        names[blank] = "   "
        let unknown = PersonID(rawValue: UUID()) // no entry at all

        let meetings = [
            meeting("Solo 1", createdAt: date(2026, 8, 1)),
            meeting("With Attendees", createdAt: date(2026, 8, 2), additional: [dana, blank, unknown]),
        ]

        let index = PeopleDirectoryIndex.build(meetings: meetings, displayNames: names)

        #expect(index.count == 1)
        #expect(index[0].displayName == "Dana Scully")
        #expect(index[0].noteCount == 1)
    }

    @Test("deterministic ordering: count DESC, then date DESC, then name ASC")
    func deterministicOrdering() {
        let (zachary, namesZ) = people(("z", "Zachary Adams"))
        let (aaron, namesA) = people(("a", "Aaron Paul"))
        let (beta, namesB) = people(("b", "Beta User"))
        let names = merged([namesZ, namesA, namesB])

        let meetings = [
            meeting("M3", createdAt: date(2026, 8, 10), additional: beta),
            meeting("M2", createdAt: date(2026, 8, 5), additional: beta + aaron),
            meeting("M1", createdAt: date(2026, 8, 1), additional: zachary + aaron + beta),
        ]

        let index = PeopleDirectoryIndex.build(meetings: meetings, displayNames: names)

        // Beta User: count 3; Aaron Paul: count 2 (Aug 5); Zachary Adams: count 1.
        #expect(index.map(\.displayName) == ["Beta User", "Aaron Paul", "Zachary Adams"])

        // When counts and dates are identical, alphabetical by name.
        var tiedNames: [PersonID: String] = [:]
        var tiedIDs: [PersonID] = []
        for name in ["Zoe", "Alice", "Charlie"] {
            let id = PersonID(rawValue: UUID())
            tiedIDs.append(id)
            tiedNames[id] = name
        }
        let tiedIndex = PeopleDirectoryIndex.build(
            meetings: [meeting("Tied", createdAt: date(2026, 8, 1), additional: tiedIDs)],
            displayNames: tiedNames
        )
        #expect(tiedIndex.map(\.displayName) == ["Alice", "Charlie", "Zoe"])
    }

    // MARK: search

    @Test("search matches name/key substrings case-insensitively")
    func searchBySubstring() {
        let (ids, names) = people(
            ("a", "Alice Smith"),
            ("b", "bob jones"),
            ("c", "唐鳳")
        )
        let meetings = [
            meeting("M1", createdAt: date(2026, 8, 1), additional: ids),
        ]
        let index = PeopleDirectoryIndex.build(meetings: meetings, displayNames: names)

        #expect(PeopleDirectoryIndex.search(index, query: "ali").map(\.displayName) == ["Alice Smith"])
        #expect(PeopleDirectoryIndex.search(index, query: "SMITH").map(\.displayName) == ["Alice Smith"])
        #expect(PeopleDirectoryIndex.search(index, query: "bob").map(\.displayName) == ["bob jones"])
        #expect(PeopleDirectoryIndex.search(index, query: "唐").map(\.displayName) == ["唐鳳"])

        // Empty query keeps everything; nonsense matches nothing.
        #expect(PeopleDirectoryIndex.search(index, query: "").count == 3)
        #expect(PeopleDirectoryIndex.search(index, query: "nobody").isEmpty)
    }
}
