import Foundation
import StenoDomain
import StenoIdentity

public struct SpeakerPresentation: Equatable, Sendable {
    public let label: String?
    public let labelKind: SpeakerLabelKind
    public let marker: SpeakerMarker?
    public let channel: String?
    public let originCue: String?

    public init(
        label: String?,
        labelKind: SpeakerLabelKind = .verbatim,
        marker: SpeakerMarker?,
        channel: String?,
        originCue: String? = nil
    ) {
        self.label = label
        self.labelKind = labelKind
        self.marker = marker
        self.channel = channel
        self.originCue = originCue
    }
}

/// Describes where a visible speaker label came from without making the apps
/// infer semantics from a user-visible string.
public enum SpeakerLabelKind: Equatable, Sendable {
    case verbatim
    case me
    case others
    case unknown
    case namedPerson
    case multiplePeople
    case probablePerson(String)
    case generic(number: Int?, identifier: String, source: SpeakerLabelSource)
}

public enum SpeakerLabelSource: Equatable, Sendable {
    case none
    case microphone
    case system
}

public enum SpeakerMarker: Equatable, Sendable {
    case person(PersonID)
    case unconfirmedRank(Int)
}

/// Expliziter Zusammenhang zwischen einem im Cluster-Identifier verwendeten
/// Namespace und dem Kanal der zugehoerigen Originalspur. Unbekannte
/// Namespaces werden absichtlich nicht aus ihrer Textform erraten.
public struct SpeakerPresentationContext: Equatable, Sendable {
    public static let empty = SpeakerPresentationContext(channelsByNamespace: [:])

    private let channelsByNamespace: [String: String]

    public init(channelsByNamespace: [String: String]) {
        self.channelsByNamespace = channelsByNamespace
    }

    fileprivate func channel(forNamespace namespace: String) -> String? {
        channelsByNamespace[namespace].map(SpeakerClusterKey.normalizedChannel)
    }
}

public enum SpeakerPresentationResolver {
    public static func presentation(
        for reference: SpeakerReference?,
        review: MeetingReviewData?,
        context: SpeakerPresentationContext = .empty
    ) -> SpeakerPresentation {
        guard let reference else {
            return SpeakerPresentation(label: nil, marker: nil, channel: nil)
        }

        switch reference {
        case .channel(let label):
            let kind: SpeakerLabelKind = switch label {
            case "Ich": .me
            case "Andere": .others
            default: .verbatim
            }
            return SpeakerPresentation(
                label: ChannelLabel.speakerLabel(label),
                labelKind: kind,
                marker: nil,
                channel: label
            )
        case .person(let personID):
            let name = review?.persons.first { $0.id == personID }?.displayName
            return SpeakerPresentation(
                label: name ?? "Named person",
                labelKind: name == nil ? .namedPerson : .verbatim,
                marker: .person(personID),
                channel: nil
            )
        case .importedTextLabel(let imported):
            let text = imported.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeakerPresentation(
                label: imported.wasConfirmedAtSource && !text.isEmpty
                    ? text
                    : "Unknown speaker",
                labelKind: imported.wasConfirmedAtSource && !text.isEmpty
                    ? .verbatim
                    : .unknown,
                marker: nil,
                channel: nil,
                originCue: "Imported text label - not a locally confirmed identity"
            )
        case .cluster(let runID, let clusterID):
            let key = SpeakerClusterKey(clusterID: clusterID, context: context)
            guard let review, runID == review.runID,
                  let cluster = review.resolvedCluster(channel: key.channel, clusterID: key.clusterID)
            else {
                return generic(clusterID: key.clusterID, channel: key.channel)
            }
            return resolvedPresentation(for: cluster, review: review)
        }
    }

