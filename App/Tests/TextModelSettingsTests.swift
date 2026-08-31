import Foundation
import StenoDomain
import StenoIntelligence
import StenoPipeline
import Testing
@testable import steno_macos

@Suite("Mac text model settings")
@MainActor
struct TextModelSettingsTests {
    @Test("native Gemma selection fails closed instead of resolving Foundation Models")
    func nativeGemmaSelectionFailsClosed() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let selection = TextModelProviderSelection(
            endpointID: NativeGemmaModelSnapshot.reservedTextModelEndpointID,
            nativeGemmaModelSnapshot: nativeGemmaSnapshot()
        )

        #if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
        #expect(throws: NativeGemmaTextModelProviderError.modelNotApproved) {
            _ = try TextModelSettings.makeProviderResolver(
                defaults: fixture.defaults,
                secrets: fixture.secrets,
                registry: fixture.registry
            )(selection)
        }
        #else
        #expect(throws: PipelineError.nativeGemmaProviderUnavailable) {
            _ = try TextModelSettings.makeProviderResolver(
                defaults: fixture.defaults,
                secrets: fixture.secrets,
                registry: fixture.registry
            )(selection)
        }
        #endif
    }

    @Test("endpoint deletion names the keychain consequence before removal")
    func endpointDeletionDisclosure() {
        let endpoint = endpoint(requiresAPIKey: true)

        #expect(
            english(MacTextModelEndpointPresentation.deletionTitle)
                == "Delete endpoint?"
        )
        #expect(
            english(MacTextModelEndpointPresentation.deletionMessage(for: endpoint))
                == "Deleting “Local model” removes its configuration and saved API key from this Mac. This cannot be undone."
        )
    }

    @Test("endpoint deletion failure remains visible after its row disappears")
    func endpointDeletionFailureOutlivesRemovedRow() throws {
        let endpoint = endpoint(requiresAPIKey: true)
        var endpoints = [endpoint]
        var state = MacTextModelEndpointDeletionState()
        state.requestDeletion(of: endpoint)

        state.confirmDeletion { removed in
            endpoints.removeAll { $0.id == removed.id }
            throw TestRegistryError.persistFailed
        }

        #expect(endpoints.isEmpty)
        #expect(state.target == nil)
        let failure = try #require(state.failure)
        #expect(failure.endpointName == endpoint.name)
        #expect(failure.reason == TestRegistryError.persistFailed.localizedDescription)
        #expect(
            english(MacTextModelEndpointPresentation.deletionFailureMessage(failure))
                .contains("may already have been removed")
        )
    }

    private func english(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }

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

    @Test("a legacy endpoint copies its key without removing the legacy slot")
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
        let legacy = endpoint(requiresAPIKey: true)
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

    @Test("dialect selection applies local defaults and survives validation")
    @MainActor
    func dialectSelectionAppliesDefaults() throws {
        let draft = EndpointDraft()

        #expect(draft.dialect == .openAICompatible)

        draft.selectDialect(.ollama)
        #expect(draft.urlText == "http://localhost:11434")
        draft.name = "Ollama"
        draft.modelID = "gemma4:12b"
        #expect(try #require(draft.validated).dialect == .ollama)

        draft.selectDialect(.lmStudio)
        #expect(draft.urlText == "http://localhost:1234/v1")
        #expect(try #require(draft.validated).dialect == .lmStudio)
    }

    /// Der Startwert gehoert zum Dialekt. 4096 reichen fuer eine laengere
    /// Besprechung nicht, aber nur bei Ollama kann Steno die Groesse per
    /// `num_ctx` auch durchsetzen - anderswo waere ein grosser Wert eine
    /// Behauptung ueber einen Server, der davon nichts weiss.
    @Test("switching to Ollama brings a usable context window along")
    @MainActor
    func ollamaDialectRaisesTheContextWindow() {
        let draft = EndpointDraft()
        #expect(draft.contextWindowText == "4096")

        draft.selectDialect(.ollama)
        #expect(draft.contextWindowText == "32768")

        draft.selectDialect(.lmStudio)
        #expect(draft.contextWindowText == "4096")
    }

    /// Auch ueber den Vorschlag im Editor, sonst haette der Knopf den halben
    /// Weg zurueckgelegt.
    @Test("accepting the Ollama suggestion brings the context window along")
    @MainActor
    func ollamaSuggestionRaisesTheContextWindow() {
        let draft = EndpointDraft()
        draft.urlText = "http://192.168.1.10:11434/v1"

        draft.applyNativeDialectSuggestion()
        #expect(draft.dialect == .ollama)
        #expect(draft.contextWindowText == "32768")
    }

    /// Ein bestehender Endpunkt behaelt seinen Wert: der Editor oeffnet ihn
    /// zum Bearbeiten, nicht um ihn zu ueberschreiben.
    @Test("editing an existing endpoint keeps its context window")
    @MainActor
    func editingKeepsTheStoredContextWindow() throws {
        let stored = TextModelEndpoint(
            id: UUID(),
            name: "Ollama 4070 Ti",
            baseURL: try #require(URL(string: "http://192.168.1.10:11434")),
            modelID: "gemma4:12b",
            requiresAPIKey: false,
            hosting: .selfHosted,
            dialect: .ollama,
            contextWindowTokens: 16_384,
            bedrock: nil
        )

        let draft = EndpointDraft(stored)
        #expect(draft.contextWindowText == "16384")
    }

    /// Gemessen an einer Besprechung von 3:37 h: mit 4096 Token brach der
    /// Lauf nach 192 Anfragen ab, weil die Zwischenergebnisse nicht mehr zu
    /// zweit in eine Anfrage passten; mit 32768 lief er in zehn Anfragen
    /// durch. Deshalb muss der Wert einstellbar sein.
    @Test("the context window can be set and reaches the endpoint")
    @MainActor
    func contextWindowIsEditable() throws {
        let draft = EndpointDraft()
        draft.name = "Ollama"
        draft.modelID = "gemma4:12b"
        #expect(draft.contextWindowText == "4096")

        draft.contextWindowText = "32768"
        #expect(try #require(draft.validated).contextWindowTokens == 32_768)
    }

    /// Kein stilles Zurechtbiegen: ein unbrauchbarer Wert blockiert das
    /// Speichern, statt heimlich durch einen anderen ersetzt zu werden.
    @Test("an out-of-range context window blocks saving")
    @MainActor
    func invalidContextWindowBlocksSaving() {
        let draft = EndpointDraft()
        draft.name = "Ollama"
        draft.modelID = "gemma4:12b"

        for text in ["100", "0", "", "viele", "2000000"] {
            draft.contextWindowText = text
            #expect(draft.contextWindowTokens == nil, "\(text) sollte ungueltig sein")
            #expect(draft.validated == nil, "\(text) sollte nicht speicherbar sein")
        }
    }

    /// Die Adresse behaelt ihren Host: `selectDialect` wuerde sie durch
    /// `http://localhost:11434` ersetzen, und ein Ollama im Netz waere weg.
    @Test("an Ollama address offers the native dialect and keeps its host")
    @MainActor
    func ollamaAddressOffersNativeDialect() throws {
        let draft = EndpointDraft()
        draft.urlText = "http://192.168.1.10:11434/v1"

        #expect(draft.nativeDialectSuggestion?.dialect == .ollama)

        draft.applyNativeDialectSuggestion()
        #expect(draft.dialect == .ollama)
        #expect(draft.urlText == "http://192.168.1.10:11434")
        // Nach dem Umstellen ist nichts mehr anzubieten.
        #expect(draft.nativeDialectSuggestion == nil)
    }

    @Test("a plain OpenAI-compatible address offers nothing")
    @MainActor
    func otherAddressOffersNothing() throws {
        let draft = EndpointDraft()
        draft.urlText = "http://localhost:1234/v1"
        #expect(draft.nativeDialectSuggestion == nil)
    }

    @Test("hosting follows the URL until the user chooses explicitly")
    @MainActor
    func hostingFollowsURLUntilExplicitChoice() throws {
        let draft = EndpointDraft()
        #expect(draft.hosting == .selfHosted)

        draft.urlText = "https://models.example.com/v1"
        draft.updateHostingFromURLIfAutomatic()
        #expect(draft.hosting == .cloud)

        draft.selectHosting(.selfHosted)
        draft.urlText = "https://another.example.com/v1"
        draft.updateHostingFromURLIfAutomatic()
        #expect(draft.hosting == .selfHosted)
    }

    @Test("selecting a Bedrock region binds the base URL to the AWS host for that region")
    @MainActor
    func selectingBedrockRegionBindsBaseURL() throws {
        let draft = EndpointDraft()
        draft.selectDialect(.amazonBedrock)
        draft.name = "Bedrock"
        draft.modelID = "anthropic.claude-3"

        draft.selectBedrockRegion("eu-central-1")

        #expect(draft.urlText == "https://bedrock-runtime.eu-central-1.amazonaws.com")
        let validated = try #require(draft.validated)
        #expect(validated.dialect == .amazonBedrock)
        #expect(validated.bedrock == AmazonBedrockConfiguration(
            region: "eu-central-1",
            inferenceProfile: nil
        ))
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

    @Test("a newly created cloud-dialect endpoint saves with cloud hosting")
    func cloudDialectEndpointSavesAsCloud() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let settings = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        let draft = EndpointDraft()
        draft.selectDialect(.anthropic)
        draft.updateHostingFromURLIfAutomatic()
        draft.name = "Anthropic"
        draft.modelID = "claude-sonnet"
        let endpoint = try #require(draft.validated)

        try settings.upsert(endpoint, apiKey: "sentinel-anthropic")

        let saved = try #require(settings.endpoints.first)
        #expect(saved.hosting == .cloud)
        #expect(saved.dialect == .anthropic)
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
        #expect(try fixture.registry.load().journal == nil)
        #expect(
            fixture.defaults.string(forKey: TextModelSettings.selectionDefaultsKey)
                == original.id.uuidString
        )
    }

    @Test("a failed first-slot delete and rollback write recover without deletion")
    func firstSlotAndRollbackPersistenceFailureRecoverSafely() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let original = endpoint(requiresAPIKey: true)
        let seeded = TextModelSettings(
            defaults: fixture.defaults,
            secrets: fixture.secrets,
            registry: fixture.registry
        )
        try seeded.upsert(original, apiKey: "sentinel-current")
        let persisted = try #require(seeded.endpoints.first)
        seeded.selectedEndpointID = persisted.id
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
        #expect(cold.selectedEndpointID == persisted.id)
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
        let original = endpoint(requiresAPIKey: true)
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
        if testCase.checkpoint == .deleteJournalPersisted {
            #expect(cold.endpoints == [persisted])
            #expect(cold.selectedEndpointID == persisted.id)
            #expect(
                try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persisted))
                    == "sentinel-delete"
            )
            #expect(
                fixture.defaults.string(forKey: TextModelSettings.selectionDefaultsKey)
                    == persisted.id.uuidString
            )
        } else {
            #expect(cold.endpoints.isEmpty)
            #expect(cold.selectedEndpointID == nil)
            #expect(
                try fixture.secrets.value(for: TextModelSecretSlot(endpoint: persisted)) == nil
            )
            #expect(fixture.defaults.string(forKey: TextModelSettings.selectionDefaultsKey) == nil)
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
            requiresAPIKey: requiresAPIKey,
            hosting: .selfHosted,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )
    }

}

private func nativeGemmaSnapshot() -> NativeGemmaModelSnapshot {
    NativeGemmaModelSnapshot(
        modelIdentifier: "mlx-community/gemma-4-e4b-it-4bit",
        checkpointRevision: String(repeating: "9", count: 40),
        adapterRevision: String(repeating: "b", count: 40),
        licenseIdentifier: "gemma",
        manifestSHA256: String(repeating: "a", count: 64)
    )
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
