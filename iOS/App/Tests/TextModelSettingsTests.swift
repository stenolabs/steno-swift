import Foundation
import StenoDomain
import StenoIntelligence
import StenoPipeline
import Testing
@testable import Steno

@MainActor
@Suite("Text model settings")
struct TextModelSettingsTests {
    @Test("a failed registry commit leaves an old queued job on its old secret slot")
    func failedRegistryCommitKeepsOldEndpointAndSecret() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = fixture.endpoint()
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(original, apiKey: "sentinel-old")
        let pinned = try #require(settings.endpoints.first)
        let oldSlot = TextModelSecretSlot(endpoint: pinned)
        fixture.registry.persistError = TestRegistryError.persistFailed
        let edited = TextModelEndpoint(
            id: original.id,
            name: original.name,
            baseURL: URL(string: "http://localhost:4321/v1")!,
            modelID: original.modelID,
            requiresAPIKey: true,
            hosting: original.hosting,
            dialect: original.dialect,
            contextWindowTokens: original.contextWindowTokens,
            bedrock: original.bedrock
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

    @Test("a Bedrock endpoint with a region-matched base URL saves as a cloud endpoint")
    func bedrockEndpointWithMatchingRegionSavesAsCloud() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        let draft = EndpointDraft()
        draft.selectDialect(.amazonBedrock)
        draft.name = "Bedrock"
        draft.modelID = "anthropic.claude-3"
        draft.selectBedrockRegion("eu-central-1")
        draft.updateHostingFromURLIfAutomatic()
        let endpoint = try #require(draft.validated)

        try settings.upsert(endpoint, apiKey: "sentinel-bedrock")

        let saved = try #require(settings.endpoints.first)
        #expect(saved.hosting == .cloud)
        #expect(saved.dialect == .amazonBedrock)
        #expect(saved.bedrock?.region == "eu-central-1")
    }

    @Test("a Bedrock endpoint whose base URL does not match its region is rejected")
    func bedrockEndpointWithMismatchedRegionIsRejected() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        let mismatched = TextModelEndpoint(
            name: "Bedrock",
            baseURL: URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com")!,
            modelID: "anthropic.claude-3",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: .amazonBedrock,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens,
            bedrock: AmazonBedrockConfiguration(region: "eu-central-1", inferenceProfile: nil)
        )

