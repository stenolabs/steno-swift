import Foundation
import StenoDomain
import StenoTranscription
@testable import StenoPipeline
import Testing

@Suite("Final ASR over appended recordings")
struct PipelineAppendTimelineTests {
    /// Eine angehangene Aufnahme wird vom selben Final-ASR-Lauf mit
    /// verarbeitet, in chronologischer Reihenfolge, und landet auf der
    /// absoluten Meeting-Zeitachse.
    @Test("appended track is transcribed last and shifted to absolute time")
    func appendedTrackLandsAtAbsoluteTime() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            // Angehangene Aufnahme: zweite Mikrofon-Spur, drei Sekunden.
            let appendedSource = root.appendingPathComponent("appended.caf")
            try Data(MediaAsset.Kind.micTrack.rawValue.utf8)
                .write(to: appendedSource)
            let appendedAsset = try await fixture.library.registerMediaAsset(
                for: fixture.meeting.id,
                sourceURL: appendedSource,
                kind: .micTrack,
                sampleRate: 48_000,
                duration: 3
            )
            #expect(appendedAsset.provenanceKey == "\(fixture.meeting.id)/micTrack#2")

            let transcription = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: transcription),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()
            defer { Task { await coordinator.stop() } }

            let finishedJob = try await fixture.jobStore.load(fixture.job.id)
            #expect(finishedJob.status == .finished)

            // Drei Spuren angefragt: erste Session (Mikro + System) zuerst,
            // die Angehangene zuletzt.
            #expect(try await transcription.callCount() == 3)

            // Die vorläufige Live-Revision bleibt stehen; der finale Lauf
            // haengt eine Revision an, deren spaeteste Turns auf der
            // fortgesetzten Zeitachse liegen (Offset = 2 Sekunden).
            let revision = try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            )
            let latestEnd = revision.turns.map(\.end).max() ?? -1
            #expect(latestEnd >= 2.5)
            #expect(
                revision.turns.contains { turn in
                    abs(turn.start - 2) < 0.001 && turn.end <= 3.5
                        && turn.segments.contains { $0.text == "Mikrofon" }
                } == true
            )
        }
    }

    @Test("artifact offsets round-trip and old artifacts decode without them")
    func artifactOffsetsRoundTrip() throws {
        let job = Job(kind: .finalASR, meetingID: MeetingID())
        let assetID = MediaAssetID()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Artefakt ohne Offset-Feld (Stand vor "Continue recording").
        let legacyJSON = try encoder.encode(FinalASRArtifact(
            jobID: job.id,
            revisionID: StablePipelineIdentifiers.revisionID(for: job),
            tracks: []
        ))
        let legacy = try decoder.decode(
            FinalASRArtifact.self,
            from: legacyJSON
        )
        #expect(legacy.trackOffsets == nil)

        // Mit Offsets: Verlustfrei ueber die Platte.
        let current = FinalASRArtifact(
            jobID: job.id,
            revisionID: StablePipelineIdentifiers.revisionID(for: job),
            tracks: [],
            trackOffsets: [assetID.description: 12.5]
        )
        let decoded = try decoder.decode(
            FinalASRArtifact.self,
            from: encoder.encode(current)
        )
        #expect(decoded.trackOffsets == [assetID.description: 12.5])
    }
}
