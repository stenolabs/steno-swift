import Darwin
import Foundation
import StenoDomain
import StenoLibrary
@testable import StenoDemo
import Testing

@Suite("Demo library seeder")
struct DemoLibrarySeederTests {
    @Test("installs exactly three bundled meetings and is a strict no-write on repeat and status")
    func installsIdempotently() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)

            #expect(try await seeder.status().items.allSatisfy { $0.state == .missing })
            try await seeder.install()
            let meetings = try await library.listMeetings()
            #expect(meetings.count == 3)
            #expect(Set(meetings.compactMap(\.folderID)).count == 1)
            #expect(try await folders.listFolders().filter { $0.name == "Demo Meetings" }.count == 1)
            #expect(meetings.allSatisfy { $0.isDemo })

            let jobs = try JobStore(layout: library.layout)
            let identities = try IdentityStore(layout: library.layout)
            #expect(try await jobs.list().isEmpty)
            #expect(try await identities.snapshot().persons.isEmpty)
            #expect(try meetings.allSatisfy { meeting in
                try FileManager.default.contentsOfDirectory(
                    at: library.layout.runsDirectory(meeting.id),
                    includingPropertiesForKeys: nil
                ).isEmpty
            })
            let noteFiles = try meetings.flatMap { meeting in
                try FileManager.default.contentsOfDirectory(
                    at: library.layout.notesDirectory(meeting.id),
                    includingPropertiesForKeys: nil
                ).map(\.lastPathComponent)
            }
            #expect(noteFiles.sorted() == ["legacy-user-notes.md", "legacy-user-notes.md"])
            let reportCount = try meetings.reduce(0) { count, meeting in
                count + (try FileManager.default.contentsOfDirectory(
                    at: library.layout.reportsDirectory(meeting.id),
                    includingPropertiesForKeys: nil
                ).count)
            }
            #expect(reportCount == 2)

            let installedSnapshot = try recursiveSnapshot(root)
            try await seeder.install()
            #expect(try recursiveSnapshot(root) == installedSnapshot)
            #expect(try await seeder.status().items.allSatisfy { $0.state == .installed })
            #expect(try recursiveSnapshot(root) == installedSnapshot)
        }
    }

    @Test("an interruption after the first meeting and index checkpoint resumes exactly two meetings")
    func resumesAfterOneCompleteCheckpoint() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let recorder = SeederCheckpointRecorder(interruptFirstMeetingOnce: true)
            let seeder = try DemoLibrarySeeder(
                library: library,
                folders: folders,
                checkpoint: recorder.call
            )

            do {
                try await seeder.install()
                Issue.record("Expected injected interruption")
            } catch is InjectedSeederInterruption {
                // Expected only after both the meeting and index are visible.
            }

            let firstMeetings = try await library.listMeetings()
            let first = try #require(firstMeetings.only)
            let firstSnapshot = try recursiveSnapshot(library.layout.meetingDirectory(first.id))
            let interruptedIndex = try readIndex(library.layout)
            #expect(interruptedIndex.items.map(\.meetingID) == [first.id])

            try await seeder.install()

            let allMeetings = try await library.listMeetings()
            #expect(allMeetings.count == 3)
            #expect(Set(recorder.meetingCheckpoints).count == 3)
            #expect(recorder.meetingCheckpoints.count == 3)
            #expect(try recursiveSnapshot(library.layout.meetingDirectory(first.id)) == firstSnapshot)
            let completeIndex = try readIndex(library.layout)
            #expect(completeIndex.items.count == 3)
            #expect(Set(completeIndex.items.map(\.meetingID)) == Set(allMeetings.map(\.id)))
            #expect(completeIndex.seederOwnedFolder != nil)
        }
    }

    @Test("a conflicting fixed ID fails typed before folder or index mutation")
    func detectsConflictBeforeMutation() async throws {
        try await withTemporaryDirectory { root in
            let manifest = try bundledManifest()
            let fixedID = manifest.meetings[0].id
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            try await commitOccupant(meetingID: fixedID, provenance: nil, through: library)
            let snapshot = try recursiveSnapshot(root)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)

            await expectDemoError(.conflictingMeeting(fixedID)) {
                try await seeder.install()
            }
            #expect(try recursiveSnapshot(root) == snapshot)
            #expect(!FileManager.default.fileExists(atPath: library.layout.demoInstallationIndex.path))
            #expect(try await folders.listFolders().allSatisfy { $0.name != "Demo Meetings" })
        }
    }

    @Test("a corrupt foreign occupant conflicts without quarantine or any root mutation")
    func corruptConflictIsReadOnly() async throws {
        try await withTemporaryDirectory { root in
            let manifest = try bundledManifest()
            let fixedID = manifest.meetings[0].id
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let meetingDirectory = library.layout.meetingDirectory(fixedID)
            try FileManager.default.createDirectory(
                at: meetingDirectory,
                withIntermediateDirectories: true
            )
            try Data("not a meeting document".utf8).write(
                to: library.layout.meetingMetadata(fixedID)
            )
            let before = try recursiveSnapshot(root)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)

            await expectDemoError(.conflictingMeeting(fixedID)) {
                try await seeder.install()
            }

            #expect(try recursiveSnapshot(root) == before)
            #expect(!FileManager.default.fileExists(atPath: library.layout.demoInstallationIndex.path))
            #expect(try await folders.listFolders().isEmpty)
        }
    }

    @Test(
        "a symlink at a fixed meeting ID is always a read-only conflict",
        arguments: FixedIDLinkOccupant.allCases
    )
    func fixedIDLinksConflictWithoutMutation(_ occupant: FixedIDLinkOccupant) async throws {
        try await withTemporaryDirectory { outerRoot in
            let targetRoot = outerRoot.appending(path: "target", directoryHint: .isDirectory)
            let externalRoot = outerRoot.appending(path: "external", directoryHint: .isDirectory)
            let targetLibrary = try Library.open(at: targetRoot)
            let targetFolders = try FolderStore.open(layout: targetLibrary.layout)
            let manifest = try bundledManifest()
            let fixedID = manifest.meetings[0].id
            let destination: URL
            switch occupant {
            case .dangling:
                destination = outerRoot.appending(path: "does-not-exist")
            case .matchingExternalTree:
                let externalLibrary = try Library.open(at: externalRoot)
                let externalFolders = try FolderStore.open(layout: externalLibrary.layout)
                try await DemoLibrarySeeder(
                    library: externalLibrary,
                    folders: externalFolders
                ).install()
                destination = externalLibrary.layout.meetingDirectory(fixedID)
            }
            try FileManager.default.createSymbolicLink(
                at: targetLibrary.layout.meetingDirectory(fixedID),
                withDestinationURL: destination
            )
            let before = try recursiveSnapshot(targetRoot)
            let seeder = try DemoLibrarySeeder(
                library: targetLibrary,
                folders: targetFolders
            )

            let item = try #require(try await seeder.status().items.first {
                $0.meetingID == fixedID
            })
            #expect(item.state == .conflictingMeeting)
            #expect(try recursiveSnapshot(targetRoot) == before)
            await expectDemoError(.conflictingMeeting(fixedID)) {
                try await seeder.install()
            }
            #expect(try recursiveSnapshot(targetRoot) == before)
            #expect(try await targetFolders.listFolders().isEmpty)
            #expect(!FileManager.default.fileExists(
                atPath: targetLibrary.layout.demoInstallationIndex.path
            ))
        }
    }

    @Test("schema-four baselines hash the raw tree and record installation generation")
    func persistsCompleteBaselineFingerprint() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let index = try readIndex(library.layout)
            let item = try #require(index.items.first)
            let claim = try #require(index.seederOwnedFolder)
            let folder = try #require(try await folders.folder(claim.folderID))

            #expect(index.schemaVersion == 4)
            #expect(index.items.allSatisfy { $0.installationGenerationID != nil })
            #expect(item.baseline.algorithm == DemoInstallationBaseline.sha256TreeV1)
            #expect(item.baseline.digest.count == 64)
            #expect(claim.createdAt == folder.createdAt)
            #expect(claim.expectedName == folder.name)
            #expect(claim.expectedParentFolderID == nil)
            let measured = try await library.withExclusiveMutationTransaction { _, transaction in
                try DemoInstalledItemFingerprint.compute(
                    meetingID: item.meetingID,
                    layout: library.layout,
                    transaction: transaction
                )
            }
            #expect(measured == item.baseline)

            let audioURL = library.layout.mediaFile(item.meetingID, fileName: "audio.wav")
            let audio = try Data(contentsOf: audioURL)
            var originalMetadata = stat()
            #expect(lstat(audioURL.path, &originalMetadata) == 0)
            try audio.write(to: audioURL, options: .atomic)
            #expect(chmod(audioURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: audioURL.path
            )
            var changedMetadata = stat()
            #expect(lstat(audioURL.path, &changedMetadata) == 0)
            #expect(originalMetadata.st_ino != changedMetadata.st_ino)
            let metadataIndependent = try await library.withExclusiveMutationTransaction {
                _, transaction in
                try DemoInstalledItemFingerprint.compute(
                    meetingID: item.meetingID,
                    layout: library.layout,
                    transaction: transaction
                )
            }
            #expect(metadataIndependent == item.baseline)

            _ = try await library.setMeetingFolder(item.meetingID, folderID: nil)
            let moved = try await library.withExclusiveMutationTransaction { _, transaction in
                try DemoInstalledItemFingerprint.compute(
                    meetingID: item.meetingID,
                    layout: library.layout,
                    transaction: transaction
                )
            }
            #expect(moved != item.baseline)
            let state = try #require(try await seeder.status().items.first {
                $0.meetingID == item.meetingID
            })
            #expect(state.state == .modified)
        }
    }

    @Test(
        "baseline fingerprint rejects symlinks and special files",
        arguments: ForeignTreeNode.allCases
    )
    func fingerprintRejectsForeignTreeNodes(_ node: ForeignTreeNode) async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let meetingID = try #require(try readIndex(library.layout).items.first?.meetingID)
            let foreignURL = library.layout.meetingDirectory(meetingID)
                .appending(path: "foreign-node")
            switch node {
            case .symbolicLink:
                try FileManager.default.createSymbolicLink(
                    at: foreignURL,
                    withDestinationURL: library.layout.meetingMetadata(meetingID)
                )
            case .namedPipe:
                guard mkfifo(foreignURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }

            do {
                _ = try await library.withExclusiveMutationTransaction { _, transaction in
                    try DemoInstalledItemFingerprint.compute(
                        meetingID: meetingID,
                        layout: library.layout,
                        transaction: transaction
                    )
                }
                Issue.record("Expected the foreign tree node to be rejected")
            } catch let error as DemoLibraryError {
                #expect(error == .commitOutcomeUncertain(meetingID))
            }
            let item = try #require(try await seeder.status().items.first {
                $0.meetingID == meetingID
            })
            #expect(item.state == .modified)
        }
    }

    @Test("baseline fingerprint rejects an injected path swap before descriptor open")
    func fingerprintRejectsInjectedPathSwap() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let meetingID = try #require(try readIndex(library.layout).items.first?.meetingID)
            let audioURL = library.layout.mediaFile(meetingID, fileName: "audio.wav")
            let externalURL = root.appending(path: "external-target")
            try Data("must never be hashed".utf8).write(to: externalURL)
            let swap = FingerprintPathSwap(
                relativePath: "media/audio.wav",
                sourceURL: audioURL,
                destinationURL: externalURL
            )

            do {
                _ = try await library.withExclusiveMutationTransaction { _, transaction in
                    try DemoInstalledItemFingerprint.compute(
                        meetingID: meetingID,
                        layout: library.layout,
                        transaction: transaction,
                        checkpoint: swap.call
                    )
                }
                Issue.record("Expected the descriptor identity mismatch to fail closed")
            } catch let error as DemoLibraryError {
                #expect(error == .commitOutcomeUncertain(meetingID))
            }
            #expect(swap.didSwap)
            #expect(try Data(contentsOf: externalURL) == Data("must never be hashed".utf8))
        }
    }

    @Test("the locked preflight preserves a real winner committed through another library handle")
    func closesPreflightRace() async throws {
        try await withBlockingTemporaryDirectory { root in
            let manifest = try bundledManifest()
            let fixedID = manifest.meetings[0].id
            let library = try Library.open(at: root)
            let winnerLibrary = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let reachedPreflight = AsyncStream.makeStream(of: Void.self)
            let pause = BlockingTestPause(name: "demo unlocked preflight")
            let seeder = try DemoLibrarySeeder(
                library: library,
                folders: folders,
                checkpoint: { checkpoint in
                    guard checkpoint == .afterUnlockedPreflight else { return }
                    reachedPreflight.continuation.yield()
                    pause.arriveAndWait()
                }
            )
            let installation = blockingTestTask { try await seeder.install() }
            defer { pause.release() }
            var events = reachedPreflight.stream.makeAsyncIterator()
            _ = await events.next()

            try await commitOccupant(meetingID: fixedID, provenance: nil, through: winnerLibrary)
            let winnerSnapshot = try recursiveSnapshot(root)
            pause.release()

            do {
                try await installation.value
                Issue.record("Expected the real winner to conflict")
            } catch let error as DemoLibraryError {
                #expect(error == .conflictingMeeting(fixedID))
            }
            #expect(try recursiveSnapshot(root) == winnerSnapshot)
            #expect(try await library.listMeetings().filter(\.isDemo).isEmpty)
            #expect(try await folders.listFolders().allSatisfy { $0.name != "Demo Meetings" })
            #expect(!FileManager.default.fileExists(atPath: library.layout.demoInstallationIndex.path))
        }
    }

    @Test("partial, empty, stale, and ownership-damaged indexes repair from provenance", arguments: IndexDamage.allCases)
    func repairsIndexFromProvenance(_ damage: IndexDamage) async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let meetingsBefore = try await library.listMeetings()
            let original = try readIndex(library.layout)
            let originalOwner = try #require(original.seederOwnedFolder)

            switch damage {
            case .partial:
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: [original.items[0]],
                    seederOwnedFolder: originalOwner
                ), layout: library.layout)
            case .empty:
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: [],
                    seederOwnedFolder: originalOwner
                ), layout: library.layout)
            case .staleItem:
                let stale = DemoInstallationIndexItem(
                    meetingID: original.items[0].meetingID,
                    itemID: original.items[0].itemID,
                    datasetVersion: original.items[0].datasetVersion,
                    installationGenerationID: original.items[0].installationGenerationID,
                    baselineRevisionID: RevisionID(),
                    baseline: original.items[0].baseline
                )
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: [stale] + Array(original.items.dropFirst()),
                    seederOwnedFolder: originalOwner
                ), layout: library.layout)
            case .wrongMeetingID:
                let stale = DemoInstallationIndexItem(
                    meetingID: MeetingID(),
                    itemID: original.items[0].itemID,
                    datasetVersion: original.items[0].datasetVersion,
                    installationGenerationID: original.items[0].installationGenerationID,
                    baselineRevisionID: original.items[0].baselineRevisionID,
                    baseline: original.items[0].baseline
                )
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: [stale] + Array(original.items.dropFirst()),
                    seederOwnedFolder: originalOwner
                ), layout: library.layout)
            case .wrongItemID:
                let stale = DemoInstallationIndexItem(
                    meetingID: original.items[0].meetingID,
                    itemID: "not-the-manifest-item",
                    datasetVersion: original.items[0].datasetVersion,
                    installationGenerationID: original.items[0].installationGenerationID,
                    baselineRevisionID: original.items[0].baselineRevisionID,
                    baseline: original.items[0].baseline
                )
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: [stale] + Array(original.items.dropFirst()),
                    seederOwnedFolder: originalOwner
                ), layout: library.layout)
            case .wrongDatasetVersion:
                let stale = DemoInstallationIndexItem(
                    meetingID: original.items[0].meetingID,
                    itemID: original.items[0].itemID,
                    datasetVersion: "other-version",
                    installationGenerationID: original.items[0].installationGenerationID,
                    baselineRevisionID: original.items[0].baselineRevisionID,
                    baseline: original.items[0].baseline
                )
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: [stale] + Array(original.items.dropFirst()),
                    seederOwnedFolder: originalOwner
                ), layout: library.layout)
            case .wrongBaselineAlgorithm:
                let stale = DemoInstallationIndexItem(
                    meetingID: original.items[0].meetingID,
                    itemID: original.items[0].itemID,
                    datasetVersion: original.items[0].datasetVersion,
                    installationGenerationID: original.items[0].installationGenerationID,
                    baselineRevisionID: original.items[0].baselineRevisionID,
                    baseline: DemoInstallationBaseline(
                        algorithm: "unknown-tree-format",
                        digest: original.items[0].baseline.digest
                    )
                )
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: [stale] + Array(original.items.dropFirst()),
                    seederOwnedFolder: originalOwner
                ), layout: library.layout)
            case .duplicateMeetingID:
                let duplicate = DemoInstallationIndexItem(
                    meetingID: original.items[0].meetingID,
                    itemID: original.items[1].itemID,
                    datasetVersion: original.items[1].datasetVersion,
                    installationGenerationID: original.items[1].installationGenerationID,
                    baselineRevisionID: original.items[1].baselineRevisionID,
                    baseline: original.items[1].baseline
                )
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: [original.items[0], duplicate, original.items[2]],
                    seederOwnedFolder: originalOwner
                ), layout: library.layout)
            case .duplicateItemID:
                let duplicate = DemoInstallationIndexItem(
                    meetingID: original.items[1].meetingID,
                    itemID: original.items[0].itemID,
                    datasetVersion: original.items[1].datasetVersion,
                    installationGenerationID: original.items[1].installationGenerationID,
                    baselineRevisionID: original.items[1].baselineRevisionID,
                    baseline: original.items[1].baseline
                )
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: [original.items[0], duplicate, original.items[2]],
                    seederOwnedFolder: originalOwner
                ), layout: library.layout)
            case .staleFolder:
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: original.items,
                    seederOwnedFolder: DemoOwnedFolderClaim(
                        folderID: FolderID(),
                        createdAt: originalOwner.createdAt,
                        expectedName: originalOwner.expectedName,
                        expectedParentFolderID: originalOwner.expectedParentFolderID
                    )
                ), layout: library.layout)
            case .tamperedFolderCreatedAt:
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: original.items,
                    seederOwnedFolder: DemoOwnedFolderClaim(
                        folderID: originalOwner.folderID,
                        createdAt: originalOwner.createdAt.addingTimeInterval(1),
                        expectedName: originalOwner.expectedName,
                        expectedParentFolderID: nil
                    )
                ), layout: library.layout)
            case .tamperedFolderName:
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: original.items,
                    seederOwnedFolder: DemoOwnedFolderClaim(
                        folderID: originalOwner.folderID,
                        createdAt: originalOwner.createdAt,
                        expectedName: "Other Name",
                        expectedParentFolderID: nil
                    )
                ), layout: library.layout)
            case .tamperedFolderParent:
                try writeIndex(DemoInstallationIndex(
                    datasetID: original.datasetID,
                    items: original.items,
                    seederOwnedFolder: DemoOwnedFolderClaim(
                        folderID: originalOwner.folderID,
                        createdAt: originalOwner.createdAt,
                        expectedName: originalOwner.expectedName,
                        expectedParentFolderID: FolderID()
                    )
                ), layout: library.layout)
            case .missingFile:
                try FileManager.default.removeItem(at: library.layout.demoInstallationIndex)
            case .missingOwnedFolder:
                _ = try await folders.deleteFolder(originalOwner.folderID)
            case .renamedOwnedFolder:
                _ = try await folders.renameFolder(originalOwner.folderID, to: "Renamed Demo Folder")
            case .movedOwnedFolder:
                let parent = try await folders.createFolder(name: "Parent")
                _ = try await folders.moveFolder(
                    originalOwner.folderID,
                    toParentFolderID: parent.id
                )
            }

            #expect(try await seeder.status().items.allSatisfy { $0.state == .installed })
            let repaired = try readIndex(library.layout)
            #expect(repaired.items.count == 3)
            #expect(Set(repaired.items.map(\.meetingID)).count == 3)
            #expect(Set(repaired.items.map(\.itemID)).count == 3)
            #expect(try await library.listMeetings() == meetingsBefore)
            let keepsIndependentFolderClaim: Bool = switch damage {
            case .partial, .empty, .staleItem, .wrongMeetingID, .wrongItemID,
                 .wrongDatasetVersion, .wrongBaselineAlgorithm:
                true
            case .duplicateMeetingID, .duplicateItemID, .staleFolder,
                 .tamperedFolderCreatedAt, .tamperedFolderName,
                 .tamperedFolderParent, .missingFile, .missingOwnedFolder,
                 .renamedOwnedFolder, .movedOwnedFolder:
                false
            }
            #expect(repaired.seederOwnedFolder == (
                keepsIndependentFolderClaim ? originalOwner : nil
            ))
        }
    }

    @Test("a well-formed mismatched baseline fails closed without cache repair")
    func mismatchedBaselineIsModifiedAndNotRepaired() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let original = try readIndex(library.layout)
            let stale = DemoInstallationIndexItem(
                meetingID: original.items[0].meetingID,
                itemID: original.items[0].itemID,
                datasetVersion: original.items[0].datasetVersion,
                installationGenerationID: original.items[0].installationGenerationID,
                baselineRevisionID: original.items[0].baselineRevisionID,
                baseline: DemoInstallationBaseline(
                    digest: String(repeating: "0", count: 64)
                )
            )
            try writeIndex(DemoInstallationIndex(
                datasetID: original.datasetID,
                items: [stale] + Array(original.items.dropFirst()),
                seederOwnedFolder: original.seederOwnedFolder
            ), layout: library.layout)
            let before = try Data(contentsOf: library.layout.demoInstallationIndex)

            let status = try await seeder.status()

            #expect(status.items.first { $0.meetingID == stale.meetingID }?.state == .modified)
            #expect(try Data(contentsOf: library.layout.demoInstallationIndex) == before)
        }
    }

    @Test(
        "cacheless provenance never blesses raw-changed meeting metadata",
        arguments: CachelessIndexDamage.allCases
    )
    func cachelessRawMeetingChangeIsModified(_ damage: CachelessIndexDamage) async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let meetingID = try #require(try readIndex(library.layout).items.first?.meetingID)
            let meetingURL = library.layout.meetingMetadata(meetingID)
            var document = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: meetingURL))
                    as? [String: Any]
            )
            document["unknown-future-field"] = "raw tree edit"
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                .write(to: meetingURL)

            func applyIndexDamage() throws {
                switch damage {
                case .missing:
                    try? FileManager.default.removeItem(at: library.layout.demoInstallationIndex)
                case .invalid:
                    try Data("invalid index".utf8).write(
                        to: library.layout.demoInstallationIndex
                    )
                }
            }
            try applyIndexDamage()
            let beforeStatus = try recursiveSnapshot(root)
            let item = try #require(try await seeder.status().items.first {
                $0.meetingID == meetingID
            })
            #expect(item.state == .modified)
            #expect(try recursiveSnapshot(root) == beforeStatus)

            try applyIndexDamage()
            let beforeInstall = try recursiveSnapshot(root)
            try await seeder.install()
            #expect(try recursiveSnapshot(root) == beforeInstall)
            let afterInstall = try #require(try await seeder.status().items.first {
                $0.meetingID == meetingID
            })
            #expect(afterInstall.state == .modified)
            #expect(try recursiveSnapshot(root) == beforeInstall)
        }
    }

    @Test("cacheless repair rejects a root swap after semantic validation")
    func cachelessRepairRejectsSemanticToFingerprintRootSwap() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let initialSeeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await initialSeeder.install()
            let meetingID = try #require(try readIndex(library.layout).items.first?.meetingID)
            try FileManager.default.removeItem(at: library.layout.demoInstallationIndex)
            let swap = SemanticToFingerprintRootSwap(
                meetingID: meetingID,
                meetingRoot: library.layout.meetingDirectory(meetingID),
                meetingMetadata: library.layout.meetingMetadata(meetingID),
                backupRoot: root.appending(path: "semantic-snapshot-backup")
            )
            let seeder = try DemoLibrarySeeder(
                library: library,
                folders: folders,
                checkpoint: swap.call
            )

            let item = try #require(try await seeder.status().items.first {
                $0.meetingID == meetingID
            })

            #expect(swap.didSwap)
            #expect(item.state == .modified)
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.demoInstallationIndex.path
            ))
        }
    }

    @Test(
        "later-item mutation never blesses an earlier validated tree",
        arguments: RepairBlessingRace.allCases
    )
    func repairNeverBlessesEarlierItemMutation(_ scenario: RepairBlessingRace) async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let initialSeeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await initialSeeder.install()
            let manifest = try bundledManifest()
            let earlierID = manifest.meetings[0].id
            let laterID = manifest.meetings[1].id
            let originalIndex = try readIndex(library.layout)
            let originalBaseline = try #require(originalIndex.items.first {
                $0.meetingID == earlierID
            }?.baseline)
            let damagedIndexData: Data?
            switch scenario.indexDamage {
            case .missing:
                try FileManager.default.removeItem(at: library.layout.demoInstallationIndex)
                damagedIndexData = nil
            case .invalid:
                let invalid = Data("invalid index".utf8)
                try invalid.write(to: library.layout.demoInstallationIndex)
                damagedIndexData = invalid
            case .valid:
                damagedIndexData = try Data(contentsOf: library.layout.demoInstallationIndex)
            }
            let mutation = EarlierValidatedItemMutation(
                earlierMeetingMetadata: library.layout.meetingMetadata(earlierID),
                laterMeetingID: laterID
            )
            let racingSeeder = try DemoLibrarySeeder(
                library: library,
                folders: folders,
                checkpoint: mutation.call
            )

            switch scenario.operation {
            case .status:
                _ = try await racingSeeder.status()
            case .install:
                try await racingSeeder.install()
            }

            #expect(mutation.didMutate)
            #expect(try optionalData(at: library.layout.demoInstallationIndex) == damagedIndexData)
            if let indexData = try optionalData(at: library.layout.demoInstallationIndex),
               let index = try? JSONDecoder().decode(
                DemoInstallationIndex.self,
                from: indexData
               ) {
                #expect(index.items.first {
                    $0.meetingID == earlierID
                }?.baseline == originalBaseline)
            }
            let subsequent = try #require(try await initialSeeder.status().items.first {
                $0.meetingID == earlierID
            })
            #expect(subsequent.state == .modified)
            #expect(try optionalData(at: library.layout.demoInstallationIndex) == damagedIndexData)
        }
    }

    @Test("a crash after visible commit before index checkpoint resumes safely")
    func resumesAfterVisibleCommitBeforeIndex() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let interruption = PreIndexInterruption()
            let seeder = try DemoLibrarySeeder(
                library: library,
                folders: folders,
                checkpoint: interruption.call
            )

            do {
                try await seeder.install()
                Issue.record("Expected pre-index interruption")
            } catch is InjectedSeederInterruption {
                // The meeting is durable, while the index does not exist yet.
            }
            let firstMeeting = try #require(try await library.listMeetings().only)
            let firstSnapshot = try recursiveSnapshot(
                library.layout.meetingDirectory(firstMeeting.id)
            )
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.demoInstallationIndex.path
            ))

            try await seeder.install()

            #expect(try await library.listMeetings().count == 3)
            #expect(try recursiveSnapshot(
                library.layout.meetingDirectory(firstMeeting.id)
            ) == firstSnapshot)
            #expect(try readIndex(library.layout).items.count == 3)
        }
    }

    @Test("install repairs a missing index when zero meetings are missing")
    func zeroMissingInstallRepairsIndex() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let installedMeetings = try await library.listMeetings()
            let meetingSnapshots = try Dictionary(uniqueKeysWithValues: installedMeetings.map {
                ($0.id, try recursiveSnapshot(library.layout.meetingDirectory($0.id)))
            })
            try FileManager.default.removeItem(at: library.layout.demoInstallationIndex)

            try await seeder.install()

            let firstRepair = try Data(contentsOf: library.layout.demoInstallationIndex)
            #expect(try readIndex(library.layout).items.count == 3)
            for (meetingID, snapshot) in meetingSnapshots {
                #expect(try recursiveSnapshot(library.layout.meetingDirectory(meetingID)) == snapshot)
            }
            try FileManager.default.removeItem(at: library.layout.demoInstallationIndex)
            try await seeder.install()
            #expect(try Data(contentsOf: library.layout.demoInstallationIndex) == firstRepair)
        }
    }

    @Test("an existing same-named user folder is atomically reused and never claimed")
    func reusesUserFolderWithoutOwnership() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let userFolder = try await folders.createFolder(name: "  demo meetings ")
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)

            try await seeder.install()

            let meetings = try await library.listMeetings()
            #expect(meetings.allSatisfy { $0.folderID == userFolder.id })
            #expect(try await folders.listFolders().filter {
                $0.name.caseInsensitiveCompare("Demo Meetings") == .orderedSame
            }.count == 1)
            #expect(try readIndex(library.layout).seederOwnedFolder == nil)
        }
    }

    @Test("installed content comes only from one-read verified snapshots after sources mutate")
    func installsVerifiedSnapshotsAfterSourceMutation() async throws {
        try await withTemporaryDemoDataset { datasetRoot, manifest in
            let manifestURL = datasetRoot.appending(path: "manifest.json")
            try JSONEncoder().encode(manifest).write(to: manifestURL)
            let original = try Dictionary(uniqueKeysWithValues: manifest.resources.map {
                ($0.id, try Data(contentsOf: datasetRoot.appending(path: $0.relativePath)))
            })
            let reader = DataReadRecorder()
            let libraryRoot = datasetRoot.appending(path: "Library", directoryHint: .isDirectory)
            let library = try Library.open(at: libraryRoot)
            let folders = try FolderStore.open(layout: library.layout)
            let bundle = DemoResourceBundle(rootURL: datasetRoot, dataReader: reader.read)
            let seeder = try DemoLibrarySeeder(
                library: library,
                folders: folders,
                resourceBundle: bundle,
                checkpoint: { checkpoint in
                    guard checkpoint == .afterUnlockedPreflight else { return }
                    for descriptor in manifest.resources where [
                        DemoResourceKind.audio, .transcript, .note, .report,
                    ].contains(descriptor.kind) {
                        try Data("mutated \(descriptor.id)".utf8).write(
                            to: datasetRoot.appending(path: descriptor.relativePath)
                        )
                    }
                }
            )

            try await seeder.install()

            #expect(reader.counts.count == manifest.resources.count + 1)
            #expect(reader.counts.values.allSatisfy { $0 == 1 })
            for meeting in manifest.meetings {
                #expect(try Data(contentsOf: library.layout.mediaFile(meeting.id, fileName: "audio.wav")) == original[meeting.audio.resourceID])
                let installedRevision = try await library.loadCurrentRevision(meetingID: meeting.id)
                let verifiedRevision = try JSONDecoder().decode(
                    TranscriptRevision.self,
                    from: try #require(original[meeting.transcript.resourceID])
                )
                #expect(installedRevision == verifiedRevision)
                for resourceID in meeting.runs.flatMap(\.resourceIDs) {
                    guard let descriptor = manifest.resources.first(where: { $0.id == resourceID }) else { continue }
                    switch descriptor.kind {
                    case .note:
                        #expect(try Data(contentsOf: library.layout.legacyUserNotes(meeting.id)) == original[resourceID])
                    case .report:
                        let runID = try #require(meeting.runs.first { $0.resourceIDs.contains(resourceID) }?.id)
                        let result = try JSONDecoder().decode(
                            TemplateResult.self,
                            from: Data(contentsOf: library.layout.report(meeting.id, runID: runID))
                        )
                        #expect(Data(result.markdown.utf8) == original[resourceID])
                    default:
                        break
                    }
                }
            }
        }
    }

    @Test("status rejects every changed or unexpected installed artifact", arguments: StatusCorruption.allCases)
    func statusDetectsInstalledArtifactCorruption(_ corruption: StatusCorruption) async throws {
        try await withTemporaryDirectory { root in
            let manifest = try bundledManifest()
            let meeting = try #require(manifest.meetings.first { $0.itemID == "projektauftakt" })
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()

            try await apply(corruption, meeting: meeting, library: library)

            let baseline = try #require(try readIndex(library.layout).items.first {
                $0.meetingID == meeting.id
            }).baseline
            let changedFingerprint = try await library.withExclusiveMutationTransaction {
                _, transaction in
                try DemoInstalledItemFingerprint.compute(
                    meetingID: meeting.id,
                    layout: library.layout,
                    transaction: transaction
                )
            }
            #expect(changedFingerprint != baseline)
            let item = try #require(try await seeder.status().items.first { $0.meetingID == meeting.id })
            #expect(item.state == .modified)
        }
    }

    @Test("plain install refuses another dataset version before filling missing items")
    func installRefusesOutdatedMeetingWithoutMutation() async throws {
        try await withTemporaryDirectory { root in
            let manifest = try bundledManifest()
            let meeting = manifest.meetings[0]
            let provenance = DemoProvenance(
                datasetID: manifest.datasetID,
                datasetVersion: "older-version",
                itemID: meeting.itemID
            )
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            try await commitOccupant(meetingID: meeting.id, provenance: provenance, through: library)
            let snapshot = try recursiveSnapshot(root)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)

            await expectDemoError(.outdatedMeeting(meeting.id, installedVersion: "older-version")) {
                try await seeder.install()
            }
            #expect(try recursiveSnapshot(root) == snapshot)
            #expect(try await library.listMeetings().count == 1)
            #expect(try await folders.listFolders().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: library.layout.demoInstallationIndex.path))
        }
    }

    @Test("replace installs missing items and removal trashes exactly indexed demo items")
    func replacementAndRemovalAreRecoverable() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)

            let replacement = try await seeder.replace(
                policy: .keepModifiedMeetings
            )
            #expect(replacement.completedItems.count == 3)
            #expect(replacement.remainingItems.isEmpty)
            #expect(try await library.listMeetings().allSatisfy {
                $0.processingGenerationID != nil
            })

            let removal = try await seeder.remove()
            #expect(removal.completedItems.count == 3)
            #expect(removal.remainingItems.isEmpty)
            #expect(try await library.listMeetings().isEmpty)
            #expect(try await folders.listFolders().isEmpty)
        }
    }

    @Test("keep preserves edited meetings byte-for-byte and explicit replace creates a new generation")
    func replacementPolicyProtectsEdits() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let meeting = try #require(try await library.listMeetings().first)
            let generationOne = try #require(meeting.processingGenerationID)
            _ = try await library.renameMeeting(meeting.id, to: "My edited demo")
            let editedSnapshot = try recursiveSnapshot(
                library.layout.meetingDirectory(meeting.id)
            )

            let kept = try await seeder.replace(policy: .keepModifiedMeetings)

            #expect(kept.retainedItems.contains {
                $0 == meeting.metadata?.demoProvenance?.itemID
            })
            #expect(try recursiveSnapshot(
                library.layout.meetingDirectory(meeting.id)
            ) == editedSnapshot)

            let replaced = try await seeder.replace(
                policy: .replaceModifiedMeetings
            )
            let generationTwo = try #require(
                try await library.loadMeeting(meeting.id).processingGenerationID
            )
            #expect(replaced.completedItems.contains {
                $0 == meeting.metadata?.demoProvenance?.itemID
            })
            #expect(generationTwo != generationOne)
            #expect(try await library.loadMeeting(meeting.id).title != "My edited demo")
        }
    }

    @Test("real v1 and v2 resources upgrade only proven-unmodified items")
    func versionedReplacementProtectsModifiedItems() async throws {
        try await withTemporaryDirectory { root in
            let v1 = try makeVersionedDemoBundle(
                at: root.appending(path: "v1"),
                datasetVersion: "v1",
                revisionOffset: 0
            )
            let v2 = try makeVersionedDemoBundle(
                at: root.appending(path: "v2"),
                datasetVersion: "v2",
                revisionOffset: 1_000
            )
            let library = try Library.open(at: root.appending(path: "Library"))
            let folders = try FolderStore.open(layout: library.layout)
            try await DemoLibrarySeeder(
                library: library,
                folders: folders,
                resourceBundle: v1.bundle
            ).install()
            let editedID = v1.manifest.meetings[0].id
            let originalGeneration = try #require(
                try await library.loadMeeting(editedID).processingGenerationID
            )
            _ = try await library.renameMeeting(editedID, to: "My v1 edit")
            let editedSnapshot = try recursiveSnapshot(
                library.layout.meetingDirectory(editedID)
            )

            let kept = try await DemoLibrarySeeder(
                library: library,
                folders: folders,
                resourceBundle: v2.bundle
            ).replace(policy: .keepModifiedMeetings)

            #expect(kept.completedItems.count == 2)
            #expect(kept.retainedItems == [v1.manifest.meetings[0].itemID])
            #expect(kept.remainingItems == kept.retainedItems)
            #expect(try recursiveSnapshot(
                library.layout.meetingDirectory(editedID)
            ) == editedSnapshot)
            for manifestMeeting in v2.manifest.meetings.dropFirst() {
                let upgraded = try await library.loadMeeting(manifestMeeting.id)
                #expect(upgraded.metadata?.demoProvenance?.datasetVersion == "v2")
                #expect(try await library.loadCurrentRevision(
                    meetingID: manifestMeeting.id
                ).id == manifestMeeting.transcript.id)
                #expect(upgraded.processingGenerationID != originalGeneration)
            }

            let replaced = try await DemoLibrarySeeder(
                library: library,
                folders: folders,
                resourceBundle: v2.bundle
            ).replace(policy: .replaceModifiedMeetings)
            let reset = try await library.loadMeeting(editedID)
            #expect(replaced.completedItems == [v1.manifest.meetings[0].itemID])
            #expect(reset.metadata?.demoProvenance?.datasetVersion == "v2")
            #expect(try await library.loadCurrentRevision(
                meetingID: editedID
            ).id == v2.manifest.meetings[0].transcript.id)
            #expect(reset.processingGenerationID != originalGeneration)
            #expect(reset.title == v2.manifest.meetings[0].title)
        }
    }

    @Test("version upgrade checkpoints one item and resumes without a third generation")
    func versionedReplacementResumesPerItem() async throws {
        try await withTemporaryDirectory { root in
            let v1 = try makeVersionedDemoBundle(
                at: root.appending(path: "v1"),
                datasetVersion: "v1",
                revisionOffset: 0
            )
            let v2 = try makeVersionedDemoBundle(
                at: root.appending(path: "v2"),
                datasetVersion: "v2",
                revisionOffset: 1_000
            )
            let library = try Library.open(at: root.appending(path: "Library"))
            let folders = try FolderStore.open(layout: library.layout)
            try await DemoLibrarySeeder(
                library: library,
                folders: folders,
                resourceBundle: v1.bundle
            ).install()
            let beforePlainInstall = try recursiveSnapshot(library.layout.root)
            let v2Seeder = try DemoLibrarySeeder(
                library: library,
                folders: folders,
                resourceBundle: v2.bundle
            )

            await expectDemoError(
                .outdatedMeeting(
                    v2.manifest.meetings[0].id,
                    installedVersion: "v1"
                )
            ) {
                try await v2Seeder.install()
            }
            #expect(try recursiveSnapshot(library.layout.root) == beforePlainInstall)

            let interruption = SeederCheckpointRecorder(interruptFirstMeetingOnce: true)
            let interruptedSeeder = try DemoLibrarySeeder(
                library: library,
                folders: folders,
                resourceBundle: v2.bundle,
                checkpoint: interruption.call
            )
            let partial = try await interruptedSeeder.replace(
                policy: .keepModifiedMeetings
            )
            #expect(partial.completedItems == [v2.manifest.meetings[0].itemID])
            #expect(partial.remainingItems.count == 2)
            let firstGeneration = try #require(
                try await library.loadMeeting(
                    v2.manifest.meetings[0].id
                ).processingGenerationID
            )

            let resumed = try await interruptedSeeder.replace(
                policy: .keepModifiedMeetings
            )
            #expect(resumed.skippedItems == [v2.manifest.meetings[0].itemID])
            #expect(resumed.completedItems.count == 2)
            #expect(resumed.remainingItems.isEmpty)
            #expect(try await library.loadMeeting(
                v2.manifest.meetings[0].id
            ).processingGenerationID == firstGeneration)
            let index = try readIndex(library.layout)
            #expect(index.items.count == 3)
            #expect(index.items.allSatisfy { $0.datasetVersion == "v2" })
            #expect(Set(index.items.compactMap(\.installationGenerationID)).count == 3)
        }
    }

    @Test("removal uses provenance and preserves real meetings and a nonempty demo folder")
    func removalPreservesRealMeetings() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let demoFolder = try #require(try await folders.listFolders().first {
                $0.name == "Demo Meetings"
            })
            let real = try await library.createMeeting(
                title: "DEMO: Real meeting",
                status: .ready
            )
            _ = try await library.setMeetingFolder(
                real.id,
                folderID: demoFolder.id
            )
            let renamedDemo = try #require(try await library.listMeetings().first {
                $0.isDemo
            })
            _ = try await library.renameMeeting(renamedDemo.id, to: "Renamed")

            let result = try await seeder.remove()

            #expect(result.completedItems.count == 3)
            #expect(try await library.listMeetings() == [
                try await library.loadMeeting(real.id)
            ])
            #expect(try await folders.folder(demoFolder.id) != nil)
        }
    }

    @Test(
        "removal derives meeting ownership from provenance when the index is unusable",
        arguments: RemovalIndexDamage.allCases
    )
    func removalDoesNotRequireAValidIndex(
        _ damage: RemovalIndexDamage
    ) async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let demoFolderID = try #require(
                try readIndex(library.layout).seederOwnedFolder?.folderID
            )
            try damage.apply(to: library.layout.demoInstallationIndex)

            let result = try await seeder.remove()

            #expect(result.completedItems.count == 3)
            #expect(result.retainedItems.isEmpty)
            #expect(result.uncertainItems.isEmpty)
            #expect(result.remainingItems.isEmpty)
            #expect(try await library.listMeetings().isEmpty)
            #expect(try await folders.folder(demoFolderID) != nil)
        }
    }

    @Test("replacement leaves a failed G1 job historical and recovery queues G2")
    func replacementGenerationIsRecoveredWithoutRevivingG1() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()
            let meeting = try #require(try await library.listMeetings().first)
            let generationOne = try #require(meeting.processingGenerationID)
            let jobStore = try JobStore(layout: library.layout)
            let stale = Job(
                kind: .finalASR,
                meetingID: meeting.id,
                importGenerationID: generationOne,
                status: .failed,
                errorMessage: "missing model"
            )
            try await jobStore.enqueue(stale)
            _ = try await library.renameMeeting(meeting.id, to: "Edited")

            _ = try await seeder.replace(policy: .replaceModifiedMeetings)
            let replacement = try await library.loadMeeting(meeting.id)
            let generationTwo = try #require(replacement.processingGenerationID)
            #expect(generationTwo != generationOne)
            _ = try await library.updateMeetingStatus(meeting.id, to: .recording)

            _ = try await RecoverySweep.run(
                library: library,
                jobStore: jobStore
            )

            let jobs = try await jobStore.list().filter {
                $0.meetingID == meeting.id && $0.kind == .finalASR
            }
            #expect(jobs.count == 2)
            #expect(jobs.first { $0.id == stale.id }?.status == .failed)
            #expect(jobs.contains {
                $0.id != stale.id
                    && $0.status == .queued
                    && $0.processingGenerationID == generationTwo
            })
        }
    }

    @Test("a thrown Trash move with a missing source is reported as uncertain")
    func removalReportsUncertainTrashOutcome() async throws {
        try await withTemporaryDirectory { root in
            let manifest = try bundledManifest()
            let target = manifest.meetings[1]
            let library = try Library.open(at: root) { checkpoint, _ in
                guard checkpoint == .afterMeetingTrashMove(target.id) else {
                    return
                }
                throw InjectedSeederInterruption.afterFirstMeeting
            }
            let folders = try FolderStore.open(layout: library.layout)
            let seeder = try DemoLibrarySeeder(library: library, folders: folders)
            try await seeder.install()

            let result = try await seeder.remove()

            #expect(result.completedItems.count == 1)
            #expect(result.uncertainItems == [target.itemID])
            #expect(result.remainingItems.contains(target.itemID))
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(target.id).path
            ))

            let resumed = try await seeder.remove()

            #expect(resumed.completedItems.count == 1)
            #expect(resumed.skippedItems.count == 2)
            #expect(resumed.uncertainItems.isEmpty)
            #expect(resumed.remainingItems.isEmpty)
            #expect(try await library.listMeetings().isEmpty)
        }
    }
}

