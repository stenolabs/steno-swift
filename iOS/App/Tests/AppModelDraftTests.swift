import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline
import Testing
@testable import Steno

@Suite("Draft meetings")
struct AppModelDraftTests {
    @Test("creating a draft persists its status without global navigation")
    @MainActor
    func createDraftPersistsDraftStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Steno-iPad-draft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root)
        let store = try JobStore(layout: library.layout)
        let coordinator = PipelineCoordinator(
            library: library,
            jobStore: store,
            providers: [:],
            locale: Locale(identifier: "de-DE")
        )
        let runtime = PipelineRuntime(
            library: library,
            jobStore: store,
            coordinator: coordinator
        )
        let app = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, _, _ in runtime },
            libraryURL: root
        )
        await app.bootstrap()

        let meetingID = try #require(await app.createDraftMeeting())
        let stored = try await library.loadMeeting(meetingID)

        #expect(stored.status == .draft)
        #expect(app.meetings.map(\.id) == [meetingID])
        #expect(app.selectedMeetingID == nil)
    }
}
