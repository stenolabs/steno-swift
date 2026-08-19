import Foundation
import Testing
@testable import StenoIntelligence

@Suite("Text model endpoint registry recovery")
struct TextModelEndpointRegistryStateTests {
    @Test("prepared upsert rolls back and removes the orphan slot idempotently")
    func preparedUpsertRollsBack() throws {
        let old = endpoint(host: "old.example.test", revision: UUID())
        let new = endpoint(id: old.id, host: "new.example.test", revision: UUID())
        let journal = TextModelEndpointMutationJournal.upsert(
            phase: .prepared,
            previous: old,
            next: new
        )
        let registry = RegistryFake(.init(endpoints: [old], journal: journal))
        let secrets = SecretFake([
            TextModelSecretSlot(endpoint: old): "OLD_KEY",
            TextModelSecretSlot(endpoint: new): "NEW_KEY",
        ])

        let recovered = try TextModelEndpointRegistryRecovery.recover(
            registry: registry,
            secrets: secrets
        )
        let repeated = try TextModelEndpointRegistryRecovery.recover(
            registry: registry,
            secrets: secrets
        )

        #expect(recovered == .init(endpoints: [old]))
        #expect(repeated == recovered)
        #expect(try secrets.value(for: TextModelSecretSlot(endpoint: old)) == "OLD_KEY")
        #expect(try secrets.value(for: TextModelSecretSlot(endpoint: new)) == nil)
    }

    @Test("prepared no-op journal never removes the live legacy slot")
    func preparedNoOpKeepsLiveSlot() throws {
        let old = endpoint(host: "same.example.test", revision: UUID())
        let registry = RegistryFake(.init(
            endpoints: [old],
            journal: .upsert(phase: .prepared, previous: old, next: old)
        ))
        let secrets = SecretFake([TextModelSecretSlot(endpoint: old): "LIVE_KEY"])

        _ = try TextModelEndpointRegistryRecovery.recover(
            registry: registry,
            secrets: secrets
        )

        #expect(try secrets.value(for: TextModelSecretSlot(endpoint: old)) == "LIVE_KEY")
    }

    @Test("committed upsert keeps the new slot and completes old-slot cleanup")
    func committedUpsertCompletes() throws {
        let old = endpoint(host: "old.example.test", revision: UUID())
        let new = endpoint(id: old.id, host: "new.example.test", revision: UUID())
        let journal = TextModelEndpointMutationJournal.upsert(
            phase: .committed,
            previous: old,
            next: new
        )
        let registry = RegistryFake(.init(endpoints: [new], journal: journal))
        let secrets = SecretFake([
            TextModelSecretSlot(endpoint: old): "OLD_KEY",
            TextModelSecretSlot(endpoint: new): "NEW_KEY",
        ])

        let recovered = try TextModelEndpointRegistryRecovery.recover(
            registry: registry,
            secrets: secrets
        )

        #expect(recovered == .init(endpoints: [new]))
        #expect(try secrets.value(for: TextModelSecretSlot(endpoint: old)) == nil)
        #expect(try secrets.value(for: TextModelSecretSlot(endpoint: new)) == "NEW_KEY")
    }