enum RemovalIndexDamage: CaseIterable, Sendable {
    case missing
    case corrupt
    case schemaThree

    func apply(to indexURL: URL) throws {
        switch self {
        case .missing:
            try FileManager.default.removeItem(at: indexURL)
        case .corrupt:
            try Data("not an index".utf8).write(to: indexURL)
        case .schemaThree:
            let data = try Data(contentsOf: indexURL)
            var object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            object["schemaVersion"] = 3
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: indexURL)
        }
    }
}

private enum InjectedSeederInterruption: Error {
    case afterFirstMeeting
}

private final class SeederCheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldInterrupt: Bool
    private var storedMeetingCheckpoints: [MeetingID] = []

    init(interruptFirstMeetingOnce: Bool) {
        shouldInterrupt = interruptFirstMeetingOnce
    }

    var meetingCheckpoints: [MeetingID] {
        lock.withLock { storedMeetingCheckpoints }
    }

    func call(_ checkpoint: DemoLibrarySeederCheckpoint) throws {
        guard case .afterMeetingAndIndexCheckpoint(let meetingID) = checkpoint else { return }
        let interrupt = lock.withLock { () -> Bool in
            storedMeetingCheckpoints.append(meetingID)
            if shouldInterrupt {
                shouldInterrupt = false
                return true
            }
            return false
        }
        if interrupt { throw InjectedSeederInterruption.afterFirstMeeting }
    }
}

