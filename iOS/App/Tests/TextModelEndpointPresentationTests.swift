import Foundation
import StenoIntelligence
import Testing
@testable import Steno

@Suite("Text model endpoint presentation")
struct TextModelEndpointPresentationTests {
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
            TextModelEndpointPresentation.plaintextWarning(for: endpoint)
                == "This connection is not encrypted."
        )
    }

    @Test("probe success distinguishes a configured model from a missing one")
    func probeSuccessDistinguishesModelAvailability() {
        #expect(
            TextModelEndpointPresentation.probeMessage(
                for: TextModelProbeResult(isReachable: true, isModelAvailable: true),
                modelID: "gemma"
            ) == "Reachable, model \"gemma\" is available."
        )
        #expect(
            TextModelEndpointPresentation.probeMessage(
                for: TextModelProbeResult(isReachable: true, isModelAvailable: false),
                modelID: "gemma"
            ) == "Reachable, but model \"gemma\" was not found."
        )
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
            requiresAPIKey: false
        )
    }
}

private struct PresentationError: LocalizedError {
    let description: String
    var errorDescription: String? { description }
}
