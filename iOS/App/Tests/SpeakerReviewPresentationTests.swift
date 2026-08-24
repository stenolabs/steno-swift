import Foundation
import StenoDomain
import StenoIdentity
import StenoPipeline
import Testing
@testable import Steno

@Suite("Speaker review presentation")
struct SpeakerReviewPresentationTests {
    @Test
    func reviewErrorKeepsSectionVisibleWithoutReviewData() {
        #expect(SpeakerReviewPresentation.shouldShowSection(
            hasReview: false,
            error: "Could not reload"
        ))
        #expect(!SpeakerReviewPresentation.shouldShowSection(
            hasReview: false,
            error: nil
        ))
    }

    @Test
    func multipleClusterOnlyOffersReset() {
        let cluster = makeCluster(
            containsMultipleSpeakers: true,
            reviewState: .unreviewed
        )

        let actions = SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: nil
        )

        #expect(actions == [.resetToGeneric])
    }

    @Test
    func multipleReviewStateOnlyOffersReset() {
        let cluster = makeCluster(reviewState: .multiple)

        let actions = SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: nil
        )

        #expect(actions == [.resetToGeneric])
    }

    @Test
    func confirmedClusterCanBeReassignedOrReset() {
        let cluster = makeCluster(reviewState: .confirmed(PersonID()))

        let actions = SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: nil
        )

        #expect(actions.contains(.reassignPerson))
        #expect(actions.contains(.resetToGeneric))
        #expect(!actions.contains(.keepGeneric))
        #expect(!actions.contains(.assignPerson))
    }

    @Test
    func staleClusterUsesUnconfirmedActionsAndNeverReassigns() {
        let cluster = makeCluster(reviewState: .stale(PersonID()))

        let actions = SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: nil
        )

        #expect(actions.contains(.assignPerson))
        #expect(actions.contains(.createPerson))
        #expect(actions.contains(.markMultiple))
        #expect(actions.contains(.keepGeneric))
        #expect(!actions.contains(.reassignPerson))
        #expect(!actions.contains(.resetToGeneric))
    }

    @Test
    func possibleSuggestionIsVisibleButNotConfirmable() {
        let cluster = makeCluster(reviewState: .unreviewed)
        let suggestion = makeSuggestion(for: cluster, status: .possible)

        let actions = SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: suggestion
        )

        #expect(!actions.contains(.confirmSuggestion))
        #expect(actions.contains(.assignPerson))
        #expect(actions.contains(.keepGeneric))
        #expect(
            SpeakerReviewPresentation.suggestionLabel(suggestion).map(english)
                == "Maybe Ada"
        )
    }

    private func english(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }

    @Test
    func confirmedSuggestionCanBeConfirmed() {
        let cluster = makeCluster(reviewState: .unreviewed)
        let suggestion = makeSuggestion(for: cluster, status: .confirmed)
        let person = Person(
            id: suggestion.suggestedPersonID ?? PersonID(),
            displayName: "Ada"
        )

        let actions = SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: suggestion,
            persons: [person]
        )

        #expect(actions.contains(.confirmSuggestion))
    }

    @Test
    func confirmedSuggestionForUnknownPersonIsNotActionable() {
        let cluster = makeCluster(reviewState: .unreviewed)
        let suggestion = makeSuggestion(for: cluster, status: .confirmed)

        let actions = SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: suggestion,
            persons: [Person(displayName: "Someone else")]
        )

        #expect(!actions.contains(.confirmSuggestion))
    }

    @Test
    func selfClusterHasNoNamingActions() {
        let cluster = makeCluster(isSelf: true)
        let suggestion = makeSuggestion(for: cluster, status: .confirmed)

        let actions = SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: suggestion
        )

        #expect(actions.isEmpty)
    }

    @Test
    func genericClusterCanBeAssigned() {
        let cluster = makeCluster(reviewState: .generic)

        let actions = SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: nil
        )

        #expect(actions.contains(.assignPerson))
        #expect(actions.contains(.createPerson))
        #expect(actions.contains(.markMultiple))
        #expect(actions.contains(.keepGeneric))
    }

    @Test
    func resetActionMapsToControllerResetInsteadOfKeepGeneric() throws {
        let action = try #require(
            SpeakerReviewPresentation.controllerAction(
                for: .resetToGeneric,
                personID: nil,
                newPersonName: nil
            )
        )

        guard case .resetToGeneric = action else {
            Issue.record("Reset must call MeetingReviewController.resetToGeneric")
            return
        }
    }

    @Test
    func suggestionLookupIsScopedByMeetingRunChannelAndCluster() throws {
        let cluster = makeCluster(channel: "micTrack", clusterID: "A")
        let exact = makeSuggestion(for: cluster, status: .confirmed)
        let suggestions = [
            makeSuggestion(
                for: cluster,
                status: .confirmed,
                meetingID: MeetingID()
            ),
            makeSuggestion(
                for: cluster,
                status: .confirmed,
                runID: RunID()
            ),
            makeSuggestion(
                for: cluster,
                status: .confirmed,
                channel: "imported"
            ),
            makeSuggestion(
                for: cluster,
                status: .confirmed,
                clusterID: "B"
            ),
            exact,
        ]

        let result = SpeakerReviewPresentation.suggestion(
            for: cluster,
            in: suggestions,
            reviewRunID: cluster.runID
        )

        #expect(result == exact)
        #expect(
            SpeakerReviewPresentation.suggestion(
                for: cluster,
                in: [exact],
                reviewRunID: RunID()
            ) == nil
        )

        let normalizedCluster = makeCluster(channel: "micTrack", clusterID: "A")
        let alias = makeSuggestion(
            for: normalizedCluster,
            status: .confirmed,
            channel: "mic"
        )
        #expect(
            SpeakerReviewPresentation.suggestion(
                for: normalizedCluster,
                in: [alias],
                reviewRunID: normalizedCluster.runID
            ) == alias
        )
    }

    @Test("speaker evidence and additional attendance stay in separate sections")
    func participantSectionsKeepRolesSeparate() {
        let meetingID = MeetingID()
        let reviewRunID = RunID()
        let storedSpeaker = Person(displayName: "Berta")
        let overlappingSpeaker = Person(displayName: "Ada")
        let confirmedSpeaker = Person(displayName: "Clara")
        let additional = Person(displayName: "Dora")
        let meeting = Meeting(
            id: meetingID,
            title: "Review",
            status: .ready,
            participantIDs: [storedSpeaker.id, overlappingSpeaker.id],
            additionalParticipantIDs: [
                additional.id,
                overlappingSpeaker.id,
                additional.id,
            ]
        )
        let clusters = [
            makeCluster(
                meetingID: meetingID,
                runID: reviewRunID,
                reviewState: .confirmed(confirmedSpeaker.id)
            ),
        ]

        let sections = MeetingParticipantsPresentation.sections(
            meeting: meeting,
            persons: [
                storedSpeaker,
                overlappingSpeaker,
                confirmedSpeaker,
                additional,
            ],
            clusters: clusters,
            reviewRunID: reviewRunID
        )

        #expect(sections.speakers.map(\.personID) == [
            overlappingSpeaker.id,
            storedSpeaker.id,
            confirmedSpeaker.id,
        ])
        #expect(sections.speakers.allSatisfy { $0.role == .speaker })
        #expect(sections.additional.map(\.personID) == [additional.id])
        #expect(sections.additional.allSatisfy { $0.role == .additional })
    }

    @Test("stale, non-current, mixed, self, and unknown clusters never name speakers")
    func unsafeClustersDoNotCreateNamedSpeakers() {
        let meetingID = MeetingID()
        let reviewRunID = RunID()
        let stale = Person(displayName: "Stale")
        let nonCurrent = Person(displayName: "Old run")
        let mixed = Person(displayName: "Mixed")
        let ownVoice = Person(displayName: "Self")
        let wrongMeeting = Person(displayName: "Other meeting")
        let unknownID = PersonID()
        let clusters = [
            makeCluster(
                meetingID: meetingID,
                runID: reviewRunID,
                reviewState: .stale(stale.id)
            ),
            makeCluster(
                meetingID: meetingID,
                runID: RunID(),
                clusterID: "old",
                reviewState: .confirmed(nonCurrent.id)
            ),
            makeCluster(
                meetingID: meetingID,
                runID: reviewRunID,
                clusterID: "mixed",
                containsMultipleSpeakers: true,
                reviewState: .confirmed(mixed.id)
            ),
            makeCluster(
                meetingID: meetingID,
                runID: reviewRunID,
                clusterID: "multiple",
                reviewState: .multiple
            ),
            makeCluster(
                meetingID: meetingID,
                runID: reviewRunID,
                clusterID: "self",
                reviewState: .confirmed(ownVoice.id),
                isSelf: true
            ),
            makeCluster(
                meetingID: MeetingID(),
                runID: reviewRunID,
                clusterID: "other-meeting",
                reviewState: .confirmed(wrongMeeting.id)
            ),
            makeCluster(
                meetingID: meetingID,
                runID: reviewRunID,
                clusterID: "unknown",
                reviewState: .confirmed(unknownID)
            ),
        ]
        let meeting = Meeting(
            id: meetingID,
            title: "Review",
            status: .ready
        )

        let sections = MeetingParticipantsPresentation.sections(
            meeting: meeting,
            persons: [stale, nonCurrent, mixed, ownVoice, wrongMeeting],
            clusters: clusters,
            reviewRunID: reviewRunID
        )

        #expect(sections.speakers.isEmpty)
        #expect(sections.additional.isEmpty)
        #expect(sections.hasUnresolvedPeople)
    }

    @Test("same-name people remain distinct by ID and only additional rows remove")
    func equalNamesRemainDistinctAndRemovalFollowsRole() throws {
        let speaker = Person(displayName: "Alex")
        let additional = Person(displayName: "Alex")
        let meeting = Meeting(
            title: "Review",
            status: .ready,
            participantIDs: [speaker.id],
            additionalParticipantIDs: [additional.id]
        )

        let sections = MeetingParticipantsPresentation.sections(
            meeting: meeting,
            persons: [additional, speaker],
            clusters: [],
            reviewRunID: nil
        )

        let speakerRow = try #require(sections.speakers.first)
        let additionalRow = try #require(sections.additional.first)
        #expect(speakerRow.personID == speaker.id)
        #expect(additionalRow.personID == additional.id)
        #expect(speakerRow.name == additionalRow.name)
        #expect(!speakerRow.canRemove)
        #expect(additionalRow.canRemove)
    }

    @Test("missing stored person IDs remain visible as unresolved state")
    func unresolvedStoredPeopleRemainVisible() {
        let additional = Person(displayName: "Known additional")
        let meeting = Meeting(
            title: "Review",
            status: .ready,
            participantIDs: [PersonID()],
            additionalParticipantIDs: [additional.id, PersonID()]
        )

        let sections = MeetingParticipantsPresentation.sections(
            meeting: meeting,
            persons: [additional],
            clusters: [],
            reviewRunID: nil
        )

        #expect(sections.speakers.isEmpty)
        #expect(sections.additional.map(\.personID) == [additional.id])
        #expect(sections.hasUnresolvedPeople)
    }

    @Test
    func participantLoadingFollowsTheCurrentReloadKey() {
        #expect(
            MeetingParticipantsPresentation.isLoading(
                loadedKey: nil,
                currentKey: "meeting-a"
            )
        )
        #expect(
            MeetingParticipantsPresentation.isLoading(
                loadedKey: "meeting-a",
                currentKey: "meeting-b"
            )
        )
        #expect(
            !MeetingParticipantsPresentation.isLoading(
                loadedKey: "meeting-b",
                currentKey: "meeting-b"
            )
        )
    }

    @Test
    func participantLoadFailureStaysRetryableAndIsNotMarkedLoaded() {
        var state = MeetingParticipantsLoadState()

        let failedLoad = state.begin(key: "meeting-a")
        state.fail(
            failedLoad,
            currentKey: "meeting-a",
            message: "Could not read people"
        )

        #expect(state.loadedKey == nil)
        #expect(state.error(for: "meeting-a") == "Could not read people")
        #expect(!state.isLoading(currentKey: "meeting-a"))

        let failedTaskID = state.taskID(currentKey: "meeting-a")
        state.retry(key: "meeting-a")

        #expect(state.taskID(currentKey: "meeting-a") != failedTaskID)
        #expect(state.isLoading(currentKey: "meeting-a"))
        #expect(state.error(for: "meeting-a") == nil)

        let retryLoad = state.begin(key: "meeting-a")
        state.succeed(retryLoad, currentKey: "meeting-a")

        #expect(state.loadedKey == "meeting-a")
        #expect(!state.isLoading(currentKey: "meeting-a"))
    }

    @Test("same-publication reloads accept only the latest load generation")
    func participantLoadGenerationRejectsLateSameKeyCompletion() {
        var state = MeetingParticipantsLoadState()
        let oldLoad = state.begin(key: "publication-1")
        let newLoad = state.begin(key: "publication-1")

        let oldAccepted = state.succeed(
            oldLoad,
            currentKey: "publication-1"
        )
        let newAccepted = state.succeed(
            newLoad,
            currentKey: "publication-1"
        )

        #expect(!oldAccepted)
        #expect(newAccepted)
        #expect(state.loadedKey == "publication-1")
    }

    @Test("same-generation publications start distinct loads and only the newer wins")
    @MainActor
    func sameGenerationPublicationRacePublishesOnlyNewerPeople() async {
        let loader = ControlledParticipantPersonLoader()
        var state = MeetingParticipantsLoadState()
        var publishedPeople = "none"
        let meetingID = MeetingID()
        let oldPublication = MeetingReviewPublicationIdentity(
            meetingID: meetingID,
            generation: 7,
            publicationID: 1
        )
        let newPublication = MeetingReviewPublicationIdentity(
            meetingID: meetingID,
            generation: 7,
            publicationID: 2
        )
        #expect(oldPublication.generation == newPublication.generation)
        #expect(oldPublication != newPublication)

        let oldLoad = state.begin(key: oldPublication.loadKey)
        let oldTask = Task {
            await loader.load(id: 1)
        }
        await loader.waitUntilRequested(id: 1)

        let newLoad = state.begin(key: newPublication.loadKey)
        let newTask = Task {
            await loader.load(id: 2)
        }
        await loader.waitUntilRequested(id: 2)

        await loader.release(id: 2, value: "new people")
        let newPeople = await newTask.value
        if state.succeed(newLoad, currentKey: newPublication.loadKey) {
            publishedPeople = newPeople
        }

        await loader.release(id: 1, value: "old people")
        let oldPeople = await oldTask.value
        if state.succeed(oldLoad, currentKey: newPublication.loadKey) {
            publishedPeople = oldPeople
        }

        #expect(publishedPeople == "new people")
        #expect(state.loadedKey == newPublication.loadKey)
    }
}

