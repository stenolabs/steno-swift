import Foundation
import StenoDomain
import Testing
@testable import steno_macos

@Suite("App model folder behavior")
@MainActor
struct AppModelFolderBehaviorTests {
    @Test("a failed folder refresh keeps the last visible folder structure")
    func failedFolderRefreshKeepsVisibleFolders() async throws {
        try await withIsolatedModel { model, libraryURL in
            let folder = try #require(
                await model.createFolder(named: "Arbeit")
            )
            let visibleFolders = model.folders
            #expect(visibleFolders == [folder])

            let foldersURL = libraryURL.appendingPathComponent("folders.json")
            let persistedFolders = try Data(contentsOf: foldersURL)

            try Data("{".utf8).write(
                to: foldersURL
            )
            await model.refreshMeetings()

            #expect(model.folders == visibleFolders)
            #expect(model.startupState == .ready)
            #expect(model.runtime != nil)
            #expect(model.canStartRecording)
            let issue = try #require(
                model.libraryIssues.first { $0.id == .folders }
            )

            try persistedFolders.write(to: foldersURL)
            await model.retryLibraryIssue(issue)

            #expect(model.libraryIssues.allSatisfy { $0.id != .folders })
            #expect(model.folders == visibleFolders)
        }
    }

    @Test("a meeting-list retry preserves the open runtime and existing meetings")
    func meetingListRetryDoesNotRestartTheRuntime() async throws {
        try await withIsolatedModel { model, libraryURL in
            let runtime = try #require(model.runtime)
            _ = try #require(await model.createFolder(named: "Retained folder"))
            let meeting = try await runtime.library.createMeeting(
                title: "Persisted meeting",
                status: .ready
            )
            await model.refreshMeetings()
            #expect(model.meetings.contains { $0.id == meeting.id })

            let metadataURL = runtime.library.layout.meetingMetadata(meeting.id)
            let persistedMetadata = try Data(contentsOf: metadataURL)
            let foldersURL = libraryURL.appendingPathComponent("folders.json")
            let persistedFolders = try Data(contentsOf: foldersURL)
            try Data("{".utf8).write(to: metadataURL)
            try Data("{".utf8).write(to: foldersURL)

            await model.refreshMeetings()

            #expect(model.startupState == .ready)
            #expect(model.runtime != nil)
            #expect(model.canStartRecording)
            #expect(model.meetings.contains { $0.id == meeting.id })
            let issue = try #require(
                model.libraryIssues.first { $0.id == .meetings }
            )
            #expect(model.libraryIssues.contains { $0.id == .folders })

            try persistedMetadata.write(to: metadataURL)
            await model.retryLibraryIssue(issue)

            #expect(model.libraryIssues.allSatisfy { $0.id != .meetings })
            #expect(model.libraryIssues.contains { $0.id == .folders })
            #expect(model.meetings.contains { $0.id == meeting.id })
            #expect(model.runtime?.library === runtime.library)

            try persistedFolders.write(to: foldersURL)
            let folderIssue = try #require(
                model.libraryIssues.first { $0.id == .folders }
            )
            await model.retryLibraryIssue(folderIssue)
            #expect(model.libraryIssues.isEmpty)
        }
    }

    @Test("folder deletion unfiles meetings from the current library state")
    func folderDeletionUsesCurrentLibraryState() async throws {
        try await withIsolatedModel { model, _ in
            let runtime = try #require(model.runtime)
            let folder = try #require(
                await model.createFolder(named: "Arbeit")
            )
            let meeting = try await runtime.library.createMeeting(
                title: "Extern geänderte Zuordnung",
                status: .ready
            )
            await model.refreshMeetings()
            #expect(model.meetings.first { $0.id == meeting.id }?.folderID == nil)

            _ = try await runtime.library.setMeetingFolder(
                meeting.id,
                folderID: folder.id
            )
            #expect(model.meetings.first { $0.id == meeting.id }?.folderID == nil)

            #expect(await model.deleteFolder(folder.id))

            let persisted = try await runtime.library.loadMeeting(meeting.id)
            #expect(persisted.folderID == nil)
        }
    }

    @Test("moving a folder reports success after refreshing its parent")
    func folderMoveReportsSuccess() async throws {
        try await withIsolatedModel { model, _ in
            let work = try #require(
                await model.createFolder(named: "Arbeit")
            )
            let product = try #require(
                await model.createFolder(named: "Produktvorstellung")
            )

            #expect(await model.moveFolder(product.id, to: work.id))
            #expect(
                model.folders.first { $0.id == product.id }?.parentFolderID
                    == work.id
            )
        }
    }

    private func withIsolatedModel(
        _ operation: (AppModel, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Steno-AppModelFolderBehaviorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        let modelURL = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(
            libraryURL: libraryURL,
            modelCacheDirectoryOverride: modelURL
        )
        #expect(model.resolvedLibraryURL == libraryURL.standardizedFileURL)
        #expect(model.resolvedModelCacheDirectory == modelURL.standardizedFileURL)
        await model.bootstrap()
        let runtime = try #require(model.runtime)
        #expect(runtime.library.layout.root == libraryURL.standardizedFileURL)
        _ = try #require(model.folderStore)

        do {
            try await operation(model, libraryURL)
            await model.runtime?.coordinator.stop()
        } catch {
            await model.runtime?.coordinator.stop()
            throw error
        }
    }

}
