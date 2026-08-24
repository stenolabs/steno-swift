import Foundation
import StenoDomain
import Testing
@testable import StenoIdentity

@Suite("Resetting a speaker assignment")
struct ResetToGenericTests {
    private let engine = SpeakerSuggestionEngine()

    @Test("a reset excludes the evidence instead of deleting it")
    func resetExcludesRatherThanDeletes() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        var ada = Person(displayName: "Ada")
        ada.prototypes = [makePrototype(
            personID: ada.id,
            meetingID: meetingID,
            runID: runID,
            clusterID: "A"
        )]
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [makeCluster(meetingID: meetingID, runID: runID, clusterID: "A")],
            persons: [ada],
            participantIDs: [ada.id]
        )

        let result = try engine.resetToGeneric(
            clusterID: "A",
            channel: "system",
            runID: runID,
            in: state
        )

        let adaAfter = try #require(result.state.persons.first { $0.id == ada.id })
        // Der Eintrag bleibt bestehen und traegt ein Ausschlussdatum. Wer ihn
        // entfernte, haette den Widerruf unsichtbar gemacht.
        #expect(adaAfter.prototypes.count == 1)
        #expect(adaAfter.prototypes[0].excludedAt != nil)
        #expect(adaAfter.prototypes.allSatisfy { !$0.isActive })
        #expect(result.state.clusters[0].reviewState == .generic)
    }

    @Test("a reset also releases the evidence of merged fragments")
    func resetCoversMergedFragments() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        var ada = Person(displayName: "Ada")
        ada.prototypes = [
            makePrototype(
                personID: ada.id,
                meetingID: meetingID,
                runID: runID,
                clusterID: "fragment-A"
            ),
            makePrototype(
                personID: ada.id,
                meetingID: MeetingID(),
                runID: RunID(),
                clusterID: "other-meeting"
            ),
        ]
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [makeCluster(
                meetingID: meetingID,
                runID: runID,
                clusterID: "merged",
                mergedFrom: ["fragment-A"]
            )],
            persons: [ada],
            participantIDs: [ada.id]
        )

        // Der Cluster wird ueber den Namen seines Fragments angesprochen.
        let result = try engine.resetToGeneric(
            clusterID: "fragment-A",
            channel: "system",
            runID: runID,
            in: state
        )

        let adaAfter = try #require(result.state.persons.first { $0.id == ada.id })
        let byCluster = Dictionary(
            uniqueKeysWithValues: adaAfter.prototypes.map { ($0.clusterID, $0) }
        )
        #expect(byCluster["fragment-A"]?.isActive == false)
        // Evidenz aus einem anderen Meeting geht das hier nichts an.
        #expect(byCluster["other-meeting"]?.isActive == true)
    }

    @Test("a reset drops the participant when no other evidence remains")
    func resetReleasesTheParticipant() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        var ada = Person(displayName: "Ada")
        ada.prototypes = [makePrototype(
            personID: ada.id,
            meetingID: meetingID,
            runID: runID,
            clusterID: "A"
        )]
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [makeCluster(meetingID: meetingID, runID: runID, clusterID: "A")],
            persons: [ada],
            participantIDs: [ada.id]
        )

        let result = try engine.resetToGeneric(
            clusterID: "A",
            channel: "system",
            runID: runID,
            in: state
        )

        #expect(!result.state.participantIDs.contains(ada.id))
        #expect(result.reassignedFrom == [ada.id])
    }

    @Test("a reset against a superseded run changes nothing")
    func resetOnStaleRunIsRejected() throws {
        let meetingID = MeetingID()
        let currentRunID = RunID()
        let staleRunID = RunID()
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: currentRunID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [makeCluster(meetingID: meetingID, runID: currentRunID, clusterID: "A")],
            persons: []
        )

        let result = try engine.resetToGeneric(
            clusterID: "A",
            channel: "system",
            runID: staleRunID,
            in: state
        )

        #expect(result.status == .stale)
        #expect(result.state == state)
    }

    @Test("an alias claimed by two clusters is reported, never guessed")
    func ambiguousAliasIsReported() {
        let meetingID = MeetingID()
        let runID = RunID()
        // Beide Cluster beanspruchen "fragment-A" als Herkunft. Welcher
        // gemeint ist, laesst sich nicht entscheiden.
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [
                makeCluster(
                    meetingID: meetingID,
                    runID: runID,
                    clusterID: "merged-one",
                    mergedFrom: ["fragment-A"]
                ),
                makeCluster(
                    meetingID: meetingID,
                    runID: runID,
                    clusterID: "merged-two",
                    mergedFrom: ["fragment-A"]
                ),
            ],
            persons: []
        )

        #expect(throws: IdentityReviewError.ambiguousClusterAlias(
            channel: "system",
            clusterID: "fragment-A"
        )) {
            try engine.resetToGeneric(
                clusterID: "fragment-A",
                channel: "system",
                runID: runID,
                in: state
            )
        }
    }

    @Test("an unknown cluster is still reported as not found")
    func unknownClusterIsNotFound() {
        let meetingID = MeetingID()
        let runID = RunID()
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [makeCluster(meetingID: meetingID, runID: runID, clusterID: "A")],
            persons: []
        )

        #expect(throws: IdentityReviewError.clusterNotFound(
            channel: "system",
            clusterID: "B"
        )) {
            try engine.resetToGeneric(
                clusterID: "B",
                channel: "system",
                runID: runID,
                in: state
            )
        }
    }

    @Test("a human exclusion of a derived negative survives the reset")
    func resetKeepsExcludedNegatives() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        var ada = Person(displayName: "Ada")
        var grace = Person(displayName: "Grace")
        ada.prototypes = [makePrototype(
            personID: ada.id,
            meetingID: meetingID,
            runID: runID,
            clusterID: "A"
        )]
        grace.prototypes = [makePrototype(
            personID: grace.id,
            meetingID: meetingID,
            runID: runID,
            clusterID: "B"
        )]
        let clusterB = makeCluster(meetingID: meetingID, runID: runID, clusterID: "B")
        let excludedAt = Date(timeIntervalSince1970: 1000)
        // Ein Mensch hat dieses abgeleitete Negativ ausgenommen. Das ist eine
        // Aussage ueber die Stimme und darf den Neuaufbau ueberleben.
        ada.hardNegatives = [HardNegative(
            personID: ada.id,
            embedding: clusterB.embedding,
            recordingType: clusterB.recordingType,
            channel: clusterB.channel,
            meetingID: meetingID,
            runID: runID,
            clusterID: "B",
            speechDurationSeconds: clusterB.speechDurationSeconds,
            segmentCount: clusterB.segmentCount,
            source: .userConfirmed,
            excludedAt: excludedAt
        )]
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [
                makeCluster(meetingID: meetingID, runID: runID, clusterID: "A"),
                clusterB,
            ],
            persons: [ada, grace],
            participantIDs: [ada.id, grace.id]
        )

        let result = try engine.resetToGeneric(
            clusterID: "A",
            channel: "system",
            runID: runID,
            in: state
        )

        let adaAfter = try #require(result.state.persons.first { $0.id == ada.id })
        let rebuilt = try #require(adaAfter.hardNegatives.first { $0.clusterID == "B" })
        #expect(rebuilt.excludedAt == excludedAt)
        #expect(!rebuilt.isActive)
    }

    @Test("a reset also withdraws the multiple-speakers verdict")
    func resetWithdrawsTheMultipleVerdict() throws {
        let meetingID = MeetingID()
        let runID = RunID()
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [makeCluster(
                meetingID: meetingID,
                runID: runID,
                clusterID: "A",
                multiple: true
            )],
            persons: []
        )

        let result = try engine.resetToGeneric(
            clusterID: "A",
            channel: "system",
            runID: runID,
            in: state
        )

        // Zuruecksetzen nimmt jede Aussage zurueck, auch die, dass mehrere
        // Menschen im Cluster sind. Danach steht dort keine Behauptung mehr.
        #expect(result.state.clusters[0].containsMultipleSpeakers == false)
        #expect(result.state.clusters[0].reviewState == .generic)
    }

    @Test("a contradictory run is refused as a whole, not resolved in part")
    func contradictoryRunBlocksEvenUnambiguousAliases() {
        let meetingID = MeetingID()
        let runID = RunID()
        let state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: runID,
            voiceEvidenceMutationPolicy: .allowed,
            clusters: [
                makeCluster(meetingID: meetingID, runID: runID, clusterID: "clean"),
                makeCluster(
                    meetingID: meetingID,
                    runID: runID,
                    clusterID: "merged-one",
                    mergedFrom: ["shared"]
                ),
                makeCluster(
                    meetingID: meetingID,
                    runID: runID,
                    clusterID: "merged-two",
                    mergedFrom: ["shared"]
                ),
            ],
            persons: []
        )

        // "clean" waere fuer sich eindeutig. Der Lauf widerspricht sich aber an
        // anderer Stelle, und dann ist er als Ganzes nicht vertrauenswuerdig.
        #expect(throws: IdentityReviewError.ambiguousClusterAlias(
            channel: "system",
            clusterID: "shared"
        )) {
            try engine.resetToGeneric(
                clusterID: "clean",
                channel: "system",
                runID: runID,
                in: state
            )
        }
    }
}
