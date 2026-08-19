import Foundation
import StenoDomain

public typealias TextModelSecretResolving = @Sendable (UUID) throws -> String?

public struct TextModelEndpoint: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let baseURL: URL
    public let modelID: String
    public let requiresAPIKey: Bool
    public let configurationRevision: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        modelID: String,
        requiresAPIKey: Bool,
        configurationRevision: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelID = modelID
        self.requiresAPIKey = requiresAPIKey
        self.configurationRevision = configurationRevision
    }
}

public extension TextModelEndpoint {
    var snapshot: TextModelEndpointSnapshot {
        TextModelEndpointSnapshot(
            id: id,
            name: name,
            baseURL: baseURL,
            modelID: modelID,
            requiresAPIKey: requiresAPIKey,
            configurationRevision: configurationRevision
        )
    }

    init(snapshot: TextModelEndpointSnapshot) {
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            baseURL: snapshot.baseURL,
            modelID: snapshot.modelID,
            requiresAPIKey: snapshot.requiresAPIKey,
            configurationRevision: snapshot.configurationRevision
        )
    }

    /// Legacy snapshots predate configuration revisions and retain their
    /// original public-configuration matching contract.
    func matchesPinnedConfiguration(_ pinned: TextModelEndpointSnapshot) -> Bool {
        guard id == pinned.id,
              name == pinned.name,
              baseURL == pinned.baseURL,
              modelID == pinned.modelID,
              requiresAPIKey == pinned.requiresAPIKey
        else { return false }
        return pinned.configurationRevision == nil
            || configurationRevision == pinned.configurationRevision
    }
}

/// Non-secret address of the keychain entry belonging to one persisted
/// endpoint configuration. A nil revision denotes the legacy UUID-only slot.
public struct TextModelSecretSlot: Hashable, Sendable {
    public let endpointID: UUID
    public let configurationRevision: UUID?

    public init(endpointID: UUID, configurationRevision: UUID?) {
        self.endpointID = endpointID
        self.configurationRevision = configurationRevision
    }

    public init(endpoint: TextModelEndpoint) {
        self.init(
            endpointID: endpoint.id,
            configurationRevision: endpoint.configurationRevision
        )
    }

    public init(snapshot: TextModelEndpointSnapshot) {
        self.init(
            endpointID: snapshot.id,
            configurationRevision: snapshot.configurationRevision
        )
    }
}
