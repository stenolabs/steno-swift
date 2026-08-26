import Foundation
import StenoDomain

public enum RecoverySweep {
    @discardableResult
    public static func run(
        library: Library,
        jobStore: JobStore,
        activeMeetingIDs: Set<MeetingID> = []
    ) async throws -> [MeetingID] {
        let meetings = try await library.listMeetings()
        var interrupted: [MeetingID] = []

        for meeting in meetings
        where meeting.status == .recording && !activeMeetingIDs.contains(meeting.id) {
            // Einen Finalisierungslauf gibt es nur, wenn Originalspuren
            // registriert sind. Nach einem harten Absturz liegen die
            // Capture-Dateien noch unregistriert im Meeting-Ordner; deren
            // Adoption (und das Einreihen des Jobs) übernimmt die
            // plattformspezifische Capture-Recovery nach diesem Sweep.
            //
            // Liegen noch gestrandete Capture-Dateien, reiht dieser Sweep
            // bewusst NICHT ein - auch nicht, wenn schon ältere Spuren
            // existieren (angehangene Aufnahme): Der Job liefe sonst gegen
            // einen unvollständigen Spurstand, bevor die Adoption die
            // fehlenden Dateien registriert hat.
            let hasStrandedCaptures = Self.hasStrandedCaptureFiles(
                meetingID: meeting.id,
                layout: library.layout
            )
            let hasAssets = try await !library.listMediaAssets(
                meetingID: meeting.id
            ).isEmpty
            if hasAssets, !hasStrandedCaptures, try await !jobStore.containsJob(
                kind: .finalASR,
                meetingID: meeting.id,
                processingGenerationID: meeting.processingGenerationID
            ) {
                try await jobStore.enqueue(
                    Job.finalASR(for: meeting)
                )
            }
            _ = try await library.updateMeetingStatus(
                meeting.id,
                to: .interrupted
            )
            interrupted.append(meeting.id)
        }

        return interrupted
    }

    /// True, wenn im Capture-Ordner des Meetings noch unregistrierte
    /// Aufnahmedateien auf ihre Adoption warten.
    private static func hasStrandedCaptureFiles(
        meetingID: MeetingID,
        layout: LibraryLayout
    ) -> Bool {
        let captureDirectory = layout.captureDirectory(meetingID)
        guard FileManager.default.fileExists(atPath: captureDirectory.path) else {
            return false
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: captureDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return !contents.isEmpty
    }
}
