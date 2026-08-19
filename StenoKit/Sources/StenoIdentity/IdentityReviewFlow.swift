import Foundation
import StenoDomain

public struct IdentityReviewState: Equatable, Sendable {
    public let meetingID: MeetingID
    public let currentRunID: RunID
    public var clusters: [IdentityCluster]
    public var persons: [Person]
    public var participantIDs: [PersonID]

    public init(
        meetingID: MeetingID,
        currentRunID: RunID,
        clusters: [IdentityCluster],
        persons: [Person],
        participantIDs: [PersonID] = []
    ) {
        self.meetingID = meetingID
        self.currentRunID = currentRunID
        self.clusters = clusters
        self.persons = persons
        self.participantIDs = participantIDs
    }
}

public enum IdentityReviewStatus: Equatable, Sendable {
    case confirmed
    case reassigned
    case multiple
    case generic
    case stale
}

public struct IdentityReviewResult: Equatable, Sendable {
    public let status: IdentityReviewStatus
    public let state: IdentityReviewState
    public let reassignedFrom: [PersonID]

    public init(
        status: IdentityReviewStatus,
        state: IdentityReviewState,
        reassignedFrom: [PersonID] = []
    ) {
        self.status = status
        self.state = state
        self.reassignedFrom = reassignedFrom
    }
}

public enum IdentityReviewError: Error, Equatable, Sendable {
    case clusterNotFound(channel: String, clusterID: String)
    case personNotFound(PersonID)
    case mixedClusterCannotBeNamed
    case selfClusterCannotBeNamed
    case noAssignmentToReassign
}

public extension SpeakerSuggestionEngine {
    func confirm(
        clusterID: String,
        channel: String,
        runID: RunID,
        as personID: PersonID,
        in state: IdentityReviewState
    ) throws -> IdentityReviewResult {
        try assign(
            clusterID: clusterID,
            channel: channel,
            runID: runID,
            personID: personID,
            forceCorrection: false,
            in: state
        )
    }

    func reassign(
        clusterID: String,
        channel: String,
        runID: RunID,
        to personID: PersonID,
        in state: IdentityReviewState
    ) throws -> IdentityReviewResult {
        try assign(
            clusterID: clusterID,
            channel: channel,
            runID: runID,
            personID: personID,
            forceCorrection: true,
            in: state
        )
    }

    func markMultiple(
        clusterID: String,
        channel: String,
        runID: RunID,
        in state: IdentityReviewState
    ) throws -> IdentityReviewResult {
        guard runID == state.currentRunID else {
            return IdentityReviewResult(status: .stale, state: state)
        }
        var updated = state
        let clusterIndex = try resolveClusterIndex(
            clusterID: clusterID,
            channel: channel,
            runID: runID,
            in: updated
        )
        let cluster = updated.clusters[clusterIndex]
        let ids = Set([cluster.clusterID] + cluster.mergedFrom)
        let previousOwners = removePositiveEvidence(
            clusterIDs: ids,
            channel: channel,
            runID: runID,
            from: &updated
        )
        updated.clusters[clusterIndex].containsMultipleSpeakers = true
        updated.clusters[clusterIndex].reviewState = .multiple
        removeParticipantsWithoutMeetingEvidence(previousOwners, from: &updated)
        rebuildHardNegatives(
            meetingID: state.meetingID,
            runID: runID,
            channel: channel,
            in: &updated
        )
        return IdentityReviewResult(
            status: .multiple,
            state: updated,
            reassignedFrom: previousOwners.sorted()
        )
    }

    func keepGeneric(
        clusterID: String,
        channel: String,
        runID: RunID,
        in state: IdentityReviewState
    ) throws -> IdentityReviewResult {
        guard runID == state.currentRunID else {
            return IdentityReviewResult(status: .stale, state: state)
        }
        var updated = state
        let index = try resolveClusterIndex(
            clusterID: clusterID,
            channel: channel,
            runID: runID,
            in: updated
        )
        if !updated.clusters[index].containsMultipleSpeakers {
            updated.clusters[index].reviewState = .generic
        }
        return IdentityReviewResult(status: .generic, state: updated)
    }

