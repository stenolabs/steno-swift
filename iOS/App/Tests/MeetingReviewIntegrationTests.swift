import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary
import StenoPipeline
import Testing
@testable import Steno

/// Exercises the iPad inspector's speaker review path against a real
/// library: the shared publication that keeps two windows coherent, and the
/// non-negotiable rules from `AGENTS.md` - a confirmation only ever comes
/// from `MeetingReviewController`, `resetToGeneric` exempts evidence instead
/// of naming it away, and an ambiguous cluster alias is refused rather than
/// guessed.
@Suite("iPad speaker review integration")
struct MeetingReviewIntegrationTests {
    @Test("identity review errors have complete user-facing messages")
    @MainActor
    func identityReviewErrorsHaveCompleteMessages() {
        let personID = PersonID()
        let cases: [(IdentityReviewError, LocalizedStringResource)] = [
            (
                .clusterNotFound(channel: "system", clusterID: "speaker-1"),
                "This speaker belongs to a superseded run. Reload the view."
            ),
            (
                .ambiguousClusterAlias(channel: "system", clusterID: "speaker-1"),
                "This speaker cannot be changed because its source is ambiguous."
            ),
            (.personNotFound(personID), "The selected person no longer exists."),
            (
                .mixedClusterCannotBeNamed,
                "This cluster contains multiple people and cannot be assigned to one person."
            ),
            (.selfClusterCannotBeNamed, "Your own microphone track is not named as a person."),
            (
                .noAssignmentToReassign,
                "There is no assignment here that can be changed."
            ),
            (
                .voiceEvidenceForbidden,
                "Demo meetings cannot create or change real voice profiles."
            ),
        ]

        for (error, expected) in cases {
            #expect(AppModel.reviewMessage(for: error) == String(localized: expected))
        }
    }

