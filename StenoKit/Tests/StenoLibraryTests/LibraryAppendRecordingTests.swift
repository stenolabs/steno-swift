import Foundation
import AVFAudio
import StenoDomain
@testable import StenoAudioCore
@testable import StenoLibrary
import Testing

@Suite("Append-to-meeting library behavior")
struct LibraryAppendRecordingTests {
    private func makeLibrary() throws -> (Library, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("append-recording-\(UUID())", isDirectory: true)
        let library = try Library.open(at: root)
        return (library, root)
    }

    private func writeTemporaryCAF(
        in directory: URL,
        name: String
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(name)
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
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        try file.write(from: buffer)
        return url
    }

    @Test("a continued session registers distinct sequenced keys")
    func continuedSessionRegistersSequencedKeys() async throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let meeting = try await library.createMeeting(title: "Appended", status: .draft)
        let firstSource = try writeTemporaryCAF(
            in: root,
            name: "first-mic.caf"
        )
        let first = try await library.registerMediaAsset(
            for: meeting.id,
            sourceURL: firstSource,
            kind: .micTrack,
            sampleRate: 16_000,
            duration: 1
        )
        // Die erste Spur behaelt den historischen Schluessel - bestehende
        // Bibliotheken, Alt-Importe und Dedup-Lookups bleiben unberuehrt.
        #expect(first.provenanceKey == "\(meeting.id)/micTrack")

        let secondSource = try writeTemporaryCAF(
            in: root,
            name: "second-mic.caf"
        )
        let second = try await library.registerMediaAsset(
            for: meeting.id,
            sourceURL: secondSource,
            kind: .micTrack,
            sampleRate: 16_000,
            duration: 2
        )
        #expect(second.provenanceKey == "\(meeting.id)/micTrack#2")
        #expect(second.id != first.id)

        // System-Spuren zaehlen unabhängig von den Mikrofon-Spuren.
        let systemSource = try writeTemporaryCAF(
            in: root,
            name: "first-system.caf"
        )
        let systemFirst = try await library.registerMediaAsset(
            for: meeting.id,
            sourceURL: systemSource,
            kind: .systemTrack,
            sampleRate: 16_000,
            duration: 1
        )
        #expect(systemFirst.provenanceKey == "\(meeting.id)/systemTrack")

        let assets = try await library.listMediaAssets(meetingID: meeting.id)
        #expect(Set(assets.map(\.provenanceKey)).count == assets.count)
    }

    @Test("imported assets still reject duplicate provenance")
    func importedDuplicatesStillRejected() async throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let meeting = try await library.createMeeting(title: "Imported", status: .ready)
        let source = root.appendingPathComponent("import.bin")
        try Data("identical".utf8).write(to: source)

        _ = try await library.registerMediaAsset(
            for: meeting.id,
            sourceURL: source,
            kind: .imported,
            sampleRate: 48_000,
            duration: 0
        )
        do {
            _ = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: source,
                kind: .imported,
                sampleRate: 48_000,
                duration: 0
            )
            Issue.record("Expected duplicateProvenance")
        } catch let error as LibraryError {
            guard case .duplicateProvenance = error else {
                Issue.record("Unexpected LibraryError \(error)")
                return
            }
        }
    }

    @Test("recovery sweep waits for stranded captures before queueing final ASR")
    func sweepGatesOnStrandedCaptures() async throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobStore = try JobStore(layout: library.layout)

        let meeting = try await library.createMeeting(title: "Appended recovery", status: .recording)
        let source = try writeTemporaryCAF(in: root, name: "existing.caf")
        _ = try await library.registerMediaAsset(
            for: meeting.id,
            sourceURL: source,
            kind: .micTrack,
            sampleRate: 16_000,
            duration: 1
        )

        // Angehangene Aufnahme hart gestorben: alte Spuren existieren, die
        // neue Capture-Datei liegt noch im Meeting-Ordner. Der Sweep darf
        // den Finalisierungslauf NICHT einreihen - der Job liefe sonst
        // gegen einen unvollstaendigen Spurstand.
        let captureDirectory = library.layout.captureDirectory(meeting.id)
        _ = try writeTemporaryCAF(
            in: captureDirectory,
            name: "\(meeting.id)-microphone-\(UUID()).caf"
        )
        // Phase 1: Der Sweep reiht bewusst NICHT ein, solange gestrandete
        // Capture-Dateien liegen - der Job liefe sonst gegen einen
        // unvollstaendigen Spurstand. Er markiert das Meeting interrupted.
        _ = try await RecoverySweep.run(library: library, jobStore: jobStore)
        #expect(try await jobStore.list().isEmpty)
        #expect(try await library.loadMeeting(meeting.id).status == .interrupted)

        // Phase 2: Die Adoption (Bootstrap-Pfad) uebernimmt die gestrandete
        // Datei und reiht genau einen Finalisierungslauf ein.
        let report = try await CaptureRecovery.run(library: library, jobStore: jobStore)
        #expect(report.adoptedMeetings.count == 1)
        #expect(report.failures.isEmpty)
        let jobs = try await jobStore.list()
        #expect(jobs.count == 1)
        #expect(jobs[0].kind == .finalASR && jobs[0].status == .queued)

        // Der Statuswechsel zu interrupted bleibt davon unberuehrt.
        let swept = try await library.loadMeeting(meeting.id)
        #expect(swept.status == .interrupted)
    }

    @Test("media asset recovery assigns sequenced keys to adopted orphans")
    func recoveryAdoptsOrphansWithSequences() async throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobStore = try JobStore(layout: library.layout)

        let meeting = try await library.createMeeting(title: "Appended recovery", status: .recording)
        let existingSource = try writeTemporaryCAF(in: root, name: "existing.caf")
        _ = try await library.registerMediaAsset(
            for: meeting.id,
            sourceURL: existingSource,
            kind: .micTrack,
            sampleRate: 16_000,
            duration: 1
        )
        _ = try await library.updateMeetingStatus(meeting.id, to: .interrupted)

        // Zwei verwaiste Medien-Dateien ohne Metadaten: eine zweite
        // Mikrofon-Spur (angehangene Aufnahme) und eine System-Spur.
        let mediaDirectory = library.layout.mediaDirectory(meeting.id)
        _ = try writeTemporaryCAF(
            in: mediaDirectory,
            name: "\(UUID())-micTrack.caf"
        )
        _ = try writeTemporaryCAF(
            in: mediaDirectory,
            name: "\(UUID())-systemTrack.caf"
        )

        let report = try MediaAssetRecovery.recoverAll(layout: library.layout)
        #expect(report.issues.isEmpty)
        #expect(report.recoveredAssets.count == 2)

        let assets = try await library.listMediaAssets(meetingID: meeting.id)
        let keys = Set(assets.map(\.provenanceKey))
        #expect(keys.contains("\(meeting.id)/micTrack"))
        #expect(keys.contains("\(meeting.id)/micTrack#2"))
        #expect(keys.contains("\(meeting.id)/systemTrack"))
        #expect(assets.count == 3)
    }
}
