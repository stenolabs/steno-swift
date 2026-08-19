import Foundation
import StenoDomain
import Testing
@testable import StenoIdentity

@Suite("Speaker identity: 13 invariants")
struct IdentityInvariantTests {
    private let engine = SpeakerSuggestionEngine()

    @Test("Invariant 01: suggestions never assign names or mutate profiles")
    func suggestionsAreAdvisoryOnly() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let person = makeKnownPerson(
            name: "Ada",
            prototypeDistances: [0, 0],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        let people = [person]
        let cluster = makeCluster(
            meetingID: meetingID,
            runID: runID,
            clusterID: "A"
        )

        let suggestions = engine.suggestions(for: [cluster], people: people)

        #expect(suggestions.first?.status == .confirmed)
        #expect(suggestions.first?.suggestedPersonID == person.id)
        #expect(people == [person])
        #expect(person.prototypes.allSatisfy { $0.meetingID != meetingID })
    }

    @Test("Invariant 02: only explicit confirmation persists positive evidence")
    func onlyConfirmationCreatesPrototype() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let knownPerson = Person(displayName: "Ada")
        let cluster = makeCluster(
            meetingID: meetingID,
            runID: runID,
            clusterID: "A"
        )
        let original = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            clusters: [cluster],
            persons: [knownPerson]
        )
        _ = engine.suggestions(for: [cluster], people: original.persons)

        let result = try engine.confirm(
            clusterID: "A",
            channel: "system",
            runID: runID,
            as: knownPerson.id,
            in: original
        )

        #expect(original.persons[0].prototypes.isEmpty)
        #expect(person(knownPerson.id, in: result.state)?.prototypes.count == 1)
        #expect(result.status == .confirmed)
    }

    @Test("Invariant 03: same-context prototypes win and scoring uses minimum distance, never an average")
    func contextPoolAndMinimumDistance() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let personID = PersonID()
        let person = Person(
            id: personID,
            displayName: "Ada",
            prototypes: [
                makePrototype(personID: personID, meetingID: MeetingID(), recordingType: .remote, distance: 0),
                makePrototype(personID: personID, meetingID: MeetingID(), recordingType: .remote, distance: 1.8),
                makePrototype(personID: personID, meetingID: MeetingID(), recordingType: .inPerson, distance: 0.7),
            ]
        )
        let result = try #require(engine.suggestions(
            for: [makeCluster(meetingID: meetingID, runID: runID, clusterID: "A")],
            people: [person]
        ).first)

        #expect(abs(try #require(result.candidates.first).distance) < 0.000_001)
        #expect(result.status == .confirmed)
        #expect(result.candidates.first?.confirmedMeetingCount == 2)
    }

    @Test("Invariant 04: all inclusive gate boundaries confirm at 0.40, 0.10, 20s, 3 turns, 1.55s and 2 meetings")
    func inclusiveGateBoundaries() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let best = makeKnownPerson(
            name: "Ada",
            prototypeDistances: [0.40, 0.40],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        let runner = makeKnownPerson(
            name: "Grace",
            prototypeDistances: [0.50, 0.50],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        let cluster = makeCluster(
            meetingID: meetingID,
            runID: runID,
            clusterID: "A",
            duration: 31,
            segments: 20
        )

        let result = try #require(engine.suggestions(
            for: [cluster],
            people: [best, runner]
        ).first)

        #expect(result.status == .confirmed)
        #expect(result.suggestedPersonID == best.id)
    }

    @Test("Invariant 05: weak margin or stability stays possible while distance above 0.40 yields none")
    func possibleAndNoneTiers() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let best = makeKnownPerson(
            name: "Ada",
            prototypeDistances: [0.10, 0.10],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        let closeRunner = makeKnownPerson(
            name: "Grace",
            prototypeDistances: [0.199, 0.199],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        let cases = [
            makeCluster(meetingID: meetingID, runID: runID, clusterID: "short", duration: 19.99),
            makeCluster(meetingID: meetingID, runID: runID, clusterID: "few", duration: 20, segments: 2),
            makeCluster(meetingID: meetingID, runID: runID, clusterID: "fragmented", duration: 30.99, segments: 20),
        ]
        for cluster in cases {
            let result = try #require(engine.suggestions(for: [cluster], people: [best]).first)
            #expect(result.status == .possible)
        }
        let ambiguous = try #require(engine.suggestions(
            for: [makeCluster(meetingID: meetingID, runID: runID, clusterID: "ambiguous")],
            people: [best, closeRunner]
        ).first)
        #expect(ambiguous.status == .possible)

        let far = makeKnownPerson(
            name: "Far",
            prototypeDistances: [0.401, 0.401],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        let none = try #require(engine.suggestions(
            for: [makeCluster(meetingID: meetingID, runID: runID, clusterID: "far")],
            people: [far]
        ).first)
        #expect(none.status == .none)
        #expect(none.suggestedPersonID == nil)
    }

    @Test("Invariant 06: confirmed evidence counts distinct meetings, not prototype rows")
    func distinctConfirmedMeetings() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let oneMeeting = MeetingID()
        let person = makeKnownPerson(
            name: "Ada",
            prototypeDistances: [0, 0],
            meetingIDs: [oneMeeting, oneMeeting]
        )
        let cluster = makeCluster(meetingID: meetingID, runID: runID, clusterID: "A")

        let result = try #require(engine.suggestions(for: [cluster], people: [person]).first)

        #expect(result.status == .possible)
        #expect(result.candidates.first?.confirmedMeetingCount == 1)
    }

    @Test("Invariant 07: hard negatives suppress only when absolutely close and relative to the positive")
    func relativeHardNegativeSuppression() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let cluster = makeCluster(meetingID: meetingID, runID: runID, clusterID: "A")
        let base = makeKnownPerson(
            name: "Ada",
            prototypeDistances: [0.15, 0.15],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        var harmless = base
        harmless.hardNegatives = [HardNegative(
            personID: harmless.id,
            embedding: embedding(atCosineDistance: 0.39),
            recordingType: .remote,
            channel: "system",
            meetingID: MeetingID(),
            runID: RunID(),
            clusterID: "negative",
            speechDurationSeconds: 20,
            segmentCount: 3,
            source: .userConfirmed
        )]
        var conflicting = base
        conflicting.hardNegatives = [HardNegative(
            personID: conflicting.id,
            embedding: embedding(atCosineDistance: 0.24),
            recordingType: .remote,
            channel: "system",
            meetingID: MeetingID(),
            runID: RunID(),
            clusterID: "negative",
            speechDurationSeconds: 20,
            segmentCount: 3,
            source: .userConfirmed
        )]

        #expect(engine.suggestions(for: [cluster], people: [harmless]).first?.status == .confirmed)
        let suppressed = try #require(engine.suggestions(for: [cluster], people: [conflicting]).first)
        #expect(suppressed.status == .none)
        #expect(suppressed.candidates.first?.hardNegativeConflict == true)
    }

    @Test("Invariant 08: only confirmed suggestions consume a person meeting-wide")
    func confirmedOnlyExclusivity() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let person = makeKnownPerson(
            name: "Ada",
            prototypeDistances: [0, 0],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        let possible = makeCluster(
            meetingID: meetingID,
            runID: runID,
            channel: "mic",
            clusterID: "possible",
            distance: 0,
            duration: 10
        )
        let confirmed = makeCluster(
            meetingID: meetingID,
            runID: runID,
            channel: "system",
            clusterID: "confirmed",
            distance: 0.05
        )
        let weakerConfirmed = makeCluster(
            meetingID: meetingID,
            runID: runID,
            channel: "system",
            clusterID: "weaker",
            distance: 0.08
        )

        let results = engine.suggestions(
            for: [possible, weakerConfirmed, confirmed],
            people: [person]
        )

        #expect(results.first { $0.clusterID == "possible" }?.status == .possible)
        #expect(results.first { $0.clusterID == "confirmed" }?.status == .confirmed)
        #expect(
            results.first { $0.clusterID == "weaker" }?.status
                == ClusterSuggestion.Status.none
        )
    }

    @Test("Invariant 09: fragment merge is transitive, duration-weighted, normalized and keeps the strongest id")
    func unionFindMerge() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let clusters = [
            makeCluster(meetingID: meetingID, runID: runID, clusterID: "A", distance: 0, duration: 10),
            makeCluster(meetingID: meetingID, runID: runID, clusterID: "B", distance: 0.087, duration: 30),
            makeCluster(meetingID: meetingID, runID: runID, clusterID: "C", distance: 0.331, duration: 20),
        ]

        let merge = engine.mergeSameChannelFragments(clusters)
        let merged = try #require(merge.clusters.first)

        #expect(merge.clusters.count == 1)
        #expect(merged.clusterID == "B")
        #expect(merged.mergedFrom == ["A", "C"])
        #expect(merged.speechDurationSeconds == 60)
        #expect(abs(merged.embedding.reduce(0) { $0 + $1 * $1 } - 1) < 0.000_001)
        #expect(merge.primaryKey(for: clusters[0])?.clusterID == "B")
    }

    @Test("Invariant 10: a mixed fragment contaminates the merge and the whole cluster has no candidates")
    func mixedContaminationSurvivesMerge() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let person = makeKnownPerson(
            name: "Ada",
            prototypeDistances: [0, 0],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        let merge = engine.mergeSameChannelFragments([
            makeCluster(meetingID: meetingID, runID: runID, clusterID: "A", multiple: true),
            makeCluster(meetingID: meetingID, runID: runID, clusterID: "B", distance: 0.02),
        ])
        let merged = try #require(merge.clusters.first)
        let result = try #require(engine.suggestions(for: [merged], people: [person]).first)

        #expect(merged.containsMultipleSpeakers)
        #expect(result.status == .none)
        #expect(result.candidates.isEmpty)
    }

    @Test("Invariant 11: equal cluster ids on different channels never reassign each other")
    func channelScopedConfirmation() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let ada = Person(displayName: "Ada")
        let grace = Person(displayName: "Grace")
        var state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            clusters: [
                makeCluster(meetingID: meetingID, runID: runID, channel: "mic", clusterID: "SPEAKER_0"),
                makeCluster(meetingID: meetingID, runID: runID, channel: "system", clusterID: "SPEAKER_0", distance: 1),
            ],
            persons: [ada, grace]
        )
        state = try engine.confirm(
            clusterID: "SPEAKER_0", channel: "mic", runID: runID,
            as: ada.id, in: state
        ).state
        state = try engine.confirm(
            clusterID: "SPEAKER_0", channel: "system", runID: runID,
            as: grace.id, in: state
        ).state

        #expect(person(ada.id, in: state)?.prototypes.map(\.channel) == ["mic"])
        #expect(person(grace.id, in: state)?.prototypes.map(\.channel) == ["system"])
    }

    @Test("Invariant 12: superseded-run confirmations are stale while meeting participants survive re-diarization")
    func staleRunAndMeetingParticipants() throws {
        let meetingID = MeetingID()
        let oldRunID = RunID()
        let currentRunID = RunID()
        let ada = Person(displayName: "Ada")
        let currentCluster = makeCluster(
            meetingID: meetingID,
            runID: currentRunID,
            clusterID: "SPEAKER_0"
        )
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: currentRunID,
            clusters: [currentCluster],
            persons: [ada],
            participantIDs: [ada.id]
        )

        let stale = try engine.confirm(
            clusterID: "SPEAKER_0",
            channel: "system",
            runID: oldRunID,
            as: ada.id,
            in: state
        )

        #expect(stale.status == .stale)
        #expect(stale.state.persons == state.persons)
        #expect(stale.state.participantIDs == [ada.id])
    }

    @Test("Invariant 13: self clusters are never suggested or renamed")
    func selfIsNeverRenamed() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let ada = makeKnownPerson(
            name: "Ada",
            prototypeDistances: [0, 0],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        let selfCluster = makeCluster(
            meetingID: meetingID,
            runID: runID,
            clusterID: "self",
            isSelf: true
        )
        let suggestion = try #require(engine.suggestions(for: [selfCluster], people: [ada]).first)
        #expect(suggestion.status == .none)
        #expect(suggestion.candidates.isEmpty)
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            clusters: [selfCluster],
            persons: [ada]
        )

        #expect(throws: IdentityReviewError.self) {
            _ = try engine.confirm(
                clusterID: "self", channel: "system", runID: runID,
                as: ada.id, in: state
            )
        }
    }

    @Test("prototypes without a known meeting do not count toward the meeting gate")
    func prototypesWithoutMeetingDoNotCount() throws {
        // Altimportierte Prototypen können auf gelöschte Alt-Meetings zeigen
        // (meetingID nil). Sie liefern weiterhin Distanz-Evidenz, dürfen aber
        // das Zwei-Meeting-Gate nicht erfüllen: sonst würde eine automatische
        // Bestätigung auf Belegen fußen, deren Herkunft nicht mehr existiert.
        let personID = PersonID()
        let person = Person(
            id: personID,
            displayName: "Ada",
            prototypes: [
                makePrototype(personID: personID, meetingID: nil, runID: nil, distance: 0),
                makePrototype(personID: personID, meetingID: nil, runID: nil, distance: 0),
            ]
        )

        let result = try #require(engine.suggestions(
            for: [makeCluster(meetingID: MeetingID(), runID: RunID(), clusterID: "A")],
            people: [person]
        ).first)

        #expect(result.candidates.first?.confirmedMeetingCount == 0)
        #expect(result.status == .possible)
    }
}
