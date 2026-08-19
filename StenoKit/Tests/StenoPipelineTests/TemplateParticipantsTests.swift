import Foundation
import StenoDomain
import StenoIdentity
import Testing
@testable import StenoPipeline

@Suite("Template participants")
struct TemplateParticipantsTests {
    @Test("participants are ordered by word contribution, names resolved")
    func orderedByContribution() {
        let runID = RunID()
        let ada = Person(displayName: "Ada Lovelace")
        let grace = Person(displayName: "Grace Hopper")
        let review = makeReview(
            runID: runID,
            clusters: [
                cluster(runID: runID, id: "A", state: .confirmed(ada.id)),
                cluster(runID: runID, id: "B", state: .confirmed(grace.id)),
            ],
            persons: [ada, grace]
        )
        let revision = makeRevision(turns: [
            (.cluster(runID: runID, clusterID: "A"), "Kurzer Beitrag"),
            (.cluster(runID: runID, clusterID: "B"), "Ein deutlich längerer Beitrag mit vielen Wörtern"),
        ])

        let names = TemplateParticipants.list(revision: revision, review: review)

        #expect(names == ["Grace Hopper", "Ada Lovelace"])
    }

    @Test("generic and multiple clusters and channel labels are excluded")
    func hotMicAndChannelsExcluded() {
        let runID = RunID()
        let ada = Person(displayName: "Ada Lovelace")
        let review = makeReview(
            runID: runID,
            clusters: [
                cluster(runID: runID, id: "A", state: .confirmed(ada.id)),
                cluster(runID: runID, id: "HOT", state: .generic),
                cluster(runID: runID, id: "MIX", state: .multiple),
            ],
            persons: [ada]
        )
        let revision = makeRevision(turns: [
            (.cluster(runID: runID, clusterID: "A"), "Inhaltlicher Beitrag"),
            (.cluster(runID: runID, clusterID: "HOT"), "nein nein nein nein"),
            (.cluster(runID: runID, clusterID: "MIX"), "Durcheinander"),
            (.channel("Andere"), "Kanalrest ohne Person"),
        ])

        let names = TemplateParticipants.list(revision: revision, review: review)

        #expect(names == ["Ada Lovelace"])
    }

    @Test("same person from several clusters is counted once with summed words")
    func manyToOneIsSummed() {
        let runID = RunID()
        let ada = Person(displayName: "Ada Lovelace")
        let grace = Person(displayName: "Grace Hopper")
        let review = makeReview(
            runID: runID,
            clusters: [
                cluster(runID: runID, id: "A1", state: .confirmed(ada.id)),
                cluster(runID: runID, id: "A2", state: .confirmed(ada.id)),
                cluster(runID: runID, id: "B", state: .confirmed(grace.id)),
            ],
            persons: [ada, grace]
        )
        let revision = makeRevision(turns: [
            (.cluster(runID: runID, clusterID: "B"), "Eins zwei drei vier"),
            (.cluster(runID: runID, clusterID: "A1"), "Eins zwei drei"),
            (.cluster(runID: runID, clusterID: "A2"), "vier fünf sechs"),
        ])

        let names = TemplateParticipants.list(revision: revision, review: review)

        #expect(names == ["Ada Lovelace", "Grace Hopper"])
    }

    @Test("unreviewed clusters appear as generic labels numbered by appearance")
    func unreviewedGetsPlaceholder() {
        let runID = RunID()
        let ada = Person(displayName: "Ada Lovelace")
        let review = makeReview(
            runID: runID,
            clusters: [
                cluster(runID: runID, id: "A", state: .confirmed(ada.id)),
                cluster(runID: runID, id: "U1", state: .unreviewed),
                cluster(runID: runID, id: "U2", state: .unreviewed),
            ],
            persons: [ada]
        )
        let revision = makeRevision(turns: [
            (.cluster(runID: runID, clusterID: "U1"), "Kurz"),
            (.cluster(runID: runID, clusterID: "A"), "Ein deutlich längerer inhaltlicher Beitrag mit den meisten Wörtern von allen"),
            (.cluster(runID: runID, clusterID: "U2"), "Etwas mehr Text als der erste"),
        ])

        let names = TemplateParticipants.list(revision: revision, review: review)

        // Nummerierung nach erstem Auftreten, Reihenfolge nach Beitragsmenge.
        #expect(names == ["Ada Lovelace", "Speaker 2", "Speaker 1"])
    }

