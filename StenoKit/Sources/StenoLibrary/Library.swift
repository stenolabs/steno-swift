import CryptoKit
import Foundation
import StenoDomain

public struct LibraryMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let libraryID: UUID
    public let createdAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        libraryID: UUID = UUIDv7Generator.shared.generate(),
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.libraryID = libraryID
        self.createdAt = createdAt
    }
}

public actor Library {
    public nonisolated let layout: LibraryLayout
    private let metadata: LibraryMetadata
    private var meetingChangeContinuations: [
        UUID: AsyncStream<MeetingID>.Continuation
    ] = [:]

    public static func open(at root: URL) throws -> Library {
        try Library(root: root)
    }

    private init(root: URL) throws {
        let layout = LibraryLayout(root: root)
        self.layout = layout

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let rootExists = fileManager.fileExists(
            atPath: layout.root.path,
            isDirectory: &isDirectory
        )

        if rootExists {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists)
            }
        } else {
            try fileManager.createDirectory(
                at: layout.root,
                withIntermediateDirectories: true
            )
        }

        if fileManager.fileExists(atPath: layout.libraryMetadata.path) {
            metadata = try JSONDocumentStore.read(
                LibraryMetadata.self,
                from: layout.libraryMetadata,
                currentSchemaVersion: LibraryMetadata.currentSchemaVersion,
                schemaVersion: \.schemaVersion
            )
        } else {
            let existingContents = try fileManager.contentsOfDirectory(
                at: layout.root,
                includingPropertiesForKeys: nil
            )
            guard existingContents.isEmpty else {
                throw LibraryError.missingLibraryMetadata(layout.libraryMetadata)
            }
            let newMetadata = LibraryMetadata()
            try JSONDocumentStore.write(newMetadata, to: layout.libraryMetadata)
            metadata = newMetadata
        }

        for directory in [
            layout.meetingsDirectory,
            layout.identityDirectory,
            layout.jobsDirectory,
            layout.exportsDirectory,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try RevisionAppendRecovery.recoverAll(layout: layout)
        }
    }

    public func libraryMetadata() -> LibraryMetadata {
        metadata
    }

    public func createMeeting(
        title: String,
        status: Meeting.Status,
        createdAt: Date = Date(),
        metadata: MeetingMetadata? = nil,
        sourceLocale: MeetingSourceLocale? = nil
    ) throws -> Meeting {
        let meeting = Meeting(
            title: title,
            createdAt: createdAt,
            status: status,
            metadata: metadata,
            sourceLocale: sourceLocale
        )
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try createMeetingDirectories(meeting.id)
            try JSONDocumentStore.write(meeting, to: layout.meetingMetadata(meeting.id))
        }
        return meeting
    }

    public func loadMeeting(_ meetingID: MeetingID) throws -> Meeting {
        try Self.loadMeeting(meetingID, layout: layout)
    }

    package nonisolated func loadMeeting(
        _ meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> Meeting {
        try transaction.validate(layout: layout)
        return try Self.loadMeeting(meetingID, layout: layout)
    }

    private nonisolated static func loadMeeting(
        _ meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> Meeting {
        let url = layout.meetingMetadata(meetingID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.meetingNotFound(meetingID)
        }
        return try JSONDocumentStore.read(
            Meeting.self,
            from: url,
            currentSchemaVersion: Meeting.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
    }

    public func listMeetings() throws -> [Meeting] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: layout.meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let meetings = try directories.compactMap { directory -> Meeting? in
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            let document = directory.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: document.path) else { return nil }
            return try JSONDocumentStore.read(
                Meeting.self,
                from: document,
                currentSchemaVersion: Meeting.currentSchemaVersion,
                schemaVersion: \.schemaVersion
            )
        }
        return meetings.sorted {
            if $0.createdAt == $1.createdAt { return $0.id > $1.id }
            return $0.createdAt > $1.createdAt
        }
    }

    /// Meldet persistierte Statusaenderungen als Invalidierungssignal.
    /// Konsumenten laden das Meeting danach erneut, statt einen moeglicherweise
    /// ueberholten Payload in ihren Anzeigezustand zu uebernehmen.
    public func meetingChanges() -> AsyncStream<MeetingID> {
        let token = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: MeetingID.self)
        meetingChangeContinuations[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeMeetingChangeContinuation(token) }
        }
        return stream
    }

    public func updateMeetingStatus(
        _ meetingID: MeetingID,
        to status: Meeting.Status
    ) throws -> Meeting {
        let result = try LibraryMutationCoordination.withExclusiveTransaction(
            layout: layout
        ) { transaction in
            let previous = try loadMeeting(meetingID, transaction: transaction)
            let meeting = try updateMeetingStatus(
                meetingID,
                to: status,
                transaction: transaction
            )
            return (meeting, previous.status != meeting.status)
        }
        if result.1 {
            publishMeetingChange(meetingID)
        }
        return result.0
    }

    package nonisolated func updateMeetingStatus(
        _ meetingID: MeetingID,
        to status: Meeting.Status,
        transaction: LibraryMutationTransaction
    ) throws -> Meeting {
        try transaction.validate(layout: layout)
        var meeting = try Self.loadMeeting(meetingID, layout: layout)
        guard meeting.status != status else { return meeting }
        meeting.status = status
        try JSONDocumentStore.write(meeting, to: layout.meetingMetadata(meetingID))
        return meeting
    }

    private func removeMeetingChangeContinuation(_ token: UUID) {
        meetingChangeContinuations.removeValue(forKey: token)
    }

    package func publishMeetingChange(_ meetingID: MeetingID) {
        for continuation in meetingChangeContinuations.values {
            continuation.yield(meetingID)
        }
    }

    /// Teilnehmerliste ist meeting-skopiert, nicht run-skopiert: Anwesenheit
    /// bleibt wahr, egal wie oft neu diarisiert wird (Alt-Invariante).
    public func updateMeetingParticipants(
        _ meetingID: MeetingID,
        participantIDs: [PersonID]
    ) throws -> Meeting {
        var meeting = try loadMeeting(meetingID)
        meeting.participantIDs = participantIDs
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try JSONDocumentStore.write(meeting, to: layout.meetingMetadata(meetingID))
        }
        return meeting
    }

    /// Vom Benutzer ergänzte Anwesende ohne Sprachbeleg. Personen, die bereits
    /// über einen bestätigten Redebeitrag als Teilnehmer geführt werden,
    /// werden hier nicht doppelt gehalten.
    @discardableResult
    public func updateAdditionalMeetingParticipants(
        _ meetingID: MeetingID,
        participantIDs: [PersonID]
    ) throws -> Meeting {
        var meeting = try loadMeeting(meetingID)
        var seen: Set<PersonID> = Set(meeting.participantIDs)
        meeting.additionalParticipantIDs = participantIDs.filter { seen.insert($0).inserted }
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try JSONDocumentStore.write(meeting, to: layout.meetingMetadata(meetingID))
        }
        return meeting
    }

    /// Legt das Meeting in einen Ordner oder nimmt es heraus (nil).
    /// Geprueft wird hier nichts: ob es den Ordner gibt, weiss der
    /// `FolderStore`, und eine ins Leere zeigende Kennung gilt ueberall wie
    /// "nicht einsortiert".
    @discardableResult
    public func setMeetingFolder(
        _ meetingID: MeetingID,
        folderID: FolderID?
    ) throws -> Meeting {
        guard let meeting = try setMeetingFolders(
            Set([meetingID]),
            folderID: folderID
        ).first else {
            throw LibraryError.meetingNotFound(meetingID)
        }
        return meeting
    }

    @discardableResult
    public func setMeetingFolders(
        _ meetingIDs: Set<MeetingID>,
        folderID: FolderID?
    ) throws -> [Meeting] {
        let originals = try meetingIDs.sorted().map(loadMeeting)
        return try Self.writeMeetingFolderBatch(
            originals: originals,
            folderID: folderID,
            write: { meeting in
                try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
                    try JSONDocumentStore.write(
                        meeting,
                        to: layout.meetingMetadata(meeting.id)
                    )
                }
            },
            restore: { meeting in
                try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
                    try JSONDocumentStore.write(
                        meeting,
                        to: layout.meetingMetadata(meeting.id)
                    )
                }
            }
        )
    }

    static func writeMeetingFolderBatch(
        originals: [Meeting],
        folderID: FolderID?,
        write: (Meeting) throws -> Void,
        restore: (Meeting) throws -> Void
    ) throws -> [Meeting] {
        let originals = originals.sorted { $0.id < $1.id }
        var updated: [Meeting] = []
        var writtenOriginals: [Meeting] = []
        do {
            for original in originals {
                var meeting = original
                meeting.folderID = folderID
                try write(meeting)
                updated.append(meeting)
                writtenOriginals.append(original)
            }
            return updated
        } catch {
            var restorationFailures: [MeetingID] = []
            for original in writtenOriginals.reversed() {
                do {
                    try restore(original)
                } catch {
                    restorationFailures.append(original.id)
                }
            }
            throw MeetingFolderBatchError(
                reason: String(describing: error),
                restorationFailures: restorationFailures
            )
        }
    }

    public func renameMeeting(
        _ meetingID: MeetingID,
        to title: String
    ) throws -> Meeting {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.invalidMeetingTitle }
        let old = try loadMeeting(meetingID)
        let renamed = Meeting(
            schemaVersion: old.schemaVersion,
            id: old.id,
            title: trimmed,
            createdAt: old.createdAt,
            status: old.status,
            participantIDs: old.participantIDs,
            additionalParticipantIDs: old.additionalParticipantIDs,
            folderID: old.folderID,
            metadata: old.metadata,
            sourceLocale: old.sourceLocale
        )
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try JSONDocumentStore.write(renamed, to: layout.meetingMetadata(meetingID))
        }
        return renamed
    }

    /// Verschiebt den kompletten Meeting-Ordner in den Papierkorb statt hart
    /// zu löschen: Originale sind besonders geschützt, ein Fehlgriff bleibt
    /// über den Papierkorb wiederherstellbar. Liefert den Papierkorb-Ort.
    @discardableResult
    public func trashMeeting(_ meetingID: MeetingID) throws -> URL? {
        let directory = layout.meetingDirectory(meetingID)
        var trashedURL: NSURL?
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw LibraryError.meetingNotFound(meetingID)
            }
            try FileManager.default.trashItem(at: directory, resultingItemURL: &trashedURL)
        }
        return trashedURL as URL?
    }

    public func setMeetingParticipants(
        _ meetingID: MeetingID,
        participantIDs: [PersonID]
    ) throws -> Meeting {
        var meeting = try loadMeeting(meetingID)
        var seen: Set<PersonID> = []
        meeting.participantIDs = participantIDs.filter { seen.insert($0).inserted }
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try JSONDocumentStore.write(meeting, to: layout.meetingMetadata(meetingID))
        }
        return meeting
    }

    public func registerMediaAsset(
        for meetingID: MeetingID,
        sourceURL: URL,
        kind: MediaAsset.Kind,
        sampleRate: Double,
        duration: TimeInterval
    ) throws -> MediaAsset {
        _ = try loadMeeting(meetingID)

        let provenanceKey: String
        if kind == .imported {
            provenanceKey = try sha256(of: sourceURL)
        } else {
            provenanceKey = "\(meetingID)/\(kind.rawValue)"
        }

        if let duplicate = try findMediaAsset(provenanceKey: provenanceKey) {
            throw LibraryError.duplicateProvenance(
                key: provenanceKey,
                existingMeetingID: duplicate.meetingID
            )
        }

        let assetID = MediaAssetID()
        let pathExtension = sourceURL.pathExtension.isEmpty
            ? (kind == .imported ? "bin" : "caf")
            : sourceURL.pathExtension.lowercased()
        let fileName = "\(assetID).\(pathExtension)"
        let asset = MediaAsset(
            id: assetID,
            meetingID: meetingID,
            kind: kind,
            sampleRate: sampleRate,
            duration: duration,
            provenanceKey: provenanceKey,
            fileName: fileName
        )
        let destination = layout.mediaFile(meetingID, fileName: fileName)
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            do {
                try JSONDocumentStore.write(
                    asset,
                    to: layout.mediaMetadata(meetingID, assetID: assetID)
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        return asset
    }

    public func loadMediaAsset(
        _ assetID: MediaAssetID,
        meetingID: MeetingID
    ) throws -> MediaAsset {
        let url = layout.mediaMetadata(meetingID, assetID: assetID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.mediaAssetNotFound(assetID, meetingID: meetingID)
        }
        return try JSONDocumentStore.read(
            MediaAsset.self,
            from: url,
            currentSchemaVersion: MediaAsset.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
    }

    public func listMediaAssets(
        meetingID: MeetingID
    ) throws -> [MediaAsset] {
        try Self.listMediaAssets(meetingID: meetingID, layout: layout)
    }

    package nonisolated func listMediaAssets(
        meetingID: MeetingID,
        transaction: LibraryMutationTransaction
    ) throws -> [MediaAsset] {
        try transaction.validate(layout: layout)
        return try Self.listMediaAssets(meetingID: meetingID, layout: layout)
    }

    private nonisolated static func listMediaAssets(
        meetingID: MeetingID,
        layout: LibraryLayout
    ) throws -> [MediaAsset] {
        _ = try loadMeeting(meetingID, layout: layout)
        let documents = try FileManager.default.contentsOfDirectory(
            at: layout.mediaDirectory(meetingID),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try documents
            .filter { $0.pathExtension == "json" }
            .map {
                try JSONDocumentStore.read(
                    MediaAsset.self,
                    from: $0,
                    currentSchemaVersion: MediaAsset.currentSchemaVersion,
                    schemaVersion: \.schemaVersion
                )
            }
            .sorted {
                if $0.kind == $1.kind { return $0.id < $1.id }
                return $0.kind.rawValue < $1.kind.rawValue
            }
    }

    private func createMeetingDirectories(_ meetingID: MeetingID) throws {
        for directory in [
            layout.meetingDirectory(meetingID),
            layout.mediaDirectory(meetingID),
            layout.runsDirectory(meetingID),
            layout.revisionsDirectory(meetingID),
            layout.notesDirectory(meetingID),
            layout.reportsDirectory(meetingID),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private func findMediaAsset(provenanceKey: String) throws -> MediaAsset? {
        let meetings = try listMeetings()
        for meeting in meetings {
            let documents = try FileManager.default.contentsOfDirectory(
                at: layout.mediaDirectory(meeting.id),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for document in documents
            where document.pathExtension == "json" {
                let asset = try JSONDocumentStore.read(
                    MediaAsset.self,
                    from: document,
                    currentSchemaVersion: MediaAsset.currentSchemaVersion,
                    schemaVersion: \.schemaVersion
                )
                if asset.provenanceKey == provenanceKey { return asset }
            }
        }
        return nil
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
