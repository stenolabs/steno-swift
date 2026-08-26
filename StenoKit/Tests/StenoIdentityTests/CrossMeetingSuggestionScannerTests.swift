import Foundation
import StenoDomain
import Testing
@testable import StenoIdentity

/// Cross-meeting suggestion visibility. The gates stay in the unchanged
/// suggestion engine - these tests pin what the scanner surfaces on top of
/// them, and how a dismissal suppresses.
@Suite("Cross-meeting suggestion visibility")
struct CrossMeetingSuggestionScannerTests {

    private let engine = SpeakerSuggestionEngine()

    private func makeUnconfirmedCluster(
        clusterID: String,
        meetingID: MeetingID = MeetingID(),
        runID: RunID = RunID(),
        distance: Float,
        multiple: Bool = false,
        isSelf: Bool = false
    ) -> IdentityCluster {
        makeCluster(
            meetingID: meetingID,
            runID: runID,
            clusterID: clusterID,
            distance: distance,
            multiple: multiple,
            isSelf: isSelf
        )
    }

    private func scan(
        clusters: [IdentityCluster],
        people: [Person]
    ) -> [CrossMeetingSuggestion] {
        CrossMeetingSuggestionScanner.suggestions(
            clustersByMeeting: [CrossMeetingSuggestionScanner.MeetingClusters(
                meetingID: clusters.first?.meetingID ?? MeetingID(),
                clusters: clusters
            )],
            people: people,
            engine: engine
        )
    }

    @Test("an unconfirmed match inside the gate is surfaced per person")
    func surfacesPossibleMatch() throws {
        let person = makeKnownPerson(name: "Ada", prototypeDistances: [0])
        let meetingID = MeetingID()
        let runID = RunID()
        let cluster = makeUnconfirmedCluster(
            clusterID: "A",
            meetingID: meetingID,
            runID: runID,
            distance: 0.2
        )

        let suggestions = scan(clusters: [cluster], people: [person])

        #expect(suggestions.count == 1)
        let suggestion = try #require(suggestions.first)
        #expect(suggestion.personID == person.id)
        #expect(suggestion.meetingID == meetingID)
        #expect(suggestion.runID == runID)
        // The scanner reports raw cosine distance against the stored
        // prototype embedding - exactly what the documented gates rate. The
        // fixture reconstructs that embedding from the nominal 0.2, which
        // survives the round-trip only within float precision.
        #expect(abs(suggestion.distance - 0.2) < 1e-6)
        #expect(suggestion.cluster.clusterID == "A")
    }

    @Test("a confident-but-unreviewed match is surfaced as well")
    func surfacesConfidentUnreviewedMatch() throws {
        // Two distinct prototype meetings clear the engine's cross-session
        // gate, so the raw suggestion status is .confirmed - yet no human has
        // seen this new cluster, which is exactly who this list is for.
        let person = makeKnownPerson(
            name: "Ada",
            prototypeDistances: [0, 0],
            meetingIDs: [MeetingID(), MeetingID()]
        )
        let cluster = makeUnconfirmedCluster(clusterID: "A", distance: 0.2)

        let before = engine.suggestions(for: [cluster], people: [person])
        #expect(before.first?.status == .confirmed)

        #expect(scan(clusters: [cluster], people: [person]).count == 1)
    }

    @Test("the engine's own gates are untouched: beyond 0.40 nothing surfaces")
    func distantClustersStayHidden() {
        let person = makeKnownPerson(name: "Ada", prototypeDistances: [0])
        let cluster = makeUnconfirmedCluster(clusterID: "A", distance: 0.5)

        #expect(scan(clusters: [cluster], people: [person]).isEmpty)
    }

    @Test("clusters a human already assigned are not open questions")
    func confirmedClustersAreFiltered() {
        let person = makeKnownPerson(name: "Ada", prototypeDistances: [0])
        let other = Person(displayName: "Blake")
        var cluster = makeUnconfirmedCluster(clusterID: "A", distance: 0.2)
        cluster.reviewState = .confirmed(other.id)

        #expect(scan(clusters: [cluster], people: [person]).isEmpty)

        // A stale assignment belongs to a superseded run; it is not a live
        // confirmation of the current evidence either way, so it stays hidden.
        cluster.reviewState = .stale(other.id)
        #expect(scan(clusters: [cluster], people: [person]).isEmpty)
    }

    @Test("self and mixed clusters never surface")
    func selfAndMixedClustersAreFiltered() {
        let person = makeKnownPerson(name: "Ada", prototypeDistances: [0])
        let selfCluster = makeUnconfirmedCluster(clusterID: "S", distance: 0.2, isSelf: true)
        let mixed = makeUnconfirmedCluster(clusterID: "M", distance: 0.2, multiple: true)

        #expect(scan(clusters: [selfCluster, mixed], people: [person]).isEmpty)
    }

    @Test("a dismissal stores an active hard negative with full pair provenance")
    func dismissalCarriesPairProvenance() throws {
        let person = makeKnownPerson(name: "Ada", prototypeDistances: [0])
        let meetingID = MeetingID()
        let runID = RunID()
        let cluster = makeUnconfirmedCluster(
            clusterID: "A",
            meetingID: meetingID,
            runID: runID,
            distance: 0.2
        )

        let first = try #require(scan(clusters: [cluster], people: [person]).first)
        let negative = CrossMeetingSuggestionScanner.dismissalNegative(for: first)

        #expect(negative.personID == person.id)
        #expect(negative.meetingID == meetingID)
        #expect(negative.runID == runID)
        #expect(negative.channel == cluster.channel)
        #expect(negative.clusterID == "A")
        #expect(negative.isActive)

        // The negative is findable - and reversible - in the voice profile by
        // exactly this provenance.
        var dismissed = person
        dismissed.hardNegatives.append(negative)
        #expect(CrossMeetingSuggestionScanner.isDismissed(suggestion: first, person: dismissed))
        #expect(scan(clusters: [cluster], people: [dismissed]).isEmpty)
    }

    @Test("excluding the dismissal negative reverses the suppression")
    func excludingTheNegativeReversesTheSuppression() throws {
        let person = makeKnownPerson(name: "Ada", prototypeDistances: [0])
        let cluster = makeUnconfirmedCluster(clusterID: "A", distance: 0.2)

        let first = try #require(scan(clusters: [cluster], people: [person]).first)
        var reversed = person
        var negative = CrossMeetingSuggestionScanner.dismissalNegative(for: first)
        negative.excludedAt = Date()
        reversed.hardNegatives.append(negative)

        // isActive filtering is a repo non-negotiable: a read path that kept
        // suppressing an excluded negative would contradict the profile view's
        // write path.
        #expect(!CrossMeetingSuggestionScanner.isDismissed(suggestion: first, person: reversed))
        #expect(scan(clusters: [cluster], people: [reversed]).count == 1)
    }
}
