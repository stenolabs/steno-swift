import Foundation
import StenoDomain
import StenoLibrary

public struct StoredTemplateResult: Equatable, Sendable {
    public let runID: RunID
    public let result: TemplateResult

    public init(runID: RunID, result: TemplateResult) {
        self.runID = runID
        self.result = result
    }
}

public enum TemplateResultStoreError: Error, Equatable, Sendable {
    case conflictingResult(RunID)
    case invalidResult(RunID)
}

public struct TemplateResultStore: Sendable {
    private let layout: LibraryLayout

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    public func list(meetingID: MeetingID) throws -> [StoredTemplateResult] {
        let documents = try FileManager.default.contentsOfDirectory(
            at: layout.reportsDirectory(meetingID),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try documents.compactMap { url in
            guard url.pathExtension == "json",
                  let rawID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else { return nil }
            let runID = RunID(rawValue: rawID)
            do {
                return StoredTemplateResult(
                    runID: runID,
                    result: try decode(from: url, runID: runID)
                )
            } catch {
                // Ein beschädigtes Report-Dokument wird quarantänisiert und
                // aus dem committeten Lauf-Artefakt wiederhergestellt - der
                // Lauf ist die Quelle, das Report-Dokument nur eine Kopie.
                return try quarantineAndRestore(
                    url: url,
                    runID: runID,
                    meetingID: meetingID
                )
            }
        }.sorted { lhs, rhs in
            if lhs.result.createdAt == rhs.result.createdAt {
                return lhs.runID > rhs.runID
            }
            return lhs.result.createdAt > rhs.result.createdAt
        }
    }

    func persist(
        _ result: TemplateResult,
        runID: RunID,
        meetingID: MeetingID
    ) throws {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try persist(
                result,
                runID: runID,
                meetingID: meetingID,
                transaction: transaction
            )
        }
    }

    func persist(
        _ result: TemplateResult,
        runID: RunID,
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws {
        try transaction.validate(layout: layout)
        let url = layout.report(meetingID, runID: runID)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try decode(from: url, runID: runID) == result else {
                throw TemplateResultStoreError.conflictingResult(runID)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(result), to: url)
    }

    private func quarantineAndRestore(
        url: URL,
        runID: RunID,
        meetingID: MeetingID
    ) throws -> StoredTemplateResult? {
        let quarantineURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))"
        )
        try? FileManager.default.moveItem(at: url, to: quarantineURL)

        let artifactURL = layout.runTemplate(meetingID, runID: runID)
        guard let data = try? Data(contentsOf: artifactURL),
              let artifact = try? JSONDecoder().decode(
                  TemplateRenderArtifact.self,
                  from: data
              ),
              artifact.result.schemaVersion == TemplateResult.currentSchemaVersion
        else {
            // Kein wiederherstellbarer Lauf: quarantänisiert liegenlassen,
            // nicht raten.
            return nil
        }
        try persist(artifact.result, runID: runID, meetingID: meetingID)
        return StoredTemplateResult(runID: runID, result: artifact.result)
    }

    private func decode(from url: URL, runID: RunID) throws -> TemplateResult {
        let result = try JSONDecoder().decode(
            TemplateResult.self,
            from: Data(contentsOf: url)
        )
        guard result.schemaVersion == TemplateResult.currentSchemaVersion else {
            throw TemplateResultStoreError.invalidResult(runID)
        }
        return result
    }
}