private final class PreIndexInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false

    func call(_ checkpoint: DemoLibrarySeederCheckpoint) throws {
        guard case .afterMeetingCommitBeforeIndex = checkpoint else { return }
        let shouldInterrupt = lock.withLock { () -> Bool in
            guard !interrupted else { return false }
            interrupted = true
            return true
        }
        if shouldInterrupt { throw InjectedSeederInterruption.afterFirstMeeting }
    }
}

private final class SemanticToFingerprintRootSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let meetingID: MeetingID
    private let meetingRoot: URL
    private let meetingMetadata: URL
    private let backupRoot: URL
    private var swapped = false

    init(
        meetingID: MeetingID,
        meetingRoot: URL,
        meetingMetadata: URL,
        backupRoot: URL
    ) {
        self.meetingID = meetingID
        self.meetingRoot = meetingRoot
        self.meetingMetadata = meetingMetadata
        self.backupRoot = backupRoot
    }

    var didSwap: Bool { lock.withLock { swapped } }

    func call(_ checkpoint: DemoLibrarySeederCheckpoint) throws {
        guard checkpoint == .afterSemanticValidationBeforeBaseline(meetingID) else { return }
        let shouldSwap = lock.withLock { () -> Bool in
            guard !swapped else { return false }
            swapped = true
            return true
        }
        guard shouldSwap else { return }
        try FileManager.default.moveItem(at: meetingRoot, to: backupRoot)
        try FileManager.default.copyItem(at: backupRoot, to: meetingRoot)
        var document = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: meetingMetadata))
                as? [String: Any]
        )
        document["unknown-future-field"] = "post-semantic root swap"
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: meetingMetadata)
    }
}

