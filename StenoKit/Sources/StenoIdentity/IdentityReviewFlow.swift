import Foundation
import StenoDomain

public enum VoiceEvidenceMutationPolicy: Equatable, Sendable {
    case allowed
    case forbidden
}

public struct IdentityReviewState: Equatable, Sendable {
    public let meetingID: MeetingID
    public let currentRunID: RunID
    public let voiceEvidenceMutationPolicy: VoiceEvidenceMutationPolicy
    public var clusters: [IdentityCluster]
    public var persons: [Person]
    public var participantIDs: [PersonID]

    public init(
        meetingID: MeetingID,
        currentRunID: RunID,
        voiceEvidenceMutationPolicy: VoiceEvidenceMutationPolicy,
        clusters: [IdentityCluster],
        persons: [Person],
        participantIDs: [PersonID] = []
    ) {
        self.meetingID = meetingID
        self.currentRunID = currentRunID
        self.voiceEvidenceMutationPolicy = voiceEvidenceMutationPolicy
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
    case ambiguousClusterAlias(channel: String, clusterID: String)
    case personNotFound(PersonID)
    case mixedClusterCannotBeNamed
    case selfClusterCannotBeNamed
    case noAssignmentToReassign
    case voiceEvidenceForbidden
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
        guard state.voiceEvidenceMutationPolicy == .allowed else {
            throw IdentityReviewError.voiceEvidenceForbidden
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
        try rebuildHardNegatives(
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

    /// Nimmt jede Zuordnung dieses Clusters zurueck und macht ihn wieder generisch.
    ///
    /// Anders als `keepGeneric`, das nur einen unbestaetigten Cluster als
    /// gesehen markiert, loest das hier eine bestehende Bestaetigung auf: die
    /// positive Evidenz des Clusters und aller seiner Fragmente wird
    /// ausgenommen, nie geloescht, und die abgeleiteten Negative werden
    /// danach neu aufgebaut.
    func resetToGeneric(
        clusterID: String,
        channel: String,
        runID: RunID,
        in state: IdentityReviewState
    ) throws -> IdentityReviewResult {
        guard runID == state.currentRunID else {
            return IdentityReviewResult(status: .stale, state: state)
        }
        guard state.voiceEvidenceMutationPolicy == .allowed else {
            throw IdentityReviewError.voiceEvidenceForbidden
        }
        var updated = state
        let index = try resolveClusterIndex(
            clusterID: clusterID,
            channel: channel,
            runID: runID,
            in: updated
        )
        let target = updated.clusters[index]
        // Auch die Fragmente: eine Bestaetigung kann unter dem Namen eines
        // zusammengefuehrten Teilclusters entstanden sein.
        let fragmentIDs = Set([target.clusterID] + target.mergedFrom)
        let previousOwners = removePositiveEvidence(
            clusterIDs: fragmentIDs,
            channel: channel,
            runID: runID,
            from: &updated
        )
        // Auch die Mehrfach-Markierung faellt: Zuruecksetzen nimmt jede
        // Aussage ueber diesen Cluster zurueck, nicht nur die Zuordnung. Was
        // danach steht, ist ein unbeurteilter Cluster, keine Behauptung.
        updated.clusters[index].containsMultipleSpeakers = false
        updated.clusters[index].reviewState = .generic
        removeParticipantsWithoutMeetingEvidence(previousOwners, from: &updated)
        try rebuildHardNegatives(
            meetingID: state.meetingID,
            runID: runID,
            channel: channel,
            in: &updated
        )
        return IdentityReviewResult(
            status: .generic,
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
        guard state.voiceEvidenceMutationPolicy == .allowed else {
            throw IdentityReviewError.voiceEvidenceForbidden
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
        try rebuildHardNegatives(
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
        let canonicalIndex = try CanonicalClusterIndex(
            clusters: state.clusters,
            meetingID: state.meetingID,
            runID: runID,
            channel: channel
        )
        guard let index = canonicalIndex.clusterIndex(for: clusterID) else {
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
        let excludedAt = Date()
        for index in state.persons.indices {
            var removedActiveEvidence = false
            for prototypeIndex in state.persons[index].prototypes.indices {
                guard state.persons[index].prototypes[prototypeIndex].isActive else {
                    continue
                }
                let prototype = state.persons[index].prototypes[prototypeIndex]
                guard prototype.meetingID == meetingID,
                      prototype.runID == runID,
                      prototype.channel == channel,
                      clusterIDs.contains(prototype.clusterID)
                else {
                    continue
                }
                state.persons[index].prototypes[prototypeIndex].excludedAt = excludedAt
                removedActiveEvidence = true
            }
            if removedActiveEvidence {
                owners.append(state.persons[index].id)
                state.persons[index].updatedAt = excludedAt
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
                .prototypes.contains {
                    $0.isActive && $0.meetingID == state.meetingID
                } ?? false
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
    ) throws {
        let canonicalIndex = try CanonicalClusterIndex(
            clusters: state.clusters,
            meetingID: meetingID,
            runID: runID,
            channel: channel
        )
        // Diese Funktion wirft die Negatives des Bereichs weg und leitet sie
        // neu ab. Ein Mensch kann ein Negativ aber ausgenommen haben, und das
        // ist eine Aussage ueber die Stimme, keine Ableitung: sie ueberlebt
        // den Neuaufbau. Ohne das haette ein Klick im Review die stillste
        // aller Ruecknahmen ausgeloest - ein wieder scharf gestelltes falsches
        // Negativ, das eine echte Erkennung dauerhaft unterdrueckt.
        var excludedBefore: [ExcludedNegativeKey: Date] = [:]
        for index in state.persons.indices {
            for negative in state.persons[index].hardNegatives {
                guard
                    negative.meetingID == meetingID,
                    negative.runID == runID,
                    negative.channel == channel,
                    let excludedAt = negative.excludedAt,
                    let canonicalClusterID = canonicalIndex.canonicalClusterID(
                        for: negative.clusterID
                    )
                else {
                    continue
                }
                // Ueber die kanonische ID: ein Negativ, das noch auf ein
                // Fragment zeigt, meint denselben zusammengefuehrten Cluster.
                let key = ExcludedNegativeKey(
                    personID: negative.personID,
                    meetingID: meetingID,
                    runID: runID,
                    channel: channel,
                    clusterID: canonicalClusterID
                )
                excludedBefore[key] = min(excludedBefore[key] ?? excludedAt, excludedAt)
            }
            state.persons[index].hardNegatives.removeAll {
                $0.meetingID == meetingID
                    && $0.runID == runID
                    && $0.channel == channel
            }
        }

        var clusterByID: [String: IdentityCluster] = [:]
        for cluster in canonicalIndex.clusters where
            !cluster.containsMultipleSpeakers && !cluster.isSelf {
            clusterByID[cluster.clusterID] = cluster
        }
        var ownedClusters: [PersonID: [IdentityCluster]] = [:]
        for person in state.persons {
            var seen: Set<String> = []
            for prototype in person.prototypes where
                prototype.isActive
                    && prototype.meetingID == meetingID
                    && prototype.runID == runID
                    && prototype.channel == channel {
                guard
                    let canonicalClusterID = canonicalIndex.canonicalClusterID(
                        for: prototype.clusterID
                    ),
                    seen.insert(canonicalClusterID).inserted
                else {
                    continue
                }
                if let cluster = clusterByID[canonicalClusterID] {
                    ownedClusters[person.id, default: []].append(cluster)
                }
            }
        }

        for ownerIndex in state.persons.indices {
            let ownerID = state.persons[ownerIndex].id
            var otherClustersByID: [String: IdentityCluster] = [:]
            for (personID, clusters) in ownedClusters where personID != ownerID {
                for cluster in clusters {
                    otherClustersByID[cluster.clusterID] = cluster
                }
            }
            let otherClusters = otherClustersByID.values.sorted {
                $0.clusterID < $1.clusterID
            }
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

/// Ordnet jeden Cluster-Alias eines Bereichs genau einem Cluster zu.
///
/// Ein zusammengefuehrter Cluster traegt seine Fragmente in `mergedFrom`, und
/// eine Korrektur kann unter jedem dieser Namen ankommen. Zeigt derselbe Alias
/// auf zwei Cluster, ist die Herkunft nicht mehr entscheidbar: dann liefert
/// diese Klasse lieber nichts als das Falsche.
///
/// Der Aufbau prueft den ganzen Bereich, nicht nur den angefragten Alias, und
/// verweigert danach auch eindeutige Anfragen. Das ist Absicht: widersprechen
/// sich zwei Cluster desselben Laufs ueber ihre Herkunft, ist der Lauf als
/// Ganzes nicht mehr vertrauenswuerdig, und der Neuaufbau der Negative liest
/// ohnehin den gesamten Bereich.
private struct CanonicalClusterIndex {
    let clusters: [IdentityCluster]
    private let indicesByAlias: [String: Int]
    private let originalIndices: [Int]

    init(
        clusters allClusters: [IdentityCluster],
        meetingID: MeetingID,
        runID: RunID,
        channel: String
    ) throws {
        var scoped: [IdentityCluster] = []
        var indices: [String: Int] = [:]
        var sourceIndices: [Int] = []

        for (sourceIndex, cluster) in allClusters.enumerated() where
            cluster.meetingID == meetingID
                && cluster.runID == runID
                && cluster.channel == channel {
            let scopedIndex = scoped.count
            scoped.append(cluster)
            sourceIndices.append(sourceIndex)
            for alias in Set([cluster.clusterID] + cluster.mergedFrom) {
                if let existing = indices[alias], existing != scopedIndex {
                    throw IdentityReviewError.ambiguousClusterAlias(
                        channel: channel,
                        clusterID: alias
                    )
                }
                indices[alias] = scopedIndex
            }
        }

        clusters = scoped
        indicesByAlias = indices
        originalIndices = sourceIndices
    }

    func clusterIndex(for alias: String) -> Int? {
        indicesByAlias[alias].map { originalIndices[$0] }
    }

    func canonicalClusterID(for alias: String) -> String? {
        indicesByAlias[alias].map { clusters[$0].clusterID }
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