    @Test("prepared delete deterministically completes deletion after a crash")
    func preparedDeleteCompletes() throws {
        let old = endpoint(host: "delete.example.test", revision: UUID())
        let journal = TextModelEndpointMutationJournal.delete(
            phase: .prepared,
            previous: old
        )
        let registry = RegistryFake(.init(endpoints: [old], journal: journal))
        let secrets = SecretFake([TextModelSecretSlot(endpoint: old): "OLD_KEY"])

        let recovered = try TextModelEndpointRegistryRecovery.recover(
            registry: registry,
            secrets: secrets
        )
        let repeated = try TextModelEndpointRegistryRecovery.recover(
            registry: registry,
            secrets: secrets
        )

        #expect(recovered == .init())
        #expect(repeated == recovered)
        #expect(try secrets.value(for: TextModelSecretSlot(endpoint: old)) == nil)
        #expect(registry.persistedStates.contains {
            $0.endpoints.isEmpty && $0.journal?.phase == .committed
        })
    }

    @Test("committed delete completes cleanup idempotently")
    func committedDeleteCompletes() throws {
        let old = endpoint(host: "delete.example.test", revision: UUID())
        let registry = RegistryFake(.init(
            endpoints: [],
            journal: .delete(phase: .committed, previous: old)
        ))
        let secrets = SecretFake([TextModelSecretSlot(endpoint: old): "OLD_KEY"])

        let recovered = try TextModelEndpointRegistryRecovery.recover(
            registry: registry,
            secrets: secrets
        )

        #expect(recovered == .init())
        #expect(try secrets.value(for: TextModelSecretSlot(endpoint: old)) == nil)
    }

    @Test("failed prepared-upsert cleanup stays journaled and fail closed")
    func failedRecoveryRemainsDurable() throws {
        let old = endpoint(host: "old.example.test", revision: UUID())
        let new = endpoint(id: old.id, host: "new.example.test", revision: UUID())
        let initial = TextModelEndpointRegistryState(
            endpoints: [old],
            journal: .upsert(phase: .prepared, previous: old, next: new)
        )
        let registry = RegistryFake(initial)
        let secrets = SecretFake([TextModelSecretSlot(endpoint: new): "NEW_KEY"])
        secrets.removeError = RegistryTestError.injected

        #expect(throws: RegistryTestError.injected) {
            _ = try TextModelEndpointRegistryRecovery.recover(
                registry: registry,
                secrets: secrets
            )
        }
        #expect(try registry.load() == initial)
    }

    @Test("registry state and journal encode no secret material")
    func stateContainsNoSecrets() throws {
        let old = endpoint(host: "old.example.test", revision: UUID())
        let new = endpoint(id: old.id, host: "new.example.test", revision: UUID())
        let state = TextModelEndpointRegistryState(
            endpoints: [old],
            journal: .upsert(phase: .prepared, previous: old, next: new)
        )

        let text = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)

        #expect(text.contains("old.example.test"))
        #expect(text.contains("new.example.test"))
        #expect(!text.contains("OLD_KEY"))
        #expect(!text.contains("NEW_KEY"))
        #expect(!text.localizedCaseInsensitiveContains("secretValue"))
    }

    @Test("UserDefaults registry migrates the legacy endpoint array")
    func legacyDefaultsMigrate() throws {
        let suite = "TextModelEndpointRegistryStateTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = endpoint(host: "legacy.example.test", revision: nil)
        defaults.set(
            try JSONEncoder().encode([old]),
            forKey: "legacy-endpoints"
        )
        let registry = UserDefaultsTextModelEndpointRegistryStore(
            defaults: defaults,
            stateKey: "canonical-state",
            legacyEndpointsKey: "legacy-endpoints"
        )

        let loaded = try registry.load()
        let coldLoaded = try UserDefaultsTextModelEndpointRegistryStore(
            defaults: defaults,
            stateKey: "canonical-state",
            legacyEndpointsKey: "legacy-endpoints"
        ).load()

        #expect(loaded == .init(endpoints: [old]))
        #expect(coldLoaded == loaded)
        #expect(defaults.data(forKey: "canonical-state") != nil)
        #expect(defaults.data(forKey: "legacy-endpoints") == nil)
    }

    @Test(
        "atomic file failures expose only the old or renamed state",
        arguments: RegistryFileWriteFailureCase.all
    )
    func atomicFileFailureHasRecoverableDurableState(
        testCase: RegistryFileWriteFailureCase
    ) throws {
        let fixture = try RegistryFileFixture()
        defer { fixture.cleanUp() }
        let old = TextModelEndpointRegistryState(endpoints: [
            endpoint(host: "old.example.test", revision: UUID()),
        ])
        let new = TextModelEndpointRegistryState(endpoints: [
            endpoint(host: "new.example.test", revision: UUID()),
        ])
        try fixture.store().persist(old)
        let failing = fixture.store { checkpoint, _ in
            if checkpoint == testCase.checkpoint {
                throw RegistryTestError.injected
            }
        }

        #expect(throws: RegistryTestError.injected) {
            try failing.persist(new)
        }

        let cold = try fixture.store().load()
        #expect(cold == (testCase.renameCompleted ? new : old))
        #expect(try fixture.temporaryFiles().isEmpty)
    }

    @Test("atomic registry bytes are owner-only and contain no secret material")
    func atomicFileIsPrivateAndSecretFree() throws {
        let fixture = try RegistryFileFixture()
        defer { fixture.cleanUp() }
        let state = TextModelEndpointRegistryState(endpoints: [
            endpoint(host: "private.example.test", revision: UUID()),
        ])

        try fixture.store().persist(state)

        let bytes = try Data(contentsOf: fixture.fileURL)
        let text = String(decoding: bytes, as: UTF8.self)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.fileURL.path
        )
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        let directoryValues = try fixture.fileURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(permissions.intValue & 0o777 == 0o600)
        #expect(directoryValues.isExcludedFromBackup == true)
        #expect(text.contains("private.example.test"))
        #expect(!text.contains("SENTINEL_SECRET"))
        #expect(try JSONDecoder().decode(
            TextModelEndpointRegistryState.self,
            from: bytes
        ) == state)
    }

    @Test("canonical UserDefaults migration is verified before cleanup")
    func canonicalDefaultsMigrationIsDurableAndIdempotent() throws {
        let fixture = try RegistryFileFixture()
        defer { fixture.cleanUp() }
        let state = TextModelEndpointRegistryState(endpoints: [
            endpoint(host: "canonical.example.test", revision: UUID()),
        ])
        fixture.defaults.set(
            try JSONEncoder().encode(state),
            forKey: fixture.stateKey
        )

        let migrated = try fixture.store().load()
        let cold = try fixture.store().load()

        #expect(migrated == state)
        #expect(cold == state)
        #expect(fixture.defaults.data(forKey: fixture.stateKey) == nil)
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == nil)
    }

    @Test("legacy endpoint-array migration is verified before cleanup")
    func legacyEndpointArrayMigrationIsDurableAndIdempotent() throws {
        let fixture = try RegistryFileFixture()
        defer { fixture.cleanUp() }
        let old = endpoint(host: "legacy-file.example.test", revision: nil)
        fixture.defaults.set(
            try JSONEncoder().encode([old]),
            forKey: fixture.legacyKey
        )

        let migrated = try fixture.store().load()
        let cold = try fixture.store().load()

        #expect(migrated == .init(endpoints: [old]))
        #expect(cold == migrated)
        #expect(fixture.defaults.data(forKey: fixture.stateKey) == nil)
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == nil)
    }

    @Test("post-rename migration failure retains defaults until a cold verified read")
    func ambiguousMigrationCompletesCleanupOnColdLoad() throws {
        let fixture = try RegistryFileFixture()
        defer { fixture.cleanUp() }
        let state = TextModelEndpointRegistryState(endpoints: [
            endpoint(host: "ambiguous.example.test", revision: UUID()),
        ])
        fixture.defaults.set(
            try JSONEncoder().encode(state),
            forKey: fixture.stateKey
        )
        let interrupted = fixture.store { checkpoint, _ in
            if checkpoint == .afterRenameBeforeDirectorySync {
                throw RegistryTestError.injected
            }
        }

        #expect(throws: RegistryTestError.injected) {
            _ = try interrupted.load()
        }
        #expect(fixture.defaults.data(forKey: fixture.stateKey) != nil)

        let recovered = try fixture.store().load()
        #expect(recovered == state)
        #expect(fixture.defaults.data(forKey: fixture.stateKey) == nil)
    }

    @Test("a corrupt durable file never falls back to stale UserDefaults")
    func corruptFileFailsClosed() throws {
        let fixture = try RegistryFileFixture()
        defer { fixture.cleanUp() }
        let stale = endpoint(host: "stale.example.test", revision: UUID())
        fixture.defaults.set(
            try JSONEncoder().encode([stale]),
            forKey: fixture.legacyKey
        )
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fixture.fileURL)

        #expect(throws: (any Error).self) {
            _ = try fixture.store().load()
        }
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) != nil)
    }

    @Test("production path policy is shared under Application Support")
    func productionPathPolicy() {
        let base = URL(fileURLWithPath: "/private/app-support", isDirectory: true)

        let url = AtomicTextModelEndpointRegistryStore.productionFileURL(
            applicationSupportDirectory: base
        )

        #expect(
            url.path == "/private/app-support/Steno/TextModelEndpoints/registry-state.json"
        )
    }

    @Test("an isolated test process never resolves the production registry path")
    func isolatedTestPathPolicy() {
        let productionBase = URL(
            fileURLWithPath: "/private/app-support",
            isDirectory: true
        )
        let temporaryBase = URL(
            fileURLWithPath: "/private/app-temp",
            isDirectory: true
        )

        let url = AtomicTextModelEndpointRegistryStore.defaultFileURL(
            applicationSupportDirectory: productionBase,
            temporaryDirectory: temporaryBase,
            environment: [
                AtomicTextModelEndpointRegistryStore.testIsolationEnvironmentKey: "1",
            ],
            processIdentifier: 42
        )

        #expect(
            url.path
                == "/private/app-temp/StenoTextModelEndpointRegistryTests-42/registry-state.json"
        )
        #expect(
            url != AtomicTextModelEndpointRegistryStore.productionFileURL(
                applicationSupportDirectory: productionBase
            )
        )
    }
}