private final class EarlierValidatedItemMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let earlierMeetingMetadata: URL
    private let laterMeetingID: MeetingID
    private var mutated = false

    init(earlierMeetingMetadata: URL, laterMeetingID: MeetingID) {
        self.earlierMeetingMetadata = earlierMeetingMetadata
        self.laterMeetingID = laterMeetingID
    }

    var didMutate: Bool { lock.withLock { mutated } }

    func call(_ checkpoint: DemoLibrarySeederCheckpoint) throws {
        guard checkpoint == .afterSemanticValidationBeforeBaseline(laterMeetingID) else { return }
        let shouldMutate = lock.withLock { () -> Bool in
            guard !mutated else { return false }
            mutated = true
            return true
        }
        guard shouldMutate else { return }
        var document = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: earlierMeetingMetadata))
                as? [String: Any]
        )
        document["unknown-future-field"] = "later-item repair race"
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: earlierMeetingMetadata)
    }
}

private final class DataReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCounts: [String: Int] = [:]

    var counts: [String: Int] {
        lock.withLock { storedCounts }
    }

    func read(_ source: DemoResourceDataSource) throws -> Data {
        let url = source.url
        lock.withLock { storedCounts[url.path, default: 0] += 1 }
        return try source.read()
    }
}

private final class FingerprintPathSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let relativePath: String
    private let sourceURL: URL
    private let destinationURL: URL
    private var swapped = false

    init(relativePath: String, sourceURL: URL, destinationURL: URL) {
        self.relativePath = relativePath
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
    }

    var didSwap: Bool { lock.withLock { swapped } }

    func call(_ checkpoint: DemoInstalledItemFingerprintCheckpoint) throws {
        guard checkpoint == .afterEntryMetadata(relativePath: relativePath) else { return }
        let shouldSwap = lock.withLock { () -> Bool in
            guard !swapped else { return false }
            swapped = true
            return true
        }
        guard shouldSwap else { return }
        try FileManager.default.removeItem(at: sourceURL)
        try FileManager.default.createSymbolicLink(
            at: sourceURL,
            withDestinationURL: destinationURL
        )
    }
}

