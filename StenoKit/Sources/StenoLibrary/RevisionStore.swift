import Foundation
import StenoDomain

public struct CurrentRevisionPointer: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let currentRevisionID: RevisionID
    public let pendingCandidate: RevisionID?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        currentRevisionID: RevisionID,
        pendingCandidate: RevisionID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.currentRevisionID = currentRevisionID
        self.pendingCandidate = pendingCandidate
    }
}

struct RevisionAppendIntent: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let revision: TranscriptRevision
    let expectedPointer: RevisionPointerExpectation?
    let resultingPointer: CurrentRevisionPointer

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: TranscriptRevision,
        expectedCurrentPointer: CurrentRevisionPointer?,
        resultingPointer: CurrentRevisionPointer
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        expectedPointer = expectedCurrentPointer.map {
            .value($0)
        } ?? .missing
        self.resultingPointer = resultingPointer
    }
}

enum RevisionPointerExpectation: Codable, Equatable, Sendable {
    case missing
    case value(CurrentRevisionPointer)
}

enum RevisionAppendInterruption: Error {
    case afterRevisionWrite
}

public extension Library {
    func appendRevision(
        _ revision: TranscriptRevision
    ) throws -> CurrentRevisionPointer {
        try appendRevision(revision, interruptAfterRevisionWrite: false)
    }

