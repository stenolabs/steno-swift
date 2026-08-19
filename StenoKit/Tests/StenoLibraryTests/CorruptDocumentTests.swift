import Foundation
import Testing
import StenoDomain
@testable import StenoLibrary

@Suite("Corrupt document quarantine")
struct CorruptDocumentTests {
    @Test("reports and quarantines corrupt JSON without overwriting it")
    func quarantineMeetingDocument() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Meeting", status: .ready)
            let document = library.layout.meetingMetadata(meeting.id)
            let corruptBytes = Data("{not valid json".utf8)
            try corruptBytes.write(to: document)

            do {
                _ = try await library.loadMeeting(meeting.id)
                Issue.record("Expected corruptDocument")
            } catch let error as LibraryError {
                guard case .corruptDocument(let original, let quarantined) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(original == document)
                #expect(quarantined.lastPathComponent.hasPrefix("meeting.json.corrupt-"))
                #expect(!FileManager.default.fileExists(atPath: document.path))
                #expect(try Data(contentsOf: quarantined) == corruptBytes)
            }
        }
    }
}
