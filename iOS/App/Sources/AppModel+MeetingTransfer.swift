import Darwin
import Foundation
import StenoDomain
import StenoExchange
import StenoPipeline

enum MeetingTransferExportCleanupError: LocalizedError, Equatable {
    case runtimeUnavailable
    case invalidTemporaryExport
    case notOwned
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "Steno is not ready to share this meeting."
        case .invalidTemporaryExport:
            "Steno could not create a private temporary export."
        case .notOwned:
            "Steno refused to remove a file it does not own."
        case .cleanupFailed:
            "Steno could not remove its temporary meeting export."
        }
    }
}

struct MeetingTransferExportWorkspace: Sendable {
    let rootURL: URL

    init(parentDirectory: URL, identifier: UUID = UUID()) {
        rootURL = parentDirectory.standardizedFileURL.appending(
            path: "Steno-MeetingTransferExport-\(identifier.uuidString)",
            directoryHint: .isDirectory
        )
    }

    func perform(
        _ operation: @escaping @Sendable (URL) async throws
            -> MeetingTransferExportResult
    ) async throws -> MeetingTransferExportResult {
        guard mkdir(rootURL.path, S_IRWXU) == 0 else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
        do {
            try Task.checkCancellation()
            _ = try MeetingTransferPrivateRoot.prepareAndVerify(at: rootURL)
            try excludeFromBackup(rootURL)
            let result = try await operation(rootURL)
            try Task.checkCancellation()
            try validate(result)
            try excludeFromBackup(result.packageURL)
            return result
        } catch {
            let operationError = error
            do {
                try removeRootIfPresent()
            } catch {
                throw MeetingTransferExportCleanupError.cleanupFailed
            }
            throw operationError
        }
    }

    private func validate(_ result: MeetingTransferExportResult) throws {
        let cleanupRoot = result.cleanupRoot.standardizedFileURL
        let packageURL = result.packageURL.standardizedFileURL
        guard cleanupRoot == rootURL,
              packageURL.deletingLastPathComponent() == rootURL,
              packageURL.pathExtension == "stenomeeting"
        else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
        let values = try packageURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        let verified = try mutableURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        guard verified.isExcludedFromBackup == true else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
    }

    private func removeRootIfPresent() throws {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try FileManager.default.removeItem(at: rootURL)
        guard !FileManager.default.fileExists(atPath: rootURL.path) else {
            throw MeetingTransferExportCleanupError.cleanupFailed
        }
    }
}

@MainActor
extension AppModel {
    func registerMeetingTransferScene(_ sceneID: MeetingTransferSceneID) {
        hasRegisteredMeetingTransferScene = true
        guard !livingMeetingTransferSceneIDs.contains(sceneID) else { return }
        livingMeetingTransferSceneIDs.append(sceneID)
        rehomeMeetingTransferStateIfNeeded()
    }

    func unregisterMeetingTransferScene(_ sceneID: MeetingTransferSceneID) {
        guard let index = livingMeetingTransferSceneIDs.firstIndex(of: sceneID) else {
            return
        }
        livingMeetingTransferSceneIDs.remove(at: index)
        let fallbackSceneID = livingMeetingTransferSceneIDs.first

        if pendingMeetingTransferSceneID == sceneID {
            pendingMeetingTransferURL = nil
            pendingMeetingTransferSceneID = nil
        }
        if selectedMeetingSceneID == sceneID, let fallbackSceneID {
            selectedMeetingSceneID = fallbackSceneID
        }
        guard meetingTransferSceneID == sceneID else { return }

        if let fallbackSceneID {
            meetingTransferSceneID = fallbackSceneID
        }
        switch meetingTransferImportState {
        case .preview:
            scheduleMeetingTransferDiscard(completeCommittedResult: false)
        case .preparing, .importing:
            requestMeetingTransferCancellation()
        case .cleanupRequired, .completed, .recoveryRequired, .failed, nil:
            break
        }
    }

