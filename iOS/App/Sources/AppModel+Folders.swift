import Foundation
import StenoDomain
import StenoLibrary

enum AppModelFolderError: LocalizedError {
    case runtimeUnavailable
    case storeUnavailable
    case operationInProgress
    case runtimeTransitionInProgress
    case operationInvalidated

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable: "The library is not ready yet."
        case .storeUnavailable: "The folder index is not available."
        case .operationInProgress: "Another folder action is still in progress."
        case .runtimeTransitionInProgress: "The folder action waits for the runtime transition to finish."
        case .operationInvalidated: "The folder action was superseded by a runtime change."
        }
    }
}

@MainActor
extension AppModel {
    @discardableResult
    func createFolder(named name: String, parentFolderID: FolderID? = nil) async -> Folder? {
        guard let operation = beginFolderOperation() else { return nil }
        defer { endFolderOperation(operation) }
        let snapshot: RuntimeFolderSnapshot
        do { snapshot = try folderOperationSnapshot() }
        catch { reportFolderFailure("The folder could not be created.", error); return nil }
        guard let store = snapshot.folderStore else { return nil }
        do {
            let folder = try await store.createFolder(name: name, parentFolderID: parentFolderID)
            guard isCurrent(snapshot, operation: operation) else { return nil }
            guard await reloadMeetings(for: snapshot, operation: operation) == .published else { return nil }
            return folder
        } catch {
            guard isCurrent(snapshot, operation: operation) else { return nil }
            _ = await reloadMeetings(for: snapshot, operation: operation)
            reportFolderFailure("The folder could not be created.", error)
            return nil
        }
    }

    @discardableResult
    func renameFolder(_ folderID: FolderID, to name: String) async -> Bool {
        guard let operation = beginFolderOperation() else { return false }
        defer { endFolderOperation(operation) }
        let snapshot: RuntimeFolderSnapshot
        do { snapshot = try folderOperationSnapshot() }
        catch { reportFolderFailure("The folder could not be renamed.", error); return false }
        guard let store = snapshot.folderStore else { return false }
        do {
            _ = try await store.renameFolder(folderID, to: name)
            guard isCurrent(snapshot, operation: operation) else { return false }
            return await reloadMeetings(for: snapshot, operation: operation) == .published
        } catch {
            guard isCurrent(snapshot, operation: operation) else { return false }
            _ = await reloadMeetings(for: snapshot, operation: operation)
            reportFolderFailure("The folder could not be renamed.", error)
            return false
        }
    }

    @discardableResult
    func deleteFolder(_ folderID: FolderID) async -> Bool {
        guard let operation = beginFolderOperation() else { return false }
        defer { endFolderOperation(operation) }
        let snapshot: RuntimeFolderSnapshot
        do { snapshot = try folderOperationSnapshot() }
        catch { reportFolderFailure("The folder could not be deleted.", error); return false }
        guard let store = snapshot.folderStore else { return false }

        let directMeetingIDs: Set<MeetingID>
        do {
            let currentMeetings = try await runtimeMeetingLoader(snapshot.runtime.library)
            guard isCurrent(snapshot, operation: operation) else { return false }
            directMeetingIDs = Set(currentMeetings.compactMap { $0.folderID == folderID ? $0.id : nil })
            guard try await store.folder(folderID) != nil else { throw LibraryError.folderNotFound(folderID) }
            guard isCurrent(snapshot, operation: operation) else { return false }
            _ = try await setMeetingFolders(directMeetingIDs, to: nil, in: snapshot, operation: operation)
            guard isCurrent(snapshot, operation: operation) else { return false }
        } catch {
            guard isCurrent(snapshot, operation: operation) else { return false }
            _ = await reloadMeetings(for: snapshot, operation: operation)
            reportFolderFailure("The folder could not be deleted.", error)
            return false
        }

        do {
            guard try await deleteFolderIndex(folderID, from: store) != nil else {
                guard isCurrent(snapshot, operation: operation) else { return false }
                _ = await reloadMeetings(for: snapshot, operation: operation)
                reportFolderStateReloaded()
                return false
            }
            guard isCurrent(snapshot, operation: operation) else { return false }
            return await reloadMeetings(for: snapshot, operation: operation) == .published
        } catch {
            return await resolveAmbiguousFolderDeletion(
                folderID,
                directMeetingIDs: directMeetingIDs,
                snapshot: snapshot,
                operation: operation,
                deletionError: error
            )
        }
    }