private actor ControlledParticipantPersonLoader {
    private var requested: Set<Int> = []
    private var requestWaiters: [
        Int: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var resultWaiters: [
        Int: CheckedContinuation<String, Never>
    ] = [:]

    func load(id: Int) async -> String {
        requested.insert(id)
        requestWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            resultWaiters[id] = continuation
        }
    }

    func waitUntilRequested(id: Int) async {
        guard !requested.contains(id) else { return }
        await withCheckedContinuation { continuation in
            requestWaiters[id, default: []].append(continuation)
        }
    }

    func release(id: Int, value: String) {
        resultWaiters.removeValue(forKey: id)?.resume(returning: value)
    }
}

private func makeCluster(
    meetingID: MeetingID = MeetingID(),
    runID: RunID = RunID(),
    channel: String = "micTrack",
    clusterID: String = "A",
    containsMultipleSpeakers: Bool = false,
    reviewState: IdentityCluster.ReviewState = .unreviewed,
    isSelf: Bool = false
) -> IdentityCluster {
    IdentityCluster(
        meetingID: meetingID,
        runID: runID,
        channel: channel,
        clusterID: clusterID,
        recordingType: .inPerson,
        embedding: [1, 0],
        speechDurationSeconds: 30,
        segmentCount: 3,
        containsMultipleSpeakers: containsMultipleSpeakers,
        reviewState: reviewState,
        isSelf: isSelf
    )
}

private func makeSuggestion(
    for cluster: IdentityCluster,
    status: ClusterSuggestion.Status,
    meetingID: MeetingID? = nil,
    runID: RunID? = nil,
    channel: String? = nil,
    clusterID: String? = nil
) -> ClusterSuggestion {
    ClusterSuggestion(
        meetingID: meetingID ?? cluster.meetingID,
        runID: runID ?? cluster.runID,
        channel: channel ?? cluster.channel,
        clusterID: clusterID ?? cluster.clusterID,
        status: status,
        suggestedPersonID: PersonID(),
        suggestedName: "Ada"
    )
}
