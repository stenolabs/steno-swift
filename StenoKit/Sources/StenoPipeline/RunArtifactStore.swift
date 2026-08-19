import Darwin
import Foundation
import StenoDomain
import StenoLibrary

struct CommittedRun<Artifact: Sendable>: Sendable {
    let run: ProcessingRun
    let artifact: Artifact
}

struct RunArtifactStore: Sendable {
    let layout: LibraryLayout

    func runID(for job: Job) -> RunID {
        StablePipelineIdentifiers.runID(for: job)
    }

    func temporaryDirectory(for job: Job) -> URL {
        layout.runsDirectory(job.meetingID).appendingPathComponent(
            ".run-\(runID(for: job)).tmp",
            isDirectory: true
        )
    }

    func prepare(_ run: ProcessingRun, for job: Job) throws {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try prepare(run, for: job, transaction: transaction)
        }
    }

    func prepare(
        _ run: ProcessingRun,
        for job: Job,
        transaction: LibraryMutationTransaction
    ) throws {
        try transaction.validate(layout: layout)
        try prepareWithoutMutationLock(run, for: job)
    }

    private func prepareWithoutMutationLock(_ run: ProcessingRun, for job: Job) throws {
        let temporary = temporaryDirectory(for: job)
        if FileManager.default.fileExists(atPath: temporary.path) {
            try FileManager.default.removeItem(at: temporary)
        }
        let destination = layout.runDirectory(job.meetingID, runID: run.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existingRun = try decode(
                ProcessingRun.self,
                from: destination.appendingPathComponent("run.json")
            )
            if existingRun.status == .finished {
                return
            }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        try encode(run, to: temporary.appendingPathComponent("run.json"))
    }

    func commit<Artifact: Encodable>(
        run: ProcessingRun,
        artifact: Artifact,
        artifactFileName: String,
        for job: Job
    ) throws {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try commit(
                run: run,
                artifact: artifact,
                artifactFileName: artifactFileName,
                for: job,
                transaction: transaction
            )
        }
    }

    func commit<Artifact: Encodable>(
        run: ProcessingRun,
        artifact: Artifact,
        artifactFileName: String,
        for job: Job,
        transaction: LibraryMutationTransaction
    ) throws {
        try transaction.validate(layout: layout)
        let temporary = temporaryDirectory(for: job)
        let destination = layout.runDirectory(job.meetingID, runID: run.id)
        try encode(run, to: temporary.appendingPathComponent("run.json"))
        try encode(artifact, to: temporary.appendingPathComponent(artifactFileName))
        try renameDirectory(from: temporary, to: destination)
    }

    func commitFailure(
        run: ProcessingRun,
        for job: Job
    ) throws {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try commitFailure(run: run, for: job, transaction: transaction)
        }
    }

    func commitFailure(
        run: ProcessingRun,
        for job: Job,
        transaction: LibraryMutationTransaction
    ) throws {
        try transaction.validate(layout: layout)
        let temporary = temporaryDirectory(for: job)
        let destination = layout.runDirectory(job.meetingID, runID: run.id)
        guard FileManager.default.fileExists(atPath: temporary.path) else { return }
        try encode(run, to: temporary.appendingPathComponent("run.json"))
        try renameDirectory(from: temporary, to: destination)
    }

    func loadCommitted<Artifact: Decodable & Sendable>(
        for job: Job,
        expectedKind: ProcessingRun.Kind,
        artifactFileName: String,
        artifactType: Artifact.Type,
        validate: (Artifact) -> Bool
    ) throws -> CommittedRun<Artifact>? {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try loadCommitted(
                for: job,
                expectedKind: expectedKind,
                artifactFileName: artifactFileName,
                artifactType: artifactType,
                transaction: transaction,
                validate: validate
            )
        }
    }

    func loadCommitted<Artifact: Decodable & Sendable>(
        for job: Job,
        expectedKind: ProcessingRun.Kind,
        artifactFileName: String,
        artifactType: Artifact.Type,
        transaction: LibraryMutationTransaction,
        validate: (Artifact) -> Bool
    ) throws -> CommittedRun<Artifact>? {
        try loadFinished(
            runID: runID(for: job),
            meetingID: job.meetingID,
            expectedKind: expectedKind,
            artifactFileName: artifactFileName,
            artifactType: artifactType,
            transaction: transaction,
            validate: validate
        )
    }

    func loadFinished<Artifact: Decodable & Sendable>(
        runID: RunID,
        meetingID: MeetingID,
        expectedKind: ProcessingRun.Kind,
        artifactFileName: String,
        artifactType: Artifact.Type,
        validate: (Artifact) -> Bool
    ) throws -> CommittedRun<Artifact>? {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try loadFinished(
                runID: runID,
                meetingID: meetingID,
                expectedKind: expectedKind,
                artifactFileName: artifactFileName,
                artifactType: artifactType,
                transaction: transaction,
                validate: validate
            )
        }
    }

    func loadFinished<Artifact: Decodable & Sendable>(
        runID: RunID,
        meetingID: MeetingID,
        expectedKind: ProcessingRun.Kind,
        artifactFileName: String,
        artifactType: Artifact.Type,
        transaction: LibraryMutationTransaction,
        validate: (Artifact) -> Bool
    ) throws -> CommittedRun<Artifact>? {
        try transaction.validate(layout: layout)
        let directory = layout.runDirectory(meetingID, runID: runID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        do {
            let run = try decode(
                ProcessingRun.self,
                from: directory.appendingPathComponent("run.json")
            )
            guard run.schemaVersion == ProcessingRun.currentSchemaVersion,
                  run.id == runID,
                  run.meetingID == meetingID,
                  run.kind == expectedKind else {
                throw PipelineError.invalidRunArtifact(runID)
            }
            guard run.status == .finished else { return nil }
            let artifact = try decode(
                artifactType,
                from: directory.appendingPathComponent(artifactFileName)
            )
            guard validate(artifact) else {
                throw PipelineError.invalidRunArtifact(runID)
            }
            return CommittedRun(run: run, artifact: artifact)
        } catch {
            try quarantine(directory, transaction: transaction)
            throw PipelineError.corruptRunArtifact(runID)
        }
    }

    func removeTemporaryArtifacts(for job: Job) throws {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try removeTemporaryArtifacts(for: job, transaction: transaction)
        }
    }

    func removeTemporaryArtifacts(
        for job: Job,
        transaction: LibraryMutationTransaction
    ) throws {
        try transaction.validate(layout: layout)
        let temporary = temporaryDirectory(for: job)
        guard FileManager.default.fileExists(atPath: temporary.path) else { return }
        try FileManager.default.removeItem(at: temporary)
    }

    private func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(value), to: url)
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func renameDirectory(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXFailure(operation: "rename run directory", code: errno)
        }

        let parent = destination.deletingLastPathComponent()
        let descriptor = parent.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "open runs directory", code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXFailure(operation: "fsync runs directory", code: errno)
        }
    }

    private func quarantine(
        _ directory: URL,
        transaction: LibraryMutationTransaction
    ) throws {
        try transaction.validate(layout: layout)
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        var destination = directory.appendingPathExtension("corrupt-\(timestamp)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathExtension(
                "corrupt-\(timestamp)-\(suffix)"
            )
            suffix += 1
        }
        try FileManager.default.moveItem(at: directory, to: destination)
    }
}