    @Test("same cluster ID across channels keeps participants separate")
    func sameClusterIDAcrossChannelsKeepsParticipantsSeparate() {
        let runID = RunID()
        let review = makeReview(
            runID: runID,
            clusters: [
                cluster(
                    runID: runID,
                    id: "SPEAKER_0",
                    channel: MediaAsset.Kind.micTrack.rawValue,
                    state: .unreviewed
                ),
                cluster(
                    runID: runID,
                    id: "SPEAKER_0",
                    channel: MediaAsset.Kind.systemTrack.rawValue,
                    state: .unreviewed
                ),
            ],
            persons: []
        )
        let revision = makeRevision(turns: [
            (.cluster(runID: runID, clusterID: "mic/SPEAKER_0"), "Mikrofonbeitrag"),
            (.cluster(runID: runID, clusterID: "system/SPEAKER_0"), "Systembeitrag"),
        ])

        let names = TemplateParticipants.list(revision: revision, review: review)

        #expect(names == ["Speaker 1", "Speaker 2"])
    }

    @Test("manually added attendees follow the speakers and are never doubled")
    func additionalParticipantsAppendedOnce() {
        let runID = RunID()
        let ada = Person(displayName: "Ada Lovelace")
        let review = makeReview(
            runID: runID,
            clusters: [cluster(runID: runID, id: "A", state: .confirmed(ada.id))],
            persons: [ada]
        )
        let revision = makeRevision(turns: [
            (.cluster(runID: runID, clusterID: "A"), "Ein inhaltlicher Beitrag"),
        ])

        let names = TemplateParticipants.list(
            revision: revision,
            review: review,
            // "Ada Lovelace" hat gesprochen und darf nicht doppelt erscheinen.
            additional: ["Grace Hopper", "Ada Lovelace"]
        )

        #expect(names == ["Ada Lovelace", "Grace Hopper"])
    }

    // MARK: - Hilfen

    private func makeReview(
        runID: RunID,
        clusters: [IdentityCluster],
        resolutions: [IdentityClusterResolution] = [],
        persons: [Person]
    ) -> MeetingReviewData {
        MeetingReviewData(
            runID: runID,
            clusters: clusters,
            suggestions: [],
            resolutions: resolutions,
            persons: persons
        )
    }

    private func cluster(
        runID: RunID,
        id: String,
        channel: String = "system",
        state: IdentityCluster.ReviewState
    ) -> IdentityCluster {
        IdentityCluster(
            meetingID: MeetingID(),
            runID: runID,
            channel: channel,
            clusterID: id,
            recordingType: .unknown,
            embedding: [],
            speechDurationSeconds: 1,
            segmentCount: 1,
            reviewState: state
        )
    }

    @Test("an organization is carried into the list, an e-mail never is")
    func organizationTravelsButEmailDoesNot() {
        let runID = RunID()
        let ada = Person(
            displayName: "Ada Lovelace",
            email: "ada@example.org",
            organization: "Example GmbH"
        )
        let review = makeReview(
            runID: runID,
            clusters: [cluster(runID: runID, id: "A", state: .confirmed(ada.id))],
            persons: [ada]
        )
        let revision = makeRevision(turns: [
            (.cluster(runID: runID, clusterID: "A"), "Ein inhaltlicher Beitrag"),
        ])

        let names = TemplateParticipants.list(revision: revision, review: review)

        // Die Firma hilft dem Modell, sie richtig zu schreiben; die Adresse
        // ist reines Ordnungsmerkmal und hat im Prompt nichts verloren.
        #expect(names == ["Ada Lovelace (Example GmbH)"])
        #expect(!names.contains { $0.contains("@") })
    }

    @Test("e-mail addresses never reach the participant list a model sees")
    func emailStaysOutOfTheParticipantList() {
        let runID = RunID()
        let ada = Person(displayName: "Ada Lovelace", email: "ada@example.org")
        let review = makeReview(
            runID: runID,
            clusters: [cluster(runID: runID, id: "A", state: .confirmed(ada.id))],
            persons: [ada]
        )
        let revision = makeRevision(turns: [
            (.cluster(runID: runID, clusterID: "A"), "Ein inhaltlicher Beitrag"),
        ])

        let names = TemplateParticipants.list(
            revision: revision,
            review: review,
            additional: ["Grace Hopper"]
        )

        #expect(names == ["Ada Lovelace", "Grace Hopper"])
        #expect(!names.contains { $0.contains("@") })
    }

    private func makeRevision(
        turns: [(SpeakerReference?, String)]
    ) -> TranscriptRevision {
        TranscriptRevision(
            meetingID: MeetingID(),
            origin: .liveProvisional,
            turns: turns.enumerated().map { index, turn in
                TranscriptTurn(
                    speaker: turn.0,
                    start: TimeInterval(index),
                    end: TimeInterval(index + 1),
                    segments: [
                        TranscriptSegment(
                            text: turn.1,
                            start: TimeInterval(index),
                            end: TimeInterval(index + 1),
                            words: []
                        ),
                    ]
                )
            }
        )
    }
}
