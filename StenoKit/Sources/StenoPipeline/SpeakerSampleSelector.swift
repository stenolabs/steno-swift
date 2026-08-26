import Foundation
import StenoDiarization
import StenoDomain
import StenoIdentity

/// Ein anhörbarer Beleg für einen Sprecher-Cluster: Zitat plus Zeitbereich
/// in der Originalspur. Text und Audio stammen aus demselben Turn, die
/// Paarung kann also nicht auseinanderlaufen (anders als im Altsystem, wo
/// ein positionsgebundenes Manifest Transkriptzeilen und Cluster verband).
public struct SpeakerSample: Equatable, Sendable, Identifiable {
    public let turnStart: TimeInterval
    public let clipStart: TimeInterval
    public let clipEnd: TimeInterval
    public let text: String
    public let channel: String

    public var id: Double { turnStart }
    public var duration: TimeInterval { clipEnd - clipStart }

    public init(
        turnStart: TimeInterval,
        clipStart: TimeInterval,
        clipEnd: TimeInterval,
        text: String,
        channel: String
    ) {
        self.turnStart = turnStart
        self.clipStart = clipStart
        self.clipEnd = clipEnd
        self.text = text
        self.channel = channel
    }
}

public enum SpeakerSampleSelector {
    /// Auswahlregeln aus dem Altsystem (dort an echten Bibliotheken geeicht):
    /// Ausschnitte unter 2 s sind als Hörprobe wenig nützlich und werden nur
    /// genommen, wenn nichts Besseres da ist; über 20 s hört niemand zu Ende.
    public static let minimumUsefulSeconds: TimeInterval = 2.0
    public static let maximumSeconds: TimeInterval = 20.0
    public static let maximumSamples = 5
    /// Dauer allein reicht nicht: ein Turn kann durch Nicht-Sprache (real
    /// beobachtet: Zoom-Beitrittston am Meetinganfang) künstlich lang sein
    /// und trotzdem nur zwei Wörter tragen. Erst ab dieser Wortzahl taugt
    /// ein Ausschnitt als Wiedererkennungs-Beleg.
    public static let minimumUsefulWords = 6

