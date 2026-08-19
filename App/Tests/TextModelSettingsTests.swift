import Foundation
import StenoDomain
import StenoIntelligence
import StenoPipeline
import Testing
@testable import steno_macos

@Suite("Mac text model settings")
@MainActor
struct TextModelSettingsTests {
    @Test("a failed registry commit leaves an old queued job on its old secret slot")
    func failedRegistryCommitKeepsOldEndpointAndSecret() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = endpoint(requiresAPIKey: true)
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(original, apiKey: "sentinel-old")
        let pinned = try #require(settings.endpoints.first)
        let oldSlot = TextModelSecretSlot(endpoint: pinned)
        fixture.registry.persistError = TestRegistryError.persistFailed
        let edited = endpoint(
            id: original.id,
            url: "http://localhost:4321/v1",
            requiresAPIKey: true
        )

        #expect(throws: TestRegistryError.persistFailed) {
            try settings.upsert(edited, apiKey: "sentinel-new")
        }

        #expect(settings.endpoints == [pinned])
        #expect(try fixture.registry.load().endpoints == [pinned])
        #expect(fixture.secrets.writtenSlots.count == 2)
        #expect(fixture.secrets.writtenSlots.last != oldSlot)

        let constructions = ProviderConstructionRecorder()
        _ = try TextModelSettings.makeProviderResolver(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            providerFactory: constructions.make
        )(TextModelProviderSelection(
            endpointID: pinned.id.uuidString,
            endpointSnapshot: pinned.snapshot
        ))

        #expect(fixture.secrets.readSlots.last == oldSlot)
        #expect(constructions.values == [
            .init(endpoint: pinned, secret: "sentinel-old"),
        ])
    }

    @Test("a legacy endpoint migrates its legacy keychain slot compatibly")
    func legacyEndpointMigratesSecretSlot() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let legacy = endpoint(requiresAPIKey: true)
        try fixture.registry.persist(.init(endpoints: [legacy]))
        let legacySlot = TextModelSecretSlot(
            endpointID: legacy.id,
            configurationRevision: nil
        )
        try fixture.secrets.setValue("sentinel-legacy", for: legacySlot)
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )

        try settings.upsert(legacy, apiKey: nil)

        let migrated = try #require(settings.endpoints.first)
        #expect(migrated.configurationRevision != nil)
        #expect(try fixture.secrets.value(for: legacySlot) == nil)
        let constructions = ProviderConstructionRecorder()
        _ = try TextModelSettings.makeProviderResolver(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            providerFactory: constructions.make
        )(TextModelProviderSelection(
            endpointID: legacy.id.uuidString,
            endpointSnapshot: legacy.snapshot
        ))
        #expect(constructions.values == [
            .init(endpoint: migrated, secret: "sentinel-legacy"),
        ])
    }

    @Test("a probe that finishes after an edit cannot restore its stale result")
    func lateProbeResultAfterEditIsIgnored() {
        let endpointID = UUID()
        var state = TextModelProbeState()
        let staleGeneration = state.beginProbe(for: endpointID)

        state.endpointWasSaved(endpointID)
        state.setResult(
            "STALE_PROBE_RESULT",
            for: endpointID,
            generation: staleGeneration
        )

        #expect(state.result(for: endpointID) == nil)
    }

    @Test("editing keeps the persisted key requirement without reading the keychain")
    func draftKeepsRequiredKeyFlag() throws {
        let endpoint = endpoint(requiresAPIKey: true)
        let draft = EndpointDraft(endpoint)

        let validated = try #require(draft.validated)

        #expect(validated.requiresAPIKey)
    }

    @Test("a keychain read error rejects an endpoint edit without changing the registry")
    func readFailurePreservesEndpointConfiguration() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = endpoint(requiresAPIKey: true)
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(original, apiKey: "sentinel-one")
        let persistedOriginal = try #require(settings.endpoints.first)
        fixture.secrets.readError = TestSecretStoreError.readFailed
        let edited = endpoint(
            id: original.id,
            url: "http://localhost:4321/v1",
            requiresAPIKey: true
        )

        #expect(throws: TestSecretStoreError.readFailed) {
            try settings.upsert(edited, apiKey: nil)
        }

        #expect(settings.endpoints == [persistedOriginal])
        #expect(try fixture.registry.load().endpoints == [persistedOriginal])
    }

    @Test("a failed keychain write never persists the endpoint")
    func writeFailurePreservesEmptyRegistry() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.writeError = TestSecretStoreError.writeFailed
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )

        #expect(throws: TestSecretStoreError.writeFailed) {
            try settings.upsert(endpoint(requiresAPIKey: true), apiKey: "sentinel-one")
        }

        #expect(settings.endpoints.isEmpty)
        #expect(try fixture.registry.load().endpoints.isEmpty)
    }

    @Test("changing the URL cannot reuse the old host key")
    func changedURLRequiresReplacementKey() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = endpoint(requiresAPIKey: true)
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(original, apiKey: "sentinel-one")
        let persistedOriginal = try #require(settings.endpoints.first)
        let edited = endpoint(
            id: original.id,
            url: "http://localhost:4321/v1",
            requiresAPIKey: true
        )

        #expect(throws: TextModelSettingsMutationError.replacementAPIKeyRequired) {
            try settings.upsert(edited, apiKey: nil)
        }

        #expect(settings.endpoints == [persistedOriginal])
        #expect(
            try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persistedOriginal))
                == "sentinel-one"
        )
    }

    @Test("a failed keychain deletion preserves endpoint and selection")
    func deleteFailurePreservesRegistryAndSelection() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = endpoint(requiresAPIKey: true)
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(original, apiKey: "sentinel-one")
        let persistedOriginal = try #require(settings.endpoints.first)
        settings.selectedEndpointID = original.id
        fixture.secrets.deleteError = TestSecretStoreError.deleteFailed

        #expect(throws: TestSecretStoreError.deleteFailed) {
            try settings.remove(original)
        }

        #expect(settings.endpoints == [persistedOriginal])
        #expect(settings.selectedEndpointID == original.id)
        #expect(try fixture.registry.load().endpoints == [persistedOriginal])
        #expect(
            fixture.defaults.string(forKey: TextModelSettings.selectionDefaultsKey)
                == original.id.uuidString
        )
    }

    @Test(
        "cold recovery resolves one endpoint-secret generation after every upsert crash",
        arguments: UpsertCrashCase.all
    )
    func coldRecoveryAfterUpsertCrash(testCase: UpsertCrashCase) throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = endpoint(requiresAPIKey: true)
        let seeded = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try seeded.upsert(original, apiKey: "sentinel-old")
        let old = try #require(seeded.endpoints.first)
        let edited = endpoint(
            id: original.id,
            url: "http://localhost:4321/v1",
            requiresAPIKey: true
        )
        let crashing = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            mutationAction: { checkpoint in
                if checkpoint == testCase.checkpoint { throw TestCrashError.injected }
            }
        )

        #expect(throws: TestCrashError.injected) {
            try crashing.upsert(edited, apiKey: "sentinel-new")
        }
        let interrupted = try fixture.registry.load()
        let newGeneration = try #require(interrupted.journal?.nextEndpoint)

        let cold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        let recovered = try #require(cold.endpoints.first)
        let expectedSecret = testCase.registryWasCommitted
            ? "sentinel-new"
            : "sentinel-old"
        #expect(recovered.baseURL == (testCase.registryWasCommitted ? edited.baseURL : old.baseURL))
        #expect(
            try fixture.secrets.value(for: TextModelSecretSlot(endpoint: recovered))
                == expectedSecret
        )
        if testCase.registryWasCommitted {
            #expect(try fixture.secrets.value(for: TextModelSecretSlot(endpoint: old)) == nil)
        } else {
            #expect(
                try fixture.secrets.value(for: TextModelSecretSlot(endpoint: newGeneration))
                    == nil
            )
        }
        let secondCold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        #expect(secondCold.endpoints == [recovered])

        let constructions = ProviderConstructionRecorder()
        let resolver = TextModelSettings.makeProviderResolver(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            providerFactory: constructions.make
        )
        let rejected = testCase.registryWasCommitted ? old : newGeneration
        #expect(throws: PipelineError.textModelEndpointConfigurationChanged(
            recovered.id.uuidString
        )) {
            _ = try resolver(.init(
                endpointID: recovered.id.uuidString,
                endpointSnapshot: rejected.snapshot
            ))
        }
        _ = try resolver(.init(
            endpointID: recovered.id.uuidString,
            endpointSnapshot: recovered.snapshot
        ))
        #expect(constructions.values == [
            .init(endpoint: recovered, secret: expectedSecret),
        ])
    }

    @Test(
        "cold recovery completes deletion after every durable delete crash",
        arguments: DeleteCrashCase.all
    )
    func coldRecoveryAfterDeleteCrash(testCase: DeleteCrashCase) throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = endpoint(requiresAPIKey: true)
        let seeded = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try seeded.upsert(original, apiKey: "sentinel-delete")
        let persisted = try #require(seeded.endpoints.first)
        seeded.selectedEndpointID = persisted.id
        let crashing = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            mutationAction: { checkpoint in
                if checkpoint == testCase.checkpoint { throw TestCrashError.injected }
            }
        )

        #expect(throws: TestCrashError.injected) {
            try crashing.remove(persisted)
        }

        let cold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        #expect(cold.endpoints.isEmpty)
        #expect(cold.selectedEndpointID == nil)
        #expect(try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persisted)) == nil)
        #expect(fixture.defaults.string(forKey: TextModelSettings.selectionDefaultsKey) == nil)
        let secondCold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        #expect(secondCold.endpoints.isEmpty)
        #expect(secondCold.recoveryErrorMessage == nil)
    }

    @Test("cold recovery errors remain visible and resolver-fail-closed")
    func coldRecoveryErrorFailsClosed() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = endpoint(requiresAPIKey: true)
        let seeded = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try seeded.upsert(original, apiKey: "sentinel-old")
        let crashing = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            mutationAction: { checkpoint in
                if checkpoint == .upsertSecretWritten { throw TestCrashError.injected }
            }
        )
        #expect(throws: TestCrashError.injected) {
            try crashing.upsert(
                endpoint(
                    id: original.id,
                    url: "http://localhost:4321/v1",
                    requiresAPIKey: true
                ),
                apiKey: "sentinel-new"
            )
        }
        fixture.secrets.deleteError = .deleteFailed

        let cold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        let constructions = ProviderConstructionRecorder()

        #expect(cold.endpoints.isEmpty)
        #expect(cold.recoveryErrorMessage != nil)
        #expect(throws: TestSecretStoreError.deleteFailed) {
            _ = try TextModelSettings.makeProviderResolver(
                defaults: fixture.defaults,
                secrets: fixture.secrets,
                registry: fixture.registry,
                providerFactory: constructions.make
            )(.init(endpointID: original.id.uuidString))
        }
        #expect(constructions.values.isEmpty)
    }

    @Test("registry write failure during cold recovery stays visible and fail-closed")
    func coldRegistryRecoveryWriteErrorFailsClosed() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = endpoint(requiresAPIKey: true)
        let seeded = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try seeded.upsert(original, apiKey: "sentinel-old")
        let old = try #require(seeded.endpoints.first)
        let crashing = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            mutationAction: { checkpoint in
                if checkpoint == .upsertSecretWritten { throw TestCrashError.injected }
            }
        )
        #expect(throws: TestCrashError.injected) {
            try crashing.upsert(
                endpoint(
                    id: original.id,
                    url: "http://localhost:4321/v1",
                    requiresAPIKey: true
                ),
                apiKey: "sentinel-new"
            )
        }
        fixture.registry.failAllPersistence = true

        let cold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        let constructions = ProviderConstructionRecorder()

        #expect(cold.endpoints.isEmpty)
        #expect(cold.recoveryErrorMessage != nil)
        #expect(try fixture.secrets.value(for: TextModelSecretSlot(endpoint: old)) == "sentinel-old")
        #expect(throws: TestRegistryError.persistFailed) {
            _ = try TextModelSettings.makeProviderResolver(
                defaults: fixture.defaults,
                secrets: fixture.secrets,
                registry: fixture.registry,
                providerFactory: constructions.make
            )(.init(endpointID: original.id.uuidString))
        }
        #expect(constructions.values.isEmpty)
    }

    @Test(
        "real file persistence failures reconcile the actual Upsert or Delete state",
        arguments: RegistryMutationPersistenceCase.all
    )
    func atomicRegistryFailureReconcilesActualState(
        testCase: RegistryMutationPersistenceCase
    ) throws {
        let fixture = try AtomicSettingsFixture()
        defer { fixture.cleanUp() }
        let original = endpoint(requiresAPIKey: true)
        let seeded = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.store()
        )
        try seeded.upsert(original, apiKey: "sentinel-old")
        let old = try #require(seeded.endpoints.first)
        let edited = endpoint(
            id: original.id,
            url: "http://localhost:4321/v1",
            requiresAPIKey: true
        )
        let failingStore = fixture.store { checkpoint, state in
            guard checkpoint == testCase.checkpoint,
                  state.journal?.operation == testCase.operation,
                  state.journal?.phase == testCase.phase
            else { return }
            throw TestAtomicPersistenceError.injected
        }
        let subject = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: failingStore
        )

        #expect(throws: TestAtomicPersistenceError.injected) {
            switch testCase.operation {
            case .upsert:
                try subject.upsert(edited, apiKey: "sentinel-new")
            case .delete:
                try subject.remove(old)
            }
        }

        let cold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.store()
        )
        #expect(subject.endpoints == cold.endpoints)
        #expect(cold.recoveryErrorMessage == nil)

        switch testCase.expected {
        case .old:
            #expect(cold.endpoints == [old])
            #expect(
                try fixture.secrets.value(for: TextModelSecretSlot(endpoint: old))
                    == "sentinel-old"
            )
        case .new:
            let new = try #require(cold.endpoints.first)
            #expect(new.baseURL == edited.baseURL)
            #expect(
                try fixture.secrets.value(for: TextModelSecretSlot(endpoint: new))
                    == "sentinel-new"
            )
            #expect(
                try fixture.secrets.value(for: TextModelSecretSlot(endpoint: old)) == nil
            )
        case .deleted:
            #expect(cold.endpoints.isEmpty)
            #expect(
                try fixture.secrets.value(for: TextModelSecretSlot(endpoint: old)) == nil
            )
        }

        let constructions = ProviderConstructionRecorder()
        let resolver = TextModelSettings.makeProviderResolver(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.store(),
            providerFactory: constructions.make
        )
        if let current = cold.endpoints.first {
            _ = try resolver(.init(
                endpointID: current.id.uuidString,
                endpointSnapshot: current.snapshot
            ))
            #expect(constructions.values.count == 1)
        } else {
            #expect(throws: PipelineError.unknownTextModelEndpoint(old.id.uuidString)) {
                _ = try resolver(.init(
                    endpointID: old.id.uuidString,
                    endpointSnapshot: old.snapshot
                ))
            }
            #expect(constructions.values.isEmpty)
        }
    }

    @Test("the real-file test fixture never targets the production registry")
    func atomicFixtureIsIsolatedFromProduction() throws {
        let fixture = try AtomicSettingsFixture()
        defer { fixture.cleanUp() }
        let applicationSupport = try #require(FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first)
        let production = AtomicTextModelEndpointRegistryStore.productionFileURL(
            applicationSupportDirectory: applicationSupport
        )

        #expect(fixture.store().fileURL.standardizedFileURL != production.standardizedFileURL)
    }

    @Test("the default test host never consumes production migration defaults")
    func isolatedDefaultStoreIgnoresMigrationDefaults() throws {
        #expect(
            ProcessInfo.processInfo.environment[
                AtomicTextModelEndpointRegistryStore.testIsolationEnvironmentKey
            ] == "1"
        )
        let fixture = try AtomicSettingsFixture()
        defer { fixture.cleanUp() }
        let old = TextModelEndpoint(
            id: UUID(),
            name: "Old endpoint",
            baseURL: URL(string: "http://localhost:1234/v1")!,
            modelID: "old-model",
            requiresAPIKey: true,
            configurationRevision: UUID()
        )
        let next = TextModelEndpoint(
            id: old.id,
            name: "New endpoint",
            baseURL: URL(string: "http://localhost:4321/v1")!,
            modelID: "new-model",
            requiresAPIKey: true,
            configurationRevision: UUID()
        )
        let canonicalData = try JSONEncoder().encode(
            TextModelEndpointRegistryState(
                endpoints: [old],
                journal: .upsert(phase: .prepared, previous: old, next: next)
            )
        )
        let legacyData = try JSONEncoder().encode([old])
        fixture.defaults.set(
            canonicalData,
            forKey: TextModelSettings.registryStateDefaultsKey
        )
        fixture.defaults.set(
            legacyData,
            forKey: TextModelSettings.endpointsDefaultsKey
        )
        try fixture.secrets.setValue(
            "sentinel-orphan",
            for: TextModelSecretSlot(endpoint: next)
        )
        let store = AtomicTextModelEndpointRegistryStore(
            defaults: fixture.defaults,
            applicationSupportDirectory: fixture.root
        )
        let isolatedDirectory = store.fileURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: isolatedDirectory)
        defer { try? FileManager.default.removeItem(at: isolatedDirectory) }

        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: store,
            defaultStoreEnvironment: ProcessInfo.processInfo.environment
        )

        #expect(settings.endpoints.isEmpty)
        #expect(
            fixture.defaults.data(forKey: TextModelSettings.registryStateDefaultsKey)
                == canonicalData
        )
        #expect(
            fixture.defaults.data(forKey: TextModelSettings.endpointsDefaultsKey)
                == legacyData
        )
        #expect(fixture.secrets.removedSlots.isEmpty)
        #expect(
            try fixture.secrets.value(for: TextModelSecretSlot(endpoint: next))
                == "sentinel-orphan"
        )
    }

    @Test("the default test host never consumes or rewrites the persisted selection")
    func isolatedDefaultSettingsIgnoresPersistedSelection() throws {
        #expect(
            ProcessInfo.processInfo.environment[
                AtomicTextModelEndpointRegistryStore.testIsolationEnvironmentKey
            ] == "1"
        )
        let fixture = try AtomicSettingsFixture()
        defer { fixture.cleanUp() }
        let persistedSelection = UUID()
        fixture.defaults.set(
            persistedSelection.uuidString,
            forKey: TextModelSettings.selectionDefaultsKey
        )
        let store = AtomicTextModelEndpointRegistryStore(
            defaults: fixture.defaults,
            applicationSupportDirectory: fixture.root
        )
        let isolatedDirectory = store.fileURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: isolatedDirectory)
        defer { try? FileManager.default.removeItem(at: isolatedDirectory) }

        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: store,
            defaultStoreEnvironment: ProcessInfo.processInfo.environment
        )
        #expect(
            fixture.defaults.string(forKey: TextModelSettings.selectionDefaultsKey)
                == persistedSelection.uuidString
        )
        settings.selectedEndpointID = UUID()

        #expect(
            fixture.defaults.string(forKey: TextModelSettings.selectionDefaultsKey)
                == persistedSelection.uuidString
        )
    }

    @Test("the default settings path persists selection outside test isolation")
    func defaultSettingsPersistSelectionOutsideIsolation() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let endpoint = endpoint(requiresAPIKey: false)
        try fixture.registry.persist(.init(endpoints: [endpoint]))
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            defaultStoreEnvironment: [:]
        )

        settings.selectedEndpointID = endpoint.id
        let cold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            defaultStoreEnvironment: [:]
        )

        #expect(
            fixture.defaults.string(forKey: TextModelSettings.selectionDefaultsKey)
                == endpoint.id.uuidString
        )
        #expect(cold.selectedEndpointID == endpoint.id)
    }

    @Test("explicitly injected defaults persist selection in the isolated test host")
    func explicitDefaultsPersistSelectionInTestHost() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let endpoint = endpoint(requiresAPIKey: false)
        try fixture.registry.persist(.init(endpoints: [endpoint]))
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )

        settings.selectedEndpointID = endpoint.id
        let cold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )

        #expect(
            fixture.defaults.string(forKey: TextModelSettings.selectionDefaultsKey)
                == endpoint.id.uuidString
        )
        #expect(cold.selectedEndpointID == endpoint.id)
    }

    private func endpoint(
        id: UUID = UUID(),
        url: String = "http://localhost:1234/v1",
        requiresAPIKey: Bool
    ) -> TextModelEndpoint {
        TextModelEndpoint(
            id: id,
            name: "Local model",
            baseURL: URL(string: url)!,
            modelID: "model-v1",
            requiresAPIKey: requiresAPIKey
        )
    }

}