    @Test("demo voice-evidence refusal is presented without a raw error name")
    @MainActor
    func demoVoiceEvidenceRefusalHasClearPresentation() async throws {
        let fixture = try await ReviewFixture.make(
            reviewActionPerformer: { _, _, _, _, _ in
                throw MeetingReviewController.ReviewActionError
                    .demoMeetingCannotCreateVoiceEvidence
            }
        )
        defer { fixture.remove() }
        let review = try #require(
            await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)?.review
        )

        let result = await fixture.app.performReviewUpdate(
            .confirm(personID: fixture.person.id),
            on: fixture.cluster,
            data: review,
            meetingID: fixture.meetingID
        )

        #expect(result == nil)
        #expect(
            fixture.app.reviewError(for: fixture.meetingID)
                == String(localized: "Demo meetings cannot create or change real voice profiles.")
        )
    }

    @Test("confirming a speaker publishes the update for every window")
    @MainActor
    func confirmingASpeakerPublishesTheUpdate() async throws {
        let fixture = try await ReviewFixture.make()
        defer { fixture.remove() }
        let review = try #require(
            await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)?.review
        )
        let generationBeforeAction = fixture.app.reviewGeneration(for: fixture.meetingID)

        let updated = await fixture.app.performReviewUpdate(
            .confirm(personID: fixture.person.id),
            on: fixture.cluster,
            data: review,
            meetingID: fixture.meetingID
        )

        #expect(updated?.review.clusters.first(where: {
            $0.clusterID == fixture.cluster.clusterID
        })?.reviewState == .confirmed(fixture.person.id))
        #expect(updated?.meeting.participantIDs.contains(fixture.person.id) == true)

        let published = fixture.app.meetingReviewPublication(for: fixture.meetingID)
        #expect(published?.review?.clusters.first(where: {
            $0.clusterID == fixture.cluster.clusterID
        })?.reviewState == .confirmed(fixture.person.id))
        #expect(fixture.app.reviewGeneration(for: fixture.meetingID) > generationBeforeAction)
        #expect(fixture.app.reviewError(for: fixture.meetingID) == nil)
    }

    @Test("resetting a confirmed speaker exempts evidence instead of deleting it")
    @MainActor
    func resetToGenericExemptsRatherThanDeletes() async throws {
        let fixture = try await ReviewFixture.make()
        defer { fixture.remove() }
        let review = try #require(
            await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)?.review
        )
        let confirmed = try #require(await fixture.app.performReviewUpdate(
            .confirm(personID: fixture.person.id),
            on: fixture.cluster,
            data: review,
            meetingID: fixture.meetingID
        ))

        let reset = await fixture.app.performReviewUpdate(
            .resetToGeneric,
            on: fixture.cluster,
            data: confirmed.review,
            meetingID: fixture.meetingID
        )

        let resetCluster = reset?.review.clusters.first {
            $0.clusterID == fixture.cluster.clusterID
        }
        #expect(resetCluster?.reviewState == .generic)
        #expect(reset?.meeting.participantIDs.contains(fixture.person.id) == false)
        // Rule from AGENTS.md: voice evidence is exempted, never deleted -
        // the person and their prior confirmation stay discoverable, only
        // marked out of future automatic evidence.
        let persons = try await fixture.app.allPersons()
        #expect(persons.contains { $0.id == fixture.person.id })
    }

    @Test("an ambiguous cluster alias is refused, not guessed")
    @MainActor
    func ambiguousClusterAliasSurfacesARefusalMessage() async throws {
        let fixture = try await ReviewFixture.make(
            reviewActionPerformer: { _, cluster, _, _, _ in
                throw IdentityReviewError.ambiguousClusterAlias(
                    channel: cluster.channel,
                    clusterID: cluster.clusterID
                )
            }
        )
        defer { fixture.remove() }
        let review = try #require(
            await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)?.review
        )

        let result = await fixture.app.performReviewUpdate(
            .confirm(personID: fixture.person.id),
            on: fixture.cluster,
            data: review,
            meetingID: fixture.meetingID
        )

        #expect(result == nil)
        #expect(
            fixture.app.reviewError(for: fixture.meetingID)
                == String(localized: "This speaker cannot be changed because its source is ambiguous.")
        )
    }

    @Test("a stale review action reloads the current run instead of overwriting it")
    @MainActor
    func staleReviewActionReloadsCurrentRun() async throws {
        let fixture = try await ReviewFixture.make(
            reviewActionPerformer: { _, _, _, _, _ in
                throw MeetingReviewController.ReviewActionError.stale
            }
        )
        defer { fixture.remove() }
        let review = try #require(
            await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)?.review
        )

        let result = await fixture.app.performReviewUpdate(
            .confirm(personID: fixture.person.id),
            on: fixture.cluster,
            data: review,
            meetingID: fixture.meetingID
        )

        // No controller result to trust, so the real snapshot loader (not
        // overridden) reloads the still-unconfirmed cluster from disk rather
        // than the caller's now-superseded `review` value.
        #expect(result?.review.clusters.first {
            $0.clusterID == fixture.cluster.clusterID
        }?.reviewState == .unreviewed)
        #expect(
            fixture.app.reviewError(for: fixture.meetingID)
                == String(localized: "This review belongs to a superseded run. Check the refreshed inspector before trying again.")
        )
    }

    @Test("accepted loads get unique publication IDs within one review generation")
    @MainActor
    func sameGenerationLoadsHaveDistinctPublicationIdentities() async throws {
        let fixture = try await ReviewFixture.make()
        defer { fixture.remove() }

        _ = await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)
        let first = try #require(
            fixture.app.meetingReviewPublicationIdentity(for: fixture.meetingID)
        )
        _ = await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)
        let second = try #require(
            fixture.app.meetingReviewPublicationIdentity(for: fixture.meetingID)
        )

        #expect(first.meetingID == fixture.meetingID)
        #expect(second.meetingID == fixture.meetingID)
        #expect(first.generation == second.generation)
        #expect(first.publicationID != second.publicationID)
        #expect(first != second)
    }

    @Test("the sheet coordinator couples same-generation publications to distinct people loads")
    @MainActor
    func sheetCoordinatorRejectsLatePeopleFromRealOlderPublication() async throws {
        let loader = ControlledReviewPersonsLoader()
        let fixture = try await ReviewFixture.make(
            personsLoader: { _ in await loader.load() }
        )
        defer { fixture.remove() }
        var coordinator = MeetingParticipantEditorPersonLoadCoordinator()
        var publishedPeople: [Person] = []

        _ = await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)
        let firstIdentity = try #require(
            fixture.app.meetingReviewPublicationIdentity(for: fixture.meetingID)
        )
        let firstReloadTask = MeetingParticipantEditorReloadTask(
            meetingID: fixture.meetingID,
            publicationIdentity: firstIdentity
        )
        let firstRequest = coordinator.begin(firstReloadTask)
        let firstLoad = Task { @MainActor in
            try await fixture.app.allPersons()
        }
        await loader.waitUntilRequested(id: 1)

        _ = await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)
        let secondIdentity = try #require(
            fixture.app.meetingReviewPublicationIdentity(for: fixture.meetingID)
        )
        let secondReloadTask = MeetingParticipantEditorReloadTask(
            meetingID: fixture.meetingID,
            publicationIdentity: secondIdentity
        )
        #expect(firstIdentity.generation == secondIdentity.generation)
        #expect(firstIdentity != secondIdentity)
        #expect(firstReloadTask != secondReloadTask)

        let secondRequest = coordinator.begin(secondReloadTask)
        let secondLoad = Task { @MainActor in
            try await fixture.app.allPersons()
        }
        await loader.waitUntilRequested(id: 2)

        await loader.release(
            id: 2,
            persons: [Person(displayName: "People 2")]
        )
        let people2 = try await secondLoad.value
        if coordinator.accept(
            secondRequest,
            currentTask: secondReloadTask
        ) {
            publishedPeople = people2
        }

        await loader.release(
            id: 1,
            persons: [Person(displayName: "People 1")]
        )
        let people1 = try await firstLoad.value
        if coordinator.accept(
            firstRequest,
            currentTask: secondReloadTask
        ) {
            publishedPeople = people1
        }

        #expect(publishedPeople.map(\.displayName) == ["People 2"])
    }

    @Test("adding a known person changes only Additional and publishes one coherent pair")
    @MainActor
    func knownAdditionalParticipantPublishesCoherently() async throws {
        let fixture = try await ReviewFixture.make()
        defer { fixture.remove() }
        let identityStore = try IdentityStore(layout: fixture.library.layout)
        let evidenceBackedSpeaker = try await identityStore.createPerson(
            displayName: "Evidence Speaker"
        )
        _ = try await fixture.library.updateMeetingParticipants(
            fixture.meetingID,
            participantIDs: [evidenceBackedSpeaker.id]
        )
        _ = await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)
        let publicationIdentityBefore = try #require(
            fixture.app.meetingReviewPublicationIdentity(for: fixture.meetingID)
        )
        let before = try await fixture.library.loadMeeting(fixture.meetingID)
        let generationBefore = fixture.app.reviewGeneration(for: fixture.meetingID)

        let added = await fixture.app.addAdditionalParticipant(
            fixture.person.id,
            name: nil,
            meetingID: fixture.meetingID
        )

        let stored = try await fixture.library.loadMeeting(fixture.meetingID)
        let published = fixture.app.meetingReviewPublication(
            for: fixture.meetingID
        )
        let publicationIdentityAfter = try #require(
            fixture.app.meetingReviewPublicationIdentity(for: fixture.meetingID)
        )
        #expect(added)
        #expect(stored.participantIDs == before.participantIDs)
        #expect(stored.additionalParticipantIDs == [fixture.person.id])
        #expect(published?.meeting.participantIDs == stored.participantIDs)
        #expect(
            published?.meeting.additionalParticipantIDs
                == stored.additionalParticipantIDs
        )
        #expect(published?.review?.persons.contains(fixture.person) == true)
        #expect(
            fixture.app.reviewGeneration(for: fixture.meetingID)
                > generationBefore
        )
        #expect(
            publicationIdentityAfter.publicationID
                != publicationIdentityBefore.publicationID
        )
    }

    @Test("creating an additional person creates no voice evidence")
    @MainActor
    func newAdditionalParticipantHasNoVoiceEvidence() async throws {
        let fixture = try await ReviewFixture.make()
        defer { fixture.remove() }
        let before = try await fixture.library.loadMeeting(fixture.meetingID)

        let added = await fixture.app.addAdditionalParticipant(
            nil,
            name: "  Grace Hopper  ",
            meetingID: fixture.meetingID
        )

        let stored = try await fixture.library.loadMeeting(fixture.meetingID)
        let people = try await fixture.app.allPersons()
        let created = try #require(
            people.first { $0.displayName == "Grace Hopper" }
        )
        #expect(added)
        #expect(stored.participantIDs == before.participantIDs)
        #expect(stored.additionalParticipantIDs == [created.id])
        #expect(created.prototypes.isEmpty)
        #expect(created.hardNegatives.isEmpty)
    }

    @Test("only an additional participant can be removed")
    @MainActor
    func removalNeverChangesEvidenceBackedParticipants() async throws {
        let fixture = try await ReviewFixture.make()
        defer { fixture.remove() }
        let identityStore = try IdentityStore(layout: fixture.library.layout)
        let speaker = try await identityStore.createPerson(
            displayName: "Evidence Speaker"
        )
        _ = try await fixture.library.updateMeetingParticipants(
            fixture.meetingID,
            participantIDs: [speaker.id]
        )
        #expect(await fixture.app.addAdditionalParticipant(
            fixture.person.id,
            name: nil,
            meetingID: fixture.meetingID
        ))

        let removed = await fixture.app.removeAdditionalParticipant(
            fixture.person.id,
            meetingID: fixture.meetingID
        )
        let refusedSpeakerRemoval = await fixture.app.removeAdditionalParticipant(
            speaker.id,
            meetingID: fixture.meetingID
        )

        let stored = try await fixture.library.loadMeeting(fixture.meetingID)
        #expect(removed)
        #expect(!refusedSpeakerRemoval)
        #expect(stored.participantIDs == [speaker.id])
        #expect(stored.additionalParticipantIDs.isEmpty)
    }

    @Test("duplicate names stay visible as participant-editor errors")
    @MainActor
    func duplicatePersonNameIsVisible() async throws {
        let fixture = try await ReviewFixture.make()
        defer { fixture.remove() }

        let result = await fixture.app.addAdditionalParticipantResult(
            nil,
            name: fixture.person.displayName,
            meetingID: fixture.meetingID
        )

        #expect(
            result == .failure(.duplicateName(fixture.person.displayName))
        )
        #expect(
            fixture.app.reviewError(for: fixture.meetingID)
                == String(localized: "A person named \(fixture.person.displayName) already exists.")
        )
        #expect(try await fixture.app.allPersons().count == 1)
    }

    @Test("a meeting-update failure keeps the newly created unused person")
    @MainActor
    func partialPersonCreationRemainsVisible() async throws {
        let fixture = try await ReviewFixture.make()
        defer { fixture.remove() }
        let createdName = "Created Before Failure"
        _ = await fixture.app.loadMeetingReviewPublication(for: fixture.meetingID)
        let publicationIdentityBefore = try #require(
            fixture.app.meetingReviewPublicationIdentity(for: fixture.meetingID)
        )

        let result = await fixture.app.addAdditionalParticipantResult(
            nil,
            name: createdName,
            meetingID: fixture.meetingID,
            meetingUpdater: { library, _, _ in
                let store = try IdentityStore(layout: library.layout)
                #expect(
                    try await store.listPersons().contains {
                        $0.displayName == createdName
                    }
                )
                throw InjectedParticipantUpdateFailure()
            }
        )

        let people = try await fixture.app.allPersons()
        let created = try #require(
            people.first { $0.displayName == createdName }
        )
        let stored = try await fixture.library.loadMeeting(fixture.meetingID)
        let publicationIdentityAfter = try #require(
            fixture.app.meetingReviewPublicationIdentity(for: fixture.meetingID)
        )
        #expect(
            result == .failure(
                .createdButNotAdded(createdName)
            )
        )
        #expect(created.prototypes.isEmpty)
        #expect(created.hardNegatives.isEmpty)
        #expect(stored.additionalParticipantIDs.isEmpty)
        #expect(
            publicationIdentityAfter.publicationID
                != publicationIdentityBefore.publicationID
        )
        #expect(
            fixture.app.meetingReviewPublication(for: fixture.meetingID)?
                .review?.persons.contains(created) == true
        )
        #expect(
            fixture.app.reviewError(for: fixture.meetingID)
                == String(localized: "\(createdName) was created, but could not be added to this meeting. The person remains available to try again.")
        )
    }

    @Test("demo meetings edit known attendance but never create global people")
    @MainActor
    func demoMeetingAllowsOnlyKnownAdditionalParticipants() async throws {
        let provenance = DemoProvenance(
            datasetID: "synthetic-demo",
            datasetVersion: "1",
            itemID: "participants"
        )
        let fixture = try await ReviewFixture.make(
            metadata: MeetingMetadata(demoProvenance: provenance)
        )
        defer { fixture.remove() }
        let peopleBefore = try await fixture.app.allPersons()

        let addedKnown = await fixture.app.addAdditionalParticipant(
            fixture.person.id,
            name: nil,
            meetingID: fixture.meetingID
        )
        let removedKnown = await fixture.app.removeAdditionalParticipant(
            fixture.person.id,
            meetingID: fixture.meetingID
        )
        let createdNew = await fixture.app.addAdditionalParticipant(
            nil,
            name: "Demo Attendee",
            meetingID: fixture.meetingID
        )

        let peopleAfter = try await fixture.app.allPersons()
        let stored = try await fixture.library.loadMeeting(fixture.meetingID)
        #expect(addedKnown)
        #expect(removedKnown)
        #expect(!createdNew)
        #expect(peopleAfter == peopleBefore)
        #expect(stored.additionalParticipantIDs.isEmpty)
        #expect(
            fixture.app.reviewError(for: fixture.meetingID)
                == String(localized: "Demo meetings can add existing people, but cannot create a new person in your library.")
        )
    }

    @Test("participant mutations block speaker review before their first suspension")
    @MainActor
    func participantMutationSerializesAgainstSpeakerReview() async throws {
        let fixture = try await ReviewFixture.make()
        defer { fixture.remove() }
        let review = try #require(
            await fixture.app.loadMeetingReviewPublication(
                for: fixture.meetingID
            )?.review
        )
        let gate = ParticipantMutationGate()

        let addTask = Task { @MainActor in
            await fixture.app.addAdditionalParticipant(
                fixture.person.id,
                name: nil,
                meetingID: fixture.meetingID,
                meetingUpdater: { library, meetingID, participantIDs in
                    await gate.suspend()
                    return try await library.updateAdditionalMeetingParticipants(
                        meetingID,
                        participantIDs: participantIDs
                    )
                }
            )
        }
        await gate.waitUntilSuspended()

        let competingReview = await fixture.app.performReviewUpdate(
            .confirm(personID: fixture.person.id),
            on: fixture.cluster,
            data: review,
            meetingID: fixture.meetingID
        )
        await gate.release()
        let added = await addTask.value

        let stored = try await fixture.library.loadMeeting(fixture.meetingID)
        #expect(competingReview == nil)
        #expect(added)
        #expect(stored.additionalParticipantIDs == [fixture.person.id])
    }

    @Test("reversed window completions keep each participant error bound to its call")
    @MainActor
    func participantMutationErrorsDoNotCrossWindowCalls() async throws {
        let fixture = try await ReviewFixture.make()
        defer { fixture.remove() }
        let gate = ParticipantMutationGate()

        let firstWindowTask = Task { @MainActor in
            await fixture.app.addAdditionalParticipantResult(
                fixture.person.id,
                name: nil,
                meetingID: fixture.meetingID,
                meetingUpdater: { _, _, _ in
                    await gate.suspend()
                    throw InjectedParticipantUpdateFailure()
                }
            )
        }
        await gate.waitUntilSuspended()

        let secondWindowResult = await fixture.app.addAdditionalParticipantResult(
            fixture.person.id,
            name: nil,
            meetingID: fixture.meetingID
        )
        await gate.release()
        let firstWindowResult = await firstWindowTask.value

        #expect(secondWindowResult == .failure(.actionInProgress))
        #expect(firstWindowResult == .failure(.addFailed))
        #expect(
            secondWindowResult.error?.localizedDescription
                == String(localized: "Another participant or speaker change is still finishing.")
        )
        #expect(
            fixture.app.reviewError(for: fixture.meetingID)
                == String(localized: "The participant could not be added.")
        )
    }
}

