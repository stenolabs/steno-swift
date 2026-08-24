import Foundation
import StenoDomain

private enum IdentityThresholds {
    // Cross-meeting speaker embeddings at cosine distance above 0.40 were
    // not reliable enough in the existing library, so they are not surfaced.
    static let suggestionDistance: Float = 0.40

    // The best person must lead the runner-up by 0.10. Same-room microphone
    // bias otherwise turns two plausible people into an arbitrary winner.
    static let confidenceMargin: Float = 0.10

    // At least 20 seconds of speech is required because short enrollment
    // samples were too sensitive to noise and incidental overlap.
    static let minimumDurationSeconds: TimeInterval = 20

    // Three separate turns are the minimum evidence that a centroid is not
    // dominated by one anomalous utterance.
    static let minimumSegmentCount = 3

    // False echo and crosstalk clusters in the measured library topped out at
    // 1.525 seconds per turn, while the weakest genuine anchor was 1.61.
    static let minimumAverageTurnSeconds: TimeInterval = 1.55

    // Two distinct meetings prove cross-session generalization. Multiple
    // fragments confirmed in one meeting are still only one acoustic sample.
    static let minimumConfirmedMeetings = 2

    // A hard negative is relevant only on the same conservative 0.40 scale as
    // a positive candidate. More distant voices are ordinary non-matches.
    static let hardNegativeDistance: Float = 0.40

    // Same-channel fragments share one recording fingerprint. Measured true
    // fragments were 0.02 to 0.07 apart, while the closest different people
    // were 0.11 apart, leaving 0.10 as the deliberately strict merge boundary.
    static let sameChannelMergeDistance: Float = 0.10
}

public struct IdentityClusterKey: Hashable, Sendable {
    public let meetingID: MeetingID
    public let runID: RunID
    public let channel: String
    public let clusterID: String

    public init(
        meetingID: MeetingID,
        runID: RunID,
        channel: String,
        clusterID: String
    ) {
        self.meetingID = meetingID
        self.runID = runID
        self.channel = channel
        self.clusterID = clusterID
    }

    public init(_ cluster: IdentityCluster) {
        self.init(
            meetingID: cluster.meetingID,
            runID: cluster.runID,
            channel: cluster.channel,
            clusterID: cluster.clusterID
        )
    }
}

public struct FragmentMergeResult: Equatable, Sendable {
    public let clusters: [IdentityCluster]
    public let resolution: [IdentityClusterKey: IdentityClusterKey]

    public init(
        clusters: [IdentityCluster],
        resolution: [IdentityClusterKey: IdentityClusterKey]
    ) {
        self.clusters = clusters
        self.resolution = resolution
    }

    public func primaryKey(for cluster: IdentityCluster) -> IdentityClusterKey? {
        resolution[IdentityClusterKey(cluster)]
    }
}

public func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float? {
    guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
    var dot: Float = 0
    var lhsSquared: Float = 0
    var rhsSquared: Float = 0
    for index in lhs.indices {
        dot += lhs[index] * rhs[index]
        lhsSquared += lhs[index] * lhs[index]
        rhsSquared += rhs[index] * rhs[index]
    }
    guard lhsSquared > 1e-12, rhsSquared > 1e-12 else { return nil }
    let similarity = max(-1, min(1, dot / (lhsSquared * rhsSquared).squareRoot()))
    return 1 - similarity
}

public struct SpeakerSuggestionEngine: Sendable {
    public init() {}

    public func suggestions(
        for clusters: [IdentityCluster],
        people: [Person]
    ) -> [ClusterSuggestion] {
        let ordered = clusters.sorted { lhs, rhs in
            let lhsDistance = bestDistance(for: lhs, people: people)
            let rhsDistance = bestDistance(for: rhs, people: people)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.channel != rhs.channel { return lhs.channel < rhs.channel }
            return lhs.clusterID < rhs.clusterID
        }

        var usedPersonIDs: Set<PersonID> = []
        var byKey: [IdentityClusterKey: ClusterSuggestion] = [:]
        for cluster in ordered {
            let available = people.filter { !usedPersonIDs.contains($0.id) }
            let suggestion = suggestion(for: cluster, people: available)
            if suggestion.status == .confirmed,
               let personID = suggestion.suggestedPersonID {
                usedPersonIDs.insert(personID)
            }
            byKey[IdentityClusterKey(cluster)] = suggestion
        }
        return clusters.compactMap { byKey[IdentityClusterKey($0)] }
    }