struct UpsertCrashCase: Sendable, CustomTestStringConvertible {
    let checkpoint: TextModelEndpointMutationCheckpoint
    let registryWasCommitted: Bool
    let testDescription: String

    static let all = [
        Self(checkpoint: .upsertJournalPersisted, registryWasCommitted: false, testDescription: "after journal"),
        Self(checkpoint: .upsertSecretWritten, registryWasCommitted: false, testDescription: "after secret"),
        Self(checkpoint: .upsertRegistryCommitted, registryWasCommitted: true, testDescription: "after registry"),
        Self(checkpoint: .upsertOldSecretRemoved, registryWasCommitted: true, testDescription: "after cleanup"),
    ]
}

struct DeleteCrashCase: Sendable, CustomTestStringConvertible {
    let checkpoint: TextModelEndpointMutationCheckpoint
    let testDescription: String

    static let all = [
        Self(checkpoint: .deleteJournalPersisted, testDescription: "after journal"),
        Self(checkpoint: .deleteSecretRemoved, testDescription: "after secret"),
        Self(checkpoint: .deleteRegistryCommitted, testDescription: "after registry"),
    ]
}

struct RegistryMutationPersistenceCase: Sendable, CustomTestStringConvertible {
    enum Expected: Sendable {
        case old
        case new
        case deleted
    }

