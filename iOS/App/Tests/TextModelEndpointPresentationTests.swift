import Foundation
import StenoDomain
import StenoIntelligence
import Testing
@testable import Steno

@Suite("Text model endpoint presentation")
struct TextModelEndpointPresentationTests {
    @Test("OpenAI-compatible endpoint fields have a deterministic focus order")
    func openAICompatibleEndpointFocusOrder() {
        let order = EndpointEditorFocusOrder(dialect: .openAICompatible)

        #expect(order.fields == [
            .name,
            .baseURL,
            .model,
            .contextWindow,
            .apiKey,
        ])
        #expect(order.next(after: .name) == .baseURL)
        #expect(order.next(after: .contextWindow) == .apiKey)
        #expect(order.next(after: .apiKey) == nil)
    }

    @Test("Bedrock endpoint fields skip the disabled URL")
    func bedrockEndpointFocusOrder() {
        let order = EndpointEditorFocusOrder(dialect: .amazonBedrock)

        #expect(order.fields == [
            .name,
            .inferenceProfile,
            .model,
            .contextWindow,
            .apiKey,
        ])
        #expect(!order.fields.contains(.baseURL))
        #expect(order.next(after: .name) == .inferenceProfile)
        #expect(order.next(after: .apiKey) == nil)
    }

    @Test("technical endpoint fields describe their input semantics")
    func endpointFieldSemantics() {
        let name = EndpointEditorField.name.inputConfiguration
        #expect(name.keyboard == .default)
        #expect(name.textContentType == .none)
        #expect(!name.autocorrectionDisabled)
        #expect(name.capitalization == .automatic)
        #expect(name.submitBehavior == .next)

        let baseURL = EndpointEditorField.baseURL.inputConfiguration
        #expect(baseURL.keyboard == .url)
        #expect(baseURL.textContentType == .url)
        #expect(baseURL.autocorrectionDisabled)
        #expect(baseURL.capitalization == .never)
        #expect(baseURL.submitBehavior == .next)

        for field in [EndpointEditorField.inferenceProfile, .model] {
            let configuration = field.inputConfiguration
            #expect(configuration.keyboard == .asciiCapable)
            #expect(configuration.autocorrectionDisabled)
            #expect(configuration.capitalization == .never)
            #expect(configuration.submitBehavior == .next)
        }

        let contextWindow = EndpointEditorField.contextWindow.inputConfiguration
        #expect(contextWindow.keyboard == .numberPad)
        #expect(contextWindow.autocorrectionDisabled)
        #expect(contextWindow.capitalization == .never)
        #expect(contextWindow.submitBehavior == .keyboardToolbar)

        let apiKey = EndpointEditorField.apiKey.inputConfiguration
        #expect(apiKey.keyboard == .asciiCapable)
        #expect(apiKey.autocorrectionDisabled)
        #expect(apiKey.capitalization == .never)
        #expect(apiKey.isSecure)
        #expect(apiKey.isPrivacySensitive)
        #expect(apiKey.submitBehavior == .done)
    }

    @Test("endpoint deletion copy names the endpoint, host, key consequence, and device")
    func endpointDeletionDisclosure() throws {
        let endpoint = try endpoint(url: "https://models.example.com/v1")
        let title = english(TextModelEndpointPresentation.deletionTitle(for: endpoint))
        let message = english(TextModelEndpointPresentation.deletionMessage(for: endpoint))

        #expect(title.contains(endpoint.name))
        #expect(message.contains(endpoint.baseURL.host() ?? ""))
        #expect(message.contains("saved API key"))
        #expect(message.contains("pinned"))
        #expect(message.contains("this device"))
        #expect(message.contains("cannot be undone"))
    }

    @Test("endpoint deletion stores the complete target until confirmation")
    func endpointDeletionStoresFullTarget() throws {
        let endpoint = try endpoint(url: "https://models.example.com/v1")
        var state = TextModelEndpointDeletionState()

        state.requestDeletion(of: endpoint)

        #expect(state.target == endpoint)
    }

    @Test("cancelling endpoint deletion never calls the transactional remove")
    func endpointDeletionCancelDoesNotMutate() throws {
        let endpoint = try endpoint(url: "https://models.example.com/v1")
        var state = TextModelEndpointDeletionState()
        var removeCalls = 0
        state.requestDeletion(of: endpoint)

        state.cancelDeletion()
        state.confirmDeletion { _ in removeCalls += 1 }

        #expect(state.target == nil)
        #expect(removeCalls == 0)
    }

    @Test("confirming endpoint deletion passes the complete target to remove")
    func endpointDeletionConfirmationUsesFullTarget() throws {
        let endpoint = try endpoint(url: "https://models.example.com/v1")
        var state = TextModelEndpointDeletionState()
        var removedEndpoint: TextModelEndpoint?
        state.requestDeletion(of: endpoint)

        state.confirmDeletion { removedEndpoint = $0 }

        #expect(removedEndpoint == endpoint)
        #expect(state.target == nil)
        #expect(state.failure == nil)
    }

    @Test("endpoint deletion keeps a failure visible after its row disappears")
    func endpointDeletionFailureOutlivesRemovedRow() throws {
        let endpoint = try endpoint(url: "https://models.example.com/v1")
        var endpoints = [endpoint]
        var state = TextModelEndpointDeletionState()
        state.requestDeletion(of: endpoint)

        state.confirmDeletion { removed in
            endpoints.removeAll { $0.id == removed.id }
            throw EndpointDeletionTestError.persistFailed
        }

        #expect(endpoints.isEmpty)
        #expect(state.target == nil)
        let failure = try #require(state.failure)
        #expect(failure.endpointID == endpoint.id)
        #expect(failure.endpointName == endpoint.name)
        #expect(failure.reason == EndpointDeletionTestError.persistFailed.localizedDescription)
        #expect(
            english(TextModelEndpointPresentation.deletionFailureMessage(failure))
                .contains("may already have been removed")
        )
    }

    @Test("a successful deletion only clears a failure for the same endpoint")
    func endpointDeletionSuccessPreservesAnotherEndpointsFailure() throws {
        let first = try endpoint(url: "https://first.example.com/v1")
        let second = try endpoint(url: "https://second.example.com/v1")
        var state = TextModelEndpointDeletionState()
        state.requestDeletion(of: first)
        state.confirmDeletion { _ in
            throw EndpointDeletionTestError.persistFailed
        }
        let firstFailure = try #require(state.failure)

        state.requestDeletion(of: second)
        state.confirmDeletion { _ in }

        #expect(state.failure == firstFailure)
        #expect(state.failure?.endpointID == first.id)
    }

    @Test("a successful retry clears the failure for the same endpoint")
    func endpointDeletionRetryClearsItsOwnFailure() throws {
        let endpoint = try endpoint(url: "https://models.example.com/v1")
        var state = TextModelEndpointDeletionState()
        state.requestDeletion(of: endpoint)
        state.confirmDeletion { _ in
            throw EndpointDeletionTestError.persistFailed
        }
        #expect(state.failure?.endpointID == endpoint.id)

        state.requestDeletion(of: endpoint)
        state.confirmDeletion { _ in }

        #expect(state.failure == nil)
    }

    @Test("saving an edited endpoint invalidates its previous probe result")
    func editingInvalidatesProbeResult() {
        let endpointID = UUID()
        var state = TextModelProbeState()
        let generation = state.beginProbe(for: endpointID)
        state.setResult("OLD_PROBE_RESULT", for: endpointID, generation: generation)

        state.endpointWasSaved(endpointID)

        #expect(state.result(for: endpointID) == nil)
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

    @Test("HTTPS endpoints do not show a plaintext warning")
    func encryptedEndpointHasNoPlaintextWarning() throws {
        let endpoint = try endpoint(url: "https://models.example.com/v1")

        #expect(TextModelEndpointPresentation.plaintextWarning(for: endpoint) == nil)
    }

    @Test("permitted local HTTP endpoints show a plaintext warning")
    func localPlaintextEndpointShowsWarning() throws {
        let endpoint = try endpoint(url: "http://localhost:1234/v1")

        #expect(
            TextModelEndpointPresentation.plaintextWarning(for: endpoint).map(english)
                == "This connection is not encrypted."
        )
    }

    @Test("probe success distinguishes a configured model from a missing one")
    func probeSuccessDistinguishesModelAvailability() {
        #expect(
            english(TextModelEndpointPresentation.probeMessage(
                for: TextModelProbeResult(
                    isReachable: true,
                    isModelAvailable: true,
                    supportsStructuredGeneration: true
                ),
                modelID: "gemma"
            )) == "Reachable, model \"gemma\" is available."
        )
        #expect(
            english(TextModelEndpointPresentation.probeMessage(
                for: TextModelProbeResult(isReachable: true, isModelAvailable: false),
                modelID: "gemma"
            )) == "Reachable, but model \"gemma\" was not found."
        )
    }

    @Test("probe requires structured output support")
    func probeRequiresStructuredOutput() {
        let message = english(TextModelEndpointPresentation.probeMessage(
            for: TextModelProbeResult(
                isReachable: true,
                isModelAvailable: true,
                supportsStructuredGeneration: false,
                configuredContextWindowTokens: 16_384,
                reportedContextWindowTokens: 8_192
            ),
            modelID: "gemma"
        ))

        #expect(message.contains("structured output"))
        #expect(
            message.contains(
                8_192.formatted(.number.locale(Locale(identifier: "en_US")))
            )
        )
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
    /// Lauf nach 192 Anfragen ab, mit 32768 lief er in zehn durch.
    @Test("the context window can be set and reaches the endpoint")
    @MainActor
    func contextWindowIsEditable() throws {
        let draft = EndpointDraft()
        draft.name = "Ollama"
        draft.modelID = "gemma4:12b"
        draft.urlText = "http://192.168.1.10:11434"
        draft.selectHosting(.selfHosted)
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
        draft.urlText = "http://192.168.1.10:11434"

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
        #expect(draft.nativeDialectSuggestion == nil)
    }

    @Test("a plain OpenAI-compatible address offers nothing")
    @MainActor
    func otherAddressOffersNothing() {
        let draft = EndpointDraft()
        draft.urlText = "http://localhost:1234/v1"
        #expect(draft.nativeDialectSuggestion == nil)
    }

    @Test("hosting follows the URL until the user chooses explicitly")
    @MainActor
    func hostingFollowsURLUntilExplicitChoice() {
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
        draft.updateHostingFromURLIfAutomatic()

        #expect(draft.urlText == "https://bedrock-runtime.eu-central-1.amazonaws.com")
        #expect(draft.hosting == .cloud)
        let validated = try #require(draft.validated)
        #expect(validated.dialect == .amazonBedrock)
        #expect(validated.bedrock == AmazonBedrockConfiguration(
            region: "eu-central-1",
            inferenceProfile: nil
        ))
    }

    @Test("a Bedrock draft whose base URL no longer matches its region fails validation")
    @MainActor
    func bedrockDraftWithMismatchedRegionFailsValidation() throws {
        let draft = EndpointDraft()
        draft.selectDialect(.amazonBedrock)
        draft.name = "Bedrock"
        draft.modelID = "anthropic.claude-3"
        draft.selectBedrockRegion("eu-central-1")
        draft.urlText = "https://bedrock-runtime.us-east-1.amazonaws.com"

        #expect(draft.validated == nil)
        #expect(draft.validationMessage != nil)
    }

    @Test("selecting a cloud dialect infers cloud hosting from its default base URL")
    @MainActor
    func cloudDialectDraftInfersCloudHosting() throws {
        let draft = EndpointDraft()

        draft.selectDialect(.anthropic)
        draft.updateHostingFromURLIfAutomatic()
        draft.name = "Anthropic"
        draft.modelID = "claude-sonnet"

        #expect(draft.hosting == .cloud)
        let validated = try #require(draft.validated)
        #expect(validated.dialect == .anthropic)
        #expect(validated.hosting == .cloud)
    }

    @Test("probe errors keep the provider's safe localized description")
    func probeErrorsUseLocalizedDescription() {
        let error = PresentationError(description: "Connection refused")

        #expect(
            TextModelEndpointPresentation.probeMessage(for: error) == "Connection refused"
        )
    }

    private func endpoint(url: String) throws -> TextModelEndpoint {
        TextModelEndpoint(
            name: "Model",
            baseURL: try #require(URL(string: url)),
            modelID: "gemma",
            requiresAPIKey: false,
            hosting: .selfHosted,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )
    }

    private func english(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }
}

private struct PresentationError: LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

private enum EndpointDeletionTestError: LocalizedError {
    case persistFailed

    var errorDescription: String? { "The registry could not be saved." }
}