    public static func presentation(
        for cluster: IdentityCluster,
        review: MeetingReviewData
    ) -> SpeakerPresentation {
        guard cluster.runID == review.runID else {
            return generic(clusterID: SpeakerClusterKey(clusterID: cluster.clusterID).clusterID,
                           channel: SpeakerClusterKey.normalizedChannel(cluster.channel))
        }
        let resolved = review.resolvedCluster(
            channel: SpeakerClusterKey.normalizedChannel(cluster.channel),
            clusterID: SpeakerClusterKey(clusterID: cluster.clusterID).clusterID
        ) ?? cluster
        return resolvedPresentation(for: resolved, review: review)
    }

    private static func resolvedPresentation(
        for cluster: IdentityCluster,
        review: MeetingReviewData
    ) -> SpeakerPresentation {
        let channel = SpeakerClusterKey.normalizedChannel(cluster.channel)
        let clusterID = SpeakerClusterKey(clusterID: cluster.clusterID).clusterID

        if cluster.containsMultipleSpeakers || cluster.reviewState == .multiple {
            return SpeakerPresentation(
                label: "Multiple people",
                labelKind: .multiplePeople,
                marker: nil,
                channel: channel
            )
        }

        switch cluster.reviewState {
        case .confirmed(let personID):
            let name = review.persons.first { $0.id == personID }?.displayName
            return SpeakerPresentation(
                label: name ?? "Named person",
                labelKind: name == nil ? .namedPerson : .verbatim,
                marker: .person(personID),
                channel: channel
            )
        case .stale(let personID):
            guard let name = review.persons.first(where: { $0.id == personID })?.displayName else {
                return generic(clusterID: clusterID, channel: channel)
            }
            return SpeakerPresentation(label: "\(name)?", marker: .person(personID), channel: channel)
        case .generic, .unreviewed:
            let suggestedName = review.suggestions.first {
                $0.runID == review.runID
                    && SpeakerClusterKey.normalizedChannel($0.channel) == channel
                    && SpeakerClusterKey(clusterID: $0.clusterID).clusterID == clusterID
                    && $0.status == .confirmed
            }?.suggestedName
            if let suggestedName {
                return SpeakerPresentation(
                    label: "Probably \(suggestedName)",
                    labelKind: .probablePerson(suggestedName),
                    marker: unconfirmedMarker(for: cluster, review: review),
                    channel: channel
                )
            }
            let generic = generic(clusterID: clusterID, channel: channel)
            return SpeakerPresentation(
                label: generic.label,
                labelKind: generic.labelKind,
                marker: unconfirmedMarker(for: cluster, review: review),
                channel: channel
            )
        case .multiple:
            return SpeakerPresentation(
                label: "Multiple people",
                labelKind: .multiplePeople,
                marker: nil,
                channel: channel
            )
        }
    }

    private static func unconfirmedMarker(
        for cluster: IdentityCluster,
        review: MeetingReviewData
    ) -> SpeakerMarker? {
        let ranked = review.clusters
            .filter {
                $0.runID == review.runID
                    && !$0.isSelf
                    && !$0.containsMultipleSpeakers
                    && $0.reviewState != .multiple
            }
            .sorted { $0.speechDurationSeconds > $1.speechDurationSeconds }
        guard let rank = ranked.firstIndex(where: {
            SpeakerClusterKey.normalizedChannel($0.channel)
                == SpeakerClusterKey.normalizedChannel(cluster.channel)
                && SpeakerClusterKey(clusterID: $0.clusterID).clusterID
                == SpeakerClusterKey(clusterID: cluster.clusterID).clusterID
        }) else {
            return nil
        }
        return .unconfirmedRank(rank)
    }

