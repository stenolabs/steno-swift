import Foundation
import StenoDomain
import Testing
@testable import StenoIntelligence

@Suite("Report text model display")
struct ReportTextModelDisplayTests {
    @Test("a pending snapshot owns both model label and disclosure endpoint")
    func pendingSnapshotWinsOverGlobalSelectionAndMutatedRegistry() {
        let endpointID = UUID()
        let pinned = snapshot(
            id: endpointID,
            name: "Pinned endpoint",
            url: "https://pinned.example.test/v1",
            modelID: "pinned-model"
        )
        let selectedElsewhere = snapshot(
            name: "Other scene",
            url: "https://other.example.test/v1",
            modelID: "other-model"
        )
        let mutatedCurrent = TextModelEndpoint(snapshot: snapshot(
            id: endpointID,
            name: "Mutated endpoint",
            url: "https://mutated.example.test/v1",
            modelID: "mutated-model"
        ))

        let display = ReportTextModelDisplay.resolve(
            isPending: true,
            pendingEndpointID: endpointID.uuidString,
            pendingEndpointSnapshot: pinned,
            selectedEndpointSnapshot: selectedElsewhere,
            configuredEndpoints: [mutatedCurrent]
        )

        #expect(display == .external(pinned))
        #expect(display.modelLabel == "Pinned endpoint · pinned-model (external)")
        #expect(display.endpointSnapshot?.baseURL.host() == "pinned.example.test")
    }

    @Test("a legacy pending external ID resolves by its own ID")
    func legacyPendingIDDoesNotUseGlobalSelection() {
        let pending = TextModelEndpoint(snapshot: snapshot(name: "Legacy pending"))
        let selectedElsewhere = snapshot(name: "Other scene")

        let display = ReportTextModelDisplay.resolve(
            isPending: true,
            pendingEndpointID: pending.id.uuidString,
            pendingEndpointSnapshot: nil,
            selectedEndpointSnapshot: selectedElsewhere,
            configuredEndpoints: [pending]
        )

        #expect(display == .external(pending.snapshot))
    }

    @Test("a missing legacy external endpoint is explicit instead of Apple fallback")
    func missingLegacyEndpointIsExplicit() {
        let endpointID = UUID().uuidString

        let display = ReportTextModelDisplay.resolve(
            isPending: true,
            pendingEndpointID: endpointID,
            pendingEndpointSnapshot: nil,
            selectedEndpointSnapshot: nil,
            configuredEndpoints: []
        )

        #expect(display == .unavailableExternal(endpointID))
        #expect(display.usesExternalEndpoint)
        #expect(display.endpointSnapshot == nil)
    }

    @Test("a snapshot with hosting shows the hosting classification, not a generic label")
    func modelLabelShowsHostingWhenKnown() {
        let cloudSnapshot = snapshot(name: "Cloud model", hosting: .cloud)
        let selfHostedSnapshot = snapshot(name: "Self-hosted model", hosting: .selfHosted)

        #expect(
            ReportTextModelDisplay.external(cloudSnapshot).modelLabel
                == "Cloud model · model-v1 (Cloud service)"
        )
        #expect(
            ReportTextModelDisplay.external(selfHostedSnapshot).modelLabel
                == "Self-hosted model · model-v1 (Self-hosted)"
        )
    }

    @Test("a legacy pin without hosting shows no hosting addendum, never an inferred one")
    func modelLabelOmitsHostingForLegacyPin() {
        let legacy = snapshot(name: "Legacy pin", hosting: nil)

        #expect(
            ReportTextModelDisplay.external(legacy).modelLabel
                == "Legacy pin · model-v1 (external)"
        )
    }

    /// Der gemessene Fall: der Endpunkt wechselte von der OpenAI-Schicht auf
    /// den Ollama-Dialekt, waehrend die Berichtsansicht offen war. Die alte
    /// Kopie nannte danach weiter `/v1` und "cloud" - im Job, der daran
    /// scheiterte, und im Hinweis, der dem Nutzer das Ziel nennt.
    @Test("a selected endpoint follows the registry after it was edited")
    func selectionFollowsEditedRegistry() throws {
        let endpointID = UUID()
        let stale = snapshot(
            id: endpointID,
            name: "Ollama 4070 Ti",
            url: "http://192.168.1.10:11434/v1",
            hosting: .cloud
        )
        let edited = TextModelEndpoint(
            id: endpointID,
            name: "Ollama 4070 Ti",
            baseURL: URL(string: "http://192.168.1.10:11434")!,
            modelID: "gemma4:12b",
            requiresAPIKey: false,
            hosting: .selfHosted,
            dialect: .ollama,
            contextWindowTokens: 4_096,
            bedrock: nil
        )

        let refreshed = try #require(ReportTextModelDisplay.refreshedSelection(
            stale,
            in: [edited]
        ))
        #expect(refreshed.baseURL.absoluteString == "http://192.168.1.10:11434")
        #expect(refreshed.hosting == .selfHosted)
    }

    /// Ein verschwundener Endpunkt darf nicht zu einer anderen Wahl werden.
    @Test("a selection whose endpoint is gone keeps its snapshot")
    func vanishedEndpointKeepsItsSnapshot() throws {
        let stale = snapshot(name: "Removed endpoint")

        let kept = try #require(ReportTextModelDisplay.refreshedSelection(stale, in: []))
        #expect(kept == stale)
    }

    @Test("the on-device choice stays the on-device choice")
    func onDeviceSelectionStaysNil() {
        #expect(ReportTextModelDisplay.refreshedSelection(nil, in: []) == nil)
    }

    @Test("a pending native Gemma job stays on device and never exposes an endpoint")
    func nativeGemmaHasNoExternalDisclosure() {
        let native = NativeGemmaModelSnapshot(
            modelIdentifier: "mlx-community/gemma-4-e4b-it-4bit",
            checkpointRevision: String(repeating: "9", count: 40),
            adapterRevision: String(repeating: "b", count: 40),
            licenseIdentifier: "gemma",
            manifestSHA256: String(repeating: "a", count: 64)
        )

        let display = ReportTextModelDisplay.resolve(
            isPending: true,
            pendingEndpointID: NativeGemmaModelSnapshot.reservedTextModelEndpointID,
            pendingEndpointSnapshot: nil,
            pendingNativeGemmaModelSnapshot: native,
            selectedEndpointSnapshot: snapshot(name: "External"),
            configuredEndpoints: []
        )

        #expect(display == .nativeGemma(native))
        #expect(!display.usesExternalEndpoint)
        #expect(display.endpointSnapshot == nil)
        #expect(display.modelLabel.contains("on device"))
    }

    private func snapshot(
        id: UUID = UUID(),
        name: String,
        url: String = "https://models.example.test/v1",
        modelID: String = "model-v1",
        hosting: TextModelHosting? = nil
    ) -> TextModelEndpointSnapshot {
        TextModelEndpointSnapshot(
            id: id,
            name: name,
            baseURL: URL(string: url)!,
            modelID: modelID,
            requiresAPIKey: true,
            hosting: hosting
        )
    }
}