    private func rehomeMeetingTransferStateIfNeeded() {
        guard let fallbackSceneID = livingMeetingTransferSceneIDs.first else { return }
        if meetingTransferImportState != nil,
           let meetingTransferSceneID,
           !livingMeetingTransferSceneIDs.contains(meetingTransferSceneID) {
            self.meetingTransferSceneID = fallbackSceneID
        }
        if selectedMeetingID != nil,
           let selectedMeetingSceneID,
           !livingMeetingTransferSceneIDs.contains(selectedMeetingSceneID) {
            self.selectedMeetingSceneID = fallbackSceneID
        }
    }

    private func isAuthorizedMeetingTransferScene(
        _ sceneID: MeetingTransferSceneID
    ) -> Bool {
        meetingTransferSceneID == sceneID
            && isLivingMeetingTransferScene(sceneID)
    }

    func meetingTransferClientDidBecomeReady() {
        startPendingMeetingTransferIfPossible()
    }

    func previewMeetingPackage(
        at externalURL: URL,
        sceneID: MeetingTransferSceneID
    ) {
        guard livingMeetingTransferSceneIDs.contains(sceneID) else {
            guard !hasRegisteredMeetingTransferScene else { return }
            registerMeetingTransferScene(sceneID)
            return previewMeetingPackage(at: externalURL, sceneID: sceneID)
        }
        pendingMeetingTransferURL = externalURL
        pendingMeetingTransferSceneID = sceneID
        switch meetingTransferImportState {
        case .preparing, .importing:
            requestMeetingTransferCancellation()
        case .preview:
            scheduleMeetingTransferDiscard(completeCommittedResult: false)
        case .failed:
            meetingTransferImportState = nil
            startPendingMeetingTransferIfPossible()
        case .cleanupRequired, .completed, .recoveryRequired:
            break
        case nil:
            startPendingMeetingTransferIfPossible()
        }
    }

    func previewMeetingPackage(at externalURL: URL) {
        previewMeetingPackage(
            at: externalURL,
            sceneID: meetingTransferSceneID ?? MeetingTransferSceneID()
        )
    }

