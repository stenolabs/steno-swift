import Foundation
import StenoDomain

public enum ReportTextModelDisplay: Equatable, Sendable {
    case apple
    case nativeGemma(NativeGemmaModelSnapshot)
    case external(TextModelEndpointSnapshot)
    case unavailableExternal(String)

    public static func resolve(
        isPending: Bool,
        pendingEndpointID: String?,
        pendingEndpointSnapshot: TextModelEndpointSnapshot?,
        pendingNativeGemmaModelSnapshot: NativeGemmaModelSnapshot? = nil,
        selectedEndpointSnapshot: TextModelEndpointSnapshot?,
        configuredEndpoints: [TextModelEndpoint]
    ) -> Self {
        guard isPending else {
            return selectedEndpointSnapshot.map(Self.external) ?? .apple
        }
        if let pendingEndpointSnapshot {
            return .external(pendingEndpointSnapshot)
        }
        if let pendingNativeGemmaModelSnapshot {
            return .nativeGemma(pendingNativeGemmaModelSnapshot)
        }
        guard let pendingEndpointID else { return .apple }
        if let pendingUUID = UUID(uuidString: pendingEndpointID),
           let endpoint = configuredEndpoints.first(where: { $0.id == pendingUUID }) {
            return .external(endpoint.snapshot)
        }
        return .unavailableExternal(pendingEndpointID)
    }

    /// Holt zu einer bereits getroffenen Endpunktwahl den aktuellen Stand aus
    /// der Registry. Die Wahl selbst bleibt, nur ihr Inhalt wird nachgezogen.
    ///
    /// Ohne das haelt eine offene Berichtsansicht die Kopie fest, die beim
    /// Oeffnen galt: wer danach in den Einstellungen etwas am Endpunkt
    /// aendert, reiht seinen Bericht weiter mit der alten Fassung ein, und die
    /// Pipeline weist ihn ab, weil die `configurationRevision` nicht mehr
    /// passt. Schwerer wiegt der zweite Weg: derselbe Snapshot speist den
    /// Hinweis, der dem Nutzer sagt, wohin sein Transkript geht. Eine
    /// veraltete Kopie nennt dort Adresse und Hosting von gestern.
    ///
    /// Ein Endpunkt, den es nicht mehr gibt, behaelt bewusst seinen alten
    /// Snapshot: sonst faellt die Ansicht stillschweigend auf Apple zurueck,
    /// und aus einer verschwundenen Wahl wuerde eine andere Wahl. So bleibt
    /// sie sichtbar und kann als nicht mehr verfuegbar gemeldet werden.
    public static func refreshedSelection(
        _ selection: TextModelEndpointSnapshot?,
        in endpoints: [TextModelEndpoint]
    ) -> TextModelEndpointSnapshot? {
        guard let selection else { return nil }
        return endpoints.first { $0.id == selection.id }?.snapshot ?? selection
    }

    public var endpointSnapshot: TextModelEndpointSnapshot? {
        guard case .external(let snapshot) = self else { return nil }
        return snapshot
    }

    public var usesExternalEndpoint: Bool {
        switch self {
        case .apple, .nativeGemma:
            false
        case .external, .unavailableExternal:
            true
        }
    }

    public var modelLabel: String {
        switch self {
        case .apple:
            "Apple Intelligence (on device)"
        case .nativeGemma(let snapshot):
            "Gemma · \(snapshot.modelIdentifier) (on device)"
        case .external(let snapshot):
            // Ein Legacy-Pin ohne hosting zeigt keinen Hosting-Zusatz,
            // niemals einen inferierten; "(external)" bleibt der neutrale
            // Rueckfall, der nichts ueber selfHosted/cloud behauptet.
            "\(snapshot.name) · \(snapshot.modelID) (\(snapshot.hosting?.displayName ?? "external"))"
        case .unavailableExternal:
            "External model (configuration unavailable)"
        }
    }
}