struct RegistryFileWriteFailureCase: Sendable, CustomTestStringConvertible {
    let checkpoint: TextModelEndpointRegistryWriteCheckpoint
    let renameCompleted: Bool
    let testDescription: String

    static let all = [
        Self(
            checkpoint: .beforeWrite,
            renameCompleted: false,
            testDescription: "before write"
        ),
        Self(
            checkpoint: .afterFileSync,
            renameCompleted: false,
            testDescription: "after file sync"
        ),
        Self(
            checkpoint: .afterRenameBeforeDirectorySync,
            renameCompleted: true,
            testDescription: "after rename"
        ),
    ]
}

private final class RegistryFileFixture: @unchecked Sendable {
    let root: URL
    let fileURL: URL
    let suite: String
    let defaults: UserDefaults
    let stateKey = "canonical-state"
    let legacyKey = "legacy-endpoints"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TextModelRegistryFileTests-\(UUID().uuidString)",
            isDirectory: true
        )
        fileURL = root
            .appendingPathComponent("registry", isDirectory: true)
            .appendingPathComponent("registry-state.json")
        suite = "TextModelRegistryFileTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func store(
        writeAction: @escaping @Sendable (
            TextModelEndpointRegistryWriteCheckpoint,
            TextModelEndpointRegistryState
        ) throws -> Void = { _, _ in }
    ) -> AtomicTextModelEndpointRegistryStore {
        AtomicTextModelEndpointRegistryStore(
            fileURL: fileURL,
            defaults: defaults,
            stateKey: stateKey,
            legacyEndpointsKey: legacyKey,
            writeAction: writeAction
        )
    }

    func temporaryFiles() throws -> [URL] {
        let directory = fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".tmp-") }
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private func endpoint(
    id: UUID = UUID(),
    host: String,
    revision: UUID?
) -> TextModelEndpoint {
    TextModelEndpoint(
        id: id,
        name: host,
        baseURL: URL(string: "https://\(host)/v1")!,
        modelID: "fixture-model",
        requiresAPIKey: true,
        configurationRevision: revision
    )
}

private enum RegistryTestError: Error {
    case injected
}

private final class RegistryFake: TextModelEndpointRegistryStoring, @unchecked Sendable {
    private(set) var state: TextModelEndpointRegistryState
    private(set) var persistedStates: [TextModelEndpointRegistryState] = []

    init(_ state: TextModelEndpointRegistryState) {
        self.state = state
    }

    func load() throws -> TextModelEndpointRegistryState {
        state
    }

    func persist(_ state: TextModelEndpointRegistryState) throws {
        self.state = state
        persistedStates.append(state)
    }
}

private final class SecretFake: TextModelSecretStoring, @unchecked Sendable {
    private var values: [TextModelSecretSlot: String]
    var removeError: (any Error)?

    init(_ values: [TextModelSecretSlot: String] = [:]) {
        self.values = values
    }

    func value(for slot: TextModelSecretSlot) throws -> String? {
        values[slot]
    }

    func setValue(_ value: String, for slot: TextModelSecretSlot) throws {
        values[slot] = value
    }

    func removeValue(for slot: TextModelSecretSlot) throws {
        if let removeError { throw removeError }
        values[slot] = nil
    }
}
