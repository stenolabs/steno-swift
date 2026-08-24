import Foundation
import StenoDomain
import StenoLibrary

/// Eine gespeicherte Stimm-Evidenz, aufbereitet fuer die Personenverwaltung.
///
/// Sie beschreibt, was ein Mensch ueber diese Probe wissen muss, um sie zu
/// beurteilen: aus welchem Meeting sie stammt, ueber welche Spur sie
/// aufgenommen wurde, wie lange gesprochen wurde, ob sie noch zum aktuellen
/// Diarisierungslauf gehoert - und ob sie ueberhaupt anhoerbar ist.
public struct PersonVoiceSample: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Positive Evidenz: so klingt diese Person.
        case prototype
        /// Gegen-Evidenz: so klingt diese Person gerade nicht. Ein falscher
        /// Eintrag hier unterdrueckt eine echte Erkennung dauerhaft.
        case hardNegative
    }

    /// Wo im Original der Ausschnitt liegt. Fehlt dieser Wert, ist die Probe
    /// nicht anhoerbar, und die Oberflaeche bietet nichts an, statt zu raten.
    public struct Playback: Equatable, Sendable {
        public let meetingID: MeetingID
        /// Genau die Spur, die der Lauf diarisiert hat - nicht "irgendeine des
        /// gleichen Typs". Wird eine Aufnahme spaeter erneut importiert, gibt
        /// es zwei Spuren derselben Art, und die alten Segmentzeiten passen nur
        /// auf eine davon.
        public let assetID: MediaAssetID
        public let channel: String
        public let start: TimeInterval
        public let duration: TimeInterval

        public init(
            meetingID: MeetingID,
            assetID: MediaAssetID,
            channel: String,
            start: TimeInterval,
            duration: TimeInterval
        ) {
            self.meetingID = meetingID
            self.assetID = assetID
            self.channel = channel
            self.start = start
            self.duration = duration
        }
    }

    public let id: SpeakerEvidenceID
    public let personID: PersonID
    public let kind: Kind
    public let meetingID: MeetingID?
    /// Nil, wenn das Meeting geloescht wurde. Die Evidenz bleibt trotzdem
    /// gueltig - sie ist die Stimme eines echten Menschen, nicht die Datei.
    public let meetingTitle: String?
    public let channel: String?
    public let recordingType: RecordingType
    public let speechDurationSeconds: TimeInterval
    public let segmentCount: Int
    public let source: SpeakerEvidenceSource
    public let createdAt: Date
    public let isExcluded: Bool
    /// Die Probe wurde gegen einen Diarisierungslauf bestaetigt, der nicht
    /// mehr der aktuelle des Meetings ist. Sie bleibt echte Stimm-Evidenz und
    /// wird nur gekennzeichnet, nie automatisch entfernt.
    public let isSuperseded: Bool
    public let playback: Playback?

    public init(
        id: SpeakerEvidenceID,
        personID: PersonID,
        kind: Kind,
        meetingID: MeetingID?,
        meetingTitle: String?,
        channel: String?,
        recordingType: RecordingType,
        speechDurationSeconds: TimeInterval,
        segmentCount: Int,
        source: SpeakerEvidenceSource,
        createdAt: Date,
        isExcluded: Bool,
        isSuperseded: Bool,
        playback: Playback?
    ) {
        self.id = id
        self.personID = personID
        self.kind = kind
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.channel = channel
        self.recordingType = recordingType
        self.speechDurationSeconds = speechDurationSeconds
        self.segmentCount = segmentCount
        self.source = source
        self.createdAt = createdAt
        self.isExcluded = isExcluded
        self.isSuperseded = isSuperseded
        self.playback = playback
    }
}

public enum PersonVoiceSamples {
    /// Laengster hoerbarer Ausschnitt, aber gedeckelt: eine Probe soll zeigen,
    /// wie jemand klingt, nicht das Meeting nacherzaehlen.
    static let maximumClipSeconds: TimeInterval = 8

    /// Loest alle Evidenzen einer Person auf, neueste zuerst.
    ///
    /// Fuer jede Probe wird der Lauf gelesen, an dem sie haengt - nicht der
    /// aktuelle. Wer stattdessen ueber Zeitstempel-Naehe im neuesten Lauf
    /// sucht, spielt frueher oder spaeter eine fremde Stimme unter einem
    /// Namen ab; genau das ist in der alten App passiert.
    public static func resolve(
        library: Library,
        person: Person
    ) async -> [PersonVoiceSample] {
        var context = ResolutionContext(library: library)
        var samples: [PersonVoiceSample] = []
        for prototype in person.prototypes {
            samples.append(await resolve(prototype, kind: .prototype, in: &context))
        }
        for negative in person.hardNegatives {
            samples.append(await resolve(negative, kind: .hardNegative, in: &context))
        }
        return samples.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private static func resolve(
        _ evidence: some SpeakerEvidenceDetail,
        kind: PersonVoiceSample.Kind,
        in context: inout ResolutionContext
    ) async -> PersonVoiceSample {
        var title: String?
        var superseded = false
        var playback: PersonVoiceSample.Playback?

        if let meetingID = evidence.meetingID {
            let meeting = await context.meeting(meetingID)
            title = meeting?.title
            if let runID = evidence.runID,
               let current = await context.currentDiarizationRun(meetingID) {
                superseded = runID != current
            }
            if let runID = evidence.runID,
               let channel = evidence.channel,
               meeting != nil,
               let clip = await context.clip(
                   meetingID: meetingID,
                   runID: runID,
                   channel: channel,
                   clusterID: evidence.clusterID
               ),
               await context.hasFile(meetingID, assetID: clip.assetID) {
                playback = PersonVoiceSample.Playback(
                    meetingID: meetingID,
                    assetID: clip.assetID,
                    channel: channel,
                    start: clip.segment.start,
                    duration: min(
                        clip.segment.end - clip.segment.start,
                        maximumClipSeconds
                    )
                )
            }
        }

        return PersonVoiceSample(
            id: evidence.id,
            personID: evidence.personID,
            kind: kind,
            meetingID: evidence.meetingID,
            meetingTitle: title,
            channel: evidence.channel,
            recordingType: evidence.recordingType,
            speechDurationSeconds: evidence.speechDurationSeconds,
            segmentCount: evidence.segmentCount,
            source: evidence.source,
            createdAt: evidence.createdAt,
            isExcluded: !evidence.isActive,
            isSuperseded: superseded,
            playback: playback
        )
    }
}

/// Haelt die Antworten der Bibliothek fest, weil eine Person leicht ein
/// Dutzend Evidenzen aus denselben drei Meetings hat.
private struct ResolutionContext {
    let library: Library
    private var meetings: [MeetingID: Meeting?] = [:]
    private var currentRuns: [MeetingID: RunID?] = [:]
    private var tracks: [MeetingID: Set<MediaAssetID>] = [:]
    private var artifacts: [ArtifactKey: DiarizationArtifact?] = [:]