enum IndexDamage: CaseIterable, Sendable {
    case partial
    case empty
    case staleItem
    case wrongMeetingID
    case wrongItemID
    case wrongDatasetVersion
    case wrongBaselineAlgorithm
    case duplicateMeetingID
    case duplicateItemID
    case staleFolder
    case tamperedFolderCreatedAt
    case tamperedFolderName
    case tamperedFolderParent
    case missingFile
    case missingOwnedFolder
    case renamedOwnedFolder
    case movedOwnedFolder
}

enum StatusCorruption: CaseIterable, Sendable {
    case changedMeetingTitle
    case rawMeetingMetadataChange
    case missingAudio
    case changedAudio
    case missingMediaMetadata
    case wrongMediaID
    case wrongMediaKind
    case wrongMediaMeetingID
    case wrongMediaFileName
    case wrongMediaMetadata
    case wrongMediaProvenance
    case wrongCurrentRevision
    case wrongRevisionOrigin
    case missingNote
    case changedNote
    case extraNote
    case missingReport
    case changedReport
    case wrongReportRevision
    case extraReport
    case unexpectedRun
}

enum ForeignTreeNode: CaseIterable, Sendable {
    case symbolicLink
    case namedPipe
}

enum FixedIDLinkOccupant: CaseIterable, Sendable {
    case dangling
    case matchingExternalTree
}

