import Foundation
import StenoDomain
import StenoIdentity
import Testing
@testable import StenoPipeline

@Suite("Speaker presentation")
struct SpeakerPresentationTests {
    @Test func namespacedClustersKeepTheirChannelWithoutReview() {
        let mic = SpeakerPresentationResolver.presentation(
            for: .cluster(runID: RunID(), clusterID: "mic/SPEAKER_0"),
            review: nil
        )
        let system = SpeakerPresentationResolver.presentation(
            for: .cluster(runID: RunID(), clusterID: "system/SPEAKER_0"),
            review: nil
        )

        #expect(mic.label == "Speaker 1 (microphone)")
        #expect(system.label == "Speaker 1 (system)")
    }

    @Test func trackKindAliasesKeepTheirChannelWithoutReview() {
        let mic = SpeakerPresentationResolver.presentation(
            for: .cluster(runID: RunID(), clusterID: "micTrack/SPEAKER_0"),
            review: nil
        )
        let system = SpeakerPresentationResolver.presentation(
            for: .cluster(runID: RunID(), clusterID: "systemTrack/SPEAKER_0"),
            review: nil
        )

        #expect(mic.label == "Speaker 1 (microphone)")
        #expect(mic.channel == MediaAsset.Kind.micTrack.rawValue)
        #expect(system.label == "Speaker 1 (system)")
        #expect(system.channel == MediaAsset.Kind.systemTrack.rawValue)
    }

    @Test func mediaAssetNamespacesNeedExplicitChannelContext() {
        let runID = RunID()
        let micAssetID = MediaAssetID(
            rawValue: UUID(uuidString: "01981111-7111-8111-8111-111111111111")!
        )
        let systemAssetID = MediaAssetID(
            rawValue: UUID(uuidString: "01982222-7222-8222-8222-222222222222")!
        )
        let micReference = SpeakerReference.cluster(
            runID: runID,
            clusterID: "\(micAssetID)/SPEAKER_0"
        )
        let systemReference = SpeakerReference.cluster(
            runID: runID,
            clusterID: "\(systemAssetID)/SPEAKER_0"
        )

        let unknownMic = SpeakerPresentationResolver.presentation(
            for: micReference,
            review: nil
        )
        let unknownSystem = SpeakerPresentationResolver.presentation(
            for: systemReference,
            review: nil
        )

        #expect(unknownMic.label == "Speaker 1")
        #expect(unknownMic.channel == nil)
        #expect(unknownSystem.label == "Speaker 1")
        #expect(unknownSystem.channel == nil)

        let context = SpeakerPresentationContext(channelsByNamespace: [
            micAssetID.description: MediaAsset.Kind.micTrack.rawValue,
            systemAssetID.description: MediaAsset.Kind.systemTrack.rawValue,
        ])
        let mic = SpeakerPresentationResolver.presentation(
            for: micReference,
            review: nil,
            context: context
        )
        let system = SpeakerPresentationResolver.presentation(
            for: systemReference,
            review: nil,
            context: context
        )

        #expect(mic.label == "Speaker 1 (microphone)")
        #expect(mic.channel == MediaAsset.Kind.micTrack.rawValue)
        #expect(system.label == "Speaker 1 (system)")
        #expect(system.channel == MediaAsset.Kind.systemTrack.rawValue)
    }

    @Test func ambiguousBareClusterDoesNotBorrowAnotherChannelsIdentity() {
        let meetingID = MeetingID()
        let runID = RunID()
        let person = Person(displayName: "Grace")
        let mic = cluster(
            meetingID: meetingID,
            runID: runID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "SPEAKER_0",
            state: .confirmed(person.id)
        )
        let system = cluster(
            meetingID: meetingID,
            runID: runID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            clusterID: "SPEAKER_0"
        )
        let review = review(
            runID: runID,
            clusters: [mic, system],
            persons: [person]
        )

        let result = SpeakerPresentationResolver.presentation(
            for: .cluster(runID: review.runID, clusterID: "SPEAKER_0"),
            review: review
        )

        #expect(result.label == "Speaker 1")
        #expect(result.marker == nil)
        #expect(result.channel == nil)
    }

