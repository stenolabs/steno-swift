@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import StenoLibrary

/// Adoptiert nach einem harten Absturz die gestrandeten Capture-Dateien
/// unterbrochener Meetings: registriert sie als Originalspuren und reiht
/// den Finalisierungslauf ein. Läuft nach dem RecoverySweep (der Meetings
/// von `recording` auf `interrupted` setzt, aber ohne Spuren keinen Job
/// einreiht).
public enum CaptureRecovery {
    public struct AdoptedMeeting: Equatable, Sendable {
        public let meetingID: MeetingID
        public let adoptedTracks: [AudioTrack]
    }

    @discardableResult
    public static func run(
        library: Library,
        jobStore: JobStore
    ) async throws -> [AdoptedMeeting] {
        var adopted: [AdoptedMeeting] = []
        for meeting in try await library.listMeetings()
        where meeting.status == .interrupted {
            let captureDirectory = library.layout.captureDirectory(meeting.id)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: captureDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            guard !files.isEmpty else { continue }

            var tracks: [AudioTrack] = []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let track = trackFromCaptureFileName(file.lastPathComponent) else {
                    continue
                }
                // Ein Prefix, den AVAudioFile nicht mehr lesen kann, wird
                // liegengelassen und gemeldet, nie gelöscht.
                guard let audioFile = try? AVAudioFile(forReading: file) else {
                    continue
                }
                let sampleRate = audioFile.fileFormat.sampleRate
                let duration = sampleRate > 0
                    ? Double(audioFile.length) / sampleRate
                    : 0
                do {
                    _ = try await library.registerMediaAsset(
                        for: meeting.id,
                        sourceURL: file,
                        kind: track == .microphone ? .micTrack : .systemTrack,
                        sampleRate: sampleRate,
                        duration: duration
                    )
                } catch LibraryError.duplicateProvenance {
                    // Frühere Adoption wurde zwischen Registrierung und
                    // Aufräumen unterbrochen: Asset existiert schon.
                }
                try? FileManager.default.removeItem(at: file)
                tracks.append(track)
            }
            guard !tracks.isEmpty else { continue }

            // Ein früherer Lauf kann bereits als failed dastehen ("has no
            // media assets"); der wird reaktiviert statt dupliziert.
            let existing = try await jobStore.list().filter {
                $0.kind == .finalASR && $0.meetingID == meeting.id
            }
            if let failed = existing.first(where: { $0.status == .failed }) {
                _ = try await jobStore.transition(failed.id, to: .queued)
            } else if !existing.contains(where: {
                $0.status == .queued || $0.status == .running
                    || $0.status == .finished
            }) {
                try await jobStore.enqueue(
                    Job(kind: .finalASR, meetingID: meeting.id)
                )
            }
            adopted.append(
                AdoptedMeeting(meetingID: meeting.id, adoptedTracks: tracks)
            )
        }
        return adopted
    }

    /// Capture-Dateien heißen `<meetingID>-<track>-<uuid>.caf`.
    static func trackFromCaptureFileName(_ name: String) -> AudioTrack? {
        AudioTrack.allCases.first { name.contains("-\($0.rawValue)-") }
    }
}
