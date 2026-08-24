import AVFoundation
import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary
import StenoPipeline

enum AppModelReviewError: LocalizedError {
    case runtimeUnavailable

    var errorDescription: String? {
        String(localized: "The library is not ready yet.")
    }
}

enum AppModelLibraryOperationError: LocalizedError, Equatable {
    case operationInProgress

    var errorDescription: String? {
        String(localized: "Another library change is still in progress. Try again in a moment.")
    }
}

enum MeetingRetranscriptionRequestError: LocalizedError, Equatable {
    case activeRecording
    case noPlayableAudio
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .activeRecording:
            String(localized: "The meeting currently being recorded cannot be transcribed again.")
        case .noPlayableAudio:
            String(localized: "This meeting has no original audio that Steno can transcribe again.")
        case .alreadyRunning:
            String(localized: "A transcription for this meeting is already queued or running.")
        }
    }
}

enum MeetingRetranscriptionRuntimeGuard {
    static func requireRetranscriptionAllowed(
        meetingID: MeetingID,
        recordingIsActive: Bool,
        recordingMeetingID: MeetingID?
    ) throws {
        guard !recordingIsActive || recordingMeetingID != meetingID else {
            throw MeetingRetranscriptionRequestError.activeRecording
        }
    }
}

struct MeetingDeletionOutcome: Equatable {
    let cleanupWarning: String?
}

enum MeetingDeletionError: LocalizedError, Equatable {
    case runtimeUnavailable
    case activeRecording
    case operationInProgress
    case operationInvalidated
    case processingCommitInProgress

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            String(localized: "The library is not ready yet.")
        case .activeRecording:
            String(localized: "The meeting currently being recorded cannot be moved to Trash.")
        case .operationInProgress:
            String(localized: "Another library change is still in progress. Try again in a moment.")
        case .operationInvalidated:
            String(localized: "The library changed while preparing the deletion. Try again.")
        case .processingCommitInProgress:
            String(localized: "This meeting is finishing a processing step. Try moving it to Trash again in a moment.")
        }
    }
}

enum MeetingDeletionRuntimeGuard {
    static func requireDeletionAllowed(
        meetingID: MeetingID,
        recordingIsActive: Bool,
        recordingMeetingID: MeetingID?
    ) throws {
        guard !recordingIsActive || recordingMeetingID != meetingID else {
            throw MeetingDeletionError.activeRecording
        }
    }
}

enum AdditionalParticipantMutationError: LocalizedError, Equatable {
    case runtimeUnavailable
    case actionInProgress
    case emptyName
    case demoCannotCreatePerson
    case personUnavailable
    case alreadyParticipant
    case notAdditional
    case duplicateName(String)
    case createdButNotAdded(String)
    case addFailed
    case removeFailed
    case reloadFailed

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            String(localized: "The library is not ready yet.")
        case .actionInProgress:
            String(localized: "Another participant or speaker change is still finishing.")
        case .emptyName:
            String(localized: "Enter a name for the new person.")
        case .demoCannotCreatePerson:
            String(localized: "Demo meetings can add existing people, but cannot create a new person in your library.")
        case .personUnavailable:
            String(localized: "The selected person no longer exists.")
        case .alreadyParticipant:
            String(localized: "This person is already part of the meeting.")
        case .notAdditional:
            String(localized: "Only an additional participant can be removed.")
        case .duplicateName(let name):
            String(localized: "A person named \(name) already exists.")
        case .createdButNotAdded(let name):
            String(localized: "\(name) was created, but could not be added to this meeting. The person remains available to try again.")
        case .addFailed:
            String(localized: "The participant could not be added.")
        case .removeFailed:
            String(localized: "The participant could not be removed.")
        case .reloadFailed:
            String(localized: "The participant change was saved, but the updated meeting could not be reloaded.")
        }
    }
}

enum AdditionalParticipantMutationResult: Equatable {
    case success
    case failure(AdditionalParticipantMutationError)

    var succeeded: Bool {
        self == .success
    }

    var error: AdditionalParticipantMutationError? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

struct MeetingReviewPublicationIdentity: Hashable, Sendable {
    let meetingID: MeetingID
    let generation: UInt64
    let publicationID: UInt64

