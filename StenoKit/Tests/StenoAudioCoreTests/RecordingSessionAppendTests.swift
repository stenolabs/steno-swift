@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import StenoLibrary
import Testing
@testable import StenoAudioCore

/// Capture-layer contract of "continue recording" (append-to-meeting).
///
/// A meeting can receive ADDITIONAL recording sessions. Each session writes
/// its own immutable original tracks; the library assigns sequence-aware
/// provenance keys (`"<meetingID>/<kind>"` for the first session,
/// `"...#2"`, `"...#3"`, ... for later ones) when `finalizeStop` registers
/// the captured files through `registerCapturedMediaAsset`. These tests pin
/// the behavior the append flow and its recovery depend on.
@Suite("RecordingSession append-to-meeting")
struct RecordingSessionAppendTests {
    private func makeSources()
        -> [AudioTrack: FakeAppendAudioSource]
    {
        [
            .microphone: FakeAppendAudioSource(track: .microphone),
            .system: FakeAppendAudioSource(track: .system),
        ]
    }

    private func makeSession(
        meetingID: MeetingID,
        library: Library,
        outputDirectory: URL,
        sources: [AudioTrack: FakeAppendAudioSource]
    ) -> RecordingSession {
        RecordingSession(
            meetingID: meetingID,
            library: library,
            outputDirectory: outputDirectory,
            sources: sources,
            activityManager: FakeAppendActivityManager(),
            availableDiskBytes: { _ in 3_000_000_000 }
        )
    }

    /// Drains both live lanes like the app does, then feeds one buffer per
    /// track so the writers have real audio to finalize.
    private func recordOneBuffer(
        sources: [AudioTrack: FakeAppendAudioSource],
        session: RecordingSession
    ) async throws {
        _ = try await session.liveAudioEvents(for: .microphone)
        _ = try await session.liveAudioEvents(for: .system)
        await sources[.microphone]?.emit(syntheticBuffer(amplitude: 0.25))
        await sources[.system]?.emit(
            syntheticBuffer(channels: 2, amplitude: 0.75)
        )
    }

    @Test("an appended session registers sequence-suffixed keys beside the originals")
    func appendedSessionRegistersDistinctProvenanceKeys() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(
            title: "Appended",
            status: .recording
        )
        let captureDirectory = library.layout.captureDirectory(meeting.id)