    struct ArtifactKey: Hashable {
        let meetingID: MeetingID
        let runID: RunID
    }

    init(library: Library) {
        self.library = library
    }

    mutating func meeting(_ meetingID: MeetingID) async -> Meeting? {
        if let cached = meetings[meetingID] { return cached }
        let meeting = try? await library.loadMeeting(meetingID)
        meetings[meetingID] = meeting
        return meeting
    }

    /// Der juengste abgeschlossene Diarisierungslauf des Meetings. Alles
    /// andere gilt als ueberholt.
    mutating func currentDiarizationRun(_ meetingID: MeetingID) async -> RunID? {
        if let cached = currentRuns[meetingID] { return cached }
        let layout = await library.layout
        let decoder = JSONDecoder()
        var newest: ProcessingRun?
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: layout.runsDirectory(meetingID),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries {
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("run.json")),
                  let run = try? decoder.decode(ProcessingRun.self, from: data),
                  run.kind == .diarization,
                  run.status == .finished
            else { continue }
            if newest.map({ run.createdAt > $0.createdAt }) ?? true { newest = run }
        }
        currentRuns[meetingID] = newest?.id
        return newest?.id
    }

    /// Existiert genau diese Spur noch als Datei? Die Identitaet haengt an der
    /// Asset-Kennung aus dem Artefakt, nicht an der Spurart.
    mutating func hasFile(
        _ meetingID: MeetingID,
        assetID: MediaAssetID
    ) async -> Bool {
        if tracks[meetingID] == nil {
            let assets = (try? await library.listMediaAssets(meetingID: meetingID)) ?? []
            let layout = await library.layout
            tracks[meetingID] = Set(assets.filter {
                FileManager.default.fileExists(
                    atPath: layout.mediaFile(meetingID, fileName: $0.fileName).path
                )
            }.map(\.id))
        }
        return tracks[meetingID]?.contains(assetID) ?? false
    }

    /// Das laengste Segment des Clusters in genau dem Lauf, an dem die Probe
    /// haengt, samt der Spur, auf die es sich bezieht. Ohne Artefakt, Spur,
    /// Cluster oder Segment gibt es keinen Ausschnitt - und dann wird nichts
    /// abgespielt.
    mutating func clip(
        meetingID: MeetingID,
        runID: RunID,
        channel: String,
        clusterID: String
    ) async -> (assetID: MediaAssetID, segment: DiarizationRunSegment)? {
        let key = ArtifactKey(meetingID: meetingID, runID: runID)
        if artifacts[key] == nil {
            let layout = await library.layout
            let url = layout.runDiarization(meetingID, runID: runID)
            let artifact = (try? Data(contentsOf: url)).flatMap {
                try? JSONDecoder().decode(DiarizationArtifact.self, from: $0)
            }
            artifacts[key] = artifact
        }
        guard let artifact = artifacts[key] ?? nil else { return nil }
        let matches = artifact.tracks.compactMap { track
            -> (assetID: MediaAssetID, segment: DiarizationRunSegment)? in
            guard track.assetKind.rawValue == channel,
                  let segment = track.segments
                    .filter({ $0.clusterID == clusterID && $0.end > $0.start })
                    .max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
            else { return nil }
            return (track.assetID, segment)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

/// Der gemeinsame Nenner von Prototyp und Hard Negative. Beide tragen
/// dieselbe Herkunft, und die Aufloesung ist fuer beide dieselbe - eine
/// zweite Kopie der Regel waere genau die Art Doppelung, die auseinanderlaeuft.
protocol SpeakerEvidenceDetail: SpeakerEvidence {
    var id: SpeakerEvidenceID { get }
    var personID: PersonID { get }
    var recordingType: RecordingType { get }
    var channel: String? { get }
    var meetingID: MeetingID? { get }
    var runID: RunID? { get }
    var clusterID: String { get }
    var speechDurationSeconds: TimeInterval { get }
    var segmentCount: Int { get }
    var source: SpeakerEvidenceSource { get }
    var createdAt: Date { get }
}

extension SpeakerPrototype: SpeakerEvidenceDetail {}
extension HardNegative: SpeakerEvidenceDetail {}