    let operation: TextModelEndpointMutationJournal.Operation
    let phase: TextModelEndpointMutationJournal.Phase
    let checkpoint: TextModelEndpointRegistryWriteCheckpoint
    let expected: Expected
    let testDescription: String

    static let all = [
        Self(operation: .upsert, phase: .prepared, checkpoint: .beforeWrite, expected: .old, testDescription: "upsert prepared before write"),
        Self(operation: .upsert, phase: .prepared, checkpoint: .afterFileSync, expected: .old, testDescription: "upsert prepared after file sync"),
        Self(operation: .upsert, phase: .prepared, checkpoint: .afterRenameBeforeDirectorySync, expected: .old, testDescription: "upsert prepared after rename"),
        Self(operation: .upsert, phase: .committed, checkpoint: .beforeWrite, expected: .old, testDescription: "upsert committed before write"),
        Self(operation: .upsert, phase: .committed, checkpoint: .afterFileSync, expected: .old, testDescription: "upsert committed after file sync"),
        Self(operation: .upsert, phase: .committed, checkpoint: .afterRenameBeforeDirectorySync, expected: .new, testDescription: "upsert committed after rename"),
        Self(operation: .delete, phase: .prepared, checkpoint: .beforeWrite, expected: .old, testDescription: "delete prepared before write"),
        Self(operation: .delete, phase: .prepared, checkpoint: .afterFileSync, expected: .old, testDescription: "delete prepared after file sync"),
        Self(operation: .delete, phase: .prepared, checkpoint: .afterRenameBeforeDirectorySync, expected: .deleted, testDescription: "delete prepared after rename"),
        Self(operation: .delete, phase: .committed, checkpoint: .beforeWrite, expected: .deleted, testDescription: "delete committed before write"),
        Self(operation: .delete, phase: .committed, checkpoint: .afterFileSync, expected: .deleted, testDescription: "delete committed after file sync"),
        Self(operation: .delete, phase: .committed, checkpoint: .afterRenameBeforeDirectorySync, expected: .deleted, testDescription: "delete committed after rename"),
    ]
}

