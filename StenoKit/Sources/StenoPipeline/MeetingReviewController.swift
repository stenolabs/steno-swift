import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary

/// Führt Review-Aktionen aus und persistiert sie in einem Zug:
/// Personenevidenz in identity/persons.json, Cluster-Zustand in review.json,
/// Teilnehmerliste am Meeting. Vorschläge werden nach jeder Aktion neu
/// berechnet, weil sich die Evidenz geändert hat (meetingweite Exklusivität).
public struct MeetingReviewController: Sendable {
    public enum Action: Sendable {
        case confirm(personID: PersonID)
        case reassign(personID: PersonID)
        case confirmAsNewPerson(name: String)
        case markMultiple
        case keepGeneric
    }

    public enum ReviewActionError: Error, Equatable, Sendable {
        case stale
        case rejected(String)
    }

    private let library: Library
    private let engine: SpeakerSuggestionEngine

    public init(
        library: Library,
        engine: SpeakerSuggestionEngine = SpeakerSuggestionEngine()
    ) {
        self.library = library
        self.engine = engine
    }

    public func perform(
        _ action: Action,
        on cluster: IdentityCluster,
        data: MeetingReviewData,
        meetingID: MeetingID
    ) async throws -> MeetingReviewData {
        let layout = await library.layout
        let identityStore = try IdentityStore(layout: layout)
        let meeting = try await library.loadMeeting(meetingID)
        var state = IdentityReviewState(
            meetingID: meetingID,
            currentRunID: data.runID,
            clusters: data.clusters,
            persons: data.persons,
            participantIDs: meeting.participantIDs
        )

        let result: IdentityReviewResult
        switch action {
        case .confirm(let personID):
            result = try engine.confirm(
                clusterID: cluster.clusterID,
                channel: cluster.channel,
                runID: cluster.runID,
                as: personID,
                in: state
            )
        case .reassign(let personID):
            result = try engine.reassign(
                clusterID: cluster.clusterID,
                channel: cluster.channel,
                runID: cluster.runID,
                to: personID,
                in: state
            )
        case .confirmAsNewPerson(let name):
            let person = try await identityStore.createPerson(displayName: name)
            state.persons.append(person)
            result = try engine.confirm(
                clusterID: cluster.clusterID,
                channel: cluster.channel,
                runID: cluster.runID,
                as: person.id,
                in: state
            )
        case .markMultiple:
            result = try engine.markMultiple(
                clusterID: cluster.clusterID,
                channel: cluster.channel,
                runID: cluster.runID,
                in: state
            )
        case .keepGeneric:
            result = try engine.keepGeneric(
                clusterID: cluster.clusterID,
                channel: cluster.channel,
                runID: cluster.runID,
                in: state
            )
        }

        switch result.status {
        case .confirmed, .reassigned, .multiple, .generic:
            break
        case .stale:
            throw ReviewActionError.stale
        }

        try await identityStore.replacePersons(result.state.persons)
        try MeetingReviewStore(layout: layout).save(
            MeetingReviewDocument(
                runID: data.runID,
                clusters: result.state.clusters
            ),
            meetingID: meetingID
        )
        _ = try await library.updateMeetingParticipants(
            meetingID,
            participantIDs: result.state.participantIDs
        )

        var updated = data
        updated.clusters = result.state.clusters
        updated.persons = result.state.persons
        updated.suggestions = engine.suggestions(
            for: result.state.clusters,
            people: result.state.persons
        )
        return updated
    }
}