    private static func generic(clusterID: String, channel: String?) -> SpeakerPresentation {
        let number = clusterID
            .split(separator: "_")
            .last
            .flatMap { Int($0) }
            .map { $0 + 1 }
        let base = number.map { "Speaker \($0)" } ?? clusterID
        let label: String
        let source: SpeakerLabelSource
        switch channel {
        case MediaAsset.Kind.micTrack.rawValue:
            label = "\(base) (microphone)"
            source = .microphone
        case MediaAsset.Kind.systemTrack.rawValue:
            label = "\(base) (system)"
            source = .system
        default:
            label = base
            source = .none
        }
        return SpeakerPresentation(
            label: label,
            labelKind: .generic(number: number, identifier: clusterID, source: source),
            marker: nil,
            channel: channel
        )
    }
}

struct SpeakerClusterKey {
    let channel: String?
    let clusterID: String

    init(
        clusterID: String,
        context: SpeakerPresentationContext = .empty
    ) {
        let parts = clusterID.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2, let channel = Self.inferredChannel(parts[0]) {
            self.channel = channel
            self.clusterID = parts[1]
        } else if parts.count == 2,
                  let channel = context.channel(forNamespace: parts[0]) {
            self.channel = channel
            // Produktionscluster tragen den MediaAsset-Namespace auch im
            // Review-Schluessel. Nur der Kanal wird aus dem expliziten Kontext
            // ergaenzt; die Identifier-Form bleibt unveraendert.
            self.clusterID = clusterID
        } else {
            self.channel = nil
            self.clusterID = clusterID
        }
    }

    static func inferredChannel(_ value: String) -> String? {
        switch value {
        case "mic", MediaAsset.Kind.micTrack.rawValue:
            return MediaAsset.Kind.micTrack.rawValue
        case "system", MediaAsset.Kind.systemTrack.rawValue:
            return MediaAsset.Kind.systemTrack.rawValue
        default:
            return nil
        }
    }

    static func normalizedChannel(_ value: String) -> String {
        inferredChannel(value) ?? value
    }

    static func hasOpaqueNamespace(_ clusterID: String) -> Bool {
        guard let separator = clusterID.firstIndex(of: "/") else { return false }
        guard separator != clusterID.startIndex,
              clusterID.index(after: separator) != clusterID.endIndex
        else { return false }
        let namespace = String(clusterID[..<separator])
        guard inferredChannel(namespace) == nil else { return false }
        return UUID(uuidString: namespace) != nil
    }
}

extension MeetingReviewData {
    func resolvedCluster(for reference: SpeakerReference) -> IdentityCluster? {
        guard case .cluster(let runID, let clusterID) = reference,
              runID == self.runID
        else { return nil }
        let key = SpeakerClusterKey(clusterID: clusterID)
        return resolvedCluster(channel: key.channel, clusterID: key.clusterID)
    }

    func resolvedCluster(channel: String?, clusterID: String) -> IdentityCluster? {
        let matches = clusters.filter {
            $0.runID == runID
                && SpeakerClusterKey(clusterID: $0.clusterID).clusterID == clusterID
        }
        let resolutionMatches = resolutions.filter {
            SpeakerClusterKey(clusterID: $0.sourceClusterID).clusterID == clusterID
        }
        let channels = Set(
            matches.map { SpeakerClusterKey.normalizedChannel($0.channel) }
                + resolutionMatches.map { SpeakerClusterKey.normalizedChannel($0.channel) }
        )
        let resolvedChannel: String?
        if let channel {
            resolvedChannel = channel
        } else {
            guard channels.count == 1 else { return nil }
            resolvedChannel = channels.first
        }
        if let resolution = resolutionMatches.first(where: {
            SpeakerClusterKey.normalizedChannel($0.channel) == resolvedChannel
        }) {
            let primaryID = SpeakerClusterKey(clusterID: resolution.primaryClusterID).clusterID
            return clusters.first {
                $0.runID == runID
                    && SpeakerClusterKey.normalizedChannel($0.channel) == resolvedChannel
                    && SpeakerClusterKey(clusterID: $0.clusterID).clusterID == primaryID
            }
        }
        return matches.first {
            SpeakerClusterKey.normalizedChannel($0.channel) == resolvedChannel
        }
    }
}