        #expect(throws: TextModelEndpointPolicyError.invalidProviderConfiguration) {
            try settings.upsert(mismatched, apiKey: "sentinel-bedrock")
        }
        #expect(settings.endpoints.isEmpty)
    }

    @Test("a legacy endpoint copies its key without removing the legacy slot")
    func legacyEndpointMigratesSecretSlot() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let legacy = fixture.endpoint()
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
        #expect(try fixture.secrets.value(for: legacySlot) == "sentinel-legacy")
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

    @Test("deleting a migrated endpoint removes current and legacy key slots")
    func deletingMigratedEndpointRemovesEveryKeySlot() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let legacy = fixture.endpoint()
        let legacySlot = TextModelSecretSlot(
            endpointID: legacy.id,
            configurationRevision: nil
        )
        try fixture.registry.persist(.init(endpoints: [legacy]))
        try fixture.secrets.setValue("sentinel-legacy", for: legacySlot)
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        let migrated = try #require(settings.endpoints.first)
        let currentSlot = TextModelSecretSlot(endpoint: migrated)

        #expect(try fixture.secrets.value(for: currentSlot) == "sentinel-legacy")
        #expect(try fixture.secrets.value(for: legacySlot) == "sentinel-legacy")

        try settings.remove(migrated)

        #expect(settings.endpoints.isEmpty)
        #expect(try fixture.secrets.value(for: currentSlot) == nil)
        #expect(try fixture.secrets.value(for: legacySlot) == nil)
    }

    @Test("endpoints persist without secrets or a remembered selection")
    func persistsEndpointsSeparatelyFromSecretsAndSelection() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let endpoint = fixture.endpoint()
        let first = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )

        try first.upsert(endpoint, apiKey: "secret")
        let persisted = try #require(first.endpoints.first)
        let raw = try Data(contentsOf: fixture.registry.fileURL)
        #expect(!String(decoding: raw, as: UTF8.self).contains("secret"))
        #expect(
            try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persisted)) == "secret"
        )

        first.selectedEndpointID = endpoint.id
        let second = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        #expect(second.endpoints == [persisted])
        #expect(second.selectedEndpointID == nil)
    }

    @Test("editing without a new key keeps the stored secret")
    func editWithoutKeyKeepsSecret() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let endpoint = fixture.endpoint()
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(endpoint, apiKey: "secret")
        let originalPersisted = try #require(settings.endpoints.first)

        let edited = fixture.endpoint(name: "Renamed", id: endpoint.id)
        try settings.upsert(edited, apiKey: nil)

        let editedPersisted = try #require(settings.endpoints.first)
        #expect(editedPersisted.name == edited.name)
        #expect(editedPersisted.configurationRevision != originalPersisted.configurationRevision)
        #expect(
            try fixture.secrets.value(for: TextModelSecretSlot(endpoint: editedPersisted))
                == "secret"
        )
    }

    @Test("a supplied key replaces the stored secret")
    func explicitKeyReplacesSecret() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let endpoint = fixture.endpoint()
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(endpoint, apiKey: "old secret")

        try settings.upsert(endpoint, apiKey: "new secret")

        let persisted = try #require(settings.endpoints.first)
        #expect(
            try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persisted))
                == "new secret"
        )
    }

    @Test("a supplied key marks the persisted endpoint as requiring a key")
    func suppliedKeyMarksEndpointAsRequiringKey() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let endpoint = fixture.endpoint(requiresAPIKey: false)
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )

        try settings.upsert(endpoint, apiKey: "secret")

        #expect(settings.endpoints.single?.requiresAPIKey == true)
    }

    @Test("deleting a selected endpoint removes its secret and selection")
    func deleteClearsSecretAndSelection() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let endpoint = fixture.endpoint()
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(endpoint, apiKey: "secret")
        let persisted = try #require(settings.endpoints.first)
        settings.selectedEndpointID = endpoint.id

        try settings.remove(endpoint)

        #expect(settings.endpoints.isEmpty)
        #expect(settings.selectedEndpointID == nil)
        #expect(
            try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persisted)) == nil
        )
    }

    @Test("a failed secret deletion preserves the endpoint and selection")
    func failedSecretDeletionPreservesRegistryState() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let secrets = FailingRemovalSecretStore()
        let endpoint = fixture.endpoint()
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: secrets,
            registry: fixture.registry
        )
        try settings.upsert(endpoint, apiKey: "secret")
        let persisted = try #require(settings.endpoints.first)
        settings.selectedEndpointID = endpoint.id
        secrets.refuseRemoval = true

        #expect(throws: TestSecretStoreError.removalFailed) {
            try settings.remove(endpoint)
        }

        #expect(settings.endpoints == [persisted])
        #expect(settings.selectedEndpointID == endpoint.id)
        #expect(
            try secrets.value(for: TextModelSecretSlot(endpoint: persisted)) == "secret"
        )
        #expect(try fixture.registry.load().journal == nil)
    }

    @Test("a failed first-slot delete and rollback write recover without deletion")
    func firstSlotAndRollbackPersistenceFailureRecoverSafely() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = fixture.endpoint()
        let seeded = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try seeded.upsert(original, apiKey: "sentinel-current")
        let persisted = try #require(seeded.endpoints.first)
        fixture.secrets.deleteError = .deleteFailed
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            mutationAction: { checkpoint in
                if checkpoint == .deleteJournalPersisted {
                    fixture.registry.failAllPersistence = true
                }
            }
        )
        settings.selectedEndpointID = persisted.id

        #expect(throws: TestSecretStoreError.deleteFailed) {
            try settings.remove(persisted)
        }

        #expect(settings.endpoints == [persisted])
        #expect(settings.selectedEndpointID == persisted.id)
        #expect(
            try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persisted))
                == "sentinel-current"
        )
        let interrupted = try fixture.registry.load()
        #expect(interrupted.endpoints == [persisted])
        #expect(interrupted.journal?.operation == .delete)
        #expect(interrupted.journal?.phase == .prepared)
        #expect(interrupted.journal?.deleteCurrentSecretWasPresent == true)

        fixture.registry.failAllPersistence = false
        fixture.secrets.deleteError = nil
        let cold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )

        #expect(cold.endpoints == [persisted])
        #expect(cold.recoveryErrorMessage == nil)
        #expect(try fixture.registry.load().journal == nil)
        #expect(
            try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persisted))
                == "sentinel-current"
        )
    }

    @Test("a second-slot delete failure remains journaled for cold recovery")
    func legacySlotDeleteFailureRecoversOnColdLaunch() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = fixture.endpoint()
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(original, apiKey: "sentinel-current")
        let persisted = try #require(settings.endpoints.first)
        let currentSlot = TextModelSecretSlot(endpoint: persisted)
        let legacySlot = TextModelSecretSlot(
            endpointID: persisted.id,
            configurationRevision: nil
        )
        try fixture.secrets.setValue("sentinel-legacy", for: legacySlot)
        fixture.secrets.deleteErrorSlots = [legacySlot]

        #expect(throws: TestSecretStoreError.deleteFailed) {
            try settings.remove(persisted)
        }

        #expect(try fixture.secrets.value(for: currentSlot) == nil)
        #expect(try fixture.secrets.value(for: legacySlot) == "sentinel-legacy")
        let interrupted = try fixture.registry.load()
        #expect(interrupted.endpoints == [persisted])
        #expect(interrupted.journal?.operation == .delete)
        #expect(interrupted.journal?.phase == .committed)

        fixture.secrets.deleteErrorSlots = []
        let cold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )

        #expect(cold.endpoints.isEmpty)
        #expect(cold.recoveryErrorMessage == nil)
        #expect(try fixture.secrets.value(for: currentSlot) == nil)
        #expect(try fixture.secrets.value(for: legacySlot) == nil)
    }

    @Test("a failed secret write preserves the endpoint registry")
    func failedSecretWritePreservesRegistryState() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        fixture.secrets.writeError = TestSecretStoreError.writeFailed
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )

        #expect(throws: TestSecretStoreError.writeFailed) {
            try settings.upsert(fixture.endpoint(), apiKey: "sentinel-one")
        }

        #expect(settings.endpoints.isEmpty)
        #expect(fixture.defaults.data(forKey: TextModelSettings.endpointsDefaultsKey) == nil)
    }

    @Test("changing the URL cannot reuse the old host key")
    func changedURLRequiresReplacementKey() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = fixture.endpoint()
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(original, apiKey: "sentinel-one")
        let persistedOriginal = try #require(settings.endpoints.first)
        let edited = TextModelEndpoint(
            id: original.id,
            name: original.name,
            baseURL: URL(string: "http://localhost:4321/v1")!,
            modelID: original.modelID,
            requiresAPIKey: true,
            hosting: original.hosting,
            dialect: original.dialect,
            contextWindowTokens: original.contextWindowTokens,
            bedrock: original.bedrock
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

    @Test("a remote plaintext endpoint is rejected without storing it")
    func rejectsForbiddenURL() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        let endpoint = TextModelEndpoint(
            name: "Remote HTTP",
            baseURL: try #require(URL(string: "http://models.example.com/v1")),
            modelID: "model",
            requiresAPIKey: false,
            hosting: .cloud,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )

        #expect(throws: TextModelEndpointPolicyError.insecureRemoteURL) {
            try settings.upsert(endpoint, apiKey: nil)
        }

        #expect(settings.endpoints.isEmpty)
    }

    @Test("pinned endpoint mutation fails before constructing a provider")
    func pinnedEndpointMutationFailsClosed() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = fixture.endpoint()
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(original, apiKey: "sentinel-one")
        let pinned = try #require(settings.endpoints.first)
        try settings.upsert(
            TextModelEndpoint(
                id: original.id,
                name: original.name,
                baseURL: URL(string: "http://localhost:4321/v1")!,
                modelID: original.modelID,
                requiresAPIKey: true,
                hosting: original.hosting,
                dialect: original.dialect,
                contextWindowTokens: original.contextWindowTokens,
                bedrock: original.bedrock
            ),
            apiKey: "sentinel-two"
        )
        let constructions = ProviderConstructionRecorder()
        let resolver = TextModelSettings.makeProviderResolver(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            providerFactory: constructions.make
        )

        #expect(throws: PipelineError.textModelEndpointConfigurationChanged(
            original.id.uuidString
        )) {
            _ = try resolver(TextModelProviderSelection(
                endpointID: original.id.uuidString,
                endpointSnapshot: pinned.snapshot
            ))
        }
        #expect(constructions.values.isEmpty)
    }

    @Test("resolved provider captures one endpoint and key moment")
    func providerCapturesResolvedKey() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let endpoint = fixture.endpoint()
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(endpoint, apiKey: "sentinel-one")
        let persisted = try #require(settings.endpoints.first)
        let constructions = ProviderConstructionRecorder()
        let resolver = TextModelSettings.makeProviderResolver(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            providerFactory: constructions.make
        )

        _ = try resolver(TextModelProviderSelection(
            endpointID: endpoint.id.uuidString,
            endpointSnapshot: persisted.snapshot
        ))
        try fixture.secrets.setValue(
            "sentinel-two",
            for: TextModelSecretSlot(endpoint: persisted)
        )

        #expect(constructions.values == [
            .init(endpoint: persisted, secret: "sentinel-one"),
        ])
    }

    @Test("missing required key and keychain read failure stay distinguishable")
    func missingAndUnreadableKeysAreDistinct() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let endpoint = fixture.endpoint()
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(endpoint, apiKey: nil)
        let persisted = try #require(settings.endpoints.first)
        let selection = TextModelProviderSelection(
            endpointID: endpoint.id.uuidString,
            endpointSnapshot: persisted.snapshot
        )

        #expect(throws: OpenAICompatibleProviderError.apiKeyRequired) {
            _ = try TextModelSettings.makeProviderResolver(
                defaults: fixture.defaults,
                secrets: fixture.secrets,
                registry: fixture.registry
            )(selection)
        }

        fixture.secrets.readError = TestSecretStoreError.readFailed
        #expect(throws: TestSecretStoreError.readFailed) {
            _ = try TextModelSettings.makeProviderResolver(
                defaults: fixture.defaults,
                secrets: fixture.secrets,
                registry: fixture.registry
            )(selection)
        }
    }

    @Test("an endpoint that does not require a key resolves without one")
    func noKeyRequiredIsNotMissingKey() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let endpoint = fixture.endpoint(requiresAPIKey: false)
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try settings.upsert(endpoint, apiKey: nil)
        let persisted = try #require(settings.endpoints.first)
        let constructions = ProviderConstructionRecorder()

        _ = try TextModelSettings.makeProviderResolver(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry,
            providerFactory: constructions.make
        )(TextModelProviderSelection(
            endpointID: endpoint.id.uuidString,
            endpointSnapshot: persisted.snapshot
        ))

        #expect(constructions.values == [.init(endpoint: persisted, secret: nil)])
    }

    @Test(
        "cold recovery resolves one endpoint-secret generation after every upsert crash",
        arguments: UpsertCrashCase.all
    )
    func coldRecoveryAfterUpsertCrash(testCase: UpsertCrashCase) throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = fixture.endpoint()
        let seeded = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try seeded.upsert(original, apiKey: "sentinel-old")
        let old = try #require(seeded.endpoints.first)
        let edited = TextModelEndpoint(
            id: original.id,
            name: original.name,
            baseURL: URL(string: "http://localhost:4321/v1")!,
            modelID: original.modelID,
            requiresAPIKey: true,
            hosting: original.hosting,
            dialect: original.dialect,
            contextWindowTokens: original.contextWindowTokens,
            bedrock: original.bedrock
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
        let original = fixture.endpoint()
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
        if testCase.checkpoint == .deleteJournalPersisted {
            #expect(cold.endpoints == [persisted])
            #expect(cold.selectedEndpointID == nil)
            #expect(
                try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persisted))
                    == "sentinel-delete"
            )
        } else {
            #expect(cold.endpoints.isEmpty)
            #expect(cold.selectedEndpointID == nil)
            #expect(
                try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persisted)) == nil
            )
        }
        let secondCold = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        #expect(
            secondCold.endpoints
                == (testCase.checkpoint == .deleteJournalPersisted ? [persisted] : [])
        )
        #expect(secondCold.recoveryErrorMessage == nil)
    }

    @Test("cold recovery errors remain visible and resolver-fail-closed")
    func coldRecoveryErrorFailsClosed() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = fixture.endpoint()
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
                TextModelEndpoint(
                    id: original.id,
                    name: original.name,
                    baseURL: URL(string: "http://localhost:4321/v1")!,
                    modelID: original.modelID,
                    requiresAPIKey: true,
                    hosting: original.hosting,
                    dialect: original.dialect,
                    contextWindowTokens: original.contextWindowTokens,
                    bedrock: original.bedrock
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
        let original = fixture.endpoint()
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
                TextModelEndpoint(
                    id: original.id,
                    name: original.name,
                    baseURL: URL(string: "http://localhost:4321/v1")!,
                    modelID: original.modelID,
                    requiresAPIKey: true,
                    hosting: original.hosting,
                    dialect: original.dialect,
                    contextWindowTokens: original.contextWindowTokens,
                    bedrock: original.bedrock
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
        let original = fixture.endpoint()
        let seeded = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.store()
        )
        try seeded.upsert(original, apiKey: "sentinel-old")
        let old = try #require(seeded.endpoints.first)
        let edited = TextModelEndpoint(
            id: original.id,
            name: original.name,
            baseURL: URL(string: "http://localhost:4321/v1")!,
            modelID: original.modelID,
            requiresAPIKey: true,
            hosting: original.hosting,
            dialect: original.dialect,
            contextWindowTokens: original.contextWindowTokens,
            bedrock: original.bedrock
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
            case .revisionMigration:
                // Keine Benutzeraktion: die Revisionsmigration laeuft in der
                // Wiederherstellung und wird dort eigenstaendig geprueft. Taucht
                // sie hier auf, ist der Testfall falsch aufgesetzt.
                Issue.record("revisionMigration is not a user operation")
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
            configurationRevision: UUID(),
            hosting: .selfHosted,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )
        let next = TextModelEndpoint(
            id: old.id,
            name: "New endpoint",
            baseURL: URL(string: "http://localhost:4321/v1")!,
            modelID: "new-model",
            requiresAPIKey: true,
            configurationRevision: UUID(),
            hosting: .selfHosted,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
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
            registry: store
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
        Self(checkpoint: .deleteCurrentSecretRemoved, testDescription: "after current secret"),
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
        Self(operation: .delete, phase: .prepared, checkpoint: .afterRenameBeforeDirectorySync, expected: .old, testDescription: "delete prepared after rename"),
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

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
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
            "iOSAtomicTextModelSettingsTests-\(UUID().uuidString)",
            isDirectory: true
        )
        fileURL = root.appendingPathComponent("registry-state.json")
        suiteName = "iOSAtomicTextModelSettingsTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func endpoint() -> TextModelEndpoint {
        TextModelEndpoint(
            name: "Local model",
            baseURL: URL(string: "http://localhost:1234/v1")!,
            modelID: "gemma",
            requiresAPIKey: true,
            hosting: .selfHosted,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )
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
    let suiteName = "TextModelSettingsTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let secrets = InMemoryTextModelSecretStore()
    let registry: TestEndpointRegistry

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "iOSTextModelSettingsTests-\(UUID().uuidString)",
            isDirectory: true
        )
        fileURL = root.appendingPathComponent("registry-state.json")
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        registry = TestEndpointRegistry(fileURL: fileURL, defaults: defaults)
    }

    func endpoint(
        name: String = "Local model",
        id: UUID = UUID(),
        requiresAPIKey: Bool = true
    ) -> TextModelEndpoint {
        TextModelEndpoint(
            id: id,
            name: name,
            baseURL: URL(string: "http://localhost:1234/v1")!,
            modelID: "gemma",
            requiresAPIKey: requiresAPIKey,
            hosting: .selfHosted,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class InMemoryTextModelSecretStore: TextModelSecretStoring, @unchecked Sendable {
    private var values: [TextModelSecretSlot: String] = [:]
    var readError: (any Error)?
    var writeError: (any Error)?
    var deleteError: TestSecretStoreError?
    var deleteErrorSlots: Set<TextModelSecretSlot> = []
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
        if deleteErrorSlots.contains(slot) { throw TestSecretStoreError.deleteFailed }
        if let deleteError { throw deleteError }
        removedSlots.append(slot)
        values[slot] = nil
    }
}

private final class FailingRemovalSecretStore: TextModelSecretStoring, @unchecked Sendable {
    private var values: [TextModelSecretSlot: String] = [:]
    var refuseRemoval = false

    func value(for slot: TextModelSecretSlot) throws -> String? {
        values[slot]
    }

    func setValue(_ value: String, for slot: TextModelSecretSlot) throws {
        values[slot] = value
    }

    func removeValue(for slot: TextModelSecretSlot) throws {
        guard !refuseRemoval else { throw TestSecretStoreError.removalFailed }
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
    case deleteFailed
    case removalFailed
    case readFailed
    case writeFailed
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