    func appendRevision(
        _ revision: TranscriptRevision,
        interruptAfterRevisionWrite: Bool
    ) throws -> CurrentRevisionPointer {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            try appendRevisionWithoutMutationLock(
                revision,
                interruptAfterRevisionWrite: interruptAfterRevisionWrite,
                transaction: transaction
            )
        }
    }

    package nonisolated func appendRevision(
        _ revision: TranscriptRevision,
        transaction: LibraryMutationTransaction
    ) throws -> CurrentRevisionPointer {
        try transaction.validate(layout: layout)
        return try appendRevisionWithoutMutationLock(
            revision,
            interruptAfterRevisionWrite: false,
            transaction: transaction
        )
    }

    private nonisolated func appendRevisionWithoutMutationLock(
        _ revision: TranscriptRevision,
        interruptAfterRevisionWrite: Bool,
        transaction: LibraryMutationTransaction
    ) throws -> CurrentRevisionPointer {
        _ = try loadMeeting(revision.meetingID, transaction: transaction)
        let recoveredIntent = try RevisionAppendRecovery.recover(
            layout: layout,
            meetingID: revision.meetingID
        )
        if let recoveredIntent,
           recoveredIntent.revision.id == revision.id {
            guard recoveredIntent.revision == revision else {
                throw LibraryError.documentAlreadyExists(
                    layout.revision(revision.meetingID, revisionID: revision.id)
                )
            }
            return recoveredIntent.resultingPointer
        }
        let revisionURL = layout.revision(
            revision.meetingID,
            revisionID: revision.id
        )
        guard !FileManager.default.fileExists(atPath: revisionURL.path) else {
            throw LibraryError.documentAlreadyExists(revisionURL)
        }

        guard revision.schemaVersion == TranscriptRevision.currentSchemaVersion else {
            throw LibraryError.unsupportedSchemaVersion(
                document: revisionURL,
                found: revision.schemaVersion,
                supported: TranscriptRevision.currentSchemaVersion
            )
        }

        let existingPointer = try Self.loadCurrentRevisionPointerIfPresent(
            meetingID: revision.meetingID,
            layout: layout
        )
        if case .userEdit(let parentID) = revision.origin,
           existingPointer?.currentRevisionID != parentID {
            throw LibraryError.invalidRevisionParent(
                provided: parentID,
                current: existingPointer?.currentRevisionID
            )
        }
        let newPointer: CurrentRevisionPointer
        if let existingPointer {
            let current = try Self.loadRevision(
                existingPointer.currentRevisionID,
                meetingID: revision.meetingID,
                layout: layout
            )
            if case .userEdit = current.origin,
               case .finalRun = revision.origin {
                newPointer = CurrentRevisionPointer(
                    currentRevisionID: existingPointer.currentRevisionID,
                    pendingCandidate: revision.id
                )
            } else {
                newPointer = CurrentRevisionPointer(
                    currentRevisionID: revision.id,
                    pendingCandidate: existingPointer.pendingCandidate
                )
            }
        } else {
            newPointer = CurrentRevisionPointer(currentRevisionID: revision.id)
        }

        let intent = RevisionAppendIntent(
            revision: revision,
            expectedCurrentPointer: existingPointer,
            resultingPointer: newPointer
        )
        try JSONDocumentStore.write(
            intent,
            to: layout.revisionAppendIntent(revision.meetingID)
        )
        try JSONDocumentStore.write(revision, to: revisionURL)
        if interruptAfterRevisionWrite {
            throw RevisionAppendInterruption.afterRevisionWrite
        }

        try JSONDocumentStore.write(
            newPointer,
            to: layout.currentRevision(revision.meetingID)
        )
        try FileManager.default.removeItem(
            at: layout.revisionAppendIntent(revision.meetingID)
        )
        return newPointer
    }

    /// Nimmt den geparkten Neulauf als aktuellen Stand.
    ///
    /// Er entsteht, wenn nach einer Benutzerkorrektur neu transkribiert wird:
    /// Der Lauf darf die Korrektur nicht stillschweigend ueberschreiben und
    /// wartet deshalb als `pendingCandidate`. Ohne diesen Weg wartet er fuer
    /// immer, und niemand sieht das Ergebnis der eigenen Neu-Transkription.
    ///
    /// Verworfen wird nichts: die Korrektur bleibt als Revision liegen und ist
    /// ueber ihre Kennung weiter lesbar.
    @discardableResult
    func adoptPendingRevision(
        meetingID: MeetingID
    ) throws -> CurrentRevisionPointer? {
        try adoptPendingRevision(
            meetingID: meetingID,
            expectedCurrentRevisionID: nil,
            expectedCandidateID: nil
        )
    }

    /// Adopts only the candidate the caller inspected. This keeps an explicit
    /// UI action from adopting a different run that arrived in the meantime.
    func adoptPendingRevision(
        meetingID: MeetingID,
        expectedCandidateID: RevisionID?
    ) throws -> CurrentRevisionPointer? {
        try adoptPendingRevision(
            meetingID: meetingID,
            expectedCurrentRevisionID: nil,
            expectedCandidateID: expectedCandidateID
        )
    }

    /// Binds a window action to both revisions it displayed. A newer edit in
    /// another window therefore remains current until the user has seen it.
    func adoptPendingRevision(
        meetingID: MeetingID,
        expectedCurrentRevisionID: RevisionID?,
        expectedCandidateID: RevisionID?
    ) throws -> CurrentRevisionPointer? {
        try LibraryMutationCoordination.withExclusiveTransaction(layout: layout) { transaction in
            _ = try RevisionAppendRecovery.recover(
                layout: layout,
                meetingID: meetingID
            )
            let pointer = try loadCurrentRevisionPointer(
                meetingID: meetingID,
                transaction: transaction
            )
            guard expectedCurrentRevisionID.map({
                $0 == pointer.currentRevisionID
            }) ?? true else {
                return nil
            }
            guard let candidate = pointer.pendingCandidate else { return nil }
            guard expectedCandidateID.map({ $0 == candidate }) ?? true else {
                return nil
            }
            // Erst lesen, dann umstellen: zeigt der Zeiger auf eine Datei, die es
            // nicht gibt, bliebe das Meeting sonst ohne Transkript zurueck.
            _ = try loadRevision(
                candidate,
                meetingID: meetingID,
                transaction: transaction
            )
            let updated = CurrentRevisionPointer(currentRevisionID: candidate)
            try transaction.validate(layout: layout)
            try JSONDocumentStore.write(updated, to: layout.currentRevision(meetingID))
            return updated
        }
    }

    /// Der geparkte Neulauf, falls einer wartet.
    func pendingRevision(
        meetingID: MeetingID
    ) throws -> TranscriptRevision? {
        guard let pointer = try? loadCurrentRevisionPointer(meetingID: meetingID),
              let candidate = pointer.pendingCandidate
        else { return nil }
        return try? loadRevision(candidate, meetingID: meetingID)
    }

    func loadRevision(
        _ revisionID: RevisionID,
        meetingID: MeetingID
    ) throws -> TranscriptRevision {
        try Self.loadRevision(revisionID, meetingID: meetingID, layout: layout)
    }

    package nonisolated func loadRevision(
        _ revisionID: RevisionID,
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> TranscriptRevision {
        try transaction.validate(layout: layout)
        return try Self.loadRevision(
            revisionID,
            meetingID: meetingID,
            layout: layout
        )
    }

    private nonisolated static func loadRevision(
        _ revisionID: RevisionID,
        meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> TranscriptRevision {
        try JSONDocumentStore.read(
            TranscriptRevision.self,
            from: layout.revision(meetingID, revisionID: revisionID),
            currentSchemaVersion: TranscriptRevision.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
    }

    func loadCurrentRevisionPointer(
        meetingID: MeetingID
    ) throws -> CurrentRevisionPointer {
        guard let pointer = try Self.loadCurrentRevisionPointerIfPresent(
            meetingID: meetingID,
            layout: layout
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return pointer
    }

    func loadCurrentRevision(
        meetingID: MeetingID
    ) throws -> TranscriptRevision {
        let pointer = try loadCurrentRevisionPointer(meetingID: meetingID)
        return try loadRevision(
            pointer.currentRevisionID,
            meetingID: meetingID
        )
    }

    package nonisolated func loadCurrentRevision(
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> TranscriptRevision {
        try transaction.validate(layout: layout)
        guard let pointer = try Self.loadCurrentRevisionPointerIfPresent(
            meetingID: meetingID,
            layout: layout
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Self.loadRevision(
            pointer.currentRevisionID,
            meetingID: meetingID,
            layout: layout
        )
    }

    package nonisolated func loadCurrentRevisionPointer(
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> CurrentRevisionPointer {
        try transaction.validate(layout: layout)
        guard let pointer = try Self.loadCurrentRevisionPointerIfPresent(
            meetingID: meetingID,
            layout: layout
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return pointer
    }

    fileprivate nonisolated static func loadCurrentRevisionPointerIfPresent(
        meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> CurrentRevisionPointer? {
        let url = layout.currentRevision(meetingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDocumentStore.read(
            CurrentRevisionPointer.self,
            from: url,
            currentSchemaVersion: CurrentRevisionPointer.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
    }
}

enum RevisionAppendRecovery {
    static func recoverAll(layout: LibraryLayout) throws {
        let meetingDirectories = try FileManager.default.contentsOfDirectory(
            at: layout.meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in meetingDirectories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  let uuid = UUID(uuidString: directory.lastPathComponent) else {
                continue
            }
            _ = try recover(
                layout: layout,
                meetingID: MeetingID(rawValue: uuid)
            )
        }
    }

    @discardableResult
    static func recover(
        layout: LibraryLayout,
        meetingID: MeetingID
    ) throws -> RevisionAppendIntent? {
        let intentURL = layout.revisionAppendIntent(meetingID)
        guard FileManager.default.fileExists(atPath: intentURL.path) else { return nil }

        let intent = try JSONDocumentStore.read(
            RevisionAppendIntent.self,
            from: intentURL,
            currentSchemaVersion: RevisionAppendIntent.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
        let currentPointer = try Library.loadCurrentRevisionPointerIfPresent(
            meetingID: meetingID,
            layout: layout
        )
        let pointerAlreadyApplied = currentPointer == intent.resultingPointer
        let pointerStillExpected: Bool
        switch intent.expectedPointer {
        case .missing:
            pointerStillExpected = currentPointer == nil
        case .value(let expected):
            pointerStillExpected = currentPointer == expected
        case nil:
            // Alte Absichten enthalten keinen sicheren Vorzustand. Ihre
            // Revision bleibt unveraendert erhalten, aber sie darf keinen
            // inzwischen weitergesetzten Zeiger ueberstimmen.
            pointerStillExpected = false
        }
        guard pointerAlreadyApplied || pointerStillExpected else {
            try FileManager.default.removeItem(at: intentURL)
            return nil
        }
        let revisionURL = layout.revision(
            meetingID,
            revisionID: intent.revision.id
        )
        if FileManager.default.fileExists(atPath: revisionURL.path) {
            let existing = try JSONDocumentStore.read(
                TranscriptRevision.self,
                from: revisionURL,
                currentSchemaVersion: TranscriptRevision.currentSchemaVersion,
                schemaVersion: \.schemaVersion
            )
            guard existing == intent.revision else {
                throw LibraryError.documentAlreadyExists(revisionURL)
            }
        } else {
            try JSONDocumentStore.write(intent.revision, to: revisionURL)
        }

        if !pointerAlreadyApplied {
            try JSONDocumentStore.write(
                intent.resultingPointer,
                to: layout.currentRevision(meetingID)
            )
        }
        try FileManager.default.removeItem(at: intentURL)
        return intent
    }
}