enum CachelessIndexDamage: CaseIterable, Sendable {
    case missing
    case invalid
}

enum RepairBlessingRace: CaseIterable, Sendable {
    case missingIndexStatus
    case invalidIndexStatus
    case validIndexStatus
    case missingIndexInstall
    case invalidIndexInstall
    case validIndexInstall

    enum IndexDamage {
        case missing
        case invalid
        case valid
    }

    enum Operation {
        case status
        case install
    }

    var indexDamage: IndexDamage {
        switch self {
        case .missingIndexStatus, .missingIndexInstall: .missing
        case .invalidIndexStatus, .invalidIndexInstall: .invalid
        case .validIndexStatus, .validIndexInstall: .valid
        }
    }

    var operation: Operation {
        switch self {
        case .missingIndexStatus, .invalidIndexStatus, .validIndexStatus: .status
        case .missingIndexInstall, .invalidIndexInstall, .validIndexInstall: .install
        }
    }
}

private func apply(
    _ corruption: StatusCorruption,
    meeting: DemoMeetingManifest,
    library: Library
) async throws {
    let mediaURL = library.layout.mediaFile(meeting.id, fileName: "audio.wav")
    let metadataURL = library.layout.mediaMetadata(meeting.id, assetID: meeting.audio.mediaAssetID)
    let noteURL = library.layout.legacyUserNotes(meeting.id)
    let runID = try #require(meeting.runs.first?.id)
    let reportURL = library.layout.report(meeting.id, runID: runID)
    switch corruption {
    case .changedMeetingTitle:
        let meetingURL = library.layout.meetingMetadata(meeting.id)
        var persisted = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: meetingURL))
        persisted.title += " changed"
        try JSONEncoder().encode(persisted).write(to: meetingURL)
    case .rawMeetingMetadataChange:
        let meetingURL = library.layout.meetingMetadata(meeting.id)
        var document = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: meetingURL))
                as? [String: Any]
        )
        document["unknown-future-field"] = "raw tree edit"
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: meetingURL)
    case .missingAudio:
        try FileManager.default.removeItem(at: mediaURL)
    case .changedAudio:
        try Data("changed audio".utf8).write(to: mediaURL)
    case .missingMediaMetadata:
        try FileManager.default.removeItem(at: metadataURL)
    case .wrongMediaID, .wrongMediaKind, .wrongMediaMeetingID, .wrongMediaFileName,
         .wrongMediaMetadata, .wrongMediaProvenance:
        let current = try JSONDecoder().decode(MediaAsset.self, from: Data(contentsOf: metadataURL))
        let changed = MediaAsset(
            id: corruption == .wrongMediaID ? MediaAssetID() : current.id,
            meetingID: corruption == .wrongMediaMeetingID ? MeetingID() : current.meetingID,
            kind: corruption == .wrongMediaKind ? .micTrack : current.kind,
            sampleRate: corruption == .wrongMediaMetadata ? current.sampleRate + 1 : current.sampleRate,
            duration: current.duration,
            provenanceKey: corruption == .wrongMediaProvenance ? "not-demo" : current.provenanceKey,
            fileName: corruption == .wrongMediaFileName ? "different.wav" : current.fileName,
            conversion: current.conversion
        )
        try JSONEncoder().encode(changed).write(to: metadataURL)
    case .wrongCurrentRevision:
        let current = try await library.loadCurrentRevision(meetingID: meeting.id)
        _ = try await library.appendRevision(TranscriptRevision(
            meetingID: meeting.id,
            origin: .userEdit(current.id),
            turns: current.turns
        ))
    case .wrongRevisionOrigin:
        let current = try await library.loadCurrentRevision(meetingID: meeting.id)
        let changed = TranscriptRevision(
            id: current.id,
            meetingID: current.meetingID,
            createdAt: current.createdAt,
            origin: .legacyImport,
            turns: current.turns
        )
        try JSONEncoder().encode(changed).write(
            to: library.layout.revision(meeting.id, revisionID: current.id)
        )
    case .missingNote:
        try FileManager.default.removeItem(at: noteURL)
    case .changedNote:
        try Data("changed note".utf8).write(to: noteURL)
    case .extraNote:
        try Data("unexpected note".utf8).write(
            to: library.layout.notesDirectory(meeting.id).appending(path: "user-notes.md")
        )
    case .missingReport:
        try FileManager.default.removeItem(at: reportURL)
    case .changedReport:
        let result = try JSONDecoder().decode(TemplateResult.self, from: Data(contentsOf: reportURL))
        let changed = TemplateResult(
            markdown: result.markdown + " changed",
            template: result.template,
            engine: result.engine,
            revisionID: result.revisionID,
            createdAt: result.createdAt
        )
        try JSONEncoder().encode(changed).write(to: reportURL)
    case .wrongReportRevision:
        let result = try JSONDecoder().decode(TemplateResult.self, from: Data(contentsOf: reportURL))
        let changed = TemplateResult(
            markdown: result.markdown,
            template: result.template,
            engine: result.engine,
            revisionID: RevisionID(),
            createdAt: result.createdAt
        )
        try JSONEncoder().encode(changed).write(to: reportURL)
    case .extraReport:
        try Data("unexpected report".utf8).write(
            to: library.layout.reportsDirectory(meeting.id).appending(path: "unexpected.json")
        )
    case .unexpectedRun:
        try FileManager.default.createDirectory(
            at: library.layout.runsDirectory(meeting.id).appending(path: "unexpected"),
            withIntermediateDirectories: false
        )
    }
}

