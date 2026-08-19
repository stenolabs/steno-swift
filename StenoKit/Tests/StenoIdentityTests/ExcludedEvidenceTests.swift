import Foundation
import StenoDomain
import Testing
@testable import StenoIdentity

/// Ausgenommene Evidenz ist der einzige Weg, eine falsche Stimmprobe oder ein
/// falsches Negativ zu korrigieren, ohne Evidenz zu zerstoeren. Das traegt nur,
/// wenn die Vorschlags-Engine sie auch tatsaechlich uebergeht - und wenn eine
/// menschliche Ausnahme einen Neuaufbau der abgeleiteten Negatives ueberlebt.
@Suite("Excluded voice evidence")
struct ExcludedEvidenceTests {
    private let engine = SpeakerSuggestionEngine()

    @Test("an excluded prototype produces no candidate at all")
    func excludedPrototypeIsNotACandidate() throws {
        var person = makeKnownPerson(name: "Ada", prototypeDistances: [0, 0])
        let cluster = makeCluster(
            meetingID: MeetingID(),
            runID: RunID(),
            clusterID: "A"
        )

        let before = engine.suggestions(for: [cluster], people: [person])
        #expect(before.first?.status == .confirmed)

        for index in person.prototypes.indices {
            person.prototypes[index].excludedAt = Date()
        }
        let after = engine.suggestions(for: [cluster], people: [person])

        #expect(after.first?.status == ClusterSuggestion.Status.none)
        #expect(after.first?.candidates.isEmpty == true)
        #expect(after.first?.reasons == ["no usable person evidence"])
    }

    @Test("excluding one of two prototypes leaves the person, and drops its meeting")
    func excludingOnePrototypeShrinksTheEvidence() throws {
        var person = makeKnownPerson(name: "Ada", prototypeDistances: [0, 0])
        let cluster = makeCluster(
            meetingID: MeetingID(),
            runID: RunID(),
            clusterID: "A"
        )

        person.prototypes[1].excludedAt = Date()
        let suggestion = try #require(
            engine.suggestions(for: [cluster], people: [person]).first
        )

        // Die Person bleibt Kandidatin, verliert aber ein bestaetigtes Meeting
        // und faellt damit unter das Zwei-Meeting-Gate: aus "confirmed" wird
        // "possible" statt einer stillschweigend weiterlaufenden Bestaetigung.
        #expect(suggestion.candidates.count == 1)
        #expect(suggestion.candidates.first?.confirmedMeetingCount == 1)
        #expect(suggestion.status == .possible)
    }

    @Test("an excluded hard negative stops blocking recognition")
    func excludedNegativeNoLongerBlocks() throws {
        var person = makeKnownPerson(name: "Ada", prototypeDistances: [0, 0])
        let cluster = makeCluster(
            meetingID: MeetingID(),
            runID: RunID(),
            clusterID: "A"
        )
        person.hardNegatives = [HardNegative(
            personID: person.id,
            embedding: embedding(atCosineDistance: 0),
            recordingType: .remote,
            channel: "system",
            meetingID: MeetingID(),
            runID: RunID(),
            clusterID: "N",
            speechDurationSeconds: 24,
            segmentCount: 4,
            source: .userConfirmed
        )]

        let blocked = try #require(
            engine.suggestions(for: [cluster], people: [person]).first
        )
        #expect(blocked.status == .none)
        #expect(blocked.candidates.first?.hardNegativeConflict == true)

        person.hardNegatives[0].excludedAt = Date()
        let released = try #require(
            engine.suggestions(for: [cluster], people: [person]).first
        )

        #expect(released.status == .confirmed)
        #expect(released.candidates.first?.hardNegativeConflict == false)
        #expect(released.candidates.first?.negativeDistance == nil)
    }

    @Test("rebuilding derived negatives keeps a human exclusion")
    func rebuildPreservesExclusion() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let ada = Person(displayName: "Ada")
        let grace = Person(displayName: "Grace")
        let clusterA = makeCluster(
            meetingID: meetingID,
            runID: runID,
            clusterID: "A",
            distance: 0
        )
        let clusterB = makeCluster(
            meetingID: meetingID,
            runID: runID,
            clusterID: "B",
            distance: 0.6
        )
        let clusterC = makeCluster(
            meetingID: meetingID,
            runID: runID,
            clusterID: "C",
            distance: 0.9
        )
        var state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            clusters: [clusterA, clusterB, clusterC],
            persons: [ada, grace]
        )

        state = try engine.confirm(
            clusterID: "A",
            channel: "system",
            runID: runID,
            as: ada.id,
            in: state
        ).state
        state = try engine.confirm(
            clusterID: "B",
            channel: "system",
            runID: runID,
            as: grace.id,
            in: state
        ).state

        let adaIndex = try #require(state.persons.firstIndex { $0.id == ada.id })
        let negative = try #require(state.persons[adaIndex].hardNegatives.first)
        #expect(negative.clusterID == "B")
        state.persons[adaIndex].hardNegatives[0].excludedAt = Date(
            timeIntervalSince1970: 1
        )

        // Jede weitere Zuordnung in demselben Kanal loest den Neuaufbau aus.
        // Vor dieser Vorkehrung war die Ausnahme danach weg - ein wieder
        // scharf gestelltes Negativ, ohne eine Spur im spaeteren Verhalten.
        let rebuilt = try engine.markMultiple(
            clusterID: "C",
            channel: "system",
            runID: runID,
            in: state
        ).state

        let adaAfter = try #require(rebuilt.persons.first { $0.id == ada.id })
        #expect(adaAfter.hardNegatives.count == 1)
        #expect(adaAfter.hardNegatives[0].clusterID == "B")
        #expect(adaAfter.hardNegatives[0].isActive == false)
    }
}
