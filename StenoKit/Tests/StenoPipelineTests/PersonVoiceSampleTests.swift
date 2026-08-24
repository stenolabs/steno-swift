import Foundation
import StenoDomain
import StenoLibrary
import Testing
@testable import StenoPipeline

/// Die Aufloesung entscheidet, ob unter einem Namen die richtige Stimme
/// erklingt. Sie darf lieber nichts anbieten als irgendetwas: in der alten App
/// hat genau ein solcher Rettungszweig fremde Saetze unter einer fremden
/// Stimme abgespielt.
@Suite("Person voice samples")
struct PersonVoiceSampleTests {
    @Test("takes the longest segment of the run the sample was confirmed against")
    func picksLongestSegmentOfItsOwnRun() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Board", status: .ready)
            let assetID = try await addTrack(
                library,
                meetingID: meeting.id,
                kind: .systemTrack
            )
            let runID = try await writeDiarizationRun(
                library,
                meetingID: meeting.id,
                segments: [
                    DiarizationRunSegment(clusterID: "SPEAKER_0", start: 1, end: 2.5),
                    DiarizationRunSegment(clusterID: "SPEAKER_0", start: 10, end: 14),
                    DiarizationRunSegment(clusterID: "SPEAKER_1", start: 20, end: 40),
                ],
                assetID: assetID
            )
            let person = person(
                withPrototypeIn: meeting.id,
                runID: runID,
                clusterID: "SPEAKER_0"
            )

            let samples = await PersonVoiceSamples.resolve(
                library: library,
                person: person
            )

