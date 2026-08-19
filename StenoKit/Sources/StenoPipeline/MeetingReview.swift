import Foundation
import StenoDomain
import StenoIdentity
import StenoLibrary

/// Persistierter Review-Stand eines Meetings (Bestätigungen, Markierungen).
/// Liegt als review.json im Meeting-Ordner und ist an den Diarisierungslauf
/// gebunden: nach einer Re-Diarisierung passt die runID nicht mehr und der
/// Stand wird verworfen statt fälschlich weiterverwendet (Run-Provenienz).
public struct MeetingReviewDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let runID: RunID
    public var clusters: [IdentityCluster]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        runID: RunID,
        clusters: [IdentityCluster]
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.clusters = clusters
    }
}

public struct MeetingReviewStore: Sendable {
    private let layout: LibraryLayout

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    private func url(_ meetingID: MeetingID) -> URL {
        layout.meetingDirectory(meetingID).appendingPathComponent("review.json")
    }

    public func load(meetingID: MeetingID) throws -> MeetingReviewDocument? {
        try Self.load(meetingID: meetingID, layout: layout)
    }

    func load(
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> MeetingReviewDocument? {
        try transaction.validate(layout: layout)
        return try Self.load(meetingID: meetingID, layout: layout)
    }

    private static func load(
        meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> MeetingReviewDocument? {
        let url = layout.meetingDirectory(meetingID).appendingPathComponent("review.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let document = try JSONDecoder().decode(
            MeetingReviewDocument.self,
            from: Data(contentsOf: url)
        )
        guard document.schemaVersion == MeetingReviewDocument.currentSchemaVersion else {
            return nil
        }
        return document
    }

    public func save(_ document: MeetingReviewDocument, meetingID: MeetingID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try AtomicFile.write(try encoder.encode(document), to: url(meetingID))
        }
    }
}

/// Alles, was die Review-Oberfläche für ein Meeting braucht, in einem Stück.
public struct MeetingReviewData: Sendable {
    public let runID: RunID
    public var clusters: [IdentityCluster]
    public var suggestions: [ClusterSuggestion]
    public let resolutions: [IdentityClusterResolution]
    public var persons: [Person]

    /// Die bestaetigte Person selbst, nicht nur ihr Name - fuer Stellen, die
    /// mehr als den Namen brauchen (etwa die Firma zur Unterscheidung).
    public func confirmedPerson(for reference: SpeakerReference) -> Person? {
        switch reference {
        case .person(let personID):
            return persons.first { $0.id == personID }
        case .cluster:
            guard let cluster = resolvedCluster(for: reference),
                  !cluster.containsMultipleSpeakers,
                  cluster.reviewState != .multiple,
                  case .confirmed(let personID) = cluster.reviewState
            else { return nil }
            return persons.first { $0.id == personID }
        case .channel:
            return nil
        case .importedTextLabel:
            return nil
        }
    }

    public func confirmedName(for reference: SpeakerReference) -> String? {
        switch reference {
        case .person(let personID):
            return persons.first { $0.id == personID }?.displayName
        case .cluster:
            guard let cluster = resolvedCluster(for: reference),
                  !cluster.containsMultipleSpeakers,
                  cluster.reviewState != .multiple,
                  case .confirmed(let personID) = cluster.reviewState
            else { return nil }
            return persons.first { $0.id == personID }?.displayName
        case .channel:
            return nil
        case .importedTextLabel:
            return nil
        }
    }

    func resolvingConfirmedNames(
        in revision: TranscriptRevision
    ) -> TranscriptRevision {
        TranscriptRevision(
            schemaVersion: revision.schemaVersion,
            id: revision.id,
            meetingID: revision.meetingID,
            createdAt: revision.createdAt,
            origin: revision.origin,
            turns: revision.turns.map { turn in
                TranscriptTurn(
                    speaker: turn.speaker.flatMap { reference in
                        confirmedName(for: reference).map(SpeakerReference.channel)
                            ?? reference
                    },
                    start: turn.start,
                    end: turn.end,
                    segments: turn.segments
                )
            }
        )
    }
}

public enum MeetingReviewAssembler {
    /// Baut den Review-Stand aus dem jüngsten abgeschlossenen
    /// Vorschlagslauf. Persistierte Bestätigungen werden übernommen, wenn
    /// sie zum aktuellen Diarisierungslauf gehören.
    public static func load(
        library: Library,
        engine: SpeakerSuggestionEngine = SpeakerSuggestionEngine(),
        meetingID: MeetingID,
        diarizationRunID expectedDiarizationRunID: RunID? = nil
    ) async throws -> MeetingReviewData? {
        try LibraryMutationCoordination.withExclusiveTransaction(
            layout: library.layout
        ) { transaction in
            try load(
                layout: library.layout,
                engine: engine,
                meetingID: meetingID,
                diarizationRunID: expectedDiarizationRunID,
                transaction: transaction
            )
        }
    }

