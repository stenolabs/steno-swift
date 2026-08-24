import AVFAudio
import Foundation
import StenoAudioCore
import StenoDiarization
import StenoDomain
import StenoLibrary
import StenoPipeline
import StenoTranscription
import Testing
@testable import Steno

@Suite("iOS native recording composition")
struct NativeRecordingCompositionTests {
    @Test("a native recording stays available while processing")
    func nativeMicrophoneRecordingIsOfferedWhileProcessing() async throws {
        try await withNativeRecordingFixture { library, _, meeting in
            let microphone = NativeTestMicrophoneSource()
            let session = RecordingSession(
                meetingID: meeting.id,
                library: library,
                outputDirectory: library.layout.captureDirectory(meeting.id),
                sources: [.microphone: microphone],
                activityManager: NativeTestRecordingActivity(),
                availableDiskBytes: { _ in 3_000_000_000 }
            )

            try await session.start()
            await microphone.emit(nativeRecordingBuffer())
            _ = try await session.stop()
            _ = try await library.updateMeetingStatus(meeting.id, to: .processing)

            let preview = try await MeetingTransferExportService(
                library: library
            ).preview(meetingID: meeting.id)

            let track = try #require(preview.audioTracks.first)
            #expect(preview.audioTracks.count == 1)
            #expect(track.label == "Microphone")
            #expect(track.byteCount > 0)
        }
    }

    @Test("native microphone recording finalizes into the processing chain")
    func nativeMicrophoneRecordingFlowsIntoProcessing() async throws {
        try await withNativeRecordingFixture { library, jobStore, meeting in
            let microphone = NativeTestMicrophoneSource()
            let captureDirectory = library.layout.captureDirectory(meeting.id)
            let session = RecordingSession(
                meetingID: meeting.id,
                library: library,
                outputDirectory: captureDirectory,
                sources: [.microphone: microphone],
                activityManager: NativeTestRecordingActivity(),
                availableDiskBytes: { _ in 3_000_000_000 }
            )

            try await session.start()
            await microphone.emit(nativeRecordingBuffer())
            let captureFiles = try FileManager.default.contentsOfDirectory(
                at: captureDirectory,
                includingPropertiesForKeys: nil
            )
            let result = try await session.stop()
            let assets = try await library.listMediaAssets(meetingID: meeting.id)
            let asset = try #require(assets.first)
            let mediaURL = library.layout.mediaFile(meeting.id, fileName: asset.fileName)
            let readableCAF = try AVAudioFile(forReading: mediaURL)

            #expect(result.assets.count == 1)
            #expect(result.assets[.microphone]?.kind == .micTrack)
            #expect(captureFiles.count == 1)
            #expect(assets.count == 1)
            #expect(asset.kind == .micTrack)
            #expect(readableCAF.length > 0)
            #expect(try FileManager.default.contentsOfDirectory(
                at: captureDirectory,
                includingPropertiesForKeys: nil
            ).isEmpty)
            #expect(try await library.loadMeeting(meeting.id).status == .ready)

            try await RecordingFinalizer().finalize(
                meeting: meeting,
                output: nil,
                library: library,
                jobStore: jobStore
            )
            let finalASRJobs = try await jobStore.list()
            #expect(finalASRJobs.count == 1)
            #expect(finalASRJobs.first?.kind == .finalASR)

            let coordinator = PipelineCoordinator(
                library: library,
                jobStore: jobStore,
                providers: [.micTrack: NativeTestTranscriptionProvider()],
                diarizationProvider: NativeTestDiarizationProvider(),
                locale: Locale(identifier: "de-DE")
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let jobs = try await jobStore.list()
            let runs = try nativeProcessingRuns(library: library, meetingID: meeting.id)
            let finalRun = try #require(runs.first { $0.kind == .finalASR })
            let diarizationRun = try #require(runs.first { $0.kind == .diarization })
            let identityRun = try #require(runs.first { $0.kind == .identitySuggestion })
            let revision = try #require(
                try await library.loadCurrentRevision(meetingID: meeting.id)
            )

