import Foundation
import StenoExchange
import StenoLibrary
import Testing
@testable import steno_macos

@Suite("Legacy import presentation")
struct LegacyImportPresentationTests {
    @Test("one retained import handles duplicate start, cancellation, late progress, and rerun")
    @MainActor
    func retainedImportLifecycle() async throws {
        let root = try makeLegacyImportPresentationTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library.open(at: root.appending(path: "Library"))
        let folders = try FolderStore.open(layout: library.layout)
        let operation = ControlledLegacyImportOperation()
        let model = LegacyImportModel(importOperation: { _, progress in
            try await operation.run(progress: progress)
        })

        let firstRun = Task { @MainActor in
            await model.runImport(library: library, folders: folders)
        }
        await operation.waitUntilStarted(run: 1)

        #expect(model.phase == .importing(completed: 0, total: 0, stem: ""))
        #expect(model.isBusy)
        await model.runImport(library: library, folders: folders)
        #expect(await operation.runCount == 1)

        #expect(model.cancelImport())
        await operation.waitUntilCancelled(run: 1)
        #expect(model.phase == .cancelling(completed: 0, total: 0, stem: ""))
        #expect(model.isBusy)
        #expect(!model.cancelImport())

        await operation.sendProgress(
            LegacyImportProgress(completed: 99, total: 100, stem: "Too late"),
            run: 1
        )
        await Task.yield()
        #expect(model.phase == .cancelling(completed: 0, total: 0, stem: ""))

        let partial = ImportReport(orphans: [
            LegacyOrphan(stem: "Already committed", kind: .summaryWithoutTranscript),
        ])
        await operation.finish(.cancelled(partial), run: 1)
        await firstRun.value

        #expect(model.phase == .cancelled(partial))
        #expect(!model.isBusy)
        await operation.sendProgress(
            LegacyImportProgress(completed: 100, total: 100, stem: "Later still"),
            run: 1
        )
        await Task.yield()
        #expect(model.phase == .cancelled(partial))

        let rerun = Task { @MainActor in
            await model.runImport(library: library, folders: folders)
        }
        await operation.waitUntilStarted(run: 2)
        #expect(await operation.runCount == 2)
        #expect(model.phase == .importing(completed: 0, total: 0, stem: ""))
        await operation.finish(.finished(ImportReport()), run: 2)
        await rerun.value
        #expect(model.phase == .finished(ImportReport()))
    }
}

private actor ControlledLegacyImportOperation {
    typealias Progress = @Sendable (LegacyImportProgress) -> Void

    private(set) var runCount = 0
    private var cancelledRuns: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<LegacyImportOutcome, Never>] = [:]
    private var progressHandlers: [Int: Progress] = [:]

    func run(progress: @escaping Progress) async throws -> LegacyImportOutcome {
        runCount += 1
        let run = runCount
        progressHandlers[run] = progress
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[run] = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation(run: run) }
        }
    }

    func waitUntilStarted(run: Int) async {
        while runCount < run || continuations[run] == nil {
            await Task.yield()
        }
    }

    func waitUntilCancelled(run: Int) async {
        while !cancelledRuns.contains(run) {
            await Task.yield()
        }
    }

    func sendProgress(_ progress: LegacyImportProgress, run: Int) {
        progressHandlers[run]?(progress)
    }

    func finish(_ outcome: LegacyImportOutcome, run: Int) {
        continuations.removeValue(forKey: run)?.resume(returning: outcome)
    }

    private func recordCancellation(run: Int) {
        cancelledRuns.insert(run)
    }
}

private func makeLegacyImportPresentationTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "LegacyImportPresentationTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
