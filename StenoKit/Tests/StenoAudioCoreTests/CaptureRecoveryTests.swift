@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import StenoLibrary
@testable import StenoAudioCore
import Testing

@Suite("Capture recovery")
struct CaptureRecoveryTests {
    private func makeLibrary() throws -> (Library, JobStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-recovery-\(UUID())", isDirectory: true)
        let library = try Library.open(at: root)
        let jobStore = try JobStore(layout: library.layout)
        return (library, jobStore, root)
    }

    private func writeCaptureFile(
        _ library: Library,
        meetingID: MeetingID,
        track: AudioTrack,
        seconds: Double = 0.25
    ) throws -> URL {
        let directory = library.layout.captureDirectory(meetingID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "\(meetingID)-\(track.rawValue)-\(UUID()).caf"
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    @Test("sweep without assets enqueues nothing, adoption registers and queues")
    func adoptionAfterHardCrash() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let meeting = try await library.createMeeting(
            title: "Killed",
            status: .recording
        )
        _ = try writeCaptureFile(library, meetingID: meeting.id, track: .microphone)
        _ = try writeCaptureFile(library, meetingID: meeting.id, track: .system)

        let interrupted = try await RecoverySweep.run(
            library: library,
            jobStore: jobStore
        )
        #expect(interrupted == [meeting.id])
        #expect(try await jobStore.list().isEmpty)

        let adopted = try await CaptureRecovery.run(
            library: library,
            jobStore: jobStore
        )
        #expect(adopted.count == 1)
        #expect(adopted[0].adoptedTracks.sorted { $0.rawValue < $1.rawValue }
            == [.microphone, .system])

        let assets = try await library.listMediaAssets(meetingID: meeting.id)
        #expect(assets.map(\.kind).sorted { $0.rawValue < $1.rawValue }
            == [.micTrack, .systemTrack])
        let jobs = try await jobStore.list()
        #expect(jobs.count == 1)
        #expect(jobs[0].kind == .finalASR && jobs[0].status == .queued)

        let captureLeftovers = (try? FileManager.default.contentsOfDirectory(
            at: library.layout.captureDirectory(meeting.id),
            includingPropertiesForKeys: nil
        )) ?? []
        #expect(captureLeftovers.isEmpty)
    }

    @Test("adoption reactivates an existing failed finalASR job")
    func reactivatesFailedJob() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let meeting = try await library.createMeeting(
            title: "Killed",
            status: .interrupted
        )
        let job = Job(kind: .finalASR, meetingID: meeting.id)
        try await jobStore.enqueue(job)
        _ = try await jobStore.transition(job.id, to: .running)
        _ = try await jobStore.transition(
            job.id,
            to: .failed,
            errorMessage: "has no media assets"
        )
        _ = try writeCaptureFile(library, meetingID: meeting.id, track: .microphone)

        _ = try await CaptureRecovery.run(library: library, jobStore: jobStore)

        let jobs = try await jobStore.list()
        #expect(jobs.count == 1)
        #expect(jobs[0].status == .queued)
    }

    @Test("meetings without capture files are left alone")
    func ignoresMeetingsWithoutCapture() async throws {
        let (library, jobStore, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await library.createMeeting(title: "Clean", status: .interrupted)
        let adopted = try await CaptureRecovery.run(
            library: library,
            jobStore: jobStore
        )
        #expect(adopted.isEmpty)
        #expect(try await jobStore.list().isEmpty)
    }
}
