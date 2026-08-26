import Foundation
import StenoDomain

/// One unconfirmed cross-meeting match: a cluster from another meeting whose
/// distance to the person's active prototypes cleared the possible gate.
public struct CrossMeetingSuggestion: Identifiable, Equatable, Sendable {
    public let personID: PersonID
    /// Provenance of the evidence pair. The dismissal below is scoped to
    /// exactly this meeting/run pair, never to the person as a whole.
    public let meetingID: MeetingID
    public let runID: RunID
    public let cluster: IdentityCluster
    public let distance: Float

    public var id: String {
        "\(personID)/\(meetingID)/\(runID)/\(cluster.channel)/\(cluster.clusterID)"
    }

    public init(
        personID: PersonID,
        meetingID: MeetingID,
        runID: RunID,
        cluster: IdentityCluster,
        distance: Float
    ) {
        self.personID = personID
        self.meetingID = meetingID
        self.runID = runID
        self.cluster = cluster
        self.distance = distance
    }
}

/// Surfaces the matches recognition found but a human never confirmed.
///
/// The gates themselves are NOT redefined here: the union of all meetings'
/// current-run clusters goes through the unchanged `SpeakerSuggestionEngine`,
/// and every suggestion it rates better than `.none` is surfaced per person.
/// A dismissed suggestion stores an active hard negative carrying that exact
/// meeting/run provenance - the same shape `rebuildHardNegatives` derives -
/// so it suppresses this voice for this person wherever that is acoustically
/// justified while remaining reversible through the usual exclude toggle.
public enum CrossMeetingSuggestionScanner {

    /// Current-run clusters of one meeting. Callers obtain these from the
    /// review assembler, which already enforces run provenance: only clusters
    /// of the latest finished identity-suggestion run are handed over, and
    /// persisted review states are overlaid onto them.
    public struct MeetingClusters: Sendable {
        public let meetingID: MeetingID
        public let clusters: [IdentityCluster]

        public init(meetingID: MeetingID, clusters: [IdentityCluster]) {
            self.meetingID = meetingID
            self.clusters = clusters
        }
    }

    public static func suggestions(
        clustersByMeeting: [MeetingClusters],
        people: [Person],
        engine: SpeakerSuggestionEngine = SpeakerSuggestionEngine()
    ) -> [CrossMeetingSuggestion] {
        let allClusters = clustersByMeeting.flatMap(\.clusters)
        guard !allClusters.isEmpty else { return [] }
        // The engine returns exactly one suggestion per input cluster in input
        // order, so the pairs line up without re-keying.
        let rated = zip(allClusters, engine.suggestions(for: allClusters, people: people))

        var output: [CrossMeetingSuggestion] = []
        for (cluster, suggestion) in rated {
            // Unconfirmed means unreviewed or left generic. A cluster a human
            // already assigned - or one marked stale by a newer run - is not
            // an open question anymore, and "multiple speakers" has no single
            // answer to confirm.
            switch cluster.reviewState {
            case .unreviewed, .generic:
                break
            case .confirmed, .stale, .multiple:
                continue
            }
            guard !cluster.isSelf, !cluster.containsMultipleSpeakers else { continue }
            guard suggestion.status != .none,
                  let personID = suggestion.suggestedPersonID,
                  let best = suggestion.candidates.first(where: { $0.personID == personID })
            else { continue }
            if let person = people.first(where: { $0.id == personID }),
               isDismissed(suggestion: suggestion, person: person) {
                continue
            }
            output.append(CrossMeetingSuggestion(
                personID: personID,
                meetingID: cluster.meetingID,
                runID: cluster.runID,
                cluster: cluster,
                distance: best.distance
            ))
        }
        return output
    }

    /// True when this meeting/run pair was explicitly dismissed before. Only
    /// *active* negatives count: excluding the negative in the voice profile
    /// reverses the dismissal, and a read that ignored exclusions would
    /// contradict the write path there.
    public static func isDismissed(
        suggestion: ClusterSuggestion,
        person: Person
    ) -> Bool {
        isDismissed(
            meetingID: suggestion.meetingID,
            runID: suggestion.runID,
            channel: suggestion.channel,
            clusterID: suggestion.clusterID,
            person: person
        )
    }

    public static func isDismissed(
        suggestion: CrossMeetingSuggestion,
        person: Person
    ) -> Bool {
        isDismissed(
            meetingID: suggestion.meetingID,
            runID: suggestion.runID,
            channel: suggestion.cluster.channel,
            clusterID: suggestion.cluster.clusterID,
            person: person
        )
    }

    private static func isDismissed(
        meetingID: MeetingID,
        runID: RunID,
        channel: String,
        clusterID: String,
        person: Person
    ) -> Bool {
        person.hardNegatives.contains { negative in
            negative.isActive
                && negative.meetingID == meetingID
                && negative.runID == runID
                && negative.channel == channel
                && negative.clusterID == clusterID
        }
    }

    /// The hard negative that records a dismissal. It carries the full
    /// provenance of the dismissed evidence pair so a human can find - and
    /// reverse - the verdict in the voice profile. Suppression itself follows
    /// the ordinary hard-negative rule: it applies wherever this voice scores
    /// acoustically close, exactly like the negatives derived from meeting
    /// confirmations.
    public static func dismissalNegative(
        for suggestion: CrossMeetingSuggestion,
        at date: Date = Date()
    ) -> HardNegative {
        HardNegative(
            personID: suggestion.personID,
            embedding: suggestion.cluster.embedding,
            recordingType: suggestion.cluster.recordingType,
            channel: suggestion.cluster.channel,
            meetingID: suggestion.meetingID,
            runID: suggestion.runID,
            clusterID: suggestion.cluster.clusterID,
            speechDurationSeconds: suggestion.cluster.speechDurationSeconds,
            segmentCount: suggestion.cluster.segmentCount,
            source: .userConfirmed,
            createdAt: date
        )
    }
}