private func bundledManifest() throws -> DemoDatasetManifest {
    try DemoResourceBundle.bundled().loadVerifiedDataset().manifest
}

private func makeVersionedDemoBundle(
    at root: URL,
    datasetVersion: String,
    revisionOffset: Int
) throws -> (bundle: DemoResourceBundle, manifest: DemoDatasetManifest) {
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let unverified = makeDemoManifest(
        datasetVersion: datasetVersion,
        revisionOffset: revisionOffset
    )
    try writeTemporaryDemoResources(unverified, to: root)
    let manifest = try manifestWithResourceDigests(unverified, from: root)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(
        to: root.appending(path: "manifest.json")
    )
    return (DemoResourceBundle(rootURL: root), manifest)
}

private func commitOccupant(
    meetingID: MeetingID,
    provenance: DemoProvenance?,
    through library: Library
) async throws {
    let origin: TranscriptOrigin = provenance.map(TranscriptOrigin.demo) ?? .legacyImport
    let result = try await library.commitPreparedMeeting(PreparedMeetingImport(
        meeting: Meeting(
            id: meetingID,
            title: "Real winner",
            status: .ready,
            metadata: provenance.map { MeetingMetadata(demoProvenance: $0) }
        ),
        media: [],
        revision: TranscriptRevision(meetingID: meetingID, origin: origin, turns: [])
    ))
    #expect(result == .imported(meetingID))
}