private struct InjectedParticipantUpdateFailure: Error {}

private actor ParticipantMutationGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        suspensionWaiters.forEach { $0.resume() }
        suspensionWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct ReviewFixture {
    let root: URL
    let library: Library
    let app: AppModel
    let meetingID: MeetingID
    let cluster: IdentityCluster
    let person: Person

    @MainActor
    static func make(
        reviewActionPerformer: AppModel.ReviewActionPerformer? = nil,
        reviewSnapshotLoader: AppModel.ReviewSnapshotLoader? = nil,
        personsLoader: AppModel.PersonsLoader? = nil,
        metadata: MeetingMetadata? = nil
    ) async throws -> ReviewFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-iPad-review-\(UUID().uuidString)",
            isDirectory: true
        )
        let library = try Library.open(at: root)
        let meeting = try await library.createMeeting(
            title: "Review",
            status: .ready,
            metadata: metadata
        )
        let identityStore = try IdentityStore(layout: library.layout)
        let person = try await identityStore.createPerson(displayName: "Ada Lovelace")
        let runID = RunID()
        let cluster = IdentityCluster(
            meetingID: meeting.id,
            runID: runID,
            channel: MediaAsset.Kind.systemTrack.rawValue,
            clusterID: "speaker-1",
            recordingType: .remote,
            embedding: [1, 0],
            speechDurationSeconds: 12,
            segmentCount: 2
        )
        try seedIdentitySuggestionRun(
            meetingID: meeting.id,
            runID: runID,
            cluster: cluster,
            library: library
        )

        let store = try JobStore(layout: library.layout)
        let coordinator = PipelineCoordinator(
            library: library,
            jobStore: store,
            providers: [:],
            locale: Locale(identifier: "de-DE")
        )
        let runtime = PipelineRuntime(library: library, jobStore: store, coordinator: coordinator)
        let app = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, _, _ in runtime },
            libraryURL: root,
            reviewActionPerformer: reviewActionPerformer,
            reviewSnapshotLoader: reviewSnapshotLoader,
            personsLoader: personsLoader
        )
        await app.bootstrap()

        return ReviewFixture(
            root: root,
            library: library,
            app: app,
            meetingID: meeting.id,
            cluster: cluster,
            person: person
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ControlledReviewPersonsLoader {
    private var nextID = 0
    private var requested: Set<Int> = []
    private var requestWaiters: [
        Int: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var resultWaiters: [
        Int: CheckedContinuation<[Person], Never>
    ] = [:]

    func load() async -> [Person] {
        nextID += 1
        let id = nextID
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

    func release(id: Int, persons: [Person]) {
        resultWaiters.removeValue(forKey: id)?.resume(returning: persons)
    }
}

private func seedIdentitySuggestionRun(
    meetingID: MeetingID,
    runID: RunID,
    cluster: IdentityCluster,
    library: Library
) throws {
    let layout = library.layout
    let diarization = DiarizationArtifact(
        jobID: JobID(),
        sourceRunID: runID,
        revisionID: RevisionID(),
        tracks: [
            DiarizationTrackResult(
                assetID: MediaAssetID(),
                assetKind: .systemTrack,
                engine: EngineDescriptor(name: "fixture", version: "1"),
                segments: [
                    DiarizationRunSegment(clusterID: cluster.clusterID, start: 0, end: 1),
                ],
                clusters: [
                    DiarizationClusterResult(
                        clusterID: cluster.clusterID,
                        embedding: cluster.embedding,
                        speechDurationSeconds: cluster.speechDurationSeconds,
                        segmentCount: cluster.segmentCount
                    ),
                ]
            ),
        ]
    )
    try writeFinishedRun(
        ProcessingRun(
            id: runID,
            meetingID: meetingID,
            kind: .diarization,
            engine: EngineDescriptor(name: "fixture", version: "1"),
            status: .finished
        ),
        artifact: diarization,
        artifactName: "diarization.json",
        layout: layout
    )
    try writeFinishedRun(
        ProcessingRun(
            id: RunID(),
            meetingID: meetingID,
            kind: .identitySuggestion,
            engine: EngineDescriptor(name: "fixture", version: "1"),
            status: .finished
        ),
        artifact: IdentitySuggestionArtifact(
            jobID: JobID(),
            sourceRunID: runID,
            clusterResolutions: [
                IdentityClusterResolution(
                    channel: cluster.channel,
                    sourceClusterID: cluster.clusterID,
                    primaryClusterID: cluster.clusterID
                ),
            ],
            identityEvidenceFingerprint: "fixture",
            suggestions: []
        ),
        artifactName: "suggestions.json",
        layout: layout
    )
}

private func writeFinishedRun<Artifact: Encodable>(
    _ run: ProcessingRun,
    artifact: Artifact,
    artifactName: String,
    layout: LibraryLayout
) throws {
    let directory = layout.runDirectory(run.meetingID, runID: run.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try AtomicFile.write(encoder.encode(run), to: directory.appendingPathComponent("run.json"))
    try AtomicFile.write(encoder.encode(artifact), to: directory.appendingPathComponent(artifactName))
}
