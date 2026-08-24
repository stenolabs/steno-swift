import Foundation

/// Secret-free identity of the external text-model configuration that was
/// visible when a report job was created.
public struct TextModelEndpointSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let baseURL: URL
    public let modelID: String
    public let requiresAPIKey: Bool
    public let configurationRevision: UUID?
    /// nil bedeutet ein Legacy-Pin von vor der Hosting-Klassifikation; ein
    /// Legacy-Pin zeigt keinen Hosting-Zusatz, niemals einen inferierten.
    public let hosting: TextModelHosting?
    public let dialect: TextModelAPIDialect?

    public init(
        id: UUID,
        name: String,
        baseURL: URL,
        modelID: String,
        requiresAPIKey: Bool,
        configurationRevision: UUID? = nil,
        hosting: TextModelHosting? = nil,
        dialect: TextModelAPIDialect? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelID = modelID
        self.requiresAPIKey = requiresAPIKey
        self.configurationRevision = configurationRevision
        self.hosting = hosting
        self.dialect = dialect
    }
}