    var loadKey: String {
        "\(meetingID)|\(generation)|\(publicationID)"
    }
}

typealias AdditionalParticipantMeetingUpdater = @MainActor @Sendable (
    Library,
    MeetingID,
    [PersonID]
) async throws -> Meeting

extension AppModel {
    func clearReviewStateAfterMeetingRemoval(_ meetingID: MeetingID) {
        reviewMutationGenerations[meetingID, default: 0] &+= 1
        reviewViewGenerations[meetingID, default: 0] &+= 1
        reviewActionsInFlight.remove(meetingID)
        reviewErrorsByMeeting.removeValue(forKey: meetingID)
        reviewPublicationsByMeeting.removeValue(forKey: meetingID)
        acceptedReviewLoadTickets[meetingID] = issuedReviewLoadTickets[meetingID, default: 0]
    }

    /// Adds a new final-ASR generation without replacing prior revisions.
    /// The pipeline starts fresh diarization afterwards, so its new cluster
    /// identifiers deliberately supersede the old run-scoped assignments.
    func requestRetranscription(meetingID: MeetingID) async throws {
        guard let runtime else { throw AppModelReviewError.runtimeUnavailable }
        guard let operation = beginLibraryOperation() else {
            throw AppModelLibraryOperationError.operationInProgress
        }
        defer { endFolderOperation(operation) }
        try MeetingRetranscriptionRuntimeGuard.requireRetranscriptionAllowed(
            meetingID: meetingID,
            recordingIsActive: recording.isActive,
            recordingMeetingID: recording.meetingID
        )
        try await MeetingProcessingJobRequest.requireUnpinnedJobAllowed(
            library: runtime.library,
            meetingID: meetingID
        )
        guard await hasPlayableAudio(meetingID, runtime: runtime) else {
            throw MeetingRetranscriptionRequestError.noPlayableAudio
        }
        let meeting = try await runtime.library.loadMeeting(meetingID)
        let enqueued = try await runtime.jobStore.enqueueIfNoEquivalentJob(
            Job.finalASR(for: meeting),
            blockingStatuses: [.queued, .running]
        )
        guard enqueued else {
            throw MeetingRetranscriptionRequestError.alreadyRunning
        }
    }

