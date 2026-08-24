import Foundation
import StenoDomain
import StenoIdentity
import StenoPipeline

/// Pure policy for the speaker controls shown in the iOS inspector.
///
/// It deliberately differs from the Mac's current lower-confidence shortcut:
/// a possible match stays visible as a guess but never becomes a one-tap
/// confirmation.
enum SpeakerReviewPresentation {
    enum Action: Equatable, Sendable {
        case confirmSuggestion
        case assignPerson
        case reassignPerson
        case createPerson
        case markMultiple
        case keepGeneric
        case resetToGeneric
    }

    static func shouldShowSection(
        hasReview: Bool,
        error: String?
    ) -> Bool {
        hasReview || error != nil
    }

    static func actions(
        for cluster: IdentityCluster,
        suggestion: ClusterSuggestion?,
        persons: [Person] = [],
        evidenceMutationIsAllowed: Bool = true
    ) -> [Action] {
        guard !cluster.isSelf else { return [] }
        // `keepGeneric` changes only local review state. It is the one
        // review choice that deliberately creates no positive or negative
        // voice evidence and remains safe for bundled demo audio.
        guard evidenceMutationIsAllowed else { return [.keepGeneric] }
        if cluster.containsMultipleSpeakers || cluster.reviewState == .multiple {
            return [.resetToGeneric]
        }

        if case .confirmed = cluster.reviewState {
            return [.reassignPerson, .resetToGeneric]
        }

        var result: [Action] = []
        if suggestion?.status == .confirmed,
           let personID = suggestion?.suggestedPersonID,
           persons.contains(where: { $0.id == personID }) {
            result.append(.confirmSuggestion)
        }
        result.append(contentsOf: [
            .assignPerson,
            .createPerson,
            .markMultiple,
            .keepGeneric,
        ])
        return result
    }

    static let demoExplanation: LocalizedStringResource? = "Demo audio cannot create or change real voice profiles."

    static func suggestion(
        for cluster: IdentityCluster,
        in suggestions: [ClusterSuggestion],
        reviewRunID: RunID
    ) -> ClusterSuggestion? {
        guard cluster.runID == reviewRunID else { return nil }
        return suggestions.first {
            $0.meetingID == cluster.meetingID
                && $0.runID == reviewRunID
                && normalizedChannel($0.channel)
                    == normalizedChannel(cluster.channel)
                && $0.clusterID == cluster.clusterID
        }
    }

    /// A persisted suggestion may outlive the person it named. Keeping the
    /// caption is harmless, but one-tap confirmation is only truthful while
    /// that exact PersonID still exists in the current review snapshot.
    static func actionableSuggestion(
        _ suggestion: ClusterSuggestion?,
        persons: [Person]
    ) -> ClusterSuggestion? {
        guard suggestion?.status == .confirmed,
              let personID = suggestion?.suggestedPersonID,
              persons.contains(where: { $0.id == personID })
        else { return nil }
        return suggestion
    }

    static func suggestionLabel(
        _ suggestion: ClusterSuggestion?
    ) -> LocalizedStringResource? {
        guard suggestion?.status == .possible,
              let name = suggestion?.suggestedName else { return nil }
        return "Maybe \(name)"
    }

    static func controllerAction(
        for action: Action,
        personID: PersonID?,
        newPersonName: String?
    ) -> MeetingReviewController.Action? {
        switch action {
        case .confirmSuggestion, .assignPerson:
            guard let personID else { return nil }
            return .confirm(personID: personID)
        case .reassignPerson:
            guard let personID else { return nil }
            return .reassign(personID: personID)
        case .createPerson:
            let name = (newPersonName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return .confirmAsNewPerson(name: name)
        case .markMultiple:
            return .markMultiple
        case .keepGeneric:
            return .keepGeneric
        case .resetToGeneric:
            return .resetToGeneric
        }
    }

    private static func normalizedChannel(_ channel: String) -> String {
        switch channel {
        case "mic", MediaAsset.Kind.micTrack.rawValue:
            MediaAsset.Kind.micTrack.rawValue
        case "system", MediaAsset.Kind.systemTrack.rawValue:
            MediaAsset.Kind.systemTrack.rawValue
        default:
            channel
        }
    }
}