        let firstSources = makeSources()
        let firstSession = makeSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: captureDirectory,
            sources: firstSources
        )
        try await firstSession.start()
        try await recordOneBuffer(sources: firstSources, session: firstSession)
        let firstResult = try await firstSession.stop()

        let secondSources = makeSources()
        let secondSession = makeSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: captureDirectory,
            sources: secondSources
        )
        try await secondSession.start()
        try await recordOneBuffer(sources: secondSources, session: secondSession)
        let secondResult = try await secondSession.stop()

        // The first session owns the historical keys; the appended session
        // must NOT collide with them - its tracks carry the next sequence.
        #expect(firstResult.assets[.microphone]?.provenanceKey
            == "\(meeting.id)/micTrack")
        #expect(firstResult.assets[.system]?.provenanceKey
            == "\(meeting.id)/systemTrack")
        #expect(secondResult.assets[.microphone]?.provenanceKey
            == "\(meeting.id)/micTrack#2")
        #expect(secondResult.assets[.system]?.provenanceKey
            == "\(meeting.id)/systemTrack#2")

        let assets = try await library.listMediaAssets(meetingID: meeting.id)
        #expect(assets.count == 4)
        #expect(Set(assets.map(\.provenanceKey)).count == 4)
        for asset in assets {
            let url = library.layout.mediaFile(meeting.id, fileName: asset.fileName)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(try await library.loadMeeting(meeting.id).status == .ready)

        // The staging area is empty again: every session renamed its own
        // prefix away, leaving nothing that adoption could double-take.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: captureDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(leftovers.isEmpty)
    }

    @Test("a finished session's live stream stays finished; the appended session streams independently")
    func appendedSessionLiveStreamsAreIndependent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(
            title: "Stream boundary",
            status: .recording
        )
        let captureDirectory = library.layout.captureDirectory(meeting.id)

        // First session: consume its microphone stream to completion.
        let firstSource = FakeAppendAudioSource(track: .microphone)
        let firstSession = makeSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: captureDirectory,
            sources: [.microphone: firstSource]
        )
        try await firstSession.start()
        let firstStream = try await firstSession.liveAudioEvents(for: .microphone).stream
        let firstKinds = EventKindCollector()
        let firstCollector = Task {
            for await event in firstStream {
                switch event {
                case .buffer: firstKinds.append("buffer")
                case .gapStarted: firstKinds.append("gapStarted")
                case .gapEnded: firstKinds.append("gapEnded")
                }
            }
        }
        await firstSource.emit(syntheticBuffer(amplitude: 0.5))
        try await waitUntilAppend { firstKinds.all.contains("buffer") }
        _ = try await firstSession.stop()
        await firstCollector.value
        // The live stream is deliberately lossy (`bufferingNewest`); only
        // the ordering and buffer-only content are guaranteed, not an exact
        // count - the final event may still be in flight when `stop()`
        // closes the stream.
        #expect(firstKinds.all.first == "buffer")
        #expect(firstKinds.all.allSatisfy { $0 == "buffer" })

        // A spent session hands out no new streams.
        await #expect(throws: AudioRecordingError.self) {
            try await firstSession.liveAudioEvents(for: .microphone)
        }

        // The appended session starts a FRESH lane at local time zero; it
        // neither replays nor waits on the previous session's stream. The
        // upstream offset mapping turns this local zero into absolute
        // meeting time (after everything recorded before it).
        let secondSource = FakeAppendAudioSource(track: .microphone)
        let secondSession = makeSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: captureDirectory,
            sources: [.microphone: secondSource]
        )
        try await secondSession.start()
        let secondStream = try await secondSession.liveAudioEvents(for: .microphone).stream
        let secondKinds = EventKindCollector()
        let secondCollector = Task {
            for await event in secondStream {
                switch event {
                case .buffer: secondKinds.append("buffer")
                case .gapStarted: secondKinds.append("gapStarted")
                case .gapEnded: secondKinds.append("gapEnded")
                }
            }
        }
        await secondSource.emit(syntheticBuffer(amplitude: 0.25))
        await secondSource.emit(syntheticBuffer(amplitude: 0.25))
        try await waitUntilAppend { secondKinds.all.count == 2 }
        _ = try await secondSession.stop()
        await secondCollector.value

        // Independence: the appended lane carries only its own buffers, and
        // nothing from the first session's stream leaked into it.
        #expect(!secondKinds.all.isEmpty)
        #expect(secondKinds.all.allSatisfy { $0 == "buffer" })

        let assets = try await library.listMediaAssets(meetingID: meeting.id)
        #expect(Set(assets.map(\.provenanceKey)) == [
            "\(meeting.id)/micTrack",
            "\(meeting.id)/micTrack#2",
        ])
    }

    @Test("leftover capture files from a killed session do not block an appended session")
    func leftoverCaptureFilesDoNotBlockAppending() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try Library.open(at: directory.appendingPathComponent("Library"))
        let meeting = try await library.createMeeting(
            title: "After kill -9",
            status: .recording
        )
        let captureDirectory = library.layout.captureDirectory(meeting.id)

        // A clean first stop produced one registered original ...
        let seedURL = directory.appendingPathComponent("seed-mic.caf")
        try Data(MediaAsset.Kind.micTrack.rawValue.utf8).write(to: seedURL)
        _ = try await library.registerMediaAsset(
            for: meeting.id,
            sourceURL: seedURL,
            kind: .micTrack,
            sampleRate: 16_000,
            duration: 1
        )

        // ... while a later hard crash stranded an unregistered capture file.
        let orphanURL = captureDirectory.appendingPathComponent(
            "\(meeting.id)-microphone-\(UUID()).caf"
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        // CAF writing requires an interleaved file layout; a non-interleaved
        // setting makes ExtAudioFileCreateWithURL fail with -50.
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        // ExtAudioFile cannot create files inside a missing directory.
        try FileManager.default.createDirectory(
            at: orphanURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let orphanFile = try AVAudioFile(
            forWriting: orphanURL,
            settings: settings
        )
        let orphanBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 16_000
        )!
        orphanBuffer.frameLength = 16_000
        try orphanFile.write(from: orphanBuffer)

        // Appending still works: the stranded file belongs to the capture
        // recovery sweep, not to this session's writers.
        let sources = makeSources()
        let appendedSession = makeSession(
            meetingID: meeting.id,
            library: library,
            outputDirectory: captureDirectory,
            sources: sources
        )
        try await appendedSession.start()
        try await recordOneBuffer(sources: sources, session: appendedSession)
        let result = try await appendedSession.stop()

        #expect(result.assets[.microphone]?.provenanceKey
            == "\(meeting.id)/micTrack#2")
        // System tracks sequence independently of microphone tracks: this
        // is the meeting's FIRST system track, so it keeps the plain key.
        #expect(result.assets[.system]?.provenanceKey
            == "\(meeting.id)/systemTrack")

        let captureLeftovers = try FileManager.default.contentsOfDirectory(
            at: captureDirectory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        // Only the killed session's file remains for adoption to pick up.
        #expect(captureLeftovers == [orphanURL.lastPathComponent])

        let assets = try await library.listMediaAssets(meetingID: meeting.id)
        #expect(Set(assets.map(\.provenanceKey)) == [
            "\(meeting.id)/micTrack",
            "\(meeting.id)/micTrack#2",
            "\(meeting.id)/systemTrack",
        ])
    }
}

private actor FakeAppendAudioSource: AudioSource {
    nonisolated let track: AudioTrack
    nonisolated let format: AVAudioFormat
    private var handler: AudioBufferHandler?

    init(track: AudioTrack) {
        self.track = track
        self.format = syntheticBuffer().format
    }

    func prepare() throws -> AVAudioFormat {
        format
    }

    func start(bufferHandler: @escaping AudioBufferHandler) {
        handler = bufferHandler
    }

    func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) {
        handler = bufferHandler
    }

    func stop() {
        handler = nil
    }

    func emit(_ buffer: AVAudioPCMBuffer) async {
        handler?(buffer)
        await Task.yield()
    }
}

private actor FakeAppendActivityManager: RecordingActivityManaging {
    func begin() {}
    func end() {}
}

private func waitUntilAppend(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("timed out waiting for live events")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Thread-safe event-kind collector for streams consumed from detached
/// tasks inside tests.
private final class EventKindCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String] = []

    func append(_ kind: String) {
        lock.lock()
        defer { lock.unlock() }
        kinds.append(kind)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return kinds
    }
}
