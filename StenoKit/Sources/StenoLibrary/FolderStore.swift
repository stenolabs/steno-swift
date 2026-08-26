import Foundation
import StenoDomain

package enum FolderStoreMutationCheckpoint: Equatable, Sendable {
    case afterExclusiveTransactionBeforePreparationRead
    case afterExclusiveTransactionBeforeMutationRead
    case afterEmptyFolderDocumentRead
    case afterEmptyFolderChildInspection
    case afterEmptyFolderMeetingInspectionBeforeDelete
}

package typealias FolderStoreMutationAction = @Sendable (
    FolderStoreMutationCheckpoint,
    LibraryMutationTransaction
) throws -> Void

private struct FoldersDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    var folders: [Folder]
    /// Einmalige Uebernahme der Ordnernamen aus dem Steno-Altimport. Sie darf
    /// genau einmal laufen: wer ein importiertes Meeting bewusst aus seinem
    /// Ordner nimmt, soll es beim naechsten Start nicht wieder darin finden.
    var adoptedLegacyFolders: Bool

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        folders: [Folder],
        adoptedLegacyFolders: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.folders = folders
        self.adoptedLegacyFolders = adoptedLegacyFolders
    }
}

private struct FoldersDocumentV1: Decodable {
    let schemaVersion: Int
    var folders: [FolderV1]
    var adoptedLegacyFolders: Bool
}

private struct FolderV1: Decodable {
    let id: FolderID
    var name: String
    var sortIndex: Int
    let createdAt: Date
}

public struct FolderDeletionResult: Equatable, Sendable {
    public let deletedFolderID: FolderID
    public let promotedFolderIDs: [FolderID]

    public init(
        deletedFolderID: FolderID,
        promotedFolderIDs: [FolderID]
    ) {
        self.deletedFolderID = deletedFolderID
        self.promotedFolderIDs = promotedFolderIDs
    }
}

public enum EmptyFolderDeletionResult: Equatable, Sendable {
    case deleted
    case notFound
    case notEmpty
}