    private func hasPlayableAudio(
        _ meetingID: MeetingID,
        runtime: PipelineRuntime
    ) async -> Bool {
        let layout = runtime.library.layout
        let assets = (try? await runtime.library.listMediaAssets(
            meetingID: meetingID
        )) ?? []
        for asset in assets {
            guard asset.duration > 0 else { continue }
            let url = layout.mediaFile(meetingID, fileName: asset.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if (try? await AVURLAsset(url: url).load(.isReadable)) == true {
                return true
            }
        }
        return false
    }

    /// The shared, meeting-tagged state read by every scene. Views do not
    /// retain their own writable meeting/review pair, so a late action for
    /// one meeting cannot replace another meeting and two windows always
    /// observe the same publication.
    func meetingReviewPublication(
        for meetingID: MeetingID
    ) -> MeetingReviewPublication? {
        reviewPublicationsByMeeting[meetingID]
    }

    func meetingReviewPublicationIdentity(
        for meetingID: MeetingID
    ) -> MeetingReviewPublicationIdentity? {
        guard let publication = meetingReviewPublication(for: meetingID) else {
            return nil
        }
        return MeetingReviewPublicationIdentity(
            meetingID: meetingID,
            generation: publication.generation,
            publicationID: acceptedReviewLoadTickets[meetingID, default: 0]
        )
    }

    func reviewGeneration(for meetingID: MeetingID) -> UInt64 {
        reviewViewGenerations[meetingID, default: 0]
    }

    /// Loads and publishes one coherent meeting/review pair.
    ///
    /// Mutation generations and read tickets are deliberately separate. A
    /// read only wins if no mutation committed while it was suspended and no
    /// newer successful read superseded it. A failed newer read never blocks
    /// an older valid one. A review action then accepts every issued ticket,
    /// so a late same-generation read cannot replace its exact result.
    @discardableResult
    func loadMeetingReviewPublication(
        for meetingID: MeetingID
    ) async -> MeetingReviewPublication? {
        guard let runtime else { return nil }
        let mutationGeneration = reviewMutationGenerations[meetingID, default: 0]
        let ticket = nextReviewLoadTicket(for: meetingID)

        let snapshot: MeetingReviewSnapshot
        do {
            snapshot = try await reviewSnapshotLoader(meetingID, runtime.library)
        } catch {
            return meetingReviewPublication(for: meetingID)
        }

        guard reviewMutationGenerations[meetingID, default: 0] == mutationGeneration,
              acceptedReviewLoadTickets[meetingID, default: 0] < ticket
        else {
            return meetingReviewPublication(for: meetingID)
        }
        return publishReviewPublication(
            meetingID: meetingID,
            generation: reviewGeneration(for: meetingID),
            meeting: snapshot.meeting,
            review: snapshot.review,
            accepting: ticket
        )
    }

    /// All persisted people, including silent participants who do not occur
    /// in the current review snapshot. Equal names remain distinct IDs.
    func allPersons() async throws -> [Person] {
        guard let runtime else { throw AppModelReviewError.runtimeUnavailable }
        let persons = try await personsLoader(runtime.library)
        return persons.sorted { lhs, rhs in
            let comparison = lhs.displayName.localizedCaseInsensitiveCompare(
                rhs.displayName
            )
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    func reviewError(for meetingID: MeetingID) -> String? {
        reviewErrorsByMeeting[meetingID]
    }

    func isReviewBusy(_ meetingID: MeetingID) -> Bool {
        reviewActionsInFlight.contains(meetingID)
    }

    /// Adds attendance without manufacturing speaker evidence. A known
    /// person is resolved by ID; a new person is stored first and deliberately
    /// remains stored if the later meeting update fails.
    @discardableResult
    func addAdditionalParticipant(
        _ personID: PersonID?,
        name: String?,
        meetingID: MeetingID
    ) async -> Bool {
        await addAdditionalParticipantResult(
            personID,
            name: name,
            meetingID: meetingID
        ).succeeded
    }

    func addAdditionalParticipantResult(
        _ personID: PersonID?,
        name: String?,
        meetingID: MeetingID
    ) async -> AdditionalParticipantMutationResult {
        await addAdditionalParticipantResult(
            personID,
            name: name,
            meetingID: meetingID,
            meetingUpdater: { library, meetingID, participantIDs in
                try await library.updateAdditionalMeetingParticipants(
                    meetingID,
                    participantIDs: participantIDs
                )
            }
        )
    }

    /// Dependency-bearing overload for the post-person-creation failure
    /// boundary. Production always calls the exact Library mutation above.
    @discardableResult
    func addAdditionalParticipant(
        _ personID: PersonID?,
        name: String?,
        meetingID: MeetingID,
        meetingUpdater: @escaping AdditionalParticipantMeetingUpdater
    ) async -> Bool {
        await addAdditionalParticipantResult(
            personID,
            name: name,
            meetingID: meetingID,
            meetingUpdater: meetingUpdater
        ).succeeded
    }

    func addAdditionalParticipantResult(
        _ personID: PersonID?,
        name: String?,
        meetingID: MeetingID,
        meetingUpdater: @escaping AdditionalParticipantMeetingUpdater
    ) async -> AdditionalParticipantMutationResult {
        guard let runtime else {
            return failParticipantMutation(.runtimeUnavailable, meetingID: meetingID)
        }
        guard reviewActionsInFlight.insert(meetingID).inserted else {
            return failParticipantMutation(.actionInProgress, meetingID: meetingID)
        }
        defer { reviewActionsInFlight.remove(meetingID) }
        reviewErrorsByMeeting.removeValue(forKey: meetingID)

        let identityStore: IdentityStore
        do {
            identityStore = try IdentityStore(layout: runtime.library.layout)
        } catch {
            return failParticipantMutation(.addFailed, meetingID: meetingID)
        }

        var createdPerson: Person?
        do {
            let resolvedPerson: Person
            if let personID {
                guard let person = try await identityStore.person(personID) else {
                    return failParticipantMutation(
                        .personUnavailable,
                        meetingID: meetingID
                    )
                }
                resolvedPerson = person
            } else {
                let trimmed = (name ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return failParticipantMutation(.emptyName, meetingID: meetingID)
                }
                let creationMeeting = try await runtime.library.loadMeeting(meetingID)
                guard !creationMeeting.isDemo else {
                    return failParticipantMutation(
                        .demoCannotCreatePerson,
                        meetingID: meetingID
                    )
                }
                let person = try await identityStore.createPerson(
                    displayName: trimmed
                )
                createdPerson = person
                resolvedPerson = person
            }

            let meeting = try await runtime.library.loadMeeting(meetingID)
            guard !meeting.participantIDs.contains(resolvedPerson.id),
                  !meeting.additionalParticipantIDs.contains(resolvedPerson.id)
            else {
                return failParticipantMutation(
                    .alreadyParticipant,
                    meetingID: meetingID
                )
            }
            _ = try await meetingUpdater(
                runtime.library,
                meetingID,
                meeting.additionalParticipantIDs + [resolvedPerson.id]
            )
            guard await publishCommittedParticipantChange(
                meetingID: meetingID,
                runtime: runtime
            ) else {
                return failParticipantMutation(.reloadFailed, meetingID: meetingID)
            }
            reviewErrorsByMeeting.removeValue(forKey: meetingID)
            return .success
        } catch let LibraryError.duplicatePersonName(name) {
            return failParticipantMutation(
                .duplicateName(name),
                meetingID: meetingID
            )
        } catch {
            if let createdPerson {
                await publishIdentityOnlyChange(
                    meetingID: meetingID,
                    runtime: runtime
                )
                return failParticipantMutation(
                    .createdButNotAdded(createdPerson.displayName),
                    meetingID: meetingID
                )
            }
            return failParticipantMutation(.addFailed, meetingID: meetingID)
        }
    }

    /// Removes only the manual attendance edge. Evidence-backed
    /// `participantIDs` and every Person evidence array remain untouched.
    @discardableResult
    func removeAdditionalParticipant(
        _ personID: PersonID,
        meetingID: MeetingID
    ) async -> Bool {
        await removeAdditionalParticipantResult(
            personID,
            meetingID: meetingID
        ).succeeded
    }

    func removeAdditionalParticipantResult(
        _ personID: PersonID,
        meetingID: MeetingID
    ) async -> AdditionalParticipantMutationResult {
        guard let runtime else {
            return failParticipantMutation(.runtimeUnavailable, meetingID: meetingID)
        }
        guard reviewActionsInFlight.insert(meetingID).inserted else {
            return failParticipantMutation(.actionInProgress, meetingID: meetingID)
        }
        defer { reviewActionsInFlight.remove(meetingID) }
        reviewErrorsByMeeting.removeValue(forKey: meetingID)

        do {
            let meeting = try await runtime.library.loadMeeting(meetingID)
            guard meeting.additionalParticipantIDs.contains(personID) else {
                return failParticipantMutation(.notAdditional, meetingID: meetingID)
            }
            _ = try await runtime.library.updateAdditionalMeetingParticipants(
                meetingID,
                participantIDs: meeting.additionalParticipantIDs.filter {
                    $0 != personID
                }
            )
            guard await publishCommittedParticipantChange(
                meetingID: meetingID,
                runtime: runtime
            ) else {
                return failParticipantMutation(.reloadFailed, meetingID: meetingID)
            }
            reviewErrorsByMeeting.removeValue(forKey: meetingID)
            return .success
        } catch {
            return failParticipantMutation(.removeFailed, meetingID: meetingID)
        }
    }

    private func publishCommittedParticipantChange(
        meetingID: MeetingID,
        runtime: PipelineRuntime
    ) async -> Bool {
        let generation = advanceReviewMutation(for: meetingID)
        let snapshot: MeetingReviewSnapshot
        do {
            snapshot = try await reviewSnapshotLoader(
                meetingID,
                runtime.library
            )
        } catch {
            requestReviewRefresh(for: meetingID)
            return false
        }
        publishReviewPublication(
            meetingID: meetingID,
            generation: generation,
            meeting: snapshot.meeting,
            review: snapshot.review
        )
        return true
    }

    /// Person creation is independently durable. If the meeting edge fails,
    /// publish the unchanged meeting with the new person snapshot when
    /// possible, but never roll the person back silently.
    private func publishIdentityOnlyChange(
        meetingID: MeetingID,
        runtime: PipelineRuntime
    ) async {
        let generation = advanceReviewMutation(for: meetingID)
        guard let snapshot = try? await reviewSnapshotLoader(
            meetingID,
            runtime.library
        ) else {
            requestReviewRefresh(for: meetingID)
            return
        }
        publishReviewPublication(
            meetingID: meetingID,
            generation: generation,
            meeting: snapshot.meeting,
            review: snapshot.review
        )
    }

    private func failParticipantMutation(
        _ error: AdditionalParticipantMutationError,
        meetingID: MeetingID
    ) -> AdditionalParticipantMutationResult {
        reviewErrorsByMeeting[meetingID] = error.localizedDescription
        return .failure(error)
    }

    /// Compatibility entry point for callers that only need review data.
    func performReview(
        _ action: MeetingReviewController.Action,
        on cluster: IdentityCluster,
        data: MeetingReviewData,
        meetingID: MeetingID
    ) async -> MeetingReviewData? {
        await performReviewUpdate(
            action,
            on: cluster,
            data: data,
            meetingID: meetingID
        )?.review
    }

    /// Performs exactly one review pipeline per meeting at a time.
    ///
    /// The in-flight bit is set before the first suspension point and remains
    /// set until the exact controller review and its atomically reloaded
    /// meeting have been published together.
    func performReviewUpdate(
        _ action: MeetingReviewController.Action,
        on cluster: IdentityCluster,
        data: MeetingReviewData,
        meetingID: MeetingID
    ) async -> ReviewUpdate? {
        guard let runtime,
              reviewActionsInFlight.insert(meetingID).inserted
        else { return nil }
        defer { reviewActionsInFlight.remove(meetingID) }

        let updatedReview: MeetingReviewData
        let generation: UInt64
        let keptStaleError: Bool
        var staleSnapshot: MeetingReviewSnapshot?
        do {
            updatedReview = try await reviewActionPerformer(
                action,
                cluster,
                data,
                meetingID,
                runtime.library
            )
            // The controller has committed. Invalidate every scene before any
            // reload can suspend, and invalidate reads that began pre-commit.
            generation = advanceReviewMutation(for: meetingID)
            keptStaleError = false
        } catch MeetingReviewController.ReviewActionError.stale {
            // Stale already proves the shared view is superseded. Every
            // window must refresh even when the following read itself fails.
            generation = advanceReviewMutation(for: meetingID)
            let staleMessage = String(localized: "This review belongs to a superseded run. Check the refreshed inspector before trying again.")
            reviewErrorsByMeeting[meetingID] = staleMessage
            guard let refreshedSnapshot = try? await reviewSnapshotLoader(
                meetingID,
                runtime.library
            ), let refreshed = refreshedSnapshot.review else {
                reviewErrorsByMeeting[meetingID] = String(localized: "This review belongs to a superseded run. The current review could not be reloaded.")
                requestReviewRefresh(for: meetingID)
                return nil
            }
            updatedReview = refreshed
            staleSnapshot = refreshedSnapshot
            keptStaleError = true
        } catch MeetingReviewController.ReviewActionError
            .demoMeetingCannotCreateVoiceEvidence {
            reviewErrorsByMeeting[meetingID] = Self.demoVoiceEvidenceRestrictionMessage
            return nil
        } catch let MeetingReviewController.ReviewActionError.rejected(message) {
            reviewErrorsByMeeting[meetingID] = message
            return nil
        } catch let LibraryError.duplicatePersonName(name) {
            reviewErrorsByMeeting[meetingID] = String(localized: "A person named \(name) already exists.")
            return nil
        } catch let error as IdentityReviewError {
            reviewErrorsByMeeting[meetingID] = Self.reviewMessage(for: error)
            return nil
        } catch {
            reviewErrorsByMeeting[meetingID] = String(localized: "Assigning the speaker failed: \(error.localizedDescription)")
            return nil
        }

        let updatedSnapshot: MeetingReviewSnapshot
        if let staleSnapshot {
            updatedSnapshot = staleSnapshot
        } else {
            do {
                updatedSnapshot = try await reviewSnapshotLoader(meetingID, runtime.library)
            } catch {
                reviewErrorsByMeeting[meetingID] = String(localized: "The updated meeting could not be reloaded. The inspector was not changed.")
                requestReviewRefresh(for: meetingID)
                return nil
            }
        }

        guard keptStaleError || Self.sameReview(updatedSnapshot.review, as: updatedReview) else {
            // Another writer won after this controller commit. Publish that
            // latest coherent pair, never a meeting combined with our older
            // controller value.
            publishReviewPublication(
                meetingID: meetingID,
                generation: generation,
                meeting: updatedSnapshot.meeting,
                review: updatedSnapshot.review
            )
            reviewErrorsByMeeting[meetingID] = String(localized: "The speaker review changed again. Check the refreshed inspector before trying again.")
            return nil
        }

        publishReviewPublication(
            meetingID: meetingID,
            generation: generation,
            meeting: updatedSnapshot.meeting,
            // On a successful action keep the controller's exact value. Stale
            // recovery has no controller result and publishes the freshly
            // assembled review instead.
            review: updatedReview
        )
        if !keptStaleError {
            reviewErrorsByMeeting.removeValue(forKey: meetingID)
        }
        return ReviewUpdate(review: updatedReview, meeting: updatedSnapshot.meeting)
    }

    private func nextReviewLoadTicket(for meetingID: MeetingID) -> UInt64 {
        let next = issuedReviewLoadTickets[meetingID, default: 0] &+ 1
        issuedReviewLoadTickets[meetingID] = next
        return next
    }

    @discardableResult
    private func publishReviewPublication(
        meetingID: MeetingID,
        generation: UInt64,
        meeting: Meeting,
        review: MeetingReviewData?,
        accepting issuedTicket: UInt64? = nil
    ) -> MeetingReviewPublication {
        let publicationID = issuedTicket ?? nextReviewLoadTicket(for: meetingID)
        let publication = MeetingReviewPublication(
            generation: generation,
            meeting: meeting,
            review: review
        )
        acceptedReviewLoadTickets[meetingID] = publicationID
        reviewPublicationsByMeeting[meetingID] = publication
        return publication
    }

    private func advanceReviewMutation(for meetingID: MeetingID) -> UInt64 {
        let next = reviewMutationGenerations[meetingID, default: 0] &+ 1
        reviewMutationGenerations[meetingID] = next
        reviewViewGenerations[meetingID] = reviewGeneration(for: meetingID) &+ 1
        reviewPublicationsByMeeting.removeValue(forKey: meetingID)
        return reviewGeneration(for: meetingID)
    }

    private func requestReviewRefresh(for meetingID: MeetingID) {
        reviewViewGenerations[meetingID] = reviewGeneration(for: meetingID) &+ 1
        reviewPublicationsByMeeting.removeValue(forKey: meetingID)
    }

    /// Compares only what an action actually persists: cluster review state
    /// and person evidence. `suggestions` is deliberately excluded - the
    /// controller always returns it freshly recomputed from the action's own
    /// updated evidence (`SpeakerSuggestionEngine.suggestions`), while a
    /// reload reads the static suggestions of the last finished suggestion
    /// run. Those two legitimately differ after every action that changes
    /// evidence, with or without a concurrent writer, so comparing them would
    /// treat an ordinary confirmation as a lost race.
    private static func sameReview(
        _ candidate: MeetingReviewData?,
        as controllerResult: MeetingReviewData
    ) -> Bool {
        guard let candidate else { return false }
        return candidate.runID == controllerResult.runID
            && candidate.clusters == controllerResult.clusters
            && candidate.resolutions == controllerResult.resolutions
            && candidate.persons == controllerResult.persons
    }

    /// Rohe Fehlernamen gehoeren nicht in die Oberflaeche.
    static func reviewMessage(for error: IdentityReviewError) -> String {
        switch error {
        case .clusterNotFound:
            String(localized: "This speaker belongs to a superseded run. Reload the view.")
        case .ambiguousClusterAlias:
            String(localized: "This speaker cannot be changed because its source is ambiguous.")
        case .personNotFound:
            String(localized: "The selected person no longer exists.")
        case .mixedClusterCannotBeNamed:
            String(localized: "This cluster contains multiple people and cannot be assigned to one person.")
        case .selfClusterCannotBeNamed:
            String(localized: "Your own microphone track is not named as a person.")
        case .noAssignmentToReassign:
            String(localized: "There is no assignment here that can be changed.")
        case .voiceEvidenceForbidden:
            demoVoiceEvidenceRestrictionMessage
        }
    }

    private static let demoVoiceEvidenceRestrictionMessage = String(localized: "Demo meetings cannot create or change real voice profiles.")

    /// Ein Meeting ohne Aufnahme, um vor dem Termin Notizen zu schreiben. Es
    /// zaehlt bewusst nicht als gestrandete Aufnahme.
    @discardableResult
    func createDraftMeeting() async -> MeetingID? {
        guard let runtime else { return nil }
        do {
            let meeting = try await runtime.library.createMeeting(
                title: Self.draftTitle(),
                status: .draft
            )
            await reloadMeetings()
            return meeting.id
        } catch {
            reportDraftCreationFailure(error)
            return nil
        }
    }

    private static func draftTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return String(localized: "Notes \(formatter.string(from: Date()))")
    }
}