    /// Wählt bis zu fünf Hörproben für einen Cluster aus der Revision.
    /// Turns, die über die Merge-Auflösung zu diesem Cluster gehören,
    /// zählen mit (many-to-one-fest).
    public static func samples(
        for cluster: IdentityCluster,
        revision: TranscriptRevision,
        resolutions: [IdentityClusterResolution]
    ) -> [SpeakerSample] {
        let target = SpeakerClusterKey(clusterID: cluster.clusterID)
        let targetChannel = SpeakerClusterKey.normalizedChannel(cluster.channel)

        func memberKey(channel: String, clusterID: String) -> String {
            let key = SpeakerClusterKey(clusterID: clusterID)
            return "\(SpeakerClusterKey.normalizedChannel(channel))\u{0}\(key.clusterID)"
        }

        let matchingResolutions = resolutions.filter {
            SpeakerClusterKey.normalizedChannel($0.channel) == targetChannel
                && SpeakerClusterKey(clusterID: $0.primaryClusterID).clusterID
                    == target.clusterID
        }
        let memberClusterIDs = [cluster.clusterID]
            + cluster.mergedFrom
            + matchingResolutions.map(\.sourceClusterID)
        let namespacedMemberIDs = Set(
            memberClusterIDs.filter(SpeakerClusterKey.hasOpaqueNamespace)
        )
        let memberIDs = Set(
            [cluster.clusterID].map { memberKey(channel: targetChannel, clusterID: $0) }
                + cluster.mergedFrom.map { memberKey(channel: targetChannel, clusterID: $0) }
                + matchingResolutions
                    .map { memberKey(channel: $0.channel, clusterID: $0.sourceClusterID) }
        )

        let candidates = revision.turns.compactMap { turn -> SpeakerSample? in
            guard case .cluster(let runID, let clusterID) = turn.speaker,
                  runID == cluster.runID
            else { return nil }
            let source = SpeakerClusterKey(clusterID: clusterID)
            let exactNamespacedMatch = namespacedMemberIDs.contains(clusterID)
            let channelScopedMatch = source.channel.map {
                memberIDs.contains(memberKey(channel: $0, clusterID: clusterID))
            } ?? false
            guard exactNamespacedMatch || channelScopedMatch else { return nil }
            let text = turn.segments.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, turn.end > turn.start else { return nil }
            return SpeakerSample(
                turnStart: turn.start,
                clipStart: turn.start,
                clipEnd: min(turn.end, turn.start + maximumSeconds),
                text: text,
                channel: cluster.channel
            )
        }

        func wordCount(_ sample: SpeakerSample) -> Int {
            sample.text.split(whereSeparator: \.isWhitespace).count
        }
        // Drei Güteklassen: lang genug UND wortreich genug; nur lang genug;
        // der Rest. Innerhalb der Klasse zählt der Wortgehalt, nicht die
        // Dauer, sonst gewinnen tonhaltige Fast-Stille-Turns.
        func tier(_ sample: SpeakerSample) -> Int {
            let words = wordCount(sample)
            if sample.duration >= minimumUsefulSeconds,
               words >= minimumUsefulWords { return 0 }
            if sample.duration >= minimumUsefulSeconds { return 1 }
            return 2
        }
        // Niedrigere Klassen sind reine Notnägel: sie erscheinen NUR, wenn
        // die besseren Klassen leer sind - nie als Auffüllung. Vier gute
        // Belege ohne Störschnipsel schlagen fünf mit einem (real moniert:
        // der Zoom-Beitrittston-Turn stand neben vier perfekten Proben).
        guard let bestTier = candidates.map(tier).min() else { return [] }
        let ranked = candidates
            .filter { tier($0) == bestTier }
            .sorted { wordCount($0) > wordCount($1) }
        let chosen = Array(ranked.prefix(maximumSamples))
        guard let best = chosen.first else { return [] }

        // Vertrag zur Anzeige: Element 0 ist die BESTE Probe (steht inline),
        // der Rest chronologisch, damit er den Gesprächsverlauf abbildet.
        let remainder = chosen.dropFirst().sorted { $0.turnStart < $1.turnStart }
        return [best] + remainder
    }
}

/// Computes a voiceprint for manual enrollment from a recorded or imported
/// audio clip.
///
/// It runs the SAME diarization provider over the clip that meeting
/// processing uses, then takes the voice with the most total speaking time -
/// legacy parity: a clean solo clip diarizes as effectively one speaker. The
/// selection rules themselves live in `VoiceEnrollmentSelector` (StenoIdentity)
/// and are tested there; this type only bridges DiarizationOutput onto them.
public struct EnrollmentVoiceprintExtractor: Sendable {
    private let provider: any DiarizationProvider

    /// The public surface deliberately names no StenoDiarization type: app
    /// targets that never import StenoDiarization must still be able to call
    /// this. Within the package, tests and benchmarks can inject a provider.
    public init() {
        self.provider = FluidSortformerProvider()
    }

    init(provider: any DiarizationProvider) {
        self.provider = provider
    }

    public func extract(from audioURL: URL) async throws -> VoiceEnrollmentCandidate {
        let output = try await provider.diarize(audioURL, hints: DiarizationHints())
        var durations: [String: TimeInterval] = [:]
        var segmentCounts: [String: Int] = [:]
        for segment in output.segments {
            durations[segment.clusterID, default: 0] += max(0, segment.end - segment.start)
            segmentCounts[segment.clusterID, default: 0] += 1
        }
        let candidates = output.embeddings.map { clusterID, embedding in
            VoiceEnrollmentCandidate(
                clusterID: clusterID,
                embedding: embedding,
                speechDurationSeconds: durations[clusterID] ?? 0,
                segmentCount: segmentCounts[clusterID] ?? 0
            )
        }
        return try VoiceEnrollmentSelector.dominant(candidates)
    }
}