    static func load(
        layout: LibraryLayout,
        engine: SpeakerSuggestionEngine = SpeakerSuggestionEngine(),
        meetingID: MeetingID,
        diarizationRunID expectedDiarizationRunID: RunID? = nil,
        transaction: LibraryMutationTransaction
    ) throws -> MeetingReviewData? {
        try transaction.validate(layout: layout)
        let runsDirectory = layout.runsDirectory(meetingID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let decoder = JSONDecoder()
        var latestSuggestion: (run: ProcessingRun, artifact: IdentitySuggestionArtifact)?
        for entry in entries {
            guard let runData = try? Data(contentsOf: entry.appendingPathComponent("run.json")),
                  let run = try? decoder.decode(ProcessingRun.self, from: runData),
                  run.kind == .identitySuggestion,
                  run.status == .finished,
                  let artifactData = try? Data(contentsOf: entry.appendingPathComponent("suggestions.json")),
                  let artifact = try? decoder.decode(IdentitySuggestionArtifact.self, from: artifactData),
                  artifact.schemaVersion == IdentitySuggestionArtifact.currentSchemaVersion,
                  expectedDiarizationRunID.map({ artifact.sourceRunID == $0 }) ?? true
            else { continue }
            if latestSuggestion.map({ run.createdAt > $0.run.createdAt }) ?? true {
                latestSuggestion = (run, artifact)
            }
        }
        guard let (suggestionRun, suggestionArtifact) = latestSuggestion else {
            return nil
        }
        _ = suggestionRun

        let diarizationRunID = suggestionArtifact.sourceRunID
        let diarizationURL = layout.runDiarization(meetingID, runID: diarizationRunID)
        guard let diarizationData = try? Data(contentsOf: diarizationURL),
              let diarizationArtifact = try? decoder.decode(
                  DiarizationArtifact.self,
                  from: diarizationData
              )
        else { return nil }

        let raw = identityClusters(
            from: diarizationArtifact,
            meetingID: meetingID,
            runID: diarizationRunID
        )
        var clusters = engine.mergeSameChannelFragments(raw).clusters

        // Persistierten Review-Stand überlagern, aber nur bei passender runID.
        let store = MeetingReviewStore(layout: layout)
        if let saved = try store.load(
            meetingID: meetingID,
            transaction: transaction
        ),
           saved.runID == diarizationRunID {
            clusters = clusters.map { cluster in
                guard let match = saved.clusters.first(where: {
                    $0.channel == cluster.channel && $0.clusterID == cluster.clusterID
                }) else { return cluster }
                var updated = cluster
                updated.reviewState = match.reviewState
                updated.containsMultipleSpeakers = match.containsMultipleSpeakers
                return updated
            }
        }

        let persons = try IdentityStore.listPersons(
            layout: layout,
            transaction: transaction
        )
        return MeetingReviewData(
            runID: diarizationRunID,
            clusters: clusters,
            suggestions: suggestionArtifact.suggestions,
            resolutions: suggestionArtifact.clusterResolutions,
            persons: persons
        )
    }
}

public enum DiarizationRequest {
    /// Setzt eine unterbrochene Kette nach einer bereits abgeschlossenen
    /// Diarisierung bei den Stimmenvorschlaegen fort. Eine neuere
    /// Transkription macht die alte Diarisierung als Quelle ungueltig.
    @discardableResult
    public static func enqueueMissingIdentitySuggestion(
        library: Library,
        jobStore: JobStore,
        meetingID: MeetingID
    ) async throws -> Bool {
        try await MeetingProcessingJobRequest.requireUnpinnedJobAllowed(
            library: library,
            meetingID: meetingID
        )
        let jobs = try await jobStore.list().filter {
            $0.meetingID == meetingID
        }
        let revision = try await library.loadCurrentRevision(meetingID: meetingID)
        guard let currentRunID = diarizationRunID(in: revision),
              let diarization = jobs.first(where: {
                  $0.kind == .diarization
                      && $0.status == .finished
                      && StablePipelineIdentifiers.runID(for: $0) == currentRunID
              }),
              !jobs.contains(where: {
                  $0.kind == .finalASR && $0.createdAt > diarization.createdAt
              })
        else { return false }

        let existingReview = try? await MeetingReviewAssembler.load(
            library: library,
            meetingID: meetingID,
            diarizationRunID: currentRunID
        )
        if existingReview?.runID == currentRunID {
            return false
        }
        return try await jobStore.enqueueIfNoEquivalentJob(
            Job(
                kind: .identitySuggestion,
                meetingID: meetingID,
                sourceRunID: currentRunID
            ),
            blockingStatuses: [.queued, .running]
        )
    }

