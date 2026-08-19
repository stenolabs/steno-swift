// steno-smoke: End-to-End-Rauchtest ohne UI.
// Nutzung: steno-smoke <library-dir> <audio-datei>
// Importiert die Datei in eine frische Bibliothek, lässt den finalen
// SpeechAnalyzer-Lauf über die Pipeline laufen und druckt das Transkript.

import AVFAudio
import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline
import StenoTranscription

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("steno-smoke: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: steno-smoke <library-dir> <audio-file>")
}
let libraryURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let audioURL = URL(fileURLWithPath: CommandLine.arguments[2])

// Top-Level-await statt Task+Semaphore: Top-Level-Code ist MainActor-isoliert,
// ein blockierter Main Thread würde den eigenen Task nie laufen lassen.
do {
    let runtime = try await startPipeline(
        at: libraryURL,
        providers: [.imported: SpeechAnalyzerProvider(channel: .system)],
        locale: Locale(identifier: "de-DE")
    )
    print("Bibliothek geöffnet: \(libraryURL.path)")

    let file = try AVAudioFile(forReading: audioURL)
    let sampleRate = file.fileFormat.sampleRate
    let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
    let meeting = try await runtime.library.createMeeting(
        title: audioURL.lastPathComponent,
        status: .processing
    )
    _ = try await runtime.library.registerMediaAsset(
        for: meeting.id,
        sourceURL: audioURL,
        kind: .imported,
        sampleRate: sampleRate,
        duration: duration
    )
    print("Import: \(audioURL.lastPathComponent), \(String(format: "%.1f", duration)) s")

    try await runtime.jobStore.enqueue(Job(kind: .finalASR, meetingID: meeting.id))

    let deadline = Date().addingTimeInterval(600)
    while Date() < deadline {
        let jobs = try await runtime.jobStore.list()
            .filter { $0.meetingID == meeting.id }
        if let failed = jobs.first(where: { $0.status == .failed }) {
            fail("Job fehlgeschlagen: \(failed.errorMessage ?? "unbekannt")")
        }
        if let job = jobs.first(where: { $0.kind == .finalASR }) {
            switch job.status {
            case .finished:
                let revision = try await runtime.library.loadCurrentRevision(
                    meetingID: meeting.id
                )
                print("Transkript (\(revision.turns.count) Turns):")
                for turn in revision.turns {
                    let text = turn.segments.map(\.text).joined(separator: " ")
                    let words = turn.segments.reduce(0) { $0 + $1.words.count }
                    print(String(
                        format: "  [%05.1fs-%05.1fs] (%d Wörter) %@",
                        turn.start, turn.end, words, text
                    ))
                }
                let wordCount = revision.turns
                    .flatMap(\.segments)
                    .reduce(0) { $0 + $1.words.count }
                guard wordCount > 0 else {
                    fail("Transkript enthält keine Wortzeitstempel")
                }
                print("OK: \(wordCount) Wörter mit Zeitstempeln")
                // M3-Kette: auf Diarisierung + Vorschläge warten und prüfen.
                try await runtime.coordinator.waitUntilIdle()
                guard let review = try await MeetingReviewAssembler.load(
                    library: runtime.library,
                    meetingID: meeting.id
                ) else {
                    fail("keine Review-Daten nach der Job-Kette")
                }
                print("Diarisierung: \(review.clusters.count) Cluster, "
                    + "\(review.suggestions.count) Vorschläge, "
                    + "Embeddings je Cluster: "
                    + "\(review.clusters.map { $0.embedding.count }.description)")
                guard !review.clusters.isEmpty else {
                    fail("Diarisierung lieferte keine Cluster")
                }
                print("OK: M3-Kette vollständig")
                exit(0)
            case .failed:
                fail("Job fehlgeschlagen: \(job.errorMessage ?? "unbekannt")")
            default:
                break
            }
        }
        try await Task.sleep(for: .seconds(1))
    }
    fail("Timeout nach 600 s")
} catch {
    fail(String(describing: error))
}