    @Test func publicConfirmedLookupsRejectAmbiguousBareCluster() {
        let meetingID = MeetingID()
        let runID = RunID()
        let person = Person(displayName: "Grace")
        let mic = cluster(
            meetingID: meetingID,
            runID: runID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "SPEAKER_0",
            state: .confirmed(person.id)
        )
        let system = cluster(
            meetingID: meetingID,
            runID: runID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            clusterID: "SPEAKER_0",
            state: .confirmed(person.id)
        )
        let review = review(
            runID: runID,
            clusters: [mic, system],
            persons: [person]
        )
        let reference = SpeakerReference.cluster(
            runID: runID,
            clusterID: "SPEAKER_0"
        )

        #expect(review.confirmedPerson(for: reference) == nil)
        #expect(review.confirmedName(for: reference) == nil)
    }

    @Test func confirmedPersonUsesPersonMarker() {
        let runID = RunID()
        let person = Person(displayName: "Grace")
        let reviewed = cluster(
            runID: runID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "SPEAKER_0",
            state: .confirmed(person.id)
        )
        let review = review(runID: runID, clusters: [reviewed], persons: [person])

        let result = SpeakerPresentationResolver.presentation(
            for: .cluster(runID: runID, clusterID: "mic/SPEAKER_0"),
            review: review
        )

        #expect(result.label == "Grace")
        #expect(result.marker == .person(person.id))
        #expect(result.channel == MediaAsset.Kind.micTrack.rawValue)
    }

    @Test func stalePersonKeepsQuestionMark() {
        let runID = RunID()
        let person = Person(displayName: "Grace")
        let reviewed = cluster(
            runID: runID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            clusterID: "SPEAKER_0",
            state: .stale(person.id)
        )
        let review = review(runID: runID, clusters: [reviewed], persons: [person])

        let result = SpeakerPresentationResolver.presentation(
            for: reviewed,
            review: review
        )

        #expect(result.label == "Grace?")
        #expect(result.marker == .person(person.id))
    }

    @Test func multiplePeopleHasNoMarker() {
        let runID = RunID()
        let reviewed = cluster(
            runID: runID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            clusterID: "SPEAKER_0",
            state: .multiple
        )
        let review = review(runID: runID, clusters: [reviewed])

        let result = SpeakerPresentationResolver.presentation(for: reviewed, review: review)

        #expect(result.label == "Multiple people")
        #expect(result.marker == nil)
    }

    @Test func confirmedSuggestionSaysProbably() {
        let runID = RunID()
        let reviewed = cluster(
            runID: runID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "SPEAKER_0"
        )
        let suggestion = ClusterSuggestion(
            meetingID: reviewed.meetingID,
            runID: runID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "SPEAKER_0",
            status: .confirmed,
            suggestedPersonID: PersonID(),
            suggestedName: "Grace"
        )
        let review = review(
            runID: runID,
            clusters: [reviewed],
            suggestions: [suggestion]
        )

        let result = SpeakerPresentationResolver.presentation(for: reviewed, review: review)

        #expect(result.label == "Probably Grace")
        #expect(result.marker == .unconfirmedRank(0))
    }

    @Test func otherRunStaysGeneric() {
        let currentRunID = RunID()
        let person = Person(displayName: "Grace")
        let reviewed = cluster(
            runID: currentRunID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "SPEAKER_0",
            state: .confirmed(person.id)
        )
        let review = review(runID: currentRunID, clusters: [reviewed], persons: [person])

        let result = SpeakerPresentationResolver.presentation(
            for: .cluster(runID: RunID(), clusterID: "mic/SPEAKER_0"),
            review: review
        )

        #expect(result.label == "Speaker 1 (microphone)")
        #expect(result.marker == nil)
    }

    @Test func mergeResolutionKeepsChannel() {
        let runID = RunID()
        let person = Person(displayName: "Grace")
        let micPrimary = cluster(
            runID: runID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "SPEAKER_0",
            state: .confirmed(person.id)
        )
        let systemPrimary = cluster(
            runID: runID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            clusterID: "SPEAKER_0"
        )
        let review = review(
            runID: runID,
            clusters: [micPrimary, systemPrimary],
            resolutions: [
                IdentityClusterResolution(
                    channel: MediaAsset.Kind.micTrack.rawValue,
                    sourceClusterID: "SPEAKER_1",
                    primaryClusterID: "SPEAKER_0"
                ),
                IdentityClusterResolution(
                    channel: MediaAsset.Kind.systemTrack.rawValue,
                    sourceClusterID: "SPEAKER_1",
                    primaryClusterID: "SPEAKER_0"
                ),
            ],
            persons: [person]
        )

        let mic = SpeakerPresentationResolver.presentation(
            for: .cluster(runID: runID, clusterID: "mic/SPEAKER_1"),
            review: review
        )
        let system = SpeakerPresentationResolver.presentation(
            for: .cluster(runID: runID, clusterID: "system/SPEAKER_1"),
            review: review
        )

        #expect(mic.label == "Grace")
        #expect(mic.marker == .person(person.id))
        #expect(system.label == "Speaker 1 (system)")
        #expect(system.marker == .unconfirmedRank(1))
    }

