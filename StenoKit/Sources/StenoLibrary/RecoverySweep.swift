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
            let hasAssets = try await !library.listMediaAssets(
                meetingID: meeting.id
            ).isEmpty
            if hasAssets, try await !jobStore.containsJob(
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
}
