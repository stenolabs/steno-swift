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

    private func snapshot(
        id: UUID = UUID(),
        name: String,
        url: String = "https://models.example.test/v1",
        modelID: String = "model-v1"
    ) -> TextModelEndpointSnapshot {
        TextModelEndpointSnapshot(
            id: id,
            name: name,
            baseURL: URL(string: url)!,
            modelID: modelID,
            requiresAPIKey: true
        )
    }
}
