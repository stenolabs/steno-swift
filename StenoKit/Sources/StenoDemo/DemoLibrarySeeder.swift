import Darwin
import CryptoKit
import Foundation
import StenoDomain
import StenoLibrary

package enum DemoLibrarySeederCheckpoint: Equatable, Sendable {
    case afterUnlockedPreflight
    case afterMeetingCommitBeforeIndex(MeetingID)
    case afterMeetingAndIndexCheckpoint(MeetingID)
    case afterSemanticValidationBeforeBaseline(MeetingID)
}

package typealias DemoLibrarySeederAction = @Sendable (
    DemoLibrarySeederCheckpoint
) throws -> Void

public actor DemoLibrarySeeder {
    private let library: Library
    private let folders: FolderStore
    private let resourceBundle: DemoResourceBundle
    private let checkpoint: DemoLibrarySeederAction

    public init(
        library: Library,
        folders: FolderStore,
        resourceBundle: DemoResourceBundle? = nil
    ) throws {
        self.library = library
        self.folders = folders
        self.resourceBundle = try resourceBundle ?? .bundled()
        checkpoint = { _ in }
    }

    package init(
        library: Library,
        folders: FolderStore,
        resourceBundle: DemoResourceBundle? = nil,
        checkpoint: @escaping DemoLibrarySeederAction
    ) throws {
        self.library = library
        self.folders = folders
        self.resourceBundle = try resourceBundle ?? .bundled()
        self.checkpoint = checkpoint
    }

    public func status() async throws -> DemoLibraryStatus {
        let dataset = try resourceBundle.loadVerifiedDataset()
        let blueprints = try dataset.manifest.meetings.map {
            try Self.blueprint($0, dataset: dataset)
        }
        let checkpoint = checkpoint
        return try await library.withExclusiveMutationTransaction { [folders] library, transaction in
            let currentIndex = try Self.validIndex(
                dataset: dataset,
                blueprints: blueprints,
                library: library,
                folders: folders,
                transaction: transaction
            )
            let initialFolderID = try folders.folderIfPresent(
                named: "Demo Meetings",
                transaction: transaction
            )?.id
            let items = try blueprints.map { blueprint in
                DemoLibraryItemStatus(
                    meetingID: blueprint.manifest.id,
                    itemID: blueprint.manifest.itemID,
                    state: try Self.state(
                        blueprint,
                        baseline: currentIndex?.stored.items.first {
                            $0.meetingID == blueprint.manifest.id
                        }?.baseline,
                        initialFolderID: initialFolderID,
                        library: library,
                        transaction: transaction,
                        checkpoint: checkpoint
                    )
                )
            }
            let status = DemoLibraryStatus(
                datasetID: dataset.manifest.datasetID,
                datasetVersion: dataset.manifest.datasetVersion,
                items: items
            )
            try Self.repairIndex(
                dataset: dataset,
                blueprints: blueprints,
                status: status,
                current: currentIndex,
                canonicalFolderID: initialFolderID,
                library: library,
                transaction: transaction
            )
            return status
        }
    }

    public func install() async throws {
        let dataset = try resourceBundle.loadVerifiedDataset()
        let blueprints = try dataset.manifest.meetings.map {
            try Self.blueprint($0, dataset: dataset)
        }
        try await preflightUnlocked(dataset: dataset)
        try checkpoint(.afterUnlockedPreflight)
        let checkpoint = checkpoint

        try await library.withExclusiveMutationTransaction { [folders] library, transaction in
            try Self.preflight(
                dataset: dataset,
                library: library,
                transaction: transaction
            )
            let existingIndex = try Self.validIndex(
                dataset: dataset,
                blueprints: blueprints,
                library: library,
                folders: folders,
                transaction: transaction
            )
            let initialFolderID = try folders.folderIfPresent(
                named: "Demo Meetings",
                transaction: transaction
            )?.id
            let states = try Dictionary(uniqueKeysWithValues: blueprints.map { blueprint in
                (
                    blueprint.manifest.id,
                    try Self.state(
                        blueprint,
                        baseline: existingIndex?.stored.items.first {
                            $0.meetingID == blueprint.manifest.id
                        }?.baseline,
                        initialFolderID: initialFolderID,
                        library: library,
                        transaction: transaction,
                        checkpoint: checkpoint
                    )
                )
            })
            let missing = blueprints.filter { states[$0.manifest.id] == .missing }
            if missing.isEmpty {
                let status = DemoLibraryStatus(
                    datasetID: dataset.manifest.datasetID,
                    datasetVersion: dataset.manifest.datasetVersion,
                    items: blueprints.map {
                        DemoLibraryItemStatus(
                            meetingID: $0.manifest.id,
                            itemID: $0.manifest.itemID,
                            state: states[$0.manifest.id] ?? .modified
                        )
                    }
                )
                try Self.repairIndex(
                    dataset: dataset,
                    blueprints: blueprints,
                    status: status,
                    current: existingIndex,
                    canonicalFolderID: initialFolderID,
                    library: library,
                    transaction: transaction
                )
                return
            }

            let resolvedFolder = try folders.resolveTopLevelFolder(
                named: "Demo Meetings",
                transaction: transaction
            )
            let ownedFolder = existingIndex?.trustedFolder
                ?? (resolvedFolder.wasCreated ? DemoOwnedFolderClaim(
                    folderID: resolvedFolder.folder.id,
                    createdAt: resolvedFolder.folder.createdAt,
                    expectedName: resolvedFolder.folder.name,
                    expectedParentFolderID: nil
                ) : nil)
            var indexItems = existingIndex?.stored.items ?? []
            let installationGenerationID = indexItems.compactMap(
                \.installationGenerationID
            ).first ?? blueprints.compactMap { blueprint in
                try? Self.readMeetingWithoutMutation(
                    blueprint.manifest.id,
                    layout: library.layout
                ).metadata?.demoProvenance?.installationGenerationID
            }.first ?? MeetingTransferGenerationID()
            for blueprint in blueprints where states[blueprint.manifest.id] == .installed {
                guard !indexItems.contains(where: { $0.meetingID == blueprint.manifest.id }) else {
                    continue
                }
                indexItems.append(Self.trustedIndexItem(
                    blueprint: blueprint,
                    installationGenerationID: try Self.readMeetingWithoutMutation(
                        blueprint.manifest.id,
                        layout: library.layout
                    ).processingGenerationID,
                    baseline: try DemoInstalledItemFingerprint.expected(
                        blueprint,
                        folderID: initialFolderID,
                        installationGenerationID: try Self.readMeetingWithoutMutation(
                            blueprint.manifest.id,
                            layout: library.layout
                        ).processingGenerationID
                    )
                ))
            }

            for blueprint in missing {
                let result = try library.commitPreparedMeeting(
                    blueprint.prepared(
                        folderID: resolvedFolder.folder.id,
                        installationGenerationID: installationGenerationID
                    ),
                    transaction: transaction
                )
                switch result {
                case .imported(let meetingID, _):
                    guard meetingID == blueprint.manifest.id else {
                        throw DemoLibraryError.commitOutcomeUncertain(blueprint.manifest.id)
                    }
                case .alreadyPresent:
                    throw DemoLibraryError.conflictingMeeting(blueprint.manifest.id)
                case .commitOutcomeUncertain:
                    throw DemoLibraryError.commitOutcomeUncertain(blueprint.manifest.id)
                }
                try checkpoint(.afterMeetingCommitBeforeIndex(blueprint.manifest.id))
                indexItems.removeAll { $0.meetingID == blueprint.manifest.id }
                indexItems.append(Self.trustedIndexItem(
                    blueprint: blueprint,
                    installationGenerationID: installationGenerationID,
                    baseline: try DemoInstalledItemFingerprint.expected(
                        blueprint,
                        folderID: resolvedFolder.folder.id,
                        installationGenerationID: installationGenerationID
                    )
                ))
                if let changedMeetingID = Self.firstBaselineMismatch(
                    items: indexItems,
                    library: library,
                    transaction: transaction
                ) {
                    throw DemoLibraryError.commitOutcomeUncertain(changedMeetingID)
                }
                try Self.writeIndex(
                    DemoInstallationIndex(
                        datasetID: dataset.manifest.datasetID,
                        items: indexItems,
                        seederOwnedFolder: ownedFolder
                    ),
                    layout: library.layout,
                    transaction: transaction
                )
                try checkpoint(.afterMeetingAndIndexCheckpoint(blueprint.manifest.id))
            }
        }
    }

    public func replace(
        policy: DemoReplacementPolicy
    ) async throws -> DemoLifecycleResult {
        let dataset = try resourceBundle.loadVerifiedDataset()
        let blueprints = try dataset.manifest.meetings.map {
            try Self.blueprint($0, dataset: dataset)
        }
        var completed: [String] = []
        var skipped: [String] = []
        var retained: [String] = []
        var uncertain: [String] = []

        for blueprint in blueprints {
            var checkpointFailed = false
            do {
                let outcome = try await library.withExclusiveMutationTransaction {
                    [folders] library, transaction -> ReplacementItemOutcome in
                    let currentIndex = try Self.validIndex(
                        dataset: dataset,
                        blueprints: blueprints,
                        library: library,
                        folders: folders,
                        transaction: transaction
                    )
                    let indexed = currentIndex?.stored.items.first {
                        $0.meetingID == blueprint.manifest.id
                    }
                    let occupancy = Self.meetingDirectoryOccupancy(
                        library.layout.meetingDirectory(blueprint.manifest.id)
                    )
                    let persisted: Meeting?
                    switch occupancy {
                    case .missing:
                        persisted = nil
                    case .conflict:
                        throw DemoLibraryError.conflictingMeeting(
                            blueprint.manifest.id
                        )
                    case .directory:
                        let loaded = try Self.readMeetingWithoutMutation(
                            blueprint.manifest.id,
                            layout: library.layout
                        )
                        guard Self.owns(
                            loaded,
                            meeting: blueprint.manifest,
                            manifest: dataset.manifest
                        ) else {
                            throw DemoLibraryError.conflictingMeeting(
                                blueprint.manifest.id
                            )
                        }
                        persisted = loaded
                    }

                    if let persisted {
                        let currentVersion = persisted.metadata?.demoProvenance?
                            .datasetVersion == dataset.manifest.datasetVersion
                        let currentBaseline = try? DemoInstalledItemFingerprint.compute(
                            meetingID: persisted.id,
                            layout: library.layout,
                            transaction: transaction
                        )
                        let expectedCurrentBaseline = currentVersion ? try?
                            DemoInstalledItemFingerprint.expected(
                                blueprint,
                                folderID: persisted.folderID,
                                installationGenerationID: persisted.processingGenerationID
                            ) : nil
                        let demonstrablyUnmodified = indexed != nil
                            && indexed?.baseline == currentBaseline
                            && indexed?.datasetVersion == persisted.metadata?
                                .demoProvenance?.datasetVersion
                            && indexed?.installationGenerationID
                                == persisted.processingGenerationID

                        if currentVersion,
                           currentBaseline == expectedCurrentBaseline,
                           let currentBaseline {
                            var items = currentIndex?.stored.items ?? []
                            items.removeAll { $0.meetingID == persisted.id }
                            items.append(Self.trustedIndexItem(
                                blueprint: blueprint,
                                installationGenerationID: persisted.processingGenerationID,
                                baseline: currentBaseline
                            ))
                            let repaired = DemoInstallationIndex(
                                datasetID: dataset.manifest.datasetID,
                                items: items,
                                seederOwnedFolder: currentIndex?.trustedFolder
                            )
                            if currentIndex?.stored != repaired {
                                try Self.writeIndex(
                                    repaired,
                                    layout: library.layout,
                                    transaction: transaction
                                )
                            }
                            return .skipped
                        }

                        if currentVersion && demonstrablyUnmodified {
                            return .skipped
                        }
                        if !demonstrablyUnmodified,
                           policy == .keepModifiedMeetings {
                            return .retained
                        }

                        let replacementGenerationID = MeetingTransferGenerationID()
                        switch try library.trashMeeting(
                            persisted.id,
                            expectedProcessingGenerationID: persisted.processingGenerationID,
                            transaction: transaction
                        ) {
                        case .commitOutcomeUncertain:
                            return .uncertain
                        case .trashed:
                            break
                        }
                        let resolved = try folders.resolveTopLevelFolder(
                            named: "Demo Meetings",
                            transaction: transaction
                        )
                        let claim = currentIndex?.trustedFolder
                            ?? (resolved.wasCreated ? DemoOwnedFolderClaim(
                                folderID: resolved.folder.id,
                                createdAt: resolved.folder.createdAt,
                                expectedName: resolved.folder.name,
                                expectedParentFolderID: nil
                            ) : nil)
                        let commit = try library.commitPreparedMeeting(
                            blueprint.prepared(
                                folderID: resolved.folder.id,
                                installationGenerationID: replacementGenerationID
                            ),
                            transaction: transaction
                        )
                        guard case .imported(let meetingID, _) = commit,
                              meetingID == blueprint.manifest.id else {
                            return .uncertain
                        }
                        try checkpoint(.afterMeetingCommitBeforeIndex(meetingID))
                        let baseline = try DemoInstalledItemFingerprint.compute(
                            meetingID: meetingID,
                            layout: library.layout,
                            transaction: transaction
                        )
                        var items = currentIndex?.stored.items ?? []
                        items.removeAll { $0.meetingID == meetingID }
                        items.append(Self.trustedIndexItem(
                            blueprint: blueprint,
                            installationGenerationID: replacementGenerationID,
                            baseline: baseline
                        ))
                        try Self.writeIndex(
                            DemoInstallationIndex(
                                datasetID: dataset.manifest.datasetID,
                                items: items,
                                seederOwnedFolder: claim
                            ),
                            layout: library.layout,
                            transaction: transaction
                        )
                        return .completed
                    }

                    let generationID = MeetingTransferGenerationID()
                    let resolved = try folders.resolveTopLevelFolder(
                        named: "Demo Meetings",
                        transaction: transaction
                    )
                    let claim = currentIndex?.trustedFolder
                        ?? (resolved.wasCreated ? DemoOwnedFolderClaim(
                            folderID: resolved.folder.id,
                            createdAt: resolved.folder.createdAt,
                            expectedName: resolved.folder.name,
                            expectedParentFolderID: nil
                        ) : nil)
                    let commit = try library.commitPreparedMeeting(
                        blueprint.prepared(
                            folderID: resolved.folder.id,
                            installationGenerationID: generationID
                        ),
                        transaction: transaction
                    )
                    guard case .imported(let meetingID, _) = commit,
                          meetingID == blueprint.manifest.id else {
                        return .uncertain
                    }
                    try checkpoint(.afterMeetingCommitBeforeIndex(meetingID))
                    let baseline = try DemoInstalledItemFingerprint.compute(
                        meetingID: meetingID,
                        layout: library.layout,
                        transaction: transaction
                    )
                    var items = currentIndex?.stored.items ?? []
                    items.removeAll { $0.meetingID == meetingID }
                    items.append(Self.trustedIndexItem(
                        blueprint: blueprint,
                        installationGenerationID: generationID,
                        baseline: baseline
                    ))
                    try Self.writeIndex(
                        DemoInstallationIndex(
                            datasetID: dataset.manifest.datasetID,
                            items: items,
                            seederOwnedFolder: claim
                        ),
                        layout: library.layout,
                        transaction: transaction
                    )
                    return .completed
                }
                switch outcome {
                case .completed:
                    completed.append(blueprint.manifest.itemID)
                    do {
                        try checkpoint(
                            .afterMeetingAndIndexCheckpoint(blueprint.manifest.id)
                        )
                    } catch {
                        checkpointFailed = true
                        throw error
                    }
                case .skipped: skipped.append(blueprint.manifest.itemID)
                case .retained: retained.append(blueprint.manifest.itemID)
                case .uncertain:
                    uncertain.append(blueprint.manifest.itemID)
                    let handled = Set(completed + skipped + retained)
                    return DemoLifecycleResult(
                        completedItems: completed,
                        skippedItems: skipped,
                        retainedItems: retained,
                        uncertainItems: uncertain,
                        remainingItems: blueprints.map(\.manifest.itemID).filter {
                            !handled.contains($0)
                        }
                    )
                }
            } catch {
                guard checkpointFailed else { throw error }
                let handled = Set(completed + skipped + retained + uncertain)
                return DemoLifecycleResult(
                    completedItems: completed,
                    skippedItems: skipped,
                    retainedItems: retained,
                    uncertainItems: uncertain,
                    remainingItems: blueprints.map(\.manifest.itemID).filter {
                        !handled.contains($0)
                    }
                )
            }
        }
        return DemoLifecycleResult(
            completedItems: completed,
            skippedItems: skipped,
            retainedItems: retained,
            uncertainItems: uncertain,
            remainingItems: retained + uncertain
        )
    }

    public func remove() async throws -> DemoLifecycleResult {
        let dataset = try resourceBundle.loadVerifiedDataset()
        let blueprints = try dataset.manifest.meetings.map {
            try Self.blueprint($0, dataset: dataset)
        }
        var completed: [String] = []
        var skipped: [String] = []
        var retained: [String] = []
        var uncertain: [String] = []

        for blueprint in blueprints {
            var checkpointFailed = false
            do {
                let outcome = try await library.withExclusiveMutationTransaction {
                    [folders] library, transaction -> RemovalItemOutcome in
                    let currentIndex = try Self.validIndex(
                        dataset: dataset,
                        blueprints: blueprints,
                        library: library,
                        folders: folders,
                        transaction: transaction
                    )
                    let occupancy = Self.meetingDirectoryOccupancy(
                        library.layout.meetingDirectory(blueprint.manifest.id)
                    )
                    if occupancy == .missing {
                        if let currentIndex {
                            var items = currentIndex.stored.items
                            items.removeAll {
                                $0.meetingID == blueprint.manifest.id
                            }
                            try Self.writeIndex(
                                DemoInstallationIndex(
                                    datasetID: dataset.manifest.datasetID,
                                    items: items,
                                    seederOwnedFolder: currentIndex.stored
                                        .seederOwnedFolder
                                ),
                                layout: library.layout,
                                transaction: transaction
                            )
                        }
                        return .skipped
                    }
                    guard occupancy == .directory else { return .retained }
                    guard let meeting = try? Self.readMeetingWithoutMutation(
                        blueprint.manifest.id,
                        layout: library.layout
                    ), Self.owns(
                        meeting,
                        meeting: blueprint.manifest,
                        manifest: dataset.manifest
                    ) else {
                        return .retained
                    }
                    switch try library.trashMeeting(
                        meeting.id,
                        expectedProcessingGenerationID: meeting.processingGenerationID,
                        transaction: transaction
                    ) {
                    case .commitOutcomeUncertain:
                        return .uncertain
                    case .trashed:
                        if let currentIndex {
                            var items = currentIndex.stored.items
                            items.removeAll { $0.meetingID == meeting.id }
                            try Self.writeIndex(
                                DemoInstallationIndex(
                                    datasetID: dataset.manifest.datasetID,
                                    items: items,
                                    seederOwnedFolder: currentIndex.stored
                                        .seederOwnedFolder
                                ),
                                layout: library.layout,
                                transaction: transaction
                            )
                        }
                        return .completed
                    }
                }
                switch outcome {
                case .completed:
                    completed.append(blueprint.manifest.itemID)
                    do {
                        try checkpoint(
                            .afterMeetingAndIndexCheckpoint(blueprint.manifest.id)
                        )
                    } catch {
                        checkpointFailed = true
                        throw error
                    }
                case .skipped: skipped.append(blueprint.manifest.itemID)
                case .retained: retained.append(blueprint.manifest.itemID)
                case .uncertain:
                    uncertain.append(blueprint.manifest.itemID)
                    let handled = Set(completed + skipped + retained)
                    return DemoLifecycleResult(
                        completedItems: completed,
                        skippedItems: skipped,
                        retainedItems: retained,
                        uncertainItems: uncertain,
                        remainingItems: blueprints.map(\.manifest.itemID).filter {
                            !handled.contains($0)
                        }
                    )
                }
            } catch {
                guard checkpointFailed else { throw error }
                let handled = Set(completed + skipped + retained + uncertain)
                return DemoLifecycleResult(
                    completedItems: completed,
                    skippedItems: skipped,
                    retainedItems: retained,
                    uncertainItems: uncertain,
                    remainingItems: blueprints.map(\.manifest.itemID).filter {
                        !handled.contains($0)
                    }
                )
            }
        }

        if retained.isEmpty && uncertain.isEmpty {
            let claim = try await library.withExclusiveMutationTransaction {
                [folders] library, transaction in
                try Self.validIndex(
                    dataset: dataset,
                    blueprints: blueprints,
                    library: library,
                    folders: folders,
                    transaction: transaction
                )?.trustedFolder
            }
            if let claim {
                _ = try await folders.deleteFolderIfEmpty(claim.folderID)
                try await library.withExclusiveMutationTransaction {
                    [folders] library, transaction in
                    guard let current = try Self.validIndex(
                        dataset: dataset,
                        blueprints: blueprints,
                        library: library,
                        folders: folders,
                        transaction: transaction
                    ) else { return }
                    try Self.writeIndex(
                        DemoInstallationIndex(
                            datasetID: dataset.manifest.datasetID,
                            items: current.stored.items,
                            seederOwnedFolder: nil
                        ),
                        layout: library.layout,
                        transaction: transaction
                    )
                }
            }
        }
        return DemoLifecycleResult(
            completedItems: completed,
            skippedItems: skipped,
            retainedItems: retained,
            uncertainItems: uncertain,
            remainingItems: retained + uncertain
        )
    }

    private func preflightUnlocked(dataset: VerifiedDemoDataset) async throws {
        for meeting in dataset.manifest.meetings {
            switch Self.meetingDirectoryOccupancy(
                library.layout.meetingDirectory(meeting.id)
            ) {
            case .missing:
                continue
            case .conflict:
                throw DemoLibraryError.conflictingMeeting(meeting.id)
            case .directory:
                break
            }
            let persisted: Meeting
            do {
                persisted = try Self.readMeetingWithoutMutation(
                    meeting.id,
                    layout: library.layout
                )
            } catch {
                throw DemoLibraryError.conflictingMeeting(meeting.id)
            }
            try Self.validateOccupant(
                persisted,
                meeting: meeting,
                manifest: dataset.manifest
            )
        }
    }

    private nonisolated static func preflight(
        dataset: VerifiedDemoDataset,
        library: Library,
        transaction: LibraryMutationTransaction
    ) throws {
        for meeting in dataset.manifest.meetings {
            switch meetingDirectoryOccupancy(library.layout.meetingDirectory(meeting.id)) {
            case .missing:
                continue
            case .conflict:
                throw DemoLibraryError.conflictingMeeting(meeting.id)
            case .directory:
                break
            }
            let persisted: Meeting
            do {
                persisted = try readMeetingWithoutMutation(meeting.id, layout: library.layout)
            } catch {
                throw DemoLibraryError.conflictingMeeting(meeting.id)
            }
            try validateOccupant(
                persisted,
                meeting: meeting,
                manifest: dataset.manifest
            )
        }
    }

    private nonisolated static func validateOccupant(
        _ persisted: Meeting,
        meeting: DemoMeetingManifest,
        manifest: DemoDatasetManifest
    ) throws {
        guard owns(persisted, meeting: meeting, manifest: manifest) else {
            throw DemoLibraryError.conflictingMeeting(meeting.id)
        }
        let installedVersion = persisted.metadata!.demoProvenance!.datasetVersion
        guard installedVersion == manifest.datasetVersion else {
            throw DemoLibraryError.outdatedMeeting(
                meeting.id,
                installedVersion: installedVersion
            )
        }
    }

    private nonisolated static func state(
        _ blueprint: DemoBlueprint,
        baseline: DemoInstallationBaseline?,
        initialFolderID: FolderID?,
        library: Library,
        transaction: LibraryMutationTransaction,
        checkpoint: DemoLibrarySeederAction
    ) throws -> DemoLibraryItemState {
        let meeting = blueprint.manifest
        switch meetingDirectoryOccupancy(library.layout.meetingDirectory(meeting.id)) {
        case .missing:
            return .missing
        case .conflict:
            return .conflictingMeeting
        case .directory:
            break
        }
        let persisted: Meeting
        do {
            persisted = try readMeetingWithoutMutation(meeting.id, layout: library.layout)
        } catch {
            return .conflictingMeeting
        }
        guard owns(persisted, meeting: meeting, manifest: blueprint.dataset) else {
            return .conflictingMeeting
        }
        let installedVersion = persisted.metadata!.demoProvenance!.datasetVersion
        guard installedVersion == blueprint.dataset.datasetVersion else {
            return .outdated(installedVersion: installedVersion)
        }

        do {
            let generationID = persisted.metadata?.demoProvenance?
                .installationGenerationID
            guard persisted == blueprint.persistedMeeting(
                    folderID: persisted.folderID,
                    installationGenerationID: generationID
                ),
                  try exactMeetingTreeMatches(blueprint, layout: library.layout),
                  try currentRevisionWithoutMutation(
                    meetingID: meeting.id,
                    layout: library.layout
                  ) == blueprint.transcript,
                  try mediaAssetWithoutMutation(
                    blueprint.mediaAsset.id,
                    meetingID: meeting.id,
                    layout: library.layout
                  ) == blueprint.mediaAsset,
                  try Data(contentsOf: library.layout.mediaFile(
                    meeting.id,
                    fileName: blueprint.mediaAsset.fileName
                  )) == blueprint.audio,
                  try notesMatch(blueprint, layout: library.layout),
                  try reportsMatch(blueprint, layout: library.layout) else {
                return .modified
            }
            try checkpoint(.afterSemanticValidationBeforeBaseline(meeting.id))
            if let baseline {
                let currentBaseline = try DemoInstalledItemFingerprint.compute(
                    meetingID: meeting.id,
                    layout: library.layout,
                    transaction: transaction
                )
                guard currentBaseline == baseline else {
                    return .modified
                }
            } else {
                guard persisted.folderID == initialFolderID else { return .modified }
                let currentBaseline = try DemoInstalledItemFingerprint.compute(
                    meetingID: meeting.id,
                    layout: library.layout,
                    transaction: transaction
                )
                let expectedBaseline = try DemoInstalledItemFingerprint.expected(
                    blueprint,
                    folderID: persisted.folderID,
                    installationGenerationID: generationID
                )
                guard currentBaseline == expectedBaseline else {
                    return .modified
                }
            }
            return .installed
        } catch {
            return .modified
        }
    }

    private nonisolated static func readMeetingWithoutMutation(
        _ meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> Meeting {
        let meeting = try JSONDecoder().decode(
            Meeting.self,
            from: Data(contentsOf: layout.meetingMetadata(meetingID))
        )
        guard meeting.schemaVersion == Meeting.currentSchemaVersion,
              meeting.id == meetingID else {
            throw DemoLibraryError.conflictingMeeting(meetingID)
        }
        return meeting
    }

    private nonisolated static func currentRevisionWithoutMutation(
        meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> TranscriptRevision {
        let pointer = try JSONDecoder().decode(
            CurrentRevisionPointer.self,
            from: Data(contentsOf: layout.currentRevision(meetingID))
        )
        guard pointer.schemaVersion == CurrentRevisionPointer.currentSchemaVersion,
              pointer.pendingCandidate == nil else {
            throw DemoLibraryError.commitOutcomeUncertain(meetingID)
        }
        let revision = try JSONDecoder().decode(
            TranscriptRevision.self,
            from: Data(contentsOf: layout.revision(
                meetingID,
                revisionID: pointer.currentRevisionID
            ))
        )
        guard revision.schemaVersion == TranscriptRevision.currentSchemaVersion else {
            throw DemoLibraryError.commitOutcomeUncertain(meetingID)
        }
        return revision
    }

    private nonisolated static func mediaAssetWithoutMutation(
        _ assetID: MediaAssetID,
        meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> MediaAsset {
        let asset = try JSONDecoder().decode(
            MediaAsset.self,
            from: Data(contentsOf: layout.mediaMetadata(meetingID, assetID: assetID))
        )
        guard asset.schemaVersion == MediaAsset.currentSchemaVersion else {
            throw DemoLibraryError.commitOutcomeUncertain(meetingID)
        }
        return asset
    }

    private nonisolated static func exactMeetingTreeMatches(
        _ blueprint: DemoBlueprint,
        layout: LibraryLayout
    ) throws -> Bool {
        let meetingID = blueprint.manifest.id
        return try directory(
            layout.meetingDirectory(meetingID),
            hasRegularFiles: ["meeting.json"],
            directories: ["media", "runs", "notes", "reports", "transcript"]
        ) && directory(
            layout.mediaDirectory(meetingID),
            hasRegularFiles: ["audio.wav", "\(blueprint.mediaAsset.id).json"],
            directories: []
        ) && directory(
            layout.runsDirectory(meetingID),
            hasRegularFiles: [],
            directories: []
        ) && directory(
            layout.notesDirectory(meetingID),
            hasRegularFiles: Set(blueprint.notes.map(\.fileName)),
            directories: []
        ) && directory(
            layout.reportsDirectory(meetingID),
            hasRegularFiles: Set(blueprint.reports.map { "\($0.runID).json" }),
            directories: []
        ) && directory(
            layout.transcriptDirectory(meetingID),
            hasRegularFiles: ["current.json"],
            directories: ["revisions"]
        ) && directory(
            layout.revisionsDirectory(meetingID),
            hasRegularFiles: ["\(blueprint.transcript.id).json"],
            directories: []
        )
    }

    private nonisolated static func directory(
        _ url: URL,
        hasRegularFiles expectedFiles: Set<String>,
        directories expectedDirectories: Set<String>
    ) throws -> Bool {
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
        var files = Set<String>()
        var directories = Set<String>()
        for entry in entries {
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0 else { return false }
            switch metadata.st_mode & S_IFMT {
            case S_IFREG:
                files.insert(entry.lastPathComponent)
            case S_IFDIR:
                directories.insert(entry.lastPathComponent)
            default:
                return false
            }
        }
        return files == expectedFiles && directories == expectedDirectories
    }

    private nonisolated static func notesMatch(
        _ blueprint: DemoBlueprint,
        layout: LibraryLayout
    ) throws -> Bool {
        for note in blueprint.notes {
            guard try Data(contentsOf: layout.notesDirectory(blueprint.manifest.id)
                .appending(path: note.fileName)) == note.data else {
                return false
            }
        }
        return true
    }

    private nonisolated static func reportsMatch(
        _ blueprint: DemoBlueprint,
        layout: LibraryLayout
    ) throws -> Bool {
        for report in blueprint.reports {
            let persisted = try JSONDecoder().decode(
                TemplateResult.self,
                from: Data(contentsOf: layout.report(
                    blueprint.manifest.id,
                    runID: report.runID
                ))
            )
            guard persisted == report.result else { return false }
        }
        return true
    }

    private nonisolated static func owns(
        _ persisted: Meeting,
        meeting: DemoMeetingManifest,
        manifest: DemoDatasetManifest
    ) -> Bool {
        persisted.id == meeting.id
            && persisted.metadata?.demoProvenance?.datasetID == manifest.datasetID
            && persisted.metadata?.demoProvenance?.itemID == meeting.itemID
    }

    private nonisolated static func meetingDirectoryOccupancy(
        _ url: URL
    ) -> DemoMeetingDirectoryOccupancy {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return status.st_mode & S_IFMT == S_IFDIR ? .directory : .conflict
        }
        return errno == ENOENT ? .missing : .conflict
    }

    private nonisolated static func validIndex(
        dataset: VerifiedDemoDataset,
        blueprints: [DemoBlueprint],
        library: Library,
        folders: FolderStore,
        transaction: LibraryMutationTransaction
    ) throws -> ValidatedDemoInstallationIndex? {
        guard let data = try? Data(contentsOf: library.layout.demoInstallationIndex),
              let index = try? JSONDecoder().decode(DemoInstallationIndex.self, from: data),
              index.schemaVersion == DemoInstallationIndex.currentSchemaVersion,
              index.datasetID == dataset.manifest.datasetID else {
            return nil
        }
        let blueprintsByMeetingID = Dictionary(uniqueKeysWithValues: blueprints.map {
            ($0.manifest.id, $0)
        })
        guard Set(index.items.map(\.meetingID)).count == index.items.count,
              Set(index.items.map(\.itemID)).count == index.items.count else {
            return nil
        }

        var persistedVersions: [MeetingID: String] = [:]
        for blueprint in blueprints {
            let meeting = blueprint.manifest
            guard meetingDirectoryOccupancy(
                library.layout.meetingDirectory(meeting.id)
            ) == .directory,
              let persisted = try? readMeetingWithoutMutation(
                meeting.id,
                layout: library.layout
            ), owns(persisted, meeting: meeting, manifest: dataset.manifest),
              let version = persisted.metadata?.demoProvenance?.datasetVersion else {
                continue
            }
            persistedVersions[meeting.id] = version
        }
        let validItems = index.items.filter { item in
            guard let blueprint = blueprintsByMeetingID[item.meetingID],
                  item.itemID == blueprint.manifest.itemID,
                  item.datasetVersion == persistedVersions[item.meetingID],
                  (item.datasetVersion != dataset.manifest.datasetVersion
                    || item.baselineRevisionID == blueprint.transcript.id),
                  item.installationGenerationID == (try? readMeetingWithoutMutation(
                    item.meetingID,
                    layout: library.layout
                  ).processingGenerationID),
                  item.baseline.algorithm == DemoInstallationBaseline.sha256TreeV1,
                  isSHA256(item.baseline.digest) else {
                return false
            }
            return true
        }
        var trustedFolder: DemoOwnedFolderClaim?
        if let claim = index.seederOwnedFolder,
           claim.expectedName == "Demo Meetings",
           claim.expectedParentFolderID == nil,
           let folder = try folders.folder(claim.folderID, transaction: transaction),
           folder.createdAt == claim.createdAt,
           folder.name == claim.expectedName,
           folder.parentFolderID == claim.expectedParentFolderID {
            trustedFolder = claim
        }
        return ValidatedDemoInstallationIndex(
            stored: DemoInstallationIndex(
                datasetID: index.datasetID,
                items: validItems,
                seederOwnedFolder: index.seederOwnedFolder
            ),
            trustedFolder: trustedFolder
        )
    }

    private nonisolated static func trustedIndexItem(
        blueprint: DemoBlueprint,
        installationGenerationID: MeetingTransferGenerationID?,
        baseline: DemoInstallationBaseline
    ) -> DemoInstallationIndexItem {
        DemoInstallationIndexItem(
            meetingID: blueprint.manifest.id,
            itemID: blueprint.manifest.itemID,
            datasetVersion: blueprint.dataset.datasetVersion,
            installationGenerationID: installationGenerationID,
            baselineRevisionID: blueprint.transcript.id,
            baseline: baseline
        )
    }

    private nonisolated static func repairIndex(
        dataset: VerifiedDemoDataset,
        blueprints: [DemoBlueprint],
        status: DemoLibraryStatus,
        current: ValidatedDemoInstallationIndex?,
        canonicalFolderID: FolderID?,
        library: Library,
        transaction: LibraryMutationTransaction
    ) throws {
        guard status.items.allSatisfy({ $0.state == .installed }) else { return }
        let trustedItems = try blueprints.map { blueprint in
            let storedBaseline = current?.stored.items.first {
                $0.meetingID == blueprint.manifest.id
            }?.baseline
            let generationID = try readMeetingWithoutMutation(
                blueprint.manifest.id,
                layout: library.layout
            ).processingGenerationID
            let baseline = try storedBaseline ?? DemoInstalledItemFingerprint.expected(
                blueprint,
                folderID: canonicalFolderID,
                installationGenerationID: generationID
            )
            return trustedIndexItem(
                blueprint: blueprint,
                installationGenerationID: generationID,
                baseline: baseline
            )
        }
        guard firstBaselineMismatch(
            items: trustedItems,
            library: library,
            transaction: transaction
        ) == nil else { return }
        let repaired = DemoInstallationIndex(
            datasetID: dataset.manifest.datasetID,
            items: trustedItems,
            seederOwnedFolder: current?.trustedFolder
        )
        guard current?.stored != repaired else { return }
        try writeIndex(repaired, layout: library.layout, transaction: transaction)
    }

    private nonisolated static func firstBaselineMismatch(
        items: [DemoInstallationIndexItem],
        library: Library,
        transaction: LibraryMutationTransaction
    ) -> MeetingID? {
        for item in items {
            do {
                let current = try DemoInstalledItemFingerprint.compute(
                    meetingID: item.meetingID,
                    layout: library.layout,
                    transaction: transaction
                )
                guard current == item.baseline else { return item.meetingID }
            } catch {
                return item.meetingID
            }
        }
        return nil
    }

    private nonisolated static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private nonisolated static func writeIndex(
        _ index: DemoInstallationIndex,
        layout: LibraryLayout,
        transaction: LibraryMutationTransaction
    ) throws {
        try transaction.validate(layout: layout)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFile.write(try encoder.encode(index), to: layout.demoInstallationIndex)
    }
}

private enum DemoMeetingDirectoryOccupancy: Equatable {
    case missing
    case directory
    case conflict
}

private enum ReplacementItemOutcome {
    case completed
    case skipped
    case retained
    case uncertain
}

private enum RemovalItemOutcome {
    case completed
    case skipped
    case retained
    case uncertain
}

private struct ValidatedDemoInstallationIndex: Sendable {
    let stored: DemoInstallationIndex
    let trustedFolder: DemoOwnedFolderClaim?
}

private struct DemoReportBlueprint: Sendable {
    let runID: RunID
    let result: TemplateResult
}

private struct DemoBlueprint: Sendable {
    let manifest: DemoMeetingManifest
    let dataset: DemoDatasetManifest
    let createdAt: Date
    let transcript: TranscriptRevision
    let mediaAsset: MediaAsset
    let audio: Data
    let notes: [PreparedMeetingNoteImport]
    let reports: [DemoReportBlueprint]

    func persistedMeeting(
        folderID: FolderID?,
        installationGenerationID: MeetingTransferGenerationID? = nil
    ) -> Meeting {
        Meeting(
            id: manifest.id,
            title: manifest.title,
            createdAt: createdAt,
            status: .ready,
            folderID: folderID,
            metadata: MeetingMetadata(demoProvenance: DemoProvenance(
                datasetID: dataset.datasetID,
                datasetVersion: dataset.datasetVersion,
                itemID: manifest.itemID,
                installationGenerationID: installationGenerationID
            ))
        )
    }

    func prepared(
        folderID: FolderID,
        installationGenerationID: MeetingTransferGenerationID? = nil
    ) -> PreparedMeetingImport {
        PreparedMeetingImport(
            meeting: persistedMeeting(
                folderID: folderID,
                installationGenerationID: installationGenerationID
            ),
            media: [PreparedMediaImport(asset: mediaAsset, data: audio)],
            revision: transcript,
            templateResults: reports.map {
                PreparedTemplateResultImport(runID: $0.runID, result: $0.result)
            },
            notes: notes
        )
    }
}

package enum DemoInstalledItemFingerprintCheckpoint: Equatable, Sendable {
    case afterEntryMetadata(relativePath: String)
}

package typealias DemoInstalledItemFingerprintAction = @Sendable (
    DemoInstalledItemFingerprintCheckpoint
) throws -> Void

package enum DemoInstalledItemFingerprint {
    package static func compute(
        meetingID: MeetingID,
        layout: LibraryLayout,
        transaction: LibraryMutationTransaction,
        checkpoint: DemoInstalledItemFingerprintAction = { _ in }
    ) throws -> DemoInstallationBaseline {
        try transaction.validate(layout: layout)
        let root = layout.meetingDirectory(meetingID)
        let rootDescriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { throw changed(meetingID) }
        defer { Darwin.close(rootDescriptor) }
        let rootMetadata = try directoryMetadata(rootDescriptor, meetingID: meetingID)
        try validateDirectoryPath(
            root,
            descriptor: rootDescriptor,
            expected: rootMetadata,
            meetingID: meetingID
        )
        var entries: [FingerprintEntry] = []
        try scanDirectory(
            rootDescriptor,
            relativePath: "",
            entries: &entries,
            meetingID: meetingID,
            checkpoint: checkpoint
        )
        try validateDirectoryPath(
            root,
            descriptor: rootDescriptor,
            expected: rootMetadata,
            meetingID: meetingID
        )
        return baseline(entries)
    }

    fileprivate static func expected(
        _ blueprint: DemoBlueprint,
        folderID: FolderID?,
        installationGenerationID: MeetingTransferGenerationID? = nil
    ) throws -> DemoInstallationBaseline {
        var entries = [
            directory("."),
            directory("media"),
            directory("runs"),
            directory("notes"),
            directory("reports"),
            directory("transcript"),
            directory("transcript/revisions"),
            try file(
                "meeting.json",
                data: encode(blueprint.persistedMeeting(
                    folderID: folderID,
                    installationGenerationID: installationGenerationID
                ))
            ),
            file("media/audio.wav", data: blueprint.audio),
            try file(
                "media/\(blueprint.mediaAsset.id).json",
                data: encode(blueprint.mediaAsset)
            ),
            try file(
                "transcript/current.json",
                data: encode(CurrentRevisionPointer(
                    currentRevisionID: blueprint.transcript.id
                ))
            ),
            try file(
                "transcript/revisions/\(blueprint.transcript.id).json",
                data: encode(blueprint.transcript)
            ),
        ]
        entries.append(contentsOf: blueprint.notes.map {
            file("notes/\($0.fileName)", data: $0.data)
        })
        entries.append(contentsOf: try blueprint.reports.map {
            try file("reports/\($0.runID).json", data: encode($0.result))
        })
        return baseline(entries)
    }

    private static func directory(_ relativePath: String) -> FingerprintEntry {
        FingerprintEntry(
            relativePath: relativePath,
            kind: Data("directory".utf8),
            fileSize: 0,
            fileDigest: Data()
        )
    }

    private static func file(_ relativePath: String, data: Data) -> FingerprintEntry {
        FingerprintEntry(
            relativePath: relativePath,
            kind: Data("regular-file".utf8),
            fileSize: UInt64(data.count),
            fileDigest: Data(SHA256.hash(data: data))
        )
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func baseline(
        _ unsortedEntries: [FingerprintEntry]
    ) -> DemoInstallationBaseline {
        let entries = unsortedEntries.sorted {
            $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }
        var treeHasher = SHA256()
        update(Data("org.steno.demo.sha256-tree-v1".utf8), hasher: &treeHasher)
        for entry in entries {
            update(entry.kind, hasher: &treeHasher)
            update(Data(entry.relativePath.utf8), hasher: &treeHasher)
            var bigEndianSize = entry.fileSize.bigEndian
            update(withUnsafeBytes(of: &bigEndianSize) { Data($0) }, hasher: &treeHasher)
            update(entry.fileDigest, hasher: &treeHasher)
        }
        return DemoInstallationBaseline(
            digest: treeHasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func scanDirectory(
        _ descriptor: Int32,
        relativePath: String,
        entries: inout [FingerprintEntry],
        meetingID: MeetingID,
        checkpoint: DemoInstalledItemFingerprintAction
    ) throws {
        let before = try directoryMetadata(descriptor, meetingID: meetingID)
        entries.append(FingerprintEntry(
            relativePath: relativePath.isEmpty ? "." : relativePath,
            kind: Data("directory".utf8),
            fileSize: 0,
            fileDigest: Data()
        ))
        for name in try directoryNames(descriptor, meetingID: meetingID) {
            let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw changed(meetingID)
            }
            let expected = FingerprintMetadata(status)
            try checkpoint(.afterEntryMetadata(relativePath: childPath))
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else { throw changed(meetingID) }
                defer { Darwin.close(child) }
                guard try directoryMetadata(child, meetingID: meetingID) == expected else {
                    throw changed(meetingID)
                }
                try scanDirectory(
                    child,
                    relativePath: childPath,
                    entries: &entries,
                    meetingID: meetingID,
                    checkpoint: checkpoint
                )
            case S_IFREG:
                try scanFile(
                    parentDescriptor: descriptor,
                    name: name,
                    relativePath: childPath,
                    expected: expected,
                    entries: &entries,
                    meetingID: meetingID
                )
            default:
                throw changed(meetingID)
            }
        }
        guard try directoryMetadata(descriptor, meetingID: meetingID) == before else {
            throw changed(meetingID)
        }
    }

    private static func scanFile(
        parentDescriptor: Int32,
        name: String,
        relativePath: String,
        expected: FingerprintMetadata,
        entries: inout [FingerprintEntry],
        meetingID: MeetingID
    ) throws {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw changed(meetingID) }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              FingerprintMetadata(before) == expected else {
            throw changed(meetingID)
        }
        let digest = try hashFile(
            descriptor,
            byteCount: Int64(before.st_size),
            meetingID: meetingID
        )
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              FingerprintMetadata(after) == expected else {
            throw changed(meetingID)
        }
        entries.append(FingerprintEntry(
            relativePath: relativePath,
            kind: Data("regular-file".utf8),
            fileSize: UInt64(before.st_size),
            fileDigest: digest
        ))
    }

    private static func hashFile(
        _ descriptor: Int32,
        byteCount: Int64,
        meetingID: MeetingID
    ) throws -> Data {
        var hasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while offset < byteCount {
            let wanted = Int(min(Int64(buffer.count), byteCount - offset))
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, wanted, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw changed(meetingID) }
            buffer.withUnsafeBytes {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count]))
            }
            offset += Int64(count)
        }
        var trailing: UInt8 = 0
        guard pread(descriptor, &trailing, 1, off_t(byteCount)) == 0 else {
            throw changed(meetingID)
        }
        return Data(hasher.finalize())
    }

    private static func directoryMetadata(
        _ descriptor: Int32,
        meetingID: MeetingID
    ) throws -> FingerprintMetadata {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw changed(meetingID)
        }
        return FingerprintMetadata(status)
    }

    private static func validateDirectoryPath(
        _ url: URL,
        descriptor: Int32,
        expected: FingerprintMetadata,
        meetingID: MeetingID
    ) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              lstat(url.path, &pathStatus) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              FingerprintMetadata(descriptorStatus) == expected,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            throw changed(meetingID)
        }
    }

    private static func directoryNames(
        _ descriptor: Int32,
        meetingID: MeetingID
    ) throws -> [String] {
        let copied = dup(descriptor)
        guard copied >= 0 else { throw changed(meetingID) }
        guard lseek(copied, 0, SEEK_SET) >= 0 else {
            Darwin.close(copied)
            throw changed(meetingID)
        }
        guard let directory = fdopendir(copied) else {
            Darwin.close(copied)
            throw changed(meetingID)
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            var nameBytes = entry.pointee.d_name
            let name = withUnsafePointer(to: &nameBytes) { pointer -> String? in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw changed(meetingID) }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw changed(meetingID) }
        return names
    }

    private static func changed(_ meetingID: MeetingID) -> DemoLibraryError {
        .commitOutcomeUncertain(meetingID)
    }

    private static func update(_ data: Data, hasher: inout SHA256) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: data)
    }
}