    private func assign(
        clusterID: String,
        channel: String,
        runID: RunID,
        personID: PersonID,
        forceCorrection: Bool,
        in state: IdentityReviewState
    ) throws -> IdentityReviewResult {
        guard runID == state.currentRunID else {
            return IdentityReviewResult(status: .stale, state: state)
        }
        guard state.persons.contains(where: { $0.id == personID }) else {
            throw IdentityReviewError.personNotFound(personID)
        }
        var updated = state
        let clusterIndex = try resolveClusterIndex(
            clusterID: clusterID,
            channel: channel,
            runID: runID,
            in: updated
        )
        let cluster = updated.clusters[clusterIndex]
        guard !cluster.containsMultipleSpeakers else {
            throw IdentityReviewError.mixedClusterCannotBeNamed
        }
        guard !cluster.isSelf else {
            throw IdentityReviewError.selfClusterCannotBeNamed
        }
        let fragmentIDs = Set([cluster.clusterID] + cluster.mergedFrom)
        let previousOwners = removePositiveEvidence(
            clusterIDs: fragmentIDs,
            channel: channel,
            runID: runID,
            from: &updated
        )
        let otherOwners = previousOwners.filter { $0 != personID }
        if forceCorrection && otherOwners.isEmpty {
            throw IdentityReviewError.noAssignmentToReassign
        }

        guard let personIndex = updated.persons.firstIndex(where: { $0.id == personID }) else {
            throw IdentityReviewError.personNotFound(personID)
        }
        let source: SpeakerEvidenceSource = forceCorrection || !otherOwners.isEmpty
            ? .userCorrected
            : .userConfirmed
        updated.persons[personIndex].prototypes.append(SpeakerPrototype(
            personID: personID,
            embedding: cluster.embedding,
            recordingType: cluster.recordingType,
            channel: cluster.channel,
            meetingID: cluster.meetingID,
            runID: cluster.runID,
            clusterID: cluster.clusterID,
            speechDurationSeconds: cluster.speechDurationSeconds,
            segmentCount: cluster.segmentCount,
            source: source
        ))
        updated.persons[personIndex].updatedAt = Date()
        updated.clusters[clusterIndex].reviewState = .confirmed(personID)
        if !updated.participantIDs.contains(personID) {
            updated.participantIDs.append(personID)
        }
        removeParticipantsWithoutMeetingEvidence(otherOwners, from: &updated)

        // Recomputing the complete current-run channel graph is simpler and
        // safer than incrementally repairing it. It makes confirmations
        // idempotent and covers every cluster in a many-to-one assignment.
        rebuildHardNegatives(
            meetingID: state.meetingID,
            runID: runID,
            channel: channel,
            in: &updated
        )
        let status: IdentityReviewStatus = otherOwners.isEmpty && !forceCorrection
            ? .confirmed
            : .reassigned
        return IdentityReviewResult(
            status: status,
            state: updated,
            reassignedFrom: otherOwners.sorted()
        )
    }

    private func resolveClusterIndex(
        clusterID: String,
        channel: String,
        runID: RunID,
        in state: IdentityReviewState
    ) throws -> Int {
        guard let index = state.clusters.firstIndex(where: {
            $0.meetingID == state.meetingID
                && $0.runID == runID
                && $0.channel == channel
                && ($0.clusterID == clusterID || $0.mergedFrom.contains(clusterID))
        }) else {
            throw IdentityReviewError.clusterNotFound(
                channel: channel,
                clusterID: clusterID
            )
        }
        return index
    }

    private func removePositiveEvidence(
        clusterIDs: Set<String>,
        channel: String,
        runID: RunID,
        from state: inout IdentityReviewState
    ) -> [PersonID] {
        var owners: [PersonID] = []
        let meetingID = state.meetingID
        for index in state.persons.indices {
            let before = state.persons[index].prototypes.count
            state.persons[index].prototypes.removeAll {
                $0.meetingID == meetingID
                    && $0.runID == runID
                    && $0.channel == channel
                    && clusterIDs.contains($0.clusterID)
            }
            if state.persons[index].prototypes.count != before {
                owners.append(state.persons[index].id)
                state.persons[index].updatedAt = Date()
            }
        }
        return owners
    }

    private func removeParticipantsWithoutMeetingEvidence(
        _ personIDs: [PersonID],
        from state: inout IdentityReviewState
    ) {
        for personID in personIDs {
            let remainsInMeeting = state.persons.first(where: { $0.id == personID })?
                .prototypes.contains { $0.meetingID == state.meetingID } ?? false
            if !remainsInMeeting {
                state.participantIDs.removeAll { $0 == personID }
            }
        }
    }

