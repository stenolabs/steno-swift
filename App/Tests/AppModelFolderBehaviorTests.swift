import Foundation
import StenoDomain
import Testing
@testable import steno_macos

@Suite("App model folder behavior", .serialized)
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

            try Data("{".utf8).write(
                to: libraryURL.appendingPathComponent("folders.json")
            )
            await model.refreshMeetings()

            #expect(model.folders == visibleFolders)
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

        let previousLibrary = ProcessInfo.processInfo.environment["STENO_LIBRARY_DIR"]
        let previousModels = ProcessInfo.processInfo.environment["STENO_MODEL_DIR"]
        setenv("STENO_LIBRARY_DIR", libraryURL.path, 1)
        setenv("STENO_MODEL_DIR", modelURL.path, 1)
        defer {
            restoreEnvironment("STENO_LIBRARY_DIR", to: previousLibrary)
            restoreEnvironment("STENO_MODEL_DIR", to: previousModels)
        }

        let model = AppModel()
        await model.bootstrap()
        _ = try #require(model.runtime)
        _ = try #require(model.folderStore)

        do {
            try await operation(model, libraryURL)
            await model.runtime?.coordinator.stop()
        } catch {
            await model.runtime?.coordinator.stop()
            throw error
        }
    }

    private func restoreEnvironment(_ name: String, to value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }
}
