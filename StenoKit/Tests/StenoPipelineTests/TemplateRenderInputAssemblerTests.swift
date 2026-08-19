import Foundation
import StenoDomain
import StenoIdentity
import StenoIntelligence
import Testing
@testable import StenoLibrary
@testable import StenoPipeline

@Suite("Template render input assembly")
struct TemplateRenderInputAssemblerTests {
    @Test("preflight discloses the exact assembled transcript, participants, and notes")
    func preflightDisclosesAssembledInput() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeRenderInputFixture(at: root)

            let first = try await TemplateRenderInputAssembler.preflight(
                library: fixture.library,
                meetingID: fixture.meeting.id
            )
            let second = try await TemplateRenderInputAssembler.preflight(
                library: fixture.library,
                meetingID: fixture.meeting.id
            )

            #expect(first.meetingID == fixture.meeting.id)
            #expect(first.revisionID == fixture.revision.id)
            #expect(first.disclosure.classes == [
                .transcriptWithSpeakerNames,
                .participants,
                .userNotes,
            ])
            #expect(first.inputFingerprint == second.inputFingerprint)
            #expect(first.inputFingerprint.hasPrefix("sha256:"))
            try await TemplateRenderInputAssembler.validate(first, library: fixture.library)
        }
    }

    @Test("invalid UTF-8 notes abort preflight before any render work exists")
    func invalidNotesAbortPreflight() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeRenderInputFixture(at: root)
            try FileManager.default.createDirectory(
                at: fixture.library.layout.notesDirectory(fixture.meeting.id),
                withIntermediateDirectories: true
            )
            try Data([0xff]).write(to: fixture.library.layout.userNotes(fixture.meeting.id))

            await #expect(throws: Error.self) {
                _ = try await TemplateRenderInputAssembler.preflight(
                    library: fixture.library,
                    meetingID: fixture.meeting.id
                )
            }
        }
    }
}

private struct RenderInputFixture {
    let library: Library
    let meeting: Meeting
    let revision: TranscriptRevision
}

private func makeRenderInputFixture(at root: URL) async throws -> RenderInputFixture {
    let library = try Library.open(at: root)
    let meeting = try await library.createMeeting(title: "Input", status: .ready)
    let source = root.appendingPathComponent("input.caf")
    try Data("audio".utf8).write(to: source)
    let asset = try await library.registerMediaAsset(
        for: meeting.id,
        sourceURL: source,
        kind: .imported,
        sampleRate: 48_000,
        duration: 1
    )
    let confirmed = Person(
        displayName: "Ada Lovelace",
        organization: "Analytical Engines"
    )
    let additional = Person(displayName: "Grace Hopper")
    try await IdentityStore(layout: library.layout).replacePersons([confirmed, additional])
    _ = try await library.updateAdditionalMeetingParticipants(
        meeting.id,
        participantIDs: [additional.id]
    )
    let runID = RunID()
    let clusterID = "\(asset.id)/SPEAKER_0"
    try await seedRenderInputReview(
        library: library,
        meetingID: meeting.id,
        asset: asset,
        runID: runID,
        clusterID: clusterID,
        person: confirmed
    )
    let revision = TranscriptRevision(
        meetingID: meeting.id,
        origin: .liveProvisional,
        turns: [
            TranscriptTurn(
                speaker: .cluster(runID: runID, clusterID: clusterID),
                start: 0,
                end: 1,
                segments: [
                    TranscriptSegment(text: "Agenda", start: 0, end: 1, words: []),
                ]
            ),
        ]
    )
    _ = try await library.appendRevision(revision)
    try await MeetingNotesStore(layout: library.layout).setNotes(
        meeting.id,
        to: "Synthetic Project"
    )
    return RenderInputFixture(library: library, meeting: meeting, revision: revision)
}

private func seedRenderInputReview(
    library: Library,
    meetingID: MeetingID,
    asset: MediaAsset,
    runID: RunID,
    clusterID: String,
    person: Person
) async throws {
    let cluster = IdentityCluster(
        meetingID: meetingID,
        runID: runID,
        channel: asset.kind.rawValue,
        clusterID: clusterID,
        recordingType: .imported,
        embedding: [1, 0],
        speechDurationSeconds: 1,
        segmentCount: 1,
        reviewState: .confirmed(person.id)
    )
    let diarization = DiarizationArtifact(
        jobID: JobID(),
        sourceRunID: RunID(),
        revisionID: RevisionID(),
        tracks: [
            DiarizationTrackResult(
                assetID: asset.id,
                assetKind: asset.kind,
                engine: EngineDescriptor(name: "Test", version: "1"),
                segments: [DiarizationRunSegment(clusterID: clusterID, start: 0, end: 1)],
                clusters: [
                    DiarizationClusterResult(
                        clusterID: clusterID,
                        embedding: [1, 0],
                        speechDurationSeconds: 1,
                        segmentCount: 1
                    ),
                ]
            ),
        ]
    )
    try writeRenderInputRun(
        ProcessingRun(
            id: runID,
            meetingID: meetingID,
            kind: .diarization,
            engine: EngineDescriptor(name: "Test", version: "1"),
            status: .finished
        ),
        artifact: diarization,
        artifactName: "diarization.json",
        layout: library.layout
    )
    try writeRenderInputRun(
        ProcessingRun(
            id: RunID(),
            meetingID: meetingID,
            kind: .identitySuggestion,
            engine: EngineDescriptor(name: "Test", version: "1"),
            status: .finished
        ),
        artifact: IdentitySuggestionArtifact(
            jobID: JobID(),
            sourceRunID: runID,
            clusterResolutions: [
                IdentityClusterResolution(
                    channel: asset.kind.rawValue,
                    sourceClusterID: clusterID,
                    primaryClusterID: clusterID
                ),
            ],
            identityEvidenceFingerprint: "fixture",
            suggestions: []
        ),
        artifactName: "suggestions.json",
        layout: library.layout
    )
    try MeetingReviewStore(layout: library.layout).save(
        MeetingReviewDocument(runID: runID, clusters: [cluster]),
        meetingID: meetingID
    )
}

private func writeRenderInputRun<Artifact: Encodable>(
    _ run: ProcessingRun,
    artifact: Artifact,
    artifactName: String,
    layout: LibraryLayout
) throws {
    let directory = layout.runDirectory(run.meetingID, runID: run.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try AtomicFile.write(encoder.encode(run), to: directory.appendingPathComponent("run.json"))
    try AtomicFile.write(encoder.encode(artifact), to: directory.appendingPathComponent(artifactName))
}