private enum TestCrashError: Error {
    case injected
}

private enum TestAtomicPersistenceError: Error {
    case injected
}

@MainActor
private final class AtomicSettingsFixture {
    let root: URL
    let fileURL: URL
    let suiteName: String
    let defaults: UserDefaults
    let secrets = InMemoryTextModelSecretStore()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacAtomicTextModelSettingsTests-\(UUID().uuidString)",
            isDirectory: true
        )
        fileURL = root.appendingPathComponent("registry-state.json")
        suiteName = "MacAtomicTextModelSettingsTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func store(
        writeAction: @escaping AtomicTextModelEndpointRegistryStore.WriteAction = { _, _ in }
    ) -> AtomicTextModelEndpointRegistryStore {
        AtomicTextModelEndpointRegistryStore(
            fileURL: fileURL,
            defaults: defaults,
            stateKey: TextModelSettings.registryStateDefaultsKey,
            legacyEndpointsKey: TextModelSettings.endpointsDefaultsKey,
            writeAction: writeAction
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class SettingsFixture {
    let root: URL
    let fileURL: URL
    let suiteName = "MacTextModelSettingsTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let secrets = InMemoryTextModelSecretStore()
    let registry: TestEndpointRegistry

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacTextModelSettingsTests-\(UUID().uuidString)",
            isDirectory: true
        )
        fileURL = root.appendingPathComponent("registry-state.json")
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        registry = TestEndpointRegistry(fileURL: fileURL, defaults: defaults)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class InMemoryTextModelSecretStore: TextModelSecretStoring, @unchecked Sendable {
    private var values: [TextModelSecretSlot: String] = [:]
    var readError: TestSecretStoreError?
    var writeError: TestSecretStoreError?
    var deleteError: TestSecretStoreError?
    private(set) var readSlots: [TextModelSecretSlot] = []
    private(set) var writtenSlots: [TextModelSecretSlot] = []
    private(set) var removedSlots: [TextModelSecretSlot] = []

    func value(for slot: TextModelSecretSlot) throws -> String? {
        if let readError { throw readError }
        readSlots.append(slot)
        return values[slot]
    }

    func setValue(_ value: String, for slot: TextModelSecretSlot) throws {
        if let writeError { throw writeError }
        writtenSlots.append(slot)
        values[slot] = value
    }

    func removeValue(for slot: TextModelSecretSlot) throws {
        if let deleteError { throw deleteError }
        removedSlots.append(slot)
        values[slot] = nil
    }
}

private final class TestEndpointRegistry: TextModelEndpointRegistryStoring, @unchecked Sendable {
    let fileURL: URL
    private let store: AtomicTextModelEndpointRegistryStore
    var persistError: TestRegistryError?
    var failurePhase: TextModelEndpointMutationJournal.Phase = .committed
    var failAllPersistence = false

    init(fileURL: URL, defaults: UserDefaults) {
        self.fileURL = fileURL
        store = AtomicTextModelEndpointRegistryStore(
            fileURL: fileURL,
            defaults: defaults,
            stateKey: TextModelSettings.registryStateDefaultsKey,
            legacyEndpointsKey: TextModelSettings.endpointsDefaultsKey
        )
    }

    func load() throws -> TextModelEndpointRegistryState {
        try store.load()
    }

    func persist(_ state: TextModelEndpointRegistryState) throws {
        if failAllPersistence { throw TestRegistryError.persistFailed }
        if let persistError, state.journal?.phase == failurePhase {
            self.persistError = nil
            throw persistError
        }
        try store.persist(state)
    }
}

private enum TestRegistryError: Error {
    case persistFailed
}

private enum TestSecretStoreError: Error {
    case readFailed
    case writeFailed
    case deleteFailed
}

private final class ProviderConstructionRecorder: @unchecked Sendable {
    struct Value: Equatable {
        let endpoint: TextModelEndpoint
        let secret: String?
    }

    private let lock = NSLock()
    private var storedValues: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func make(
        endpoint: TextModelEndpoint,
        secret: String?
    ) -> any TextModelProvider {
        lock.lock()
        storedValues.append(Value(endpoint: endpoint, secret: secret))
        lock.unlock()
        return ConstructionOnlyProvider(endpoint: endpoint)
    }
}

private struct ConstructionOnlyProvider: TextModelProvider {
    let endpoint: TextModelEndpoint

    var descriptor: EngineDescriptor {
        EngineDescriptor(name: endpoint.name, version: "test")
    }
    var availability: TextModelAvailability { .available }

    func render(
        template: Template,
        transcript: TranscriptRevision
    ) async throws -> TemplateResult {
        fatalError("The resolver test never renders")
    }
}
