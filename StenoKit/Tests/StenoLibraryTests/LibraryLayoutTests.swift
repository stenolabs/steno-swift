import Foundation
import Testing
import StenoDomain
@testable import StenoLibrary

@Suite("LibraryLayout")
struct LibraryLayoutTests {
    @Test("derives the complete architecture layout from typed IDs")
    func documentedPaths() {
        let root = URL(fileURLWithPath: "/tmp/StenoLibrary", isDirectory: true)
        let layout = LibraryLayout(root: root)
        let meetingID = MeetingID(
            rawValue: UUID(uuidString: "018bcfe5-6800-7000-8000-000000000001")!
        )
        let assetID = MediaAssetID(
            rawValue: UUID(uuidString: "018bcfe5-6800-7000-8000-000000000002")!
        )
        let runID = RunID(
            rawValue: UUID(uuidString: "018bcfe5-6800-7000-8000-000000000003")!
        )
        let revisionID = RevisionID(
            rawValue: UUID(uuidString: "018bcfe5-6800-7000-8000-000000000004")!
        )
        let jobID = JobID(
            rawValue: UUID(uuidString: "018bcfe5-6800-7000-8000-000000000005")!
        )
        let meeting = "/tmp/StenoLibrary/meetings/\(meetingID)"

        #expect(layout.libraryMetadata.path == "/tmp/StenoLibrary/library.json")
        #expect(layout.meetingDirectory(meetingID).path == meeting)
        #expect(layout.meetingMetadata(meetingID).path == "\(meeting)/meeting.json")
        #expect(layout.mediaDirectory(meetingID).path == "\(meeting)/media")
        #expect(layout.mediaFile(meetingID, fileName: "\(assetID).caf").path == "\(meeting)/media/\(assetID).caf")
        #expect(layout.mediaMetadata(meetingID, assetID: assetID).path == "\(meeting)/media/\(assetID).json")
        #expect(layout.runDirectory(meetingID, runID: runID).path == "\(meeting)/runs/\(runID)")
        #expect(layout.runMetadata(meetingID, runID: runID).path == "\(meeting)/runs/\(runID)/run.json")
        #expect(layout.runTranscript(meetingID, runID: runID).path == "\(meeting)/runs/\(runID)/transcript.json")
        #expect(layout.runDiarization(meetingID, runID: runID).path == "\(meeting)/runs/\(runID)/diarization.json")
        #expect(layout.runSuggestions(meetingID, runID: runID).path == "\(meeting)/runs/\(runID)/suggestions.json")
        #expect(layout.revision(meetingID, revisionID: revisionID).path == "\(meeting)/transcript/revisions/\(revisionID).json")
        #expect(layout.currentRevision(meetingID).path == "\(meeting)/transcript/current.json")
        #expect(layout.transferState(meetingID).path == "\(meeting)/transfer-state.json")
        #expect(layout.revisionAppendIntent(meetingID).path == "\(meeting)/transcript/append-intent.json")
        #expect(layout.notesDirectory(meetingID).path == "\(meeting)/notes")
        #expect(layout.reportsDirectory(meetingID).path == "\(meeting)/reports")
        #expect(layout.persons.path == "/tmp/StenoLibrary/identity/persons.json")
        #expect(layout.job(jobID).path == "/tmp/StenoLibrary/jobs/\(jobID).json")
        #expect(layout.exportsDirectory.path == "/tmp/StenoLibrary/exports")
        #expect(layout.transferValidationRoot.path == "/tmp/.StenoTransferValidation")
    }

    @Test("derives transfer validation beside each library root")
    func transferValidationRootIsSiblingForMacAndIOSLibraries() {
        let mac = LibraryLayout(root: URL(fileURLWithPath: "/Users/ada/Library/Application Support/Steno/Library"))
        let ios = LibraryLayout(root: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/UUID/Library/Steno"))

        #expect(mac.transferValidationRoot.path == "/Users/ada/Library/Application Support/Steno/.StenoTransferValidation")
        #expect(ios.transferValidationRoot.path == "/private/var/mobile/Containers/Data/Application/UUID/Library/.StenoTransferValidation")
        #expect(!mac.transferValidationRoot.path.contains("/meetings/"))
        #expect(!ios.transferValidationRoot.path.contains("/meetings/"))
    }
}