    @Test func unconfirmedRankIgnoresSelfAndMultiple() {
        let runID = RunID()
        let target = cluster(
            runID: runID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "SPEAKER_0",
            duration: 20
        )
        let selfCluster = cluster(
            runID: runID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "SPEAKER_1",
            duration: 60,
            isSelf: true
        )
        let multiple = cluster(
            runID: runID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            clusterID: "SPEAKER_2",
            duration: 40,
            state: .multiple
        )
        let shorter = cluster(
            runID: runID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            clusterID: "SPEAKER_3",
            duration: 10
        )
        let review = review(runID: runID, clusters: [target, selfCluster, multiple, shorter])

        let result = SpeakerPresentationResolver.presentation(for: target, review: review)

        #expect(result.marker == .unconfirmedRank(0))
    }

    @Test func importedTextKeepsSourceConfirmationSeparateFromLocalIdentity() {
        let confirmed = SpeakerPresentationResolver.presentation(
            for: .importedTextLabel(ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000060")!,
                text: "Ada",
                wasConfirmedAtSource: true
            )),
            review: nil
        )
        let unconfirmed = SpeakerPresentationResolver.presentation(
            for: .importedTextLabel(ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000061")!,
                text: "Ada",
                wasConfirmedAtSource: false
            )),
            review: nil
        )

        #expect(confirmed.label == "Ada")
        #expect(confirmed.marker == nil)
        #expect(
            confirmed.originCue
                == "Imported text label - not a locally confirmed identity"
        )
        #expect(unconfirmed.label == "Unknown speaker")
        #expect(unconfirmed.marker == nil)
        #expect(unconfirmed.originCue == confirmed.originCue)
    }

    @Test func mixedClusterNeverBecomesAConfirmedPersonOrParticipant() {
        let runID = RunID()
        let person = Person(displayName: "Grace")
        let mixed = cluster(
            runID: runID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "SPEAKER_0",
            state: .confirmed(person.id),
            containsMultipleSpeakers: true
        )
        let review = review(runID: runID, clusters: [mixed], persons: [person])
        let reference = SpeakerReference.cluster(
            runID: runID,
            clusterID: "mic/SPEAKER_0"
        )
        let revision = TranscriptRevision(
            meetingID: mixed.meetingID,
            origin: .liveProvisional,
            turns: [TranscriptTurn(
                speaker: reference,
                start: 0,
                end: 1,
                segments: [TranscriptSegment(
                    text: "Hallo",
                    start: 0,
                    end: 1,
                    words: []
                )]
            )]
        )

        #expect(review.confirmedPerson(for: reference) == nil)
        #expect(review.confirmedName(for: reference) == nil)
        #expect(TemplateParticipants.list(revision: revision, review: review).isEmpty)
    }

    private func review(
        runID: RunID,
        clusters: [IdentityCluster],
        suggestions: [ClusterSuggestion] = [],
        resolutions: [IdentityClusterResolution] = [],
        persons: [Person] = []
    ) -> MeetingReviewData {
        MeetingReviewData(
            runID: runID,
            clusters: clusters,
            suggestions: suggestions,
            resolutions: resolutions,
            persons: persons
        )
    }

    private func cluster(
        meetingID: MeetingID = MeetingID(),
        runID: RunID,
        channel: String,
        clusterID: String,
        duration: TimeInterval = 30,
        state: IdentityCluster.ReviewState = .unreviewed,
        isSelf: Bool = false,
        containsMultipleSpeakers: Bool = false
    ) -> IdentityCluster {
        IdentityCluster(
            meetingID: meetingID,
            runID: runID,
            channel: channel,
            clusterID: clusterID,
            recordingType: .unknown,
            embedding: [],
            speechDurationSeconds: duration,
            segmentCount: 1,
            containsMultipleSpeakers: containsMultipleSpeakers,
            reviewState: state,
            isSelf: isSelf
        )
    }
}
