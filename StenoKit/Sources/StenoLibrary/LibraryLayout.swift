import Foundation
import StenoDomain

public struct LibraryLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var libraryMetadata: URL { root.appendingPathComponent("library.json") }
    public var meetingsDirectory: URL { root.appendingPathComponent("meetings", isDirectory: true) }
    public var identityDirectory: URL { root.appendingPathComponent("identity", isDirectory: true) }
    public var persons: URL { identityDirectory.appendingPathComponent("persons.json") }
    public var folders: URL { root.appendingPathComponent("folders.json") }
    /// Reparierbarer Cache fuer die lokale Demo-Installation. Die Meeting-
    /// Metadaten bleiben die maßgebliche Besitzinformation.
    public var demoInstallationIndex: URL {
        root.appendingPathComponent("demo-installation-index.json")
    }
    public var jobsDirectory: URL { root.appendingPathComponent("jobs", isDirectory: true) }
    public var exportsDirectory: URL { root.appendingPathComponent("exports", isDirectory: true) }
    public var transferValidationRoot: URL {
        root.deletingLastPathComponent().appending(
            path: ".StenoTransferValidation",
            directoryHint: .isDirectory
        )
    }

    public func meetingDirectory(_ meetingID: MeetingID) -> URL {
        meetingsDirectory.appendingPathComponent(meetingID.description, isDirectory: true)
    }

    public func meetingMetadata(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("meeting.json")
    }

    public func transferCommitPending(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent(
            "transfer-commit-pending.json"
        )
    }

    /// Laufende Aufnahmen schreiben hierhin, INNERHALB des Meeting-Ordners:
    /// nach einem harten Absturz liegen die Spuren damit in der Bibliothek
    /// statt in einem flüchtigen Temp-Verzeichnis und können adoptiert
    /// werden. Beim sauberen Stopp wandern sie nach media/ und dieses
    /// Verzeichnis bleibt leer zurück.
    public func captureDirectory(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent(
            "capture",
            isDirectory: true
        )
    }

    public func mediaDirectory(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("media", isDirectory: true)
    }

    public func mediaFile(_ meetingID: MeetingID, fileName: String) -> URL {
        mediaDirectory(meetingID).appendingPathComponent(fileName)
    }

    public func mediaMetadata(_ meetingID: MeetingID, assetID: MediaAssetID) -> URL {
        mediaDirectory(meetingID).appendingPathComponent("\(assetID).json")
    }

    public func runsDirectory(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("runs", isDirectory: true)
    }

    public func runDirectory(_ meetingID: MeetingID, runID: RunID) -> URL {
        runsDirectory(meetingID).appendingPathComponent(runID.description, isDirectory: true)
    }

    public func runMetadata(_ meetingID: MeetingID, runID: RunID) -> URL {
        runDirectory(meetingID, runID: runID).appendingPathComponent("run.json")
    }

    public func runTranscript(_ meetingID: MeetingID, runID: RunID) -> URL {
        runDirectory(meetingID, runID: runID).appendingPathComponent("transcript.json")
    }

    public func runDiarization(_ meetingID: MeetingID, runID: RunID) -> URL {
        runDirectory(meetingID, runID: runID).appendingPathComponent("diarization.json")
    }

    public func runSuggestions(_ meetingID: MeetingID, runID: RunID) -> URL {
        runDirectory(meetingID, runID: runID).appendingPathComponent("suggestions.json")
    }

    public func runTemplate(_ meetingID: MeetingID, runID: RunID) -> URL {
        runDirectory(meetingID, runID: runID).appendingPathComponent("template.json")
    }

    public func transcriptDirectory(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("transcript", isDirectory: true)
    }

    public func revisionsDirectory(_ meetingID: MeetingID) -> URL {
        transcriptDirectory(meetingID).appendingPathComponent("revisions", isDirectory: true)
    }

    public func revision(_ meetingID: MeetingID, revisionID: RevisionID) -> URL {
        revisionsDirectory(meetingID).appendingPathComponent("\(revisionID).json")
    }

    public func currentRevision(_ meetingID: MeetingID) -> URL {
        transcriptDirectory(meetingID).appendingPathComponent("current.json")
    }

    public func transferState(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("transfer-state.json")
    }

    public func revisionAppendIntent(_ meetingID: MeetingID) -> URL {
        transcriptDirectory(meetingID).appendingPathComponent("append-intent.json")
    }

    public func notesDirectory(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("notes", isDirectory: true)
    }

    /// Die vom Benutzer geschriebene Notiz. Getrennt von `meeting.json`, weil
    /// dort parallel die Statusmaschine schreibt.
    public func userNotes(_ meetingID: MeetingID) -> URL {
        notesDirectory(meetingID).appendingPathComponent("user-notes.md")
    }

    /// Notiz aus dem Steno-Altimport. Sie wird nur gelesen und nie überschrieben;
    /// die erste eigene Änderung landet in `userNotes`.
    public func legacyUserNotes(_ meetingID: MeetingID) -> URL {
        notesDirectory(meetingID).appendingPathComponent("legacy-user-notes.md")
    }

    public func reportsDirectory(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("reports", isDirectory: true)
    }

    public func report(_ meetingID: MeetingID, runID: RunID) -> URL {
        reportsDirectory(meetingID).appendingPathComponent("\(runID).json")
    }

    public func job(_ jobID: JobID) -> URL {
        jobsDirectory.appendingPathComponent("\(jobID).json")
    }
}