    /// A write error after a filesystem rename is commit-ambiguous. Reopening
    /// the index is the only safe way to decide whether assignments belong
    /// back on the folder or must stay unfiled.
    private func resolveAmbiguousFolderDeletion(
        _ folderID: FolderID,
        directMeetingIDs: Set<MeetingID>,
        snapshot: RuntimeFolderSnapshot,
        operation: FolderOperationToken,
        deletionError: Error
    ) async -> Bool {
        guard isCurrent(snapshot, operation: operation) else { return false }
        let freshStore: FolderStore
        let freshFolders: [Folder]
        do {
            freshStore = try freshFolderStore(for: snapshot)
            freshFolders = try await folderListLoader(freshStore)
            guard isCurrent(snapshot, operation: operation) else { return false }
        } catch {
            _ = await publishReadableMeetingsWithUnavailableFolders(
                for: snapshot,
                failure: "The folders could not be verified after the deletion error. (\(error.localizedDescription))",
                operation: operation
            )
            guard isCurrent(snapshot, operation: operation) else { return false }
            reportFolderAvailabilityFailure(
                "The folders could not be verified after the deletion error. (\(error.localizedDescription)) The deletion outcome is unknown, so meeting assignments were not restored. (\(deletionError.localizedDescription))"
            )
            return false
        }

        // The verification read is the newer authoritative index. Replace the
        // actor owned by this generation before publishing it again.
        guard let freshSnapshot = adoptFolderStore(
            freshStore,
            for: snapshot,
            operation: operation
        ) else { return false }

        if freshFolders.contains(where: { $0.id == folderID }) {
            do {
                _ = try await setMeetingFolders(
                    directMeetingIDs,
                    to: folderID,
                    in: freshSnapshot,
                    operation: operation
                )
                guard isCurrent(freshSnapshot, operation: operation) else { return false }
            } catch let restorationError {
                let result = await reloadMeetings(for: freshSnapshot, operation: operation)
                guard isCurrent(freshSnapshot, operation: operation) else { return false }
                reportFolderPartialRecoveryFailure(restorationError, reloadResult: result)
                return false
            }
            let result = await reloadMeetings(for: freshSnapshot, operation: operation)
            guard isCurrent(freshSnapshot, operation: operation) else { return false }
            if result == .published {
                reportFolderFailure("The folder could not be deleted.", deletionError)
            }
            return false
        }

        // The folder is gone. Keeping persisted nil assignments avoids IDs
        // with no corresponding folder.
        let result = await reloadMeetings(for: freshSnapshot, operation: operation)
        guard isCurrent(freshSnapshot, operation: operation) else { return false }
        if result == .published {
            reportFolderFailure(
                "The folder deletion was persisted, but its durability could not be confirmed.",
                deletionError
            )
        }
        return false
    }

    @discardableResult
    func moveFolder(_ folderID: FolderID, to parentFolderID: FolderID?) async -> Bool {
        guard let operation = beginFolderOperation() else { return false }
        defer { endFolderOperation(operation) }
        let snapshot: RuntimeFolderSnapshot
        do { snapshot = try folderOperationSnapshot() }
        catch { reportFolderFailure("The folder could not be moved.", error); return false }
        guard let store = snapshot.folderStore else { return false }
        do {
            _ = try await store.moveFolder(folderID, toParentFolderID: parentFolderID)
            guard isCurrent(snapshot, operation: operation) else { return false }
            return await reloadMeetings(for: snapshot, operation: operation) == .published
        } catch {
            guard isCurrent(snapshot, operation: operation) else { return false }
            _ = await reloadMeetings(for: snapshot, operation: operation)
            reportFolderFailure("The folder could not be moved.", error)
            return false
        }
    }

    @discardableResult
    func moveFolder(_ folderID: FolderID, up: Bool) async -> Bool {
        guard let operation = beginFolderOperation() else { return false }
        defer { endFolderOperation(operation) }
        let snapshot: RuntimeFolderSnapshot
        do { snapshot = try folderOperationSnapshot() }
        catch { reportFolderFailure("The folders could not be reordered.", error); return false }
        guard let store = snapshot.folderStore else { return false }
        do {
            let persistedFolders = try await folderListLoader(store)
            guard isCurrent(snapshot, operation: operation) else { return false }
            guard let folder = persistedFolders.first(where: { $0.id == folderID }) else {
                throw LibraryError.folderNotFound(folderID)
            }
            let siblings = persistedFolders.filter { $0.parentFolderID == folder.parentFolderID }
            guard let index = siblings.firstIndex(where: { $0.id == folderID }) else {
                throw LibraryError.folderNotFound(folderID)
            }
            let targetIndex = up ? index - 1 : index + 1
            guard siblings.indices.contains(targetIndex) else { return false }
            var order = siblings.map { $0.id }
            order.swapAt(index, targetIndex)
            try await store.reorderFolders(parentFolderID: folder.parentFolderID, order: order)
            guard isCurrent(snapshot, operation: operation) else { return false }
            return await reloadMeetings(for: snapshot, operation: operation) == .published
        } catch {
            guard isCurrent(snapshot, operation: operation) else { return false }
            _ = await reloadMeetings(for: snapshot, operation: operation)
            reportFolderFailure("The folders could not be reordered.", error)
            return false
        }
    }

    @discardableResult
    func moveMeeting(_ meetingID: MeetingID, to folderID: FolderID?) async -> Bool {
        guard let operation = beginFolderOperation() else { return false }
        defer { endFolderOperation(operation) }
        let snapshot: RuntimeFolderSnapshot
        do { snapshot = try folderOperationSnapshot() }
        catch { reportFolderFailure("The meeting could not be moved.", error); return false }
        guard let store = snapshot.folderStore else { return false }
        do {
            if let folderID, try await store.folder(folderID) == nil {
                throw LibraryError.folderNotFound(folderID)
            }
            guard isCurrent(snapshot, operation: operation) else { return false }
            _ = try await setMeetingFolders(
                Set([meetingID]),
                to: folderID,
                in: snapshot,
                operation: operation
            )
            guard isCurrent(snapshot, operation: operation) else { return false }
            return await reloadMeetings(for: snapshot, operation: operation) == .published
        } catch {
            guard isCurrent(snapshot, operation: operation) else { return false }
            _ = await reloadMeetings(for: snapshot, operation: operation)
            reportFolderFailure("The meeting could not be moved.", error)
            return false
        }
    }
}