    public func mergeSameChannelFragments(
        _ clusters: [IdentityCluster]
    ) -> FragmentMergeResult {
        struct Scope: Hashable {
            let meetingID: MeetingID
            let runID: RunID
            let channel: String
        }

        let grouped = Dictionary(grouping: clusters) {
            Scope(meetingID: $0.meetingID, runID: $0.runID, channel: $0.channel)
        }
        var merged: [IdentityCluster] = []
        var resolution: [IdentityClusterKey: IdentityClusterKey] = [:]

        for group in grouped.values {
            let groupResult = mergeOneScope(group)
            merged.append(contentsOf: groupResult.clusters)
            resolution.merge(groupResult.resolution) { _, new in new }
        }
        merged.sort {
            if $0.meetingID != $1.meetingID { return $0.meetingID < $1.meetingID }
            if $0.runID != $1.runID { return $0.runID < $1.runID }
            if $0.channel != $1.channel { return $0.channel < $1.channel }
            return $0.clusterID < $1.clusterID
        }
        return FragmentMergeResult(clusters: merged, resolution: resolution)
    }

    private func bestDistance(
        for cluster: IdentityCluster,
        people: [Person]
    ) -> Float {
        guard !cluster.containsMultipleSpeakers, !cluster.isSelf else {
            return .infinity
        }
        return candidates(for: cluster, people: people).first?.distance ?? .infinity
    }

    private func suggestion(
        for cluster: IdentityCluster,
        people: [Person]
    ) -> ClusterSuggestion {
        if cluster.isSelf {
            return emptySuggestion(
                for: cluster,
                reason: "self is outside named-speaker identification"
            )
        }
        if cluster.containsMultipleSpeakers {
            return emptySuggestion(
                for: cluster,
                reason: "human marked the cluster as containing multiple speakers"
            )
        }

        let ranked = candidates(for: cluster, people: people)
        guard let best = ranked.first else {
            return emptySuggestion(for: cluster, reason: "no usable person evidence")
        }
        if best.hardNegativeConflict {
            return ClusterSuggestion(
                meetingID: cluster.meetingID,
                runID: cluster.runID,
                channel: cluster.channel,
                clusterID: cluster.clusterID,
                status: .none,
                suggestedPersonID: nil,
                suggestedName: nil,
                candidates: ranked,
                reasons: ["relative hard-negative conflict"]
            )
        }
        guard best.distance <= IdentityThresholds.suggestionDistance else {
            return ClusterSuggestion(
                meetingID: cluster.meetingID,
                runID: cluster.runID,
                channel: cluster.channel,
                clusterID: cluster.clusterID,
                status: .none,
                suggestedPersonID: nil,
                suggestedName: nil,
                candidates: ranked,
                reasons: ["best distance exceeds 0.40"]
            )
        }

        let runnerUpDistance = ranked.dropFirst().first?.distance ?? .infinity
        let averageTurn = cluster.segmentCount > 0
            ? cluster.speechDurationSeconds / Double(cluster.segmentCount)
            : 0
        let clearsMargin = runnerUpDistance - best.distance >= IdentityThresholds.confidenceMargin
        let stable = cluster.speechDurationSeconds >= IdentityThresholds.minimumDurationSeconds
            && cluster.segmentCount >= IdentityThresholds.minimumSegmentCount
            && averageTurn >= IdentityThresholds.minimumAverageTurnSeconds
        let enoughMeetings = best.confirmedMeetingCount >= IdentityThresholds.minimumConfirmedMeetings
        let status: ClusterSuggestion.Status = clearsMargin && stable && enoughMeetings
            ? .confirmed
            : .possible

        return ClusterSuggestion(
            meetingID: cluster.meetingID,
            runID: cluster.runID,
            channel: cluster.channel,
            clusterID: cluster.clusterID,
            status: status,
            suggestedPersonID: best.personID,
            suggestedName: best.displayName,
            candidates: ranked,
            reasons: reasons(
                clearsMargin: clearsMargin,
                stable: stable,
                enoughMeetings: enoughMeetings
            )
        )
    }

    private func candidates(
        for cluster: IdentityCluster,
        people: [Person]
    ) -> [SpeakerCandidate] {
        people.compactMap { person -> SpeakerCandidate? in
            // Ausgenommene Evidenz faellt vor jeder Auswertung heraus, damit
            // sie weder als Kandidat noch als Sperre wirkt und auch nicht
            // stillschweigend die Zahl der bestaetigten Meetings aufblaeht.
            let active = person.prototypes.filter(\.isActive)
            let sameContext = active.filter {
                $0.recordingType == cluster.recordingType
            }
            let pool = sameContext.isEmpty ? active : sameContext
            let positiveDistances = pool.compactMap {
                cosineDistance(cluster.embedding, $0.embedding)
            }
            guard let distance = positiveDistances.min() else { return nil }
            let negativeDistance = person.hardNegatives.filter(\.isActive).compactMap {
                cosineDistance(cluster.embedding, $0.embedding)
            }.min()
            let conflict = negativeDistance.map {
                $0 <= IdentityThresholds.hardNegativeDistance
                    && $0 < distance + IdentityThresholds.confidenceMargin
            } ?? false
            return SpeakerCandidate(
                personID: person.id,
                displayName: person.displayName,
                distance: distance,
                hardNegativeConflict: conflict,
                confirmedMeetingCount: Set(pool.compactMap(\.meetingID)).count,
                negativeDistance: negativeDistance
            )
        }.sorted {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.personID < $1.personID
        }
    }