    func importMeetingPackage(for sceneID: MeetingTransferSceneID) {
        guard isAuthorizedMeetingTransferScene(sceneID),
              meetingTransferOperation == nil,
              case .preview(let presentation) = meetingTransferImportState,
              let owner = ownedMeetingTransferSession,
              owner.sessionID == presentation.sessionID else {
            return
        }
        let operationID = UUID()
        meetingTransferOperationID = operationID
        meetingTransferCancellationRequested = false
        meetingTransferImportState = .importing(presentation, nil)
        meetingTransferOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { completeMeetingTransferOperation(operationID) }
            do {
                let result = try await owner.client.importPrepared(
                    presentation.sessionID,
                    .importOnly,
                    progressHandler(operationID: operationID)
                )
                guard meetingTransferOperationID == operationID else { return }
                ownedMeetingTransferSession = nil
                committedMeetingTransferResultAwaitingCleanup = nil
                if meetingTransferCancellationRequested {
                    switch result {
                    case .pendingRecovery(let meetingID):
                        meetingTransferImportState = .recoveryRequired(meetingID)
                    case .imported, .alreadyPresent:
                        meetingTransferImportState = .completed(result)
                    }
                } else {
                    await finishMeetingTransferImport(result)
                }
            } catch let error as MeetingTransferImportError {
                guard meetingTransferOperationID == operationID else { return }
                if case .cleanupRequired(let sessionID, let result) = error {
                    ownedMeetingTransferSession = .init(
                        sessionID: sessionID,
                        client: owner.client
                    )
                    committedMeetingTransferResultAwaitingCleanup = result
                    showCleanupRequired(
                        sessionID: sessionID,
                        committedResult: result,
                        message: "The private import copy could not be removed."
                    )
                } else {
                    await finishFailedImport(
                        error,
                        operationID: operationID
                    )
                }
            } catch {
                await finishFailedImport(
                    error,
                    operationID: operationID
                )
            }
        }
    }

    func importMeetingPackage() {
        guard let meetingTransferSceneID else { return }
        importMeetingPackage(for: meetingTransferSceneID)
    }

    func closeMeetingTransferImport(for sceneID: MeetingTransferSceneID) {
        guard isAuthorizedMeetingTransferScene(sceneID) else { return }
        switch meetingTransferImportState {
        case .preparing, .importing:
            requestMeetingTransferCancellation()
        case .preview:
            scheduleMeetingTransferDiscard(completeCommittedResult: false)
        case .cleanupRequired:
            scheduleMeetingTransferDiscard(completeCommittedResult: true)
        case .completed(let result):
            scheduleMeetingTransferCompletion(result)
        case .recoveryRequired, .failed:
            guard meetingTransferOperation == nil else { return }
            meetingTransferImportState = nil
            startPendingMeetingTransferIfPossible()
        case nil:
            startPendingMeetingTransferIfPossible()
        }
    }

    func closeMeetingTransferImport() {
        guard let meetingTransferSceneID else { return }
        closeMeetingTransferImport(for: meetingTransferSceneID)
    }

    func dismissMeetingTransferSheet(for sceneID: MeetingTransferSceneID) {
        closeMeetingTransferImport(for: sceneID)
    }

    func retryMeetingTransferCleanup(for sceneID: MeetingTransferSceneID) {
        guard isAuthorizedMeetingTransferScene(sceneID),
              meetingTransferImportState?.cleanupSessionID != nil else { return }
        scheduleMeetingTransferDiscard(completeCommittedResult: true)
    }

    func retryMeetingTransferCleanup() {
        guard let meetingTransferSceneID else { return }
        retryMeetingTransferCleanup(for: meetingTransferSceneID)
    }

    func openExistingMeetingFromTransferPreview(for sceneID: MeetingTransferSceneID) {
        guard isAuthorizedMeetingTransferScene(sceneID),
              case .preview(let presentation) = meetingTransferImportState,
              case .alreadyPresent(let meetingID) = presentation.disposition else {
            return
        }
        scheduleMeetingTransferDiscard(committedResult: .alreadyPresent(meetingID))
    }

    func openExistingMeetingFromTransferPreview() {
        guard let meetingTransferSceneID else { return }
        openExistingMeetingFromTransferPreview(for: meetingTransferSceneID)
    }

    func isPresentingMeetingTransfer(in sceneID: MeetingTransferSceneID) -> Bool {
        isAuthorizedMeetingTransferScene(sceneID) && meetingTransferImportState != nil
    }

    private func scheduleMeetingTransferDiscard(
        completeCommittedResult: Bool = false,
        committedResult: MeetingTransferImportResult? = nil
    ) {
        guard meetingTransferOperation == nil else { return }
        let operationID = UUID()
        meetingTransferOperationID = operationID
        meetingTransferCancellationRequested = false
        if let committedResult {
            committedMeetingTransferResultAwaitingCleanup = committedResult
        }
        let completionResult = committedResult
            ?? committedMeetingTransferResultAwaitingCleanup
        meetingTransferOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { completeMeetingTransferOperation(operationID) }
            guard await discardOwnedMeetingTransferSession(
                operationID: operationID
            ) else { return }
            guard meetingTransferOperationID == operationID else { return }
            if (completeCommittedResult || committedResult != nil), let completionResult {
                await finishMeetingTransferImport(completionResult)
            } else {
                meetingTransferImportState = nil
            }
        }
    }

    private func scheduleMeetingTransferCompletion(
        _ result: MeetingTransferImportResult
    ) {
        guard meetingTransferOperation == nil else { return }
        let operationID = UUID()
        meetingTransferOperationID = operationID
        meetingTransferCancellationRequested = false
        meetingTransferOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { completeMeetingTransferOperation(operationID) }
            await finishMeetingTransferImport(result)
        }
    }

    private func requestMeetingTransferCancellation() {
        meetingTransferCancellationRequested = true
        meetingTransferOperation?.cancel()
    }

    private func startPendingMeetingTransferIfPossible() {
        guard meetingTransferOperation == nil,
              meetingTransferImportState == nil,
              let client = meetingTransferClient,
              let externalURL = pendingMeetingTransferURL,
              let sceneID = pendingMeetingTransferSceneID else { return }
        pendingMeetingTransferURL = nil
        pendingMeetingTransferSceneID = nil
        meetingTransferSceneID = sceneID
        let operationID = UUID()
        meetingTransferOperationID = operationID
        meetingTransferCancellationRequested = false
        meetingTransferImportState = .preparing(nil)
        meetingTransferOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { completeMeetingTransferOperation(operationID) }
            let accessing = meetingTransferSecurityScope.startAccessing(externalURL)
            let outcome: Result<MeetingTransferImportPresentation, Error>
            do {
                outcome = .success(try await client.prepareImport(
                    externalURL,
                    progressHandler(operationID: operationID)
                ))
            } catch {
                outcome = .failure(error)
            }
            if accessing { meetingTransferSecurityScope.stopAccessing(externalURL) }
            guard meetingTransferOperationID == operationID else { return }
            switch outcome {
            case .success(let presentation):
                ownedMeetingTransferSession = .init(
                    sessionID: presentation.sessionID,
                    client: client
                )
                if meetingTransferCancellationRequested || Task.isCancelled {
                    guard await discardOwnedMeetingTransferSession(
                        operationID: operationID
                    ) else { return }
                    meetingTransferImportState = nil
                } else {
                    meetingTransferImportState = .preview(presentation)
                }
            case .failure(let error as MeetingTransferImportError):
                if case .preparationCleanupRequired(let sessionID) = error {
                    ownedMeetingTransferSession = .init(
                        sessionID: sessionID,
                        client: client
                    )
                    showCleanupRequired(
                        sessionID: sessionID,
                        committedResult: nil,
                        message: "The private import copy could not be removed."
                    )
                } else if meetingTransferCancellationRequested {
                    meetingTransferImportState = nil
                } else {
                    meetingTransferImportState = .failed(error.localizedDescription)
                }
            case .failure(let error):
                meetingTransferImportState = meetingTransferCancellationRequested
                    || error is CancellationError
                    ? nil
                    : .failed(error.localizedDescription)
            }
        }
    }

    private func completeMeetingTransferOperation(_ operationID: UUID) {
        guard meetingTransferOperationID == operationID else { return }
        meetingTransferOperation = nil
        meetingTransferCancellationRequested = false
        if meetingTransferImportState == nil {
            startPendingMeetingTransferIfPossible()
        }
    }

    private func finishFailedImport(
        _ error: Error,
        operationID: UUID
    ) async {
        let wasCancelled = error is CancellationError
        guard await discardOwnedMeetingTransferSession(
            operationID: operationID,
            failureMessage: error.localizedDescription
        ) else { return }
        guard meetingTransferOperationID == operationID else { return }
        meetingTransferImportState = wasCancelled ? nil : .failed(error.localizedDescription)
    }

    private func discardOwnedMeetingTransferSession(
        operationID: UUID,
        failureMessage: String = "The private import copy could not be removed."
    ) async -> Bool {
        guard meetingTransferOperationID == operationID else { return false }
        guard let owner = ownedMeetingTransferSession else {
            committedMeetingTransferResultAwaitingCleanup = nil
            return true
        }
        do {
            try await owner.client.discardPrepared(owner.sessionID)
        } catch MeetingTransferImportError.sessionNotFound(let missing) where missing == owner.sessionID {
            // A completed service operation already removed its own session.
        } catch {
            ownedMeetingTransferSession = owner
            guard meetingTransferOperationID == operationID else { return false }
            showCleanupRequired(
                sessionID: owner.sessionID,
                committedResult: committedMeetingTransferResultAwaitingCleanup,
                message: failureMessage
            )
            return false
        }
        guard meetingTransferOperationID == operationID else { return false }
        ownedMeetingTransferSession = nil
        committedMeetingTransferResultAwaitingCleanup = nil
        return true
    }

    private func finishMeetingTransferImport(
        _ result: MeetingTransferImportResult
    ) async {
        switch result {
        case .imported(let meetingID), .alreadyPresent(let meetingID):
            await reloadMeetings()
            if meetingTransferCancellationRequested {
                meetingTransferImportState = .completed(result)
                return
            }
            selectedMeetingID = meetingID
            selectedMeetingSceneID = meetingTransferSceneID
            meetingTransferImportState = nil
        case .pendingRecovery(let meetingID):
            meetingTransferImportState = .recoveryRequired(meetingID)
        }
    }

    private func progressHandler(
        operationID: UUID
    ) -> MeetingTransferImportClient.Progress {
        { [weak self] progress in
            Task { @MainActor in
                guard let self,
                      self.meetingTransferOperationID == operationID else { return }
                switch self.meetingTransferImportState {
                case .preparing:
                    self.meetingTransferImportState = .preparing(progress)
                case .importing(let presentation, _):
                    self.meetingTransferImportState = .importing(presentation, progress)
                case .preview, .cleanupRequired, .completed, .recoveryRequired, .failed, nil:
                    break
                }
            }
        }
    }

    private func showCleanupRequired(
        sessionID: UUID,
        committedResult: MeetingTransferImportResult?,
        message: String
    ) {
        meetingTransferImportState = .cleanupRequired(
            sessionID: sessionID,
            committedResult: committedResult,
            message: message
        )
    }

    func meetingTransferPreview(_ meetingID: MeetingID) async throws
        -> MeetingTransferExportPreview
    {
        guard let runtime else {
            throw MeetingTransferExportCleanupError.runtimeUnavailable
        }
        return try await MeetingTransferExportService(
            library: runtime.library
        ).preview(meetingID: meetingID)
    }

    func prepareMeetingTransferExport(
        meetingID: MeetingID,
        selectedAudioAssetIDs: Set<MediaAssetID>
    ) async throws -> MeetingTransferExportResult {
        guard let runtime else {
            throw MeetingTransferExportCleanupError.runtimeUnavailable
        }
        let workspace = MeetingTransferExportWorkspace(
            parentDirectory: meetingTransferTemporaryDirectory()
        )
        let sourceAppVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let result = try await workspace.perform { root in
            try await MeetingTransferExportService(
                library: runtime.library
            ).export(
                meetingID: meetingID,
                selectedAudioAssetIDs: selectedAudioAssetIDs,
                temporaryRoot: root,
                sourceAppVersion: sourceAppVersion
            )
        }
        meetingTransferExportRoots.insert(result.cleanupRoot.standardizedFileURL)
        return result
    }

    func cleanupMeetingTransferExport(_ result: MeetingTransferExportResult) throws {
        let root = result.cleanupRoot.standardizedFileURL
        let package = result.packageURL.standardizedFileURL
        guard meetingTransferExportRoots.contains(root),
              package.deletingLastPathComponent() == root
        else {
            throw MeetingTransferExportCleanupError.notOwned
        }
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            guard !FileManager.default.fileExists(atPath: root.path) else {
                throw MeetingTransferExportCleanupError.cleanupFailed
            }
            meetingTransferExportRoots.remove(root)
        } catch {
            throw MeetingTransferExportCleanupError.cleanupFailed
        }
    }
}