            #expect(jobs.map(\.kind) == [.finalASR, .diarization, .identitySuggestion])
            #expect(jobs.allSatisfy { $0.status == .finished })
            #expect(finalRun.status == .finished)
            #expect(diarizationRun.status == .finished)
            #expect(identityRun.status == .finished)
            #expect(revision.origin == .finalRun(diarizationRun.id))
            await coordinator.stop()
        }
    }
}

private func withNativeRecordingFixture(
    _ body: (Library, JobStore, Meeting) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoNativeRecordingTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library.open(at: root.appendingPathComponent("Library"))
    let meeting = try await library.createMeeting(title: "Native recording", status: .recording)
    let jobStore = try JobStore(layout: library.layout)
    try await body(library, jobStore, meeting)
}

private actor NativeTestMicrophoneSource: AudioSource {
    nonisolated let track: AudioTrack = .microphone
    nonisolated let format = nativeRecordingBuffer().format
    private var bufferHandler: AudioBufferHandler?

    func prepare() -> AVAudioFormat {
        format
    }

    func start(bufferHandler: @escaping AudioBufferHandler) {
        self.bufferHandler = bufferHandler
    }

    func stop() {
        bufferHandler = nil
    }

    func emit(_ buffer: AVAudioPCMBuffer) async {
        bufferHandler?(buffer)
        await Task.yield()
    }
}

private actor NativeTestRecordingActivity: RecordingActivityManaging {
    func begin() {}
    func end() {}
}

private actor NativeTestTranscriptionProvider: TranscriptionProvider {
    nonisolated let descriptor = EngineDescriptor(
        name: "Native recording test ASR",
        version: "1"
    )

    func liveSession(
        format: AudioFormat,
        locale: Locale
    ) async throws -> any LiveTranscriptionSession {
        throw NativeRecordingTestError.liveTranscriptionIsNotPartOfThisPath
    }

    func transcribeFile(
        _ url: URL,
        locale: Locale
    ) async throws -> TranscriptOutput {
        TranscriptOutput(
            localeIdentifier: locale.identifier,
            blocks: [
                TranscriptionBlock(
                    channel: .microphone,
                    text: "Aufnahme",
                    start: 0,
                    end: 0.5,
                    words: [
                        TranscriptionWord(text: "Aufnahme", start: 0, end: 0.5),
                    ]
                ),
            ]
        )
    }
}

private actor NativeTestDiarizationProvider: DiarizationProvider {
    nonisolated let descriptor = EngineDescriptor(
        name: "Native recording test diarization",
        version: "1"
    )

    func diarize(
        _ url: URL,
        hints: DiarizationHints
    ) async throws -> DiarizationOutput {
        DiarizationOutput(
            segments: [DiarizationSegment(clusterID: "SPEAKER_0", start: 0, end: 0.5)],
            embeddings: ["SPEAKER_0": [1, 0]],
            engine: descriptor
        )
    }
}

private enum NativeRecordingTestError: Error {
    case liveTranscriptionIsNotPartOfThisPath
}

private func nativeRecordingBuffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 8_000,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000)!
    buffer.frameLength = 4_000
    for frame in 0..<Int(buffer.frameLength) {
        buffer.floatChannelData![0][frame] = frame.isMultiple(of: 2) ? 0.5 : -0.5
    }
    return buffer
}

private func nativeProcessingRuns(
    library: Library,
    meetingID: MeetingID
) throws -> [ProcessingRun] {
    try FileManager.default.contentsOfDirectory(
        at: library.layout.runsDirectory(meetingID),
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ).compactMap { directory in
        guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
        return try JSONDecoder().decode(
            ProcessingRun.self,
            from: Data(contentsOf: directory.appendingPathComponent("run.json"))
        )
    }
}