    private static func diarizationRunID(
        in revision: TranscriptRevision
    ) -> RunID? {
        switch revision.origin {
        case .finalRun(let runID):
            return runID
        case .userEdit:
            let runIDs = revision.turns.compactMap { turn -> RunID? in
                guard let speaker = turn.speaker,
                      case .cluster(let runID, _) = speaker
                else { return nil }
                return runID
            }
            guard let first = runIDs.first,
                  runIDs.allSatisfy({ $0 == first })
            else { return nil }
            return first
        case .liveProvisional, .legacyImport, .meetingTransfer:
            return nil
        }
    }

    /// Stößt die Sprechererkennung für ein Meeting nachträglich an
    /// (Meetings aus der Zeit vor der Diarisierungs-Pipeline oder erneuter
    /// Lauf). Referenziert den jüngsten abgeschlossenen finalASR-Lauf als
    /// Alignment-Quelle. Liefert false, wenn kein Finallauf existiert oder
    /// bereits ein Diarisierungsjob für diesen Lauf ansteht.
    @discardableResult
    public static func enqueue(
        library: Library,
        jobStore: JobStore,
        meetingID: MeetingID
    ) async throws -> Bool {
        try await MeetingProcessingJobRequest.requireUnpinnedJobAllowed(
            library: library,
            meetingID: meetingID
        )
        let layout = await library.layout
        let decoder = JSONDecoder()
        var latestFinalASR: ProcessingRun?
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: layout.runsDirectory(meetingID),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries {
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("run.json")),
                  let run = try? decoder.decode(ProcessingRun.self, from: data),
                  run.kind == .finalASR,
                  run.status == .finished
            else { continue }
            if latestFinalASR.map({ run.createdAt > $0.createdAt }) ?? true {
                latestFinalASR = run
            }
        }
        guard let sourceRun = latestFinalASR else { return false }

        return try await jobStore.enqueueIfNoEquivalentJob(
            Job(
                kind: .diarization,
                meetingID: meetingID,
                sourceRunID: sourceRun.id
            ),
            blockingStatuses: [.queued, .running, .finished]
        )
    }
}

/// Baut IdentityCluster aus einem Diarisierungsartefakt. Wird vom
/// Vorschlagsjob und von der Review-Oberfläche identisch genutzt.
func identityClusters(
    from artifact: DiarizationArtifact,
    meetingID: MeetingID,
    runID: RunID
) -> [IdentityCluster] {
    artifact.tracks.flatMap { track in
        track.clusters.map { cluster in
            IdentityCluster(
                meetingID: meetingID,
                runID: runID,
                channel: track.assetKind.rawValue,
                clusterID: cluster.clusterID,
                recordingType: recordingType(for: track.assetKind),
                embedding: cluster.embedding,
                speechDurationSeconds: cluster.speechDurationSeconds,
                segmentCount: cluster.segmentCount,
                isSelf: false
            )
        }
    }
}

func recordingType(for kind: MediaAsset.Kind) -> RecordingType {
    switch kind {
    case .micTrack: .inPerson
    case .systemTrack: .remote
    case .imported: .imported
    }
}