private struct FingerprintEntry {
    let relativePath: String
    let kind: Data
    let fileSize: UInt64
    let fileDigest: Data
}

private struct FingerprintMetadata: Equatable {
    let deviceID: UInt64
    let fileID: UInt64
    let mode: mode_t
    let linkCount: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ status: stat) {
        deviceID = UInt64(status.st_dev)
        fileID = UInt64(status.st_ino)
        mode = status.st_mode
        linkCount = UInt64(status.st_nlink)
        byteCount = Int64(status.st_size)
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = status.st_ctimespec.tv_nsec
    }
}

private extension DemoLibrarySeeder {
    nonisolated static func blueprint(
        _ meeting: DemoMeetingManifest,
        dataset: VerifiedDemoDataset
    ) throws -> DemoBlueprint {
        guard let transcriptData = dataset.resources[meeting.transcript.resourceID],
              let audio = dataset.resources[meeting.audio.resourceID] else {
            throw DemoLibraryError.invalidMeetingBlueprint(
                itemID: meeting.itemID,
                reason: "missing transcript or audio snapshot"
            )
        }
        let transcript: TranscriptRevision
        do {
            transcript = try JSONDecoder().decode(TranscriptRevision.self, from: transcriptData)
        } catch {
            throw DemoLibraryError.invalidTranscript(
                resourceID: meeting.transcript.resourceID
            )
        }
        guard transcript.turns.allSatisfy({ turn in
            guard let speaker = turn.speaker else { return true }
            if case .importedTextLabel = speaker { return true }
            return false
        }) else {
            throw DemoLibraryError.invalidTranscript(resourceID: meeting.transcript.resourceID)
        }
        guard let createdAt = ISO8601DateFormatter().date(from: meeting.createdAtUTC),
              meeting.runs.count == 1 else {
            throw DemoLibraryError.invalidMeetingBlueprint(
                itemID: meeting.itemID,
                reason: "invalid meeting date or run count"
            )
        }

        let descriptors = Dictionary(uniqueKeysWithValues: dataset.manifest.resources.map {
            ($0.id, $0)
        })
        var notes: [PreparedMeetingNoteImport] = []
        var reports: [DemoReportBlueprint] = []
        for resourceID in meeting.runs[0].resourceIDs {
            guard let descriptor = descriptors[resourceID],
                  let data = dataset.resources[resourceID] else {
                throw DemoLibraryError.invalidMeetingBlueprint(
                    itemID: meeting.itemID,
                    reason: "missing verified resource \(resourceID)"
                )
            }
            switch descriptor.kind {
            case .note:
                guard String(data: data, encoding: .utf8) != nil else {
                    throw DemoLibraryError.invalidUTF8(resourceID: resourceID)
                }
                notes.append(PreparedMeetingNoteImport(
                    fileName: "legacy-user-notes.md",
                    data: data
                ))
            case .report:
                guard let markdown = String(data: data, encoding: .utf8) else {
                    throw DemoLibraryError.invalidUTF8(resourceID: resourceID)
                }
                reports.append(DemoReportBlueprint(
                    runID: meeting.runs[0].id,
                    result: TemplateResult(
                        markdown: markdown,
                        template: Template(
                            id: "synthetic-demo",
                            name: "Synthetic Demo",
                            description: "Bundled synthetic demo report.",
                            sections: [],
                            prompts: TemplatePromptComponents(
                                role: "",
                                mapInstructions: "",
                                reduceInstructions: ""
                            )
                        ),
                        engine: EngineDescriptor(
                            name: "Synthetic Demo",
                            version: dataset.manifest.datasetVersion
                        ),
                        revisionID: transcript.id,
                        createdAt: transcript.createdAt
                    )
                ))
            case .referenceTranscript, .referenceTimeline, .attribution:
                break
            case .audio, .transcript:
                throw DemoLibraryError.invalidMeetingBlueprint(
                    itemID: meeting.itemID,
                    reason: "run references \(descriptor.kind.rawValue)"
                )
            }
        }

        let expectedNoteCount = meeting.itemID == "produktinterview" ? 0 : 1
        let expectedReportCount = meeting.itemID == "wochenrunde" ? 0 : 1
        guard notes.count == expectedNoteCount,
              reports.count == expectedReportCount else {
            throw DemoLibraryError.invalidMeetingBlueprint(
                itemID: meeting.itemID,
                reason: "incomplete note or report snapshots"
            )
        }

        return DemoBlueprint(
            manifest: meeting,
            dataset: dataset.manifest,
            createdAt: createdAt,
            transcript: transcript,
            mediaAsset: MediaAsset(
                id: meeting.audio.mediaAssetID,
                meetingID: meeting.id,
                kind: .imported,
                sampleRate: meeting.audio.sampleRate,
                duration: meeting.audio.duration,
                provenanceKey: "demo:\(dataset.manifest.datasetID):\(dataset.manifest.datasetVersion):\(meeting.itemID):audio",
                fileName: "audio.wav"
            ),
            audio: audio,
            notes: notes,
            reports: reports
        )
    }
}