    private func emptySuggestion(
        for cluster: IdentityCluster,
        reason: String
    ) -> ClusterSuggestion {
        ClusterSuggestion(
            meetingID: cluster.meetingID,
            runID: cluster.runID,
            channel: cluster.channel,
            clusterID: cluster.clusterID,
            status: .none,
            suggestedPersonID: nil,
            suggestedName: nil,
            reasons: [reason]
        )
    }

    private func reasons(
        clearsMargin: Bool,
        stable: Bool,
        enoughMeetings: Bool
    ) -> [String] {
        var reasons: [String] = []
        if !clearsMargin { reasons.append("margin below 0.10") }
        if !stable { reasons.append("duration, turn count, or average turn gate failed") }
        if !enoughMeetings { reasons.append("fewer than two distinct confirmed meetings") }
        return reasons
    }

    private func mergeOneScope(
        _ clusters: [IdentityCluster]
    ) -> FragmentMergeResult {
        guard !clusters.isEmpty else {
            return FragmentMergeResult(clusters: [], resolution: [:])
        }
        var parents = Array(clusters.indices)

        func root(_ index: Int, parents: inout [Int]) -> Int {
            var current = index
            while parents[current] != current {
                parents[current] = parents[parents[current]]
                current = parents[current]
            }
            return current
        }

        for left in clusters.indices {
            for right in clusters.indices where right > left {
                guard let distance = cosineDistance(
                    clusters[left].embedding,
                    clusters[right].embedding
                ), distance <= IdentityThresholds.sameChannelMergeDistance else {
                    continue
                }
                let leftRoot = root(left, parents: &parents)
                let rightRoot = root(right, parents: &parents)
                guard leftRoot != rightRoot else { continue }

                var leftMembers: [Int] = []
                var rightMembers: [Int] = []
                for index in clusters.indices {
                    let indexRoot = root(index, parents: &parents)
                    if indexRoot == leftRoot {
                        leftMembers.append(index)
                    } else if indexRoot == rightRoot {
                        rightMembers.append(index)
                    }
                }
                let completeLink = leftMembers.allSatisfy { leftIndex in
                    rightMembers.allSatisfy { rightIndex in
                        guard let distance = cosineDistance(
                            clusters[leftIndex].embedding,
                            clusters[rightIndex].embedding
                        ) else {
                            return false
                        }
                        return distance <= IdentityThresholds.sameChannelMergeDistance
                    }
                }
                if completeLink { parents[leftRoot] = rightRoot }
            }
        }

        var components: [Int: [IdentityCluster]] = [:]
        for index in clusters.indices {
            components[root(index, parents: &parents), default: []].append(clusters[index])
        }

        var output: [IdentityCluster] = []
        var resolution: [IdentityClusterKey: IdentityClusterKey] = [:]
        for members in components.values {
            let primary = members.sorted {
                if $0.speechDurationSeconds != $1.speechDurationSeconds {
                    return $0.speechDurationSeconds > $1.speechDurationSeconds
                }
                return $0.clusterID < $1.clusterID
            }[0]
            let primaryKey = IdentityClusterKey(primary)
            for member in members {
                resolution[IdentityClusterKey(member)] = primaryKey
            }
            guard members.count > 1 else {
                output.append(primary)
                continue
            }

            let totalDuration = members.reduce(0) { $0 + $1.speechDurationSeconds }
            var weighted = Array(repeating: Float(0), count: primary.embedding.count)
            for member in members {
                let weight = Float(totalDuration > 0 ? member.speechDurationSeconds : 1)
                for index in weighted.indices {
                    weighted[index] += member.embedding[index] * weight
                }
            }
            let norm = weighted.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if norm > 1e-9 { weighted = weighted.map { $0 / norm } }
            let mergedFrom = Set(members.flatMap { member in
                member.clusterID == primary.clusterID
                    ? member.mergedFrom
                    : [member.clusterID] + member.mergedFrom
            }).sorted()
            let mixed = members.contains { $0.containsMultipleSpeakers }
            let reviewState: IdentityCluster.ReviewState
            if mixed {
                reviewState = .multiple
            } else if members.contains(where: { $0.reviewState == .generic }) {
                reviewState = .generic
            } else {
                reviewState = primary.reviewState
            }
            output.append(IdentityCluster(
                meetingID: primary.meetingID,
                runID: primary.runID,
                channel: primary.channel,
                clusterID: primary.clusterID,
                recordingType: primary.recordingType,
                embedding: weighted,
                speechDurationSeconds: totalDuration,
                segmentCount: members.reduce(0) { $0 + $1.segmentCount },
                mergedFrom: mergedFrom,
                containsMultipleSpeakers: mixed,
                reviewState: reviewState,
                isSelf: members.contains { $0.isSelf }
            ))
        }
        output.sort { $0.clusterID < $1.clusterID }
        return FragmentMergeResult(clusters: output, resolution: resolution)
    }
}