public actor FolderStore {
    public nonisolated let layout: LibraryLayout
    private let mutationAction: FolderStoreMutationAction

    private init(
        layout: LibraryLayout,
        mutationAction: @escaping FolderStoreMutationAction
    ) {
        self.layout = layout
        self.mutationAction = mutationAction
    }

    public static func open(layout: LibraryLayout) throws -> FolderStore {
        try open(layout: layout) { _, _ in }
    }

    package static func open(
        layout: LibraryLayout,
        mutationAction: @escaping FolderStoreMutationAction
    ) throws -> FolderStore {
        try prepare(layout: layout, mutationAction: mutationAction)
        return FolderStore(layout: layout, mutationAction: mutationAction)
    }

    private static func prepare(
        layout: LibraryLayout,
        mutationAction: FolderStoreMutationAction
    ) throws {
        try FileManager.default.createDirectory(
            at: layout.root,
            withIntermediateDirectories: true
        )
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try mutationAction(
                .afterExclusiveTransactionBeforePreparationRead,
                transaction
            )
            guard FileManager.default.fileExists(atPath: layout.folders.path) else {
                return
            }
            _ = try JSONDocumentStore.migrateAndRead(
                current: FoldersDocument.self,
                legacy: FoldersDocumentV1.self,
                from: layout.folders,
                legacySchemaVersion: 1,
                currentSchemaVersion: FoldersDocument.currentSchemaVersion,
                currentSchema: \.schemaVersion
            ) { legacy in
                FoldersDocument(
                    folders: legacy.folders.map {
                        Folder(
                            id: $0.id,
                            name: $0.name,
                            sortIndex: $0.sortIndex,
                            createdAt: $0.createdAt
                        )
                    },
                    adoptedLegacyFolders: legacy.adoptedLegacyFolders
                )
            }
        }
    }

    /// Hauptordner nach ihrer Reihenfolge, jeweils unmittelbar gefolgt von
    /// ihren Kindern. Ungueltige Altzustaende bleiben am Ende sichtbar; die
    /// reine Baumaufbereitung entscheidet spaeter ueber ihren Fallback.
    public func listFolders() throws -> [Folder] {
        let folders = try readDocument().folders
        let roots = Self.orderedSiblings(parentFolderID: nil, in: folders)
        var result: [Folder] = []
        var included: Set<FolderID> = []
        for root in roots {
            result.append(root)
            included.insert(root.id)
            let children = Self.orderedSiblings(
                parentFolderID: root.id,
                in: folders
            )
            result.append(contentsOf: children)
            included.formUnion(children.map(\.id))
        }
        result.append(contentsOf: folders.filter { !included.contains($0.id) }
            .sorted(by: Self.folderOrder))
        return result
    }

    public func folder(_ folderID: FolderID) throws -> Folder? {
        try listFolders().first { $0.id == folderID }
    }

    @discardableResult
    public func createFolder(
        name: String,
        parentFolderID: FolderID? = nil,
        createdAt: Date = Date()
    ) throws -> Folder {
        let normalized = try Self.normalizedName(name)
        return try mutateDocument { document in
            try Self.validateParent(parentFolderID, in: document.folders)
            try Self.validateUniqueName(
                normalized,
                parentFolderID: parentFolderID,
                among: document.folders
            )
            let folder = Folder(
                name: normalized,
                parentFolderID: parentFolderID,
                sortIndex: Self.siblings(
                    parentFolderID: parentFolderID,
                    in: document.folders
                ).count,
                createdAt: createdAt
            )
            document.folders.append(folder)
            return folder
        }
    }

    /// Liefert den Ordner mit diesem Namen und legt ihn an, falls es ihn noch
    /// nicht gibt. Fuer Importe gedacht, die Ordner mitbringen: dort ist ein
    /// vorhandener Ordner kein Konflikt, sondern genau das Ziel.
    public func folder(named name: String) throws -> Folder {
        let normalized = try Self.normalizedName(name)
        let key = Self.comparisonKey(normalized)
        return try mutateDocument { document in
            if let existing = document.folders.first(where: {
                $0.parentFolderID == nil && Self.comparisonKey($0.name) == key
            }) {
                return existing
            }
            let folder = Folder(
                name: normalized,
                sortIndex: Self.siblings(
                    parentFolderID: nil,
                    in: document.folders
                ).count
            )
            document.folders.append(folder)
            return folder
        }
    }

    /// Transaktionsbewusste Import-Variante. Sie erstellt oder findet nur
    /// einen Hauptordner und verschachtelt keinen weiteren Mutations-Lock.
    package nonisolated func folder(
        named name: String,
        transaction: LibraryMutationTransaction
    ) throws -> Folder {
        try transaction.validate(layout: layout)
        let normalized = try Self.normalizedName(name)
        let key = Self.comparisonKey(normalized)
        var document = try readDocument(transaction: transaction)
        if let existing = document.folders.first(where: {
            $0.parentFolderID == nil && Self.comparisonKey($0.name) == key
        }) {
            return existing
        }
        let folder = Folder(
            name: normalized,
            sortIndex: Self.siblings(parentFolderID: nil, in: document.folders).count
        )
        document.folders.append(folder)
        try write(document, transaction: transaction)
        return folder
    }

    package nonisolated func folderIfPresent(
        named name: String,
        transaction: LibraryMutationTransaction
    ) throws -> Folder? {
        try transaction.validate(layout: layout)
        let key = Self.comparisonKey(try Self.normalizedName(name))
        return try readDocument(transaction: transaction).folders.first {
            $0.parentFolderID == nil && Self.comparisonKey($0.name) == key
        }
    }

    package nonisolated func folder(
        _ folderID: FolderID,
        transaction: LibraryMutationTransaction
    ) throws -> Folder? {
        try transaction.validate(layout: layout)
        return try readDocument(transaction: transaction).folders.first {
            $0.id == folderID
        }
    }

    /// Atomare Auflösung für zusammengesetzte Imports. Neben dem Ordner wird
    /// festgehalten, ob genau diese Transaktion ihn erzeugt hat.
    package nonisolated func resolveTopLevelFolder(
        named name: String,
        transaction: LibraryMutationTransaction
    ) throws -> (folder: Folder, wasCreated: Bool) {
        try transaction.validate(layout: layout)
        let normalized = try Self.normalizedName(name)
        let key = Self.comparisonKey(normalized)
        var document = try readDocument(transaction: transaction)
        if let existing = document.folders.first(where: {
            $0.parentFolderID == nil && Self.comparisonKey($0.name) == key
        }) {
            return (existing, false)
        }
        let folder = Folder(name: normalized, sortIndex: Self.siblings(parentFolderID: nil, in: document.folders).count)
        document.folders.append(folder)
        try write(document, transaction: transaction)
        return (folder, true)
    }

    @discardableResult
    public func renameFolder(
        _ folderID: FolderID,
        to name: String
    ) throws -> Folder {
        let normalized = try Self.normalizedName(name)
        return try mutateDocument { document in
            guard let index = document.folders.firstIndex(where: { $0.id == folderID }) else {
                throw LibraryError.folderNotFound(folderID)
            }
            try Self.validateUniqueName(
                normalized,
                parentFolderID: document.folders[index].parentFolderID,
                among: document.folders,
                excluding: folderID
            )
            document.folders[index].name = normalized
            return document.folders[index]
        }
    }

    /// Sets or clears a folder's sidebar color token. Only the token is
    /// persisted; the concrete color values are chosen by the UI layer.
    @discardableResult
    public func setColorToken(
        _ colorToken: FolderColorToken?,
        of folderID: FolderID
    ) throws -> Folder {
        try mutateDocument { document in
            guard let index = document.folders.firstIndex(where: { $0.id == folderID }) else {
                throw LibraryError.folderNotFound(folderID)
            }
            document.folders[index].colorToken = colorToken
            return document.folders[index]
        }
    }

    /// Sets or clears a folder's SF Symbol icon. nil restores the default
    /// folder symbol.
    public func setIcon(
        _ icon: FolderIcon?,
        of folderID: FolderID
    ) throws -> Folder {
        try mutateDocument { document in
            guard let index = document.folders.firstIndex(where: { $0.id == folderID }) else {
                throw LibraryError.folderNotFound(folderID)
            }
            document.folders[index].icon = icon
            return document.folders[index]
        }
    }

    @discardableResult
    public func moveFolder(
        _ folderID: FolderID,
        toParentFolderID parentFolderID: FolderID?
    ) throws -> Folder {
        try mutateDocument { document in
            guard let index = document.folders.firstIndex(where: {
                $0.id == folderID
            }) else {
                throw LibraryError.folderNotFound(folderID)
            }
            let oldParentFolderID = document.folders[index].parentFolderID
            guard oldParentFolderID != parentFolderID else {
                return document.folders[index]
            }
            guard parentFolderID != folderID else {
                throw LibraryError.invalidFolderHierarchy(
                    "A folder cannot be its own parent."
                )
            }
            try Self.validateParent(parentFolderID, in: document.folders)
            if let parentFolderID,
               Self.isDescendant(
                   parentFolderID,
                   of: folderID,
                   in: document.folders
               )
            {
                throw LibraryError.invalidFolderHierarchy(
                    "A folder cannot move below one of its descendants."
                )
            }
            if parentFolderID != nil,
               document.folders.contains(where: {
                   $0.parentFolderID == folderID
               })
            {
                throw LibraryError.invalidFolderHierarchy(
                    "A folder with children cannot become a child."
                )
            }
            try Self.validateUniqueName(
                document.folders[index].name,
                parentFolderID: parentFolderID,
                among: document.folders,
                excluding: folderID
            )

            document.folders[index].parentFolderID = parentFolderID
            document.folders[index].sortIndex = Self.siblings(
                parentFolderID: parentFolderID,
                in: document.folders
            ).filter { $0.id != folderID }.count
            Self.normalizeSiblings(
                parentFolderID: oldParentFolderID,
                in: &document.folders
            )
            Self.normalizeSiblings(
                parentFolderID: parentFolderID,
                in: &document.folders
            )
            return document.folders[index]
        }
    }

    /// Entfernt nur den Ordnerindex. Direkte Meetingzuordnungen raeumt die
    /// App vorher auf; Kinder eines Hauptordners werden atomar hochgestuft.
    @discardableResult
    public func deleteFolder(_ folderID: FolderID) throws -> FolderDeletionResult? {
        try mutateDocument { document in
            guard let folder = document.folders.first(where: {
                $0.id == folderID
            }) else {
                return nil
            }
            let promoted = Self.orderedSiblings(
                parentFolderID: folderID,
                in: document.folders
            )
            let oldParentFolderID = folder.parentFolderID

            if oldParentFolderID == nil, !promoted.isEmpty {
                let roots = Self.orderedSiblings(
                    parentFolderID: nil,
                    in: document.folders
                )
                let futureRoots = roots.filter { $0.id != folderID } + promoted
                for promotedFolder in promoted {
                    try Self.validateUniqueName(
                        promotedFolder.name,
                        parentFolderID: nil,
                        among: futureRoots,
                        excluding: promotedFolder.id
                    )
                }
                let insertionIndex = roots.firstIndex(where: {
                    $0.id == folderID
                }) ?? 0
                let rootIDs = roots.filter { $0.id != folderID }.map(\.id)
                var newRootOrder = rootIDs
                newRootOrder.insert(
                    contentsOf: promoted.map(\.id),
                    at: min(insertionIndex, newRootOrder.count)
                )
                for promotedFolder in promoted {
                    guard let index = document.folders.firstIndex(where: {
                        $0.id == promotedFolder.id
                    }) else { continue }
                    document.folders[index].parentFolderID = nil
                }
                for (sortIndex, rootID) in newRootOrder.enumerated() {
                    guard let index = document.folders.firstIndex(where: {
                        $0.id == rootID
                    }) else { continue }
                    document.folders[index].sortIndex = sortIndex
                }
            }

            document.folders.removeAll { $0.id == folderID }
            Self.normalizeSiblings(
                parentFolderID: oldParentFolderID,
                in: &document.folders
            )
            return FolderDeletionResult(
                deletedFolderID: folderID,
                promotedFolderIDs: promoted.map(\.id)
            )
        }
    }

    /// Entfernt ausschließlich den exakt benannten, nach erneuter Prüfung
    /// leeren Ordner. Anders als `deleteFolder` werden weder Kinder befördert
    /// noch Meetings bewegt.
    @discardableResult
    public func deleteFolderIfEmpty(
        _ folderID: FolderID
    ) throws -> EmptyFolderDeletionResult {
        try LibraryMutationCoordination.withExclusiveTransaction(
            layout: layout
        ) { transaction in
            var document = try readDocument(transaction: transaction)
            try mutationAction(.afterEmptyFolderDocumentRead, transaction)
            guard document.folders.contains(where: { $0.id == folderID }) else {
                return .notFound
            }
            guard !document.folders.contains(where: {
                $0.parentFolderID == folderID
            }) else {
                return .notEmpty
            }
            try mutationAction(.afterEmptyFolderChildInspection, transaction)
            let meetingURLs = try FileManager.default.contentsOfDirectory(
                at: layout.meetingsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for directory in meetingURLs {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }
                let metadata = directory.appendingPathComponent("meeting.json")
                guard FileManager.default.fileExists(atPath: metadata.path) else {
                    continue
                }
                let meeting = try JSONDocumentStore.read(
                    Meeting.self,
                    from: metadata,
                    currentSchemaVersion: Meeting.currentSchemaVersion,
                    schemaVersion: \.schemaVersion
                )
                if meeting.folderID == folderID {
                    return .notEmpty
                }
            }
            try mutationAction(
                .afterEmptyFolderMeetingInspectionBeforeDelete,
                transaction
            )
            document.folders.removeAll { $0.id == folderID }
            try write(document, transaction: transaction)
            return .deleted
        }
    }

    /// Setzt die Reihenfolge genau einer vollstaendig benannten
    /// Geschwistergruppe. Teilmengen und fremde Kennungen werden abgelehnt.
    public func reorderFolders(
        parentFolderID: FolderID?,
        order: [FolderID]
    ) throws {
        try mutateDocument { document in
            try Self.validateParent(parentFolderID, in: document.folders)
            let expected = Set(Self.siblings(
                parentFolderID: parentFolderID,
                in: document.folders
            ).map(\.id))
            guard order.count == expected.count, Set(order) == expected else {
                throw LibraryError.invalidFolderHierarchy(
                    "A reorder must contain every sibling exactly once."
                )
            }
            for (rank, folderID) in order.enumerated() {
                guard let index = document.folders.firstIndex(where: {
                    $0.id == folderID
                }) else { continue }
                document.folders[index].sortIndex = rank
            }
        }
    }

    /// Legt Ordner fuer die Namen an, die der Steno-Altimport mitgebracht hat,
    /// und liefert die Zuordnung Meeting zu Ordner zurueck. Der Aufrufer
    /// schreibt sie an die Meetings; hier passiert nichts an Meetings.
    ///
    /// Setzt das Einmal-Flag **nicht**. Das tut `markLegacyFoldersAdopted`,
    /// und zwar erst, wenn die Zuordnungen wirklich geschrieben sind: waere es
    /// hier gesetzt, wuerde ein Absturz dazwischen die Uebernahme fuer immer
    /// verbrennen, und die Meetings blieben ohne Ordner.
    ///
    /// Die angelegten Ordner bleiben in dem Fall stehen. Das ist harmlos - der
    /// naechste Lauf findet sie ueber den Namen wieder.
    public func adoptLegacyFolders(
        from meetings: [Meeting]
    ) throws -> [MeetingID: FolderID] {
        try mutateDocument { document in
            guard !document.adoptedLegacyFolders else { return [:] }

            let roots = document.folders.filter { $0.parentFolderID == nil }
            var byKey: [String: Folder] = Dictionary(
                uniqueKeysWithValues: roots.map {
                    (Self.comparisonKey($0.name), $0)
                }
            )
            var assignments: [MeetingID: FolderID] = [:]
            var nextIndex = (roots.map(\.sortIndex).max() ?? -1) + 1

            for meeting in meetings where meeting.folderID == nil {
                // Bei mehreren Alt-Ordnern gewinnt der erste. Die vollstaendige
                // Liste bleibt in `metadata.legacyFolders` erhalten, es geht also
                // nichts verloren.
                guard let raw = meeting.metadata?.legacyFolders.first,
                      let name = try? Self.normalizedName(raw)
                else { continue }
                let key = Self.comparisonKey(name)
                let folder: Folder
                if let existing = byKey[key] {
                    folder = existing
                } else {
                    folder = Folder(name: name, sortIndex: nextIndex)
                    nextIndex += 1
                    byKey[key] = folder
                    document.folders.append(folder)
                }
                assignments[meeting.id] = folder.id
            }

            return assignments
        }
    }

    /// Schliesst die Uebernahme ab. Ab hier laeuft sie nie wieder - wer ein
    /// importiertes Meeting bewusst aus seinem Ordner nimmt, findet es beim
    /// naechsten Start nicht wieder darin.
    public func markLegacyFoldersAdopted() throws {
        try mutateDocument { document in
            guard !document.adoptedLegacyFolders else { return }
            document.adoptedLegacyFolders = true
        }
    }

    private nonisolated func readDocument() throws -> FoldersDocument {
        guard FileManager.default.fileExists(atPath: layout.folders.path) else {
            return FoldersDocument(folders: [])
        }
        return try JSONDocumentStore.read(
            FoldersDocument.self,
            from: layout.folders,
            currentSchemaVersion: FoldersDocument.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
    }

    private func mutateDocument<Result>(
        _ body: (inout FoldersDocument) throws -> Result
    ) throws -> Result {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try mutationAction(
                .afterExclusiveTransactionBeforeMutationRead,
                transaction
            )
            var document = try readDocument(transaction: transaction)
            let original = document
            let result = try body(&document)
            if document != original {
                try write(document, transaction: transaction)
            }
            return result
        }
    }

    private nonisolated func readDocument(
        transaction: LibraryMutationTransaction
    ) throws -> FoldersDocument {
        try transaction.validate(layout: layout)
        return try readDocument()
    }

    private nonisolated func write(
        _ document: FoldersDocument,
        transaction: LibraryMutationTransaction
    ) throws {
        try transaction.validate(layout: layout)
        try JSONDocumentStore.write(document, to: layout.folders)
    }

    private static func normalizedName(_ name: String) throws -> String {
        let normalized = name
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { throw LibraryError.invalidFolderName }
        return normalized
    }

    private static func comparisonKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func validateUniqueName(
        _ name: String,
        parentFolderID: FolderID?,
        among folders: [Folder],
        excluding excludedID: FolderID? = nil
    ) throws {
        let key = comparisonKey(name)
        if folders.contains(where: {
            $0.id != excludedID
                && $0.parentFolderID == parentFolderID
                && comparisonKey($0.name) == key
        }) {
            throw LibraryError.duplicateFolderName(name)
        }
    }

    private static func validateParent(
        _ parentFolderID: FolderID?,
        in folders: [Folder]
    ) throws {
        guard let parentFolderID else { return }
        guard let parent = folders.first(where: { $0.id == parentFolderID }) else {
            throw LibraryError.invalidFolderParent(parentFolderID)
        }
        guard parent.parentFolderID == nil else {
            throw LibraryError.invalidFolderHierarchy(
                "A child folder cannot receive another child."
            )
        }
    }

    private static func siblings(
        parentFolderID: FolderID?,
        in folders: [Folder]
    ) -> [Folder] {
        folders.filter { $0.parentFolderID == parentFolderID }
    }

    private static func orderedSiblings(
        parentFolderID: FolderID?,
        in folders: [Folder]
    ) -> [Folder] {
        siblings(parentFolderID: parentFolderID, in: folders)
            .sorted(by: folderOrder)
    }

    private static func folderOrder(_ lhs: Folder, _ rhs: Folder) -> Bool {
        if lhs.sortIndex != rhs.sortIndex {
            return lhs.sortIndex < rhs.sortIndex
        }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id.description < rhs.id.description
    }

    private static func normalizeSiblings(
        parentFolderID: FolderID?,
        in folders: inout [Folder]
    ) {
        let orderedIDs = orderedSiblings(
            parentFolderID: parentFolderID,
            in: folders
        ).map(\.id)
        for (sortIndex, folderID) in orderedIDs.enumerated() {
            guard let index = folders.firstIndex(where: { $0.id == folderID }) else {
                continue
            }
            folders[index].sortIndex = sortIndex
        }
    }

    private static func isDescendant(
        _ candidateID: FolderID,
        of ancestorID: FolderID,
        in folders: [Folder]
    ) -> Bool {
        var currentID: FolderID? = candidateID
        var visited: Set<FolderID> = []
        while let folderID = currentID, visited.insert(folderID).inserted {
            if folderID == ancestorID { return true }
            currentID = folders.first(where: { $0.id == folderID })?
                .parentFolderID
        }
        return false
    }
}
