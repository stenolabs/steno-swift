import AVFAudio
import Foundation
import StenoDomain
import StenoExchange
import Testing
@testable import steno_macos

@Suite("Audio export presentation")
@MainActor
struct AudioExportPresentationTests {
    @Test("progress backlog keeps only the newest value while the UI is busy")
    func progressBacklogCoalesces() async {
        let (updates, continuation) = AudioExportProgressStream.make()
        for completedFrames in 0...10 {
            continuation.yield(.init(
                completedFrames: AVAudioFramePosition(completedFrames),
                totalFrames: 10
            ))
        }
        continuation.finish()

        var received: [AVAudioFramePosition] = []
        for await update in updates {
            received.append(update.completedFrames)
        }

        #expect(received == [10])
    }

    @Test("one microphone and one system asset add one combined option after originals")
    func offersStereoForOneUnambiguousPair() {
        let microphone = asset(kind: .micTrack, fileName: "microphone.caf")
        let system = asset(kind: .systemTrack, fileName: "system.caf")

        let options = AudioExportPresentation.options(for: [microphone, system])

        #expect(options.map(\.kind) == [.original, .original, .stereoM4A])
        #expect(options.map(\.label) == [
            "Microphone",
            "System audio",
            "Both tracks - stereo M4A",
        ])
    }

    @Test("multiple microphone assets never guess a stereo pair")
    func multipleMicrophonesDoNotOfferStereo() {
        let microphone1 = asset(kind: .micTrack, fileName: "microphone-1.caf")
        let microphone2 = asset(kind: .micTrack, fileName: "microphone-2.caf")
        let system = asset(kind: .systemTrack, fileName: "system.caf")

        let options = AudioExportPresentation.options(for: [
            microphone1,
            microphone2,
            system,
        ])

        #expect(!options.contains { $0.kind == .stereoM4A })
    }

    @Test("multiple system assets never guess a stereo pair")
    func multipleSystemTracksDoNotOfferStereo() {
        let microphone = asset(kind: .micTrack, fileName: "microphone.caf")
        let system1 = asset(kind: .systemTrack, fileName: "system-1.caf")
        let system2 = asset(kind: .systemTrack, fileName: "system-2.caf")

        let options = AudioExportPresentation.options(for: [
            microphone,
            system1,
            system2,
        ])

        #expect(!options.contains { $0.kind == .stereoM4A })
    }

    @Test("imported and single-track assets remain original-only choices")
    func nonPairableAssetsStayOriginalOnly() {
        let imported = asset(kind: .imported, fileName: "imported.m4a")

        let options = AudioExportPresentation.options(for: [imported])

        #expect(options.map(\.kind) == [.original])
        #expect(options.map(\.label) == ["Imported track"])
    }

    @Test("an existing unreadable microphone never enables stereo export")
    func unreadableMicrophoneDoesNotOfferStereo() async throws {
        let directory = try makeAudioExportTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = asset(kind: .micTrack, fileName: "microphone.caf")
        let system = asset(kind: .systemTrack, fileName: "system.caf")
        try Data("not audio".utf8).write(
            to: directory.appending(path: microphone.fileName)
        )
        try writeReadableAudio(
            to: directory.appending(path: system.fileName)
        )

        let options = await AudioExportPresentation.options(
            for: [microphone, system],
            resolvingURLWith: { directory.appending(path: $0.fileName) }
        )

        #expect(options.map(\.kind) == [.original])
        #expect(options.map(\.label) == ["System audio"])
    }

    @Test("an unreadable extra microphone does not make a readable pair ambiguous")
    func unreadableExtraMicrophoneKeepsStereoPair() async throws {
        let directory = try makeAudioExportTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = asset(kind: .micTrack, fileName: "microphone.caf")
        let unreadableMicrophone = asset(
            kind: .micTrack,
            fileName: "unreadable-microphone.caf"
        )
        let system = asset(kind: .systemTrack, fileName: "system.caf")
        try writeReadableAudio(
            to: directory.appending(path: microphone.fileName)
        )
        try Data("not audio".utf8).write(
            to: directory.appending(path: unreadableMicrophone.fileName)
        )
        try writeReadableAudio(
            to: directory.appending(path: system.fileName)
        )

        let options = await AudioExportPresentation.options(
            for: [microphone, unreadableMicrophone, system],
            resolvingURLWith: { directory.appending(path: $0.fileName) }
        )

        #expect(options.map(\.kind) == [.original, .original, .stereoM4A])
        #expect(options.compactMap(\.originalAsset) == [microphone, system])
    }

    @Test("unreadable assets never appear as original export choices")
    func unreadableAssetsAreNotOriginalChoices() async throws {
        let directory = try makeAudioExportTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = asset(kind: .imported, fileName: "imported.m4a")
        try Data("not audio".utf8).write(
            to: directory.appending(path: imported.fileName)
        )

        let options = await AudioExportPresentation.options(
            for: [imported],
            resolvingURLWith: { directory.appending(path: $0.fileName) }
        )

        #expect(options.isEmpty)
    }

    @Test("the dialog request is created only after its choices have loaded")
    func dialogRequestOwnsLoadedChoices() async {
        let meeting = Meeting(title: "Export test", status: .ready)
        let microphone = asset(kind: .micTrack, fileName: "microphone.caf")

        let request = await AudioExportDialogRequest.load(for: meeting) { _ in
            [.original(asset: microphone, label: "Microphone")]
        }

        #expect(request?.meeting == meeting)
        #expect(request?.options.map(\.kind) == [.original])
    }

    @Test("missing readable tracks never opens an empty dialog")
    func emptyChoicesDoNotCreateDialogRequest() async {
        let meeting = Meeting(title: "Export test", status: .ready)

        let request = await AudioExportDialogRequest.load(for: meeting) { _ in [] }

        #expect(request == nil)
    }

    @Test("stereo filename uses only a safe meeting title and preserves md text")
    func stereoFileNameUsesMeetingTitleOnly() {
        let meeting = Meeting(
            title: "Board review.md / follow-up",
            createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            status: .ready
        )

        #expect(
            AudioExportPresentation.stereoFileName(for: meeting)
                == "Board review.md follow-up - Microphone left, System right.m4a"
        )
    }

    @Test("a combined export publishes progress and clears activity after success")
    func combinedExportProgress() async {
        let gate = ExportGate()
        let app = AppModel(stereoAudioExportPerformer: {
            _, _, _, progress in
            progress(.init(completedFrames: 25, totalFrames: 100))
            await gate.wait()
            progress(.init(completedFrames: 100, totalFrames: 100))
        })
        let task = Task {
            await app.performStereoAudioExport(
                microphoneURL: URL(fileURLWithPath: "/microphone.caf"),
                systemURL: URL(fileURLWithPath: "/system.caf"),
                destinationURL: URL(fileURLWithPath: "/combined.m4a"),
                meetingID: MeetingID(),
                fileName: "combined.m4a"
            )
        }

        await gate.waitUntilEntered()
        #expect(app.audioExportActivity?.fraction == 0.25)
        await gate.release()
        await task.value
        #expect(app.audioExportActivity == nil)
        #expect(app.notice?.isError == false)
    }

    @Test("a second combined export is rejected while the first runs")
    func duplicateCombinedExportIsRejected() async {
        let gate = ExportGate()
        let app = AppModel(stereoAudioExportPerformer: {
            _, _, _, _ in await gate.wait()
        })
        let firstMeetingID = MeetingID()
        let first = Task {
            await app.performStereoAudioExport(
                microphoneURL: URL(fileURLWithPath: "/microphone.caf"),
                systemURL: URL(fileURLWithPath: "/system.caf"),
                destinationURL: URL(fileURLWithPath: "/combined.m4a"),
                meetingID: firstMeetingID,
                fileName: "combined.m4a"
            )
        }
        await gate.waitUntilEntered()

        await app.performStereoAudioExport(
            microphoneURL: URL(fileURLWithPath: "/other-microphone.caf"),
            systemURL: URL(fileURLWithPath: "/other-system.caf"),
            destinationURL: URL(fileURLWithPath: "/other.m4a"),
            meetingID: MeetingID(),
            fileName: "other.m4a"
        )

        #expect(app.audioExportActivity?.meetingID == firstMeetingID)
        #expect(app.notice?.isError == true)
        await gate.release()
        await first.value
    }

    @Test("a combined export failure clears progress and reports the error")
    func combinedExportFailureIsVisible() async {
        let app = AppModel(stereoAudioExportPerformer: {
            _, _, _, _ in throw AudioExportTestError.failed
        })

        await app.performStereoAudioExport(
            microphoneURL: URL(fileURLWithPath: "/microphone.caf"),
            systemURL: URL(fileURLWithPath: "/system.caf"),
            destinationURL: URL(fileURLWithPath: "/combined.m4a"),
            meetingID: MeetingID(),
            fileName: "combined.m4a"
        )

        #expect(app.audioExportActivity == nil)
        #expect(app.notice?.isError == true)
        #expect(app.notice?.text.contains("could not be saved") == true)
        #expect(app.notice?.text.contains("originals remain") == true)
    }

    @Test("cancelling a combined export clears activity without reporting success")
    func combinedExportCancellation() async {
        let gate = ExportGate()
        let app = AppModel(stereoAudioExportPerformer: {
            _, _, _, _ in await gate.wait()
        })
        let task = Task {
            await app.performStereoAudioExport(
                microphoneURL: URL(fileURLWithPath: "/microphone.caf"),
                systemURL: URL(fileURLWithPath: "/system.caf"),
                destinationURL: URL(fileURLWithPath: "/combined.m4a"),
                meetingID: MeetingID(),
                fileName: "combined.m4a"
            )
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        await task.value

        #expect(app.audioExportActivity == nil)
        #expect(app.notice == nil)
    }

    private func asset(kind: MediaAsset.Kind, fileName: String) -> MediaAsset {
        MediaAsset(
            meetingID: MeetingID(),
            kind: kind,
            sampleRate: 48_000,
            duration: 60,
            provenanceKey: "test-\(fileName)",
            fileName: fileName
        )
    }
}

private actor ExportGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false

    func wait() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private enum AudioExportTestError: Error {
    case failed
}

private extension AudioExportOption {
    var originalAsset: MediaAsset? {
        guard case let .original(asset, _) = self else { return nil }
        return asset
    }
}

private func makeAudioExportTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "Steno-AudioExportPresentationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func writeReadableAudio(to url: URL) throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: 1_024
    ))
    buffer.frameLength = 1_024
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try file.write(from: buffer)
}