    private func rebuildHardNegatives(
        meetingID: MeetingID,
        runID: RunID,
        channel: String,
        in state: inout IdentityReviewState
    ) {
        // Diese Funktion wirft die Negatives des Bereichs weg und leitet sie
        // neu ab. Ein Mensch kann ein Negativ aber ausgenommen haben, und das
        // ist eine Aussage ueber die Stimme, keine Ableitung: sie ueberlebt
        // den Neuaufbau. Ohne das haette ein Klick im Review die stillste
        // aller Ruecknahmen ausgeloest - ein wieder scharf gestelltes falsches
        // Negativ, das eine echte Erkennung dauerhaft unterdrueckt.
        var excludedBefore: [ExcludedNegativeKey: Date] = [:]
        for index in state.persons.indices {
            for negative in state.persons[index].hardNegatives {
                guard let excludedAt = negative.excludedAt else { continue }
                excludedBefore[ExcludedNegativeKey(negative)] = excludedAt
            }
            state.persons[index].hardNegatives.removeAll {
                $0.meetingID == meetingID
                    && $0.runID == runID
                    && $0.channel == channel
            }
        }

        let clusterByID = Dictionary(
            uniqueKeysWithValues: state.clusters
                .filter {
                    $0.meetingID == meetingID
                        && $0.runID == runID
                        && $0.channel == channel
                        && !$0.containsMultipleSpeakers
                        && !$0.isSelf
                }
                .map { ($0.clusterID, $0) }
        )
        var ownedClusters: [PersonID: [IdentityCluster]] = [:]
        for person in state.persons {
            var seen: Set<String> = []
            for prototype in person.prototypes where
                prototype.meetingID == meetingID
                    && prototype.runID == runID
                    && prototype.channel == channel
                    && seen.insert(prototype.clusterID).inserted {
                if let cluster = clusterByID[prototype.clusterID] {
                    ownedClusters[person.id, default: []].append(cluster)
                }
            }
        }

        for ownerIndex in state.persons.indices {
            let ownerID = state.persons[ownerIndex].id
            let otherClusters = ownedClusters
                .filter { $0.key != ownerID }
                .flatMap(\.value)
                .sorted { $0.clusterID < $1.clusterID }
            for cluster in otherClusters {
                let negative = HardNegative(
                    personID: ownerID,
                    embedding: cluster.embedding,
                    recordingType: cluster.recordingType,
                    channel: cluster.channel,
                    meetingID: cluster.meetingID,
                    runID: cluster.runID,
                    clusterID: cluster.clusterID,
                    speechDurationSeconds: cluster.speechDurationSeconds,
                    segmentCount: cluster.segmentCount,
                    source: .userConfirmed,
                    excludedAt: excludedBefore[ExcludedNegativeKey(
                        personID: ownerID,
                        meetingID: cluster.meetingID,
                        runID: cluster.runID,
                        channel: cluster.channel,
                        clusterID: cluster.clusterID
                    )]
                )
                state.persons[ownerIndex].hardNegatives.append(negative)
            }
            if !otherClusters.isEmpty {
                state.persons[ownerIndex].updatedAt = Date()
            }
        }
    }
}

/// Identifiziert ein abgeleitetes Negativ ueber seine Herkunft statt ueber
/// seine ID: der Neuaufbau vergibt eine neue ID, meint aber dieselbe Stimme
/// im selben Cluster desselben Laufs.
private struct ExcludedNegativeKey: Hashable {
    let personID: PersonID
    let meetingID: MeetingID?
    let runID: RunID?
    let channel: String?
    let clusterID: String

    init(
        personID: PersonID,
        meetingID: MeetingID?,
        runID: RunID?,
        channel: String?,
        clusterID: String
    ) {
        self.personID = personID
        self.meetingID = meetingID
        self.runID = runID
        self.channel = channel
        self.clusterID = clusterID
    }

    init(_ negative: HardNegative) {
        self.init(
            personID: negative.personID,
            meetingID: negative.meetingID,
            runID: negative.runID,
            channel: negative.channel,
            clusterID: negative.clusterID
        )
    }
}