private func expectDemoError(
    _ expected: DemoLibraryError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected), but the operation succeeded")
    } catch let error as DemoLibraryError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected \(expected), got \(error)")
    }
}

private func readIndex(_ layout: LibraryLayout) throws -> DemoInstallationIndex {
    try JSONDecoder().decode(
        DemoInstallationIndex.self,
        from: Data(contentsOf: layout.demoInstallationIndex)
    )
}

private func optionalData(at url: URL) throws -> Data? {
    do {
        return try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return nil
    }
}

private func writeIndex(_ index: DemoInstallationIndex, layout: LibraryLayout) throws {
    try JSONEncoder().encode(index).write(to: layout.demoInstallationIndex)
}

private enum SnapshotNodeType: UInt16, Equatable, Sendable {
    case directory = 1
    case regularFile = 2
    case symbolicLink = 3
    case other = 4
}

private struct SnapshotEntry: Equatable, Sendable {
    let type: SnapshotNodeType
    let bytes: Data?
    let inode: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
}

private func recursiveSnapshot(_ root: URL) throws -> [String: SnapshotEntry] {
    let paths = ["."] + (try FileManager.default.subpathsOfDirectory(atPath: root.path)).sorted()
    return try Dictionary(uniqueKeysWithValues: paths.map { relativePath in
        let url = relativePath == "." ? root : root.appending(path: relativePath)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let fileType = metadata.st_mode & S_IFMT
        let type: SnapshotNodeType
        let bytes: Data?
        switch fileType {
        case S_IFDIR:
            type = .directory
            bytes = nil
        case S_IFREG:
            type = .regularFile
            bytes = try Data(contentsOf: url)
        case S_IFLNK:
            type = .symbolicLink
            bytes = nil
        default:
            type = .other
            bytes = nil
        }
        return (relativePath, SnapshotEntry(
            type: type,
            bytes: bytes,
            inode: UInt64(metadata.st_ino),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        ))
    })
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