            let sample = try #require(samples.first)
            let playback = try #require(sample.playback)
            #expect(playback.start == 10)
            #expect(playback.duration == 4)
            #expect(sample.meetingTitle == "Board")
            #expect(sample.isSuperseded == false)
            #expect(sample.isExcluded == false)
        }
    }

    @Test("a clip is capped so a sample stays a sample")
    func capsTheClipLength() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Board", status: .ready)
            let assetID = try await addTrack(
                library,
                meetingID: meeting.id,
                kind: .systemTrack
            )
            let runID = try await writeDiarizationRun(
                library,
                meetingID: meeting.id,
                segments: [
                    DiarizationRunSegment(clusterID: "SPEAKER_0", start: 5, end: 300),
                ],
                assetID: assetID
            )

            let samples = await PersonVoiceSamples.resolve(
                library: library,
                person: person(
                    withPrototypeIn: meeting.id,
                    runID: runID,
                    clusterID: "SPEAKER_0"
                )
            )

            #expect(samples.first?.playback?.duration == PersonVoiceSamples.maximumClipSeconds)
        }
    }

    @Test("a newer diarization run marks the sample as superseded, never removes it")
    func marksSupersededRun() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Board", status: .ready)
            let assetID = try await addTrack(
                library,
                meetingID: meeting.id,
                kind: .systemTrack
            )
            let oldRun = try await writeDiarizationRun(
                library,
                meetingID: meeting.id,
                segments: [
                    DiarizationRunSegment(clusterID: "SPEAKER_0", start: 0, end: 3),
                ],
                assetID: assetID,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
            _ = try await writeDiarizationRun(
                library,
                meetingID: meeting.id,
                segments: [
                    DiarizationRunSegment(clusterID: "SPEAKER_0", start: 0, end: 3),
                ],
                assetID: assetID,
                createdAt: Date(timeIntervalSince1970: 2_000)
            )

            let samples = await PersonVoiceSamples.resolve(
                library: library,
                person: person(
                    withPrototypeIn: meeting.id,
                    runID: oldRun,
                    clusterID: "SPEAKER_0"
                )
            )

            let sample = try #require(samples.first)
            #expect(sample.isSuperseded)
            // Veraltet heisst nicht weg: die Probe bleibt und bleibt hoerbar,
            // denn sie ist die Stimme eines echten Menschen.
            #expect(sample.playback != nil)
        }
    }

    @Test("no artifact, no track, or no matching cluster means no playback at all")
    func refusesToGuessAClip() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Board", status: .ready)
            let runID = try await writeDiarizationRun(
                library,
                meetingID: meeting.id,
                segments: [
                    DiarizationRunSegment(clusterID: "SPEAKER_0", start: 0, end: 3),
                ]
            )

            // Kein Track registriert.
            var samples = await PersonVoiceSamples.resolve(
                library: library,
                person: person(
                    withPrototypeIn: meeting.id,
                    runID: runID,
                    clusterID: "SPEAKER_0"
                )
            )
            #expect(samples.first?.playback == nil)
            #expect(samples.first?.meetingTitle == "Board")

            try await addTrack(library, meetingID: meeting.id, kind: .systemTrack)

            // Cluster, den dieser Lauf nicht kennt.
            samples = await PersonVoiceSamples.resolve(
                library: library,
                person: person(
                    withPrototypeIn: meeting.id,
                    runID: runID,
                    clusterID: "SPEAKER_9"
                )
            )
            #expect(samples.first?.playback == nil)

            // Lauf, zu dem es kein Artefakt gibt.
            samples = await PersonVoiceSamples.resolve(
                library: library,
                person: person(
                    withPrototypeIn: meeting.id,
                    runID: RunID(),
                    clusterID: "SPEAKER_0"
                )
            )
            #expect(samples.first?.playback == nil)
        }
    }

    @Test("another track of the same kind is not a substitute for the diarized one")
    func doesNotFallBackToAnotherTrackOfTheSameKind() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Board", status: .ready)
            // Eine Systemspur ist vorhanden - aber nicht die, die der Lauf
            // diarisiert hat. Genau so sieht ein erneuter Import derselben
            // Aufnahme aus, und die alten Segmentzeiten passen dort nicht.
            try await addTrack(library, meetingID: meeting.id, kind: .systemTrack)
            let runID = try await writeDiarizationRun(
                library,
                meetingID: meeting.id,
                segments: [
                    DiarizationRunSegment(clusterID: "SPEAKER_0", start: 0, end: 9),
                ],
                assetID: MediaAssetID()
            )

            let samples = await PersonVoiceSamples.resolve(
                library: library,
                person: person(
                    withPrototypeIn: meeting.id,
                    runID: runID,
                    clusterID: "SPEAKER_0"
                )
            )

            #expect(samples.first?.playback == nil)
        }
    }

    @Test("the matching segment selects one exact asset and ambiguity disables playback")
    func resolvesOnlyAnUnambiguousTrackOfTheSameKind() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Imports", status: .ready)
            let firstAssetID = try await addTrack(
                library,
                meetingID: meeting.id,
                kind: .imported,
                contents: "first"
            )
            let secondAssetID = try await addTrack(
                library,
                meetingID: meeting.id,
                kind: .imported,
                contents: "second"
            )
            let target = DiarizationRunSegment(
                clusterID: "second/speaker-0",
                start: 12,
                end: 18
            )
            let other = DiarizationRunSegment(
                clusterID: "first/speaker-0",
                start: 2,
                end: 4
            )
            let runID = try await writeDiarizationRun(
                library,
                meetingID: meeting.id,
                tracks: [
                    track(assetID: firstAssetID, kind: .imported, segments: [other]),
                    track(assetID: secondAssetID, kind: .imported, segments: [target]),
                ]
            )
            let evidence = person(
                withPrototypeIn: meeting.id,
                runID: runID,
                clusterID: target.clusterID,
                channel: MediaAsset.Kind.imported.rawValue
            )

            var samples = await PersonVoiceSamples.resolve(
                library: library,
                person: evidence
            )
            #expect(samples.first?.playback?.assetID == secondAssetID)

            try await overwriteDiarizationTracks(
                library,
                meetingID: meeting.id,
                runID: runID,
                tracks: [
                    track(assetID: firstAssetID, kind: .imported, segments: [target]),
                    track(assetID: secondAssetID, kind: .imported, segments: [target]),
                ]
            )
            samples = await PersonVoiceSamples.resolve(
                library: library,
                person: evidence
            )
            #expect(samples.first?.playback == nil)
        }
    }

    @Test("a deleted meeting leaves the evidence listed but silent")
    func survivesADeletedMeeting() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)

            let samples = await PersonVoiceSamples.resolve(
                library: library,
                person: person(
                    withPrototypeIn: MeetingID(),
                    runID: RunID(),
                    clusterID: "SPEAKER_0"
                )
            )

            let sample = try #require(samples.first)
            #expect(sample.meetingTitle == nil)
            #expect(sample.playback == nil)
            #expect(sample.speechDurationSeconds == 24)
        }
    }

    @Test("hard negatives are resolved as their own kind, newest evidence first")
    func resolvesBothKinds() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let personID = PersonID()
            let older = SpeakerPrototype(
                personID: personID,
                embedding: [1, 0],
                recordingType: .remote,
                channel: "system",
                meetingID: MeetingID(),
                runID: RunID(),
                clusterID: "A",
                speechDurationSeconds: 24,
                segmentCount: 4,
                source: .userConfirmed,
                createdAt: Date(timeIntervalSince1970: 100)
            )
            let newer = HardNegative(
                personID: personID,
                embedding: [0, 1],
                recordingType: .remote,
                channel: "system",
                meetingID: MeetingID(),
                runID: RunID(),
                clusterID: "B",
                speechDurationSeconds: 24,
                segmentCount: 4,
                source: .userConfirmed,
                createdAt: Date(timeIntervalSince1970: 200),
                excludedAt: Date(timeIntervalSince1970: 300)
            )

            let samples = await PersonVoiceSamples.resolve(
                library: library,
                person: Person(
                    id: personID,
                    displayName: "Ada",
                    prototypes: [older],
                    hardNegatives: [newer]
                )
            )

            #expect(samples.map(\.kind) == [.hardNegative, .prototype])
            #expect(samples[0].isExcluded)
            #expect(samples[1].isExcluded == false)
        }
    }

    // MARK: - Helfer

    private func person(
        withPrototypeIn meetingID: MeetingID,
        runID: RunID,
        clusterID: String,
        channel: String = MediaAsset.Kind.systemTrack.rawValue
    ) -> Person {
        let personID = PersonID()
        return Person(
            id: personID,
            displayName: "Ada",
            prototypes: [SpeakerPrototype(
                personID: personID,
                embedding: [1, 0],
                recordingType: .remote,
                channel: channel,
                meetingID: meetingID,
                runID: runID,
                clusterID: clusterID,
                speechDurationSeconds: 24,
                segmentCount: 4,
                source: .userConfirmed
            )]
        )
    }

    @discardableResult
    private func addTrack(
        _ library: Library,
        meetingID: MeetingID,
        kind: MediaAsset.Kind,
        contents: String = "audio"
    ) async throws -> MediaAssetID {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).caf")
        try Data(contents.utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        return try await library.registerMediaAsset(
            for: meetingID,
            sourceURL: source,
            kind: kind,
            sampleRate: 16_000,
            duration: 300
        ).id
    }

    @discardableResult
    private func writeDiarizationRun(
        _ library: Library,
        meetingID: MeetingID,
        segments: [DiarizationRunSegment] = [],
        // Die Spur, die dieser Lauf diarisiert hat. Ohne sie zeigt das
        // Artefakt auf eine Spur, die es nicht gibt - und dann darf auch
        // nichts abgespielt werden.
        assetID: MediaAssetID = MediaAssetID(),
        tracks: [DiarizationTrackResult]? = nil,
        createdAt: Date = Date()
    ) async throws -> RunID {
        let layout = library.layout
        let run = ProcessingRun(
            meetingID: meetingID,
            kind: .diarization,
            engine: EngineDescriptor(name: "fixture", version: "1"),
            status: .finished,
            createdAt: createdAt
        )
        let directory = layout.runDirectory(meetingID, runID: run.id)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        try encoder.encode(run).write(to: layout.runMetadata(meetingID, runID: run.id))
        let artifact = DiarizationArtifact(
            jobID: JobID(),
            sourceRunID: RunID(),
            revisionID: RevisionID(),
            tracks: tracks ?? [DiarizationTrackResult(
                assetID: assetID,
                assetKind: .systemTrack,
                engine: EngineDescriptor(name: "fixture", version: "1"),
                segments: segments,
                clusters: []
            )]
        )
        try encoder.encode(artifact).write(
            to: layout.runDiarization(meetingID, runID: run.id)
        )
        return run.id
    }

    private func track(
        assetID: MediaAssetID,
        kind: MediaAsset.Kind,
        segments: [DiarizationRunSegment]
    ) -> DiarizationTrackResult {
        DiarizationTrackResult(
            assetID: assetID,
            assetKind: kind,
            engine: EngineDescriptor(name: "fixture", version: "1"),
            segments: segments,
            clusters: []
        )
    }

    private func overwriteDiarizationTracks(
        _ library: Library,
        meetingID: MeetingID,
        runID: RunID,
        tracks: [DiarizationTrackResult]
    ) async throws {
        let artifactURL = library.layout.runDiarization(meetingID, runID: runID)
        let previous = try JSONDecoder().decode(
            DiarizationArtifact.self,
            from: Data(contentsOf: artifactURL)
        )
        let replacement = DiarizationArtifact(
            jobID: previous.jobID,
            sourceRunID: previous.sourceRunID,
            revisionID: previous.revisionID,
            tracks: tracks
        )
        try JSONEncoder().encode(replacement).write(to: artifactURL)
    }
}
