import Foundation
import StenoDomain

public enum ReportTextModelDisplay: Equatable, Sendable {
    case apple
    case external(TextModelEndpointSnapshot)
    case unavailableExternal(String)

    public static func resolve(
        isPending: Bool,
        pendingEndpointID: String?,
        pendingEndpointSnapshot: TextModelEndpointSnapshot?,
        selectedEndpointSnapshot: TextModelEndpointSnapshot?,
        configuredEndpoints: [TextModelEndpoint]
    ) -> Self {
        guard isPending else {
            return selectedEndpointSnapshot.map(Self.external) ?? .apple
        }
        if let pendingEndpointSnapshot {
            return .external(pendingEndpointSnapshot)
        }
        guard let pendingEndpointID else { return .apple }
        if let pendingUUID = UUID(uuidString: pendingEndpointID),
           let endpoint = configuredEndpoints.first(where: { $0.id == pendingUUID }) {
            return .external(endpoint.snapshot)
        }
        return .unavailableExternal(pendingEndpointID)
    }

    public var endpointSnapshot: TextModelEndpointSnapshot? {
        guard case .external(let snapshot) = self else { return nil }
        return snapshot
    }

    public var usesExternalEndpoint: Bool {
        switch self {
        case .apple:
            false
        case .external, .unavailableExternal:
            true
        }
    }

    public var modelLabel: String {
        switch self {
        case .apple:
            "Apple Intelligence (on device)"
        case .external(let snapshot):
            "\(snapshot.name) · \(snapshot.modelID) (external)"
        case .unavailableExternal:
            "External model (configuration unavailable)"
        }
    }
}
