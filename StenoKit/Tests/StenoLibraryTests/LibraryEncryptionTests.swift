import CryptoKit
import Foundation
import Testing
@testable import StenoLibrary

/// Key store that never touches the login keychain, so tests stay
/// hermetic and parallel-safe.
final class InMemoryKEKStore: KEKStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func storeKEK(_ kek: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        data = kek
    }

    func loadKEK() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func deleteKEK() throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
    }
}
/// Sendable progress sink; the coordinator invokes the callback from
/// arbitrary task contexts.
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EncryptionProgress] = []

    func record(_ value: EncryptionProgress) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [EncryptionProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite("LibraryEncryption")
struct LibraryEncryptionTests {
    /// Builds a fixture library covering every on-disk store family the
    /// coordinator must handle: library metadata, meeting metadata,
    /// transcript revisions, user notes, media CAF bytes, jobs, persons,
    /// and folders. Returns relativePath -> expected plaintext.
    @discardableResult
    private func makeFixtureLibrary(at root: URL) throws -> [String: Data] {
        let fileManager = FileManager.default
        var contents: [String: Data] = [:]

        let files: [String: Data] = [
            "library.json": Data(#"{"schemaVersion":1,"createdAt":"2026-08-26"}"#.utf8),
            "meetings/01JABCDEF/meeting.json": Data(
                #"{"id":"01JABCDEF","title":"Weekly sync","status":"ready"}"#.utf8
            ),
            "meetings/01JABCDEF/transcript/revisions/01RREV001.json": Data(
                #"{"revisionID":"01RREV001","words":[{"text":"hello","start":0}]}"#.utf8
            ),
            "meetings/01JABCDEF/transcript/revisions/01RREV002.json": Data(
                #"{"revisionID":"01RREV002","words":[{"text":"final","start":0}]}"#.utf8
            ),
            "meetings/01JABCDEF/notes/user-notes.md": Data("# Decisions\n\n- ship it\n".utf8),
            // Media asset: binary CAF-like bytes with high entropy.
            "meetings/01JABCDEF/media/01MASSET1.caf": CryptoBox.generateKeyData(byteCount: 65_536 + 3),
            "jobs/01JJOB0001.json": Data(#"{"jobID":"01JJOB0001","kind":"finalASR"}"#.utf8),
            "identity/persons.json": Data(
                #"{"persons":[{"personID":"01PPERSON1","name":"Ada"}]}"#.utf8
            ),
            "folders.json": Data(#"{"folders":[{"folderID":"01FFOLDER1","name":"Work"}]}"#.utf8),
        ]
        for (relativePath, data) in files {
            let destination = root.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AtomicFile.write(data, to: destination)
            contents[relativePath] = data
        }

        // A hidden dotfile must be ignored by the copy, not encrypted.
        try AtomicFile.write(Data("noise".utf8), to: root.appendingPathComponent(".DS_Store"))
        return contents
    }

    private func makeCoordinator(
        root: URL,
        keyStore: KEKStoring = InMemoryKEKStore()
    ) -> LibraryEncryptionCoordinator {
        LibraryEncryptionCoordinator(
            layout: LibraryLayout(root: root),
            keyStore: keyStore
        )
    }

    // MARK: Round trip

    @Test("enable round-trips every store type byte-exactly")
    func encryptionRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let expected = try makeFixtureLibrary(at: root)
            let keyStore = InMemoryKEKStore()
            let coordinator = makeCoordinator(root: root, keyStore: keyStore)
            // prepareEncryption generates and stores the KEK on first use.
            #expect(try keyStore.loadKEK() == nil)
            let staged = try await coordinator.prepareEncryption()
            #expect(staged.operation == .encryption)
            #expect(staged.fileCount == expected.count)
            let code = try #require(staged.recoveryCode)

            try await coordinator.activateStaged()

            let status = await coordinator.status()
            #expect(status.isEncrypted)
            #expect(status.pendingOperation == nil)


            let effectiveKEK = try #require(try keyStore.loadKEK())
            #expect(effectiveKEK.count == 32)
            for (relativePath, plaintext) in expected {
                let framed = try Data(contentsOf: root.appendingPathComponent(relativePath))
                let decrypted = try CryptoBox.decrypt(framed, keyEncryptionKey: effectiveKEK)
                #expect(CryptoBox.isEncryptedFile(framed) && decrypted == plaintext)
            }
            // The header travels with the activated library.
            let header = try #require(
                await LibraryEncryptionHeader.loadIfPresent(root: root)
            )
            #expect(header.schemaVersion == LibraryEncryptionHeader.currentSchemaVersion)
            #expect(header.encryptedFileCount == expected.count)

            // The recovery code from the staged copy unwraps this header's
            // backup blob to exactly the active KEK.
            #expect(try header.unwrapKEK(using: code) == effectiveKEK)

            // No plaintext residue anywhere in the active tree.
            let entries = try #require(FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ))
            let allObjects = try #require(entries.allObjects)
            for case let url as URL in allObjects
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                let framed = try Data(contentsOf: url)
                let isAllowedPlain =
                    url.lastPathComponent == LibraryEncryptionLocation.headerFileName
                #expect(isAllowedPlain || CryptoBox.isEncryptedFile(framed))
            }
        }
    }

    @Test("progress reports transferring then verifying over all files")
    func progressPhases() async throws {
        try await withTemporaryDirectory { root in
            try makeFixtureLibrary(at: root)
            let coordinator = makeCoordinator(root: root)
            let updates = ProgressCollector()
            _ = try await coordinator.prepareEncryption { updates.record($0) }
            let phases = updates.snapshot().map(\.phase)
            #expect(phases.contains(.transferring))
            #expect(phases.contains(.verifying))
            if let firstVerify = phases.firstIndex(of: .verifying) {
                #expect(!phases[firstVerify...].contains(.transferring))
            }
            #expect(updates.snapshot().allSatisfy { $0.totalFiles == 9 })
        }
    }

    // MARK: Crash-phase safety

    @Test("crash before activation leaves the original library intact")
    func crashBeforeActivation() async throws {
        try await withTemporaryDirectory { root in
            let expected = try makeFixtureLibrary(at: root)
            let coordinator = makeCoordinator(root: root)

            _ = try await coordinator.prepareEncryption()

            // Simulated crash phase: staging exists, nothing switched.
            let status = await coordinator.status()
            #expect(status.isEncrypted == false)
            #expect(status.pendingOperation == .encryption)

            // Original bytes are still plain and untouched.
            for (relativePath, plaintext) in expected {
                #expect(
                    try Data(contentsOf: root.appendingPathComponent(relativePath)) == plaintext
                )
            }

            await coordinator.cancel()
            let afterCancel = await coordinator.status()
            #expect(afterCancel.pendingOperation == nil)
            for (relativePath, plaintext) in expected {
                #expect(
                    try Data(contentsOf: root.appendingPathComponent(relativePath)) == plaintext
                )
            }
        }
    }

    @Test("interrupted activation switch restores the backup deterministically")
    func interruptedSwitchRecovery() async throws {
        try await withTemporaryDirectory { root in
            try makeFixtureLibrary(at: root)

            // Simulate a crash between rename(root -> backup) and
            // rename(staging -> root): root missing, complete backup present.
            let backup = LibraryEncryptionLocation.backupURL(root: root, operation: .encryption)
            try FileManager.default.moveItem(at: root, to: backup)

            #expect(LibraryEncryptionCoordinator.recoverInterruptedSwitch(root: root))
            #expect(FileManager.default.fileExists(atPath: backup.path) == false)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))

            // A healthy root is never touched by recovery.
            #expect(LibraryEncryptionCoordinator.recoverInterruptedSwitch(root: root) == false)
        }
    }

    // MARK: Disable

    @Test("disable decrypts back to byte-identical plaintext")
    func disableRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let expected = try makeFixtureLibrary(at: root)
            let coordinator = makeCoordinator(root: root)

            _ = try await coordinator.prepareEncryption()
            try await coordinator.activateStaged()

            let staged = try await coordinator.prepareDecryption()
            #expect(staged.operation == .decryption)
            #expect(staged.recoveryCode == nil)
            try await coordinator.activateStaged()

            let status = await coordinator.status()
            #expect(status.isEncrypted == false)

            for (relativePath, plaintext) in expected {
                #expect(
                    try Data(contentsOf: root.appendingPathComponent(relativePath)) == plaintext
                )
            }
            #expect(try LibraryEncryptionHeader.loadIfPresent(root: root) == nil)

            // The encrypted past survives only in the explicit backup.
            #expect(FileManager.default.fileExists(
                atPath: LibraryEncryptionLocation.backupURL(root: root, operation: .decryption).path
            ))
            try await coordinator.deleteBackup(.decryption)
            // The enable-direction backup (.plain.bak) is unrelated and
            // legitimately still present; only the decryption backup must
            // be gone.
            #expect(FileManager.default.fileExists(
                atPath: LibraryEncryptionLocation.backupURL(root: root, operation: .decryption).path
            ) == false)
        }
    }

    // MARK: Recovery path

    @Test("lost Keychain entry recovers through the recovery code alone")
    func recoveryUnwrapAfterKeyLoss() async throws {
        try await withTemporaryDirectory { root in
            try makeFixtureLibrary(at: root)
            let keyStore = InMemoryKEKStore()
            let coordinator = makeCoordinator(root: root, keyStore: keyStore)

            let staged = try await coordinator.prepareEncryption()
            let code = try #require(staged.recoveryCode)
            try await coordinator.activateStaged()

            // Lose the Keychain entry entirely.
            try keyStore.deleteKEK()

            // Disabling now refuses instead of half-decrypting...
            do {
                _ = try await coordinator.prepareDecryption()
                Issue.record("prepareDecryption should require the KEK")
            } catch {}

            // ...and a well-formed wrong code fails cleanly without writes.
            let wrongCode = RecoveryCode.generate()
            await #expect(throws: LibraryEncryptionError.recoveryCodeWrong) {
                try await coordinator.decryptWithRecoveryCode(wrongCode)
            }

            // The real code reinstates the KEK; decryption then works.
            try await coordinator.decryptWithRecoveryCode(code)
            #expect(try keyStore.loadKEK() != nil)
            _ = try await coordinator.prepareDecryption()
            try await coordinator.activateStaged()

            let status = await coordinator.status()
            #expect(status.isEncrypted == false)
        }
    }

    @Test("wrong recovery code never modifies header or library")
    func wrongCodeLeavesNoTrace() async throws {
        try await withTemporaryDirectory { root in
            try makeFixtureLibrary(at: root)
            let coordinator = makeCoordinator(root: root)
            _ = try await coordinator.prepareEncryption()
            try await coordinator.activateStaged()

            let headerBefore = try LibraryEncryptionHeader.rawData(root: root)
            let snapshotBefore = try snapshot(root: root)

            await #expect(throws: LibraryEncryptionError.recoveryCodeWrong) {
                try await coordinator.decryptWithRecoveryCode(RecoveryCode.generate())
            }

            #expect(try LibraryEncryptionHeader.rawData(root: root) == headerBefore)
            #expect(try snapshot(root: root) == snapshotBefore)
        }
    }

    @Test("malformed codes are rejected before touching anything")
    func malformedCodeRejected() async throws {
        try await withTemporaryDirectory { root in
            try makeFixtureLibrary(at: root)
            let coordinator = makeCoordinator(root: root)
            _ = try await coordinator.prepareEncryption()
            try await coordinator.activateStaged()

            let headerBefore = try LibraryEncryptionHeader.rawData(root: root)
            #expect(throws: RecoveryCode.CodeError.invalidLength(characterCount: 4)) {
                _ = try RecoveryCode("STEN")
            }
            #expect(try LibraryEncryptionHeader.rawData(root: root) == headerBefore)
        }
    }

    // MARK: Guard rails

    @Test("stale staging directories are rejected until cancelled")
    func staleStagingRejected() async throws {
        try await withTemporaryDirectory { root in
            try makeFixtureLibrary(at: root)
            let coordinator = makeCoordinator(root: root)

            let stale = LibraryEncryptionLocation.stagingURL(root: root, operation: .encryption)
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

            await #expect(throws: LibraryEncryptionError.staleStagingFound(stale)) {
                _ = try await coordinator.prepareEncryption()
            }

            await coordinator.cancel()
            #expect(await coordinator.status().pendingOperation == nil)
        }
    }

    @Test("activation requires staging and refuses over an existing backup")
    func activationGuardRails() async throws {
        try await withTemporaryDirectory { root in
            try makeFixtureLibrary(at: root)
            let coordinator = makeCoordinator(root: root)

            await #expect(throws: LibraryEncryptionError.noStagedOperation) {
                try await coordinator.activateStaged()
            }

            _ = try await coordinator.prepareEncryption()
            let backup = LibraryEncryptionLocation.backupURL(root: root, operation: .encryption)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)

            await #expect(throws: LibraryEncryptionError.backupAlreadyExists(backup)) {
                try await coordinator.activateStaged()
            }

            // Explicit purge unblocks the switch.
            try await coordinator.deleteBackup(.encryption)
            try await coordinator.activateStaged()
            #expect(await coordinator.status().isEncrypted)
        }
    }

    // MARK: Helpers

    private func snapshot(root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        for case let url as URL in try #require(enumerator)
        where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }
}
