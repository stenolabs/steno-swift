import Foundation
import StenoDomain

public typealias TextModelSecretResolving = @Sendable (UUID) throws -> String?

public struct TextModelEndpoint: Codable, Equatable, Sendable {
    public static let defaultContextWindowTokens = 4_096
    public static let minimumContextWindowTokens = 4_096
    public static let maximumContextWindowTokens = 1_048_576

    public let id: UUID
    public let name: String
    public let baseURL: URL
    public let modelID: String
    public let requiresAPIKey: Bool
    public let configurationRevision: UUID?
    public let hosting: TextModelHosting
    public let dialect: TextModelAPIDialect
    public let contextWindowTokens: Int
    public let bedrock: AmazonBedrockConfiguration?

    /// Bewusst ohne Defaults fuer hosting, dialect und contextWindowTokens:
    /// jede Kopierstelle (upsert, migrateRevision, Draft-Erzeugung) muss die
    /// Werte des Ausgangsendpunkts ausdruecklich weiterreichen, sonst
    /// verliert ein vergessener Parameter die Nutzerwahl still. Nur bedrock
    /// bleibt optional, weil er ausschliesslich fuer den Dialekt
    /// amazonBedrock gilt.
    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        modelID: String,
        requiresAPIKey: Bool,
        configurationRevision: UUID? = nil,
        hosting: TextModelHosting,
        dialect: TextModelAPIDialect,
        contextWindowTokens: Int,
        bedrock: AmazonBedrockConfiguration? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelID = modelID
        self.requiresAPIKey = requiresAPIKey
        self.configurationRevision = configurationRevision
        self.hosting = hosting
        self.dialect = dialect
        self.contextWindowTokens = contextWindowTokens
        self.bedrock = bedrock
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case modelID
        case requiresAPIKey
        case configurationRevision
        case hosting
        case dialect
        case contextWindowTokens
        case bedrock
    }

    /// Toleranter Decode fuer bestehende, vor S4 gespeicherte Endpunkte:
    /// fehlendes hosting wird ueber die eine Inferenzstelle abgeleitet,
    /// fehlender dialect wird konservativ openAICompatible, fehlendes
    /// contextWindowTokens wird der Standardwert, fehlendes bedrock bleibt
    /// nil. Kein Port-Raten.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        modelID = try container.decode(String.self, forKey: .modelID)
        requiresAPIKey = try container.decode(Bool.self, forKey: .requiresAPIKey)
        configurationRevision = try container.decodeIfPresent(
            UUID.self,
            forKey: .configurationRevision
        )
        hosting = try container.decodeIfPresent(
            TextModelHosting.self,
            forKey: .hosting
        ) ?? TextModelEndpointPolicy.inferredHosting(for: baseURL)
        dialect = try container.decodeIfPresent(
            TextModelAPIDialect.self,
            forKey: .dialect
        ) ?? .openAICompatible
        contextWindowTokens = try container.decodeIfPresent(
            Int.self,
            forKey: .contextWindowTokens
        ) ?? Self.defaultContextWindowTokens
        bedrock = try container.decodeIfPresent(
            AmazonBedrockConfiguration.self,
            forKey: .bedrock
        )
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
            configurationRevision: configurationRevision,
            hosting: hosting,
            dialect: dialect
        )
    }

    /// bedrock und contextWindowTokens reisen nicht im Snapshot: fuer
    /// Pin-Treue genuegt configurationRevision, und die Anzeige braucht sie
    /// nicht. Ein Legacy-Pin ohne hosting/dialect bekommt konservative Werte
    /// (cloud statt Inferenz, openAICompatible), keine Vermutung.
    init(snapshot: TextModelEndpointSnapshot) {
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            baseURL: snapshot.baseURL,
            modelID: snapshot.modelID,
            requiresAPIKey: snapshot.requiresAPIKey,
            configurationRevision: snapshot.configurationRevision,
            hosting: snapshot.hosting ?? .cloud,
            dialect: snapshot.dialect ?? .openAICompatible,
            contextWindowTokens: Self.defaultContextWindowTokens,
            bedrock: nil
        )
    }

    /// Legacy snapshots predate configuration revisions and retain their
    /// original public-configuration matching contract. Nil-Felder eines
    /// Legacy-Pins werden nicht verglichen; der eigentliche Anker bleibt
    /// configurationRevision.
    func matchesPinnedConfiguration(_ pinned: TextModelEndpointSnapshot) -> Bool {
        guard id == pinned.id,
              name == pinned.name,
              baseURL == pinned.baseURL,
              modelID == pinned.modelID,
              requiresAPIKey == pinned.requiresAPIKey,
              pinned.hosting == nil || hosting == pinned.hosting,
              pinned.dialect == nil || dialect == pinned.dialect
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
