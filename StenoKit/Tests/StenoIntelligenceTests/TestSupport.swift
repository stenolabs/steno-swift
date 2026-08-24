import Foundation
import StenoDomain
@testable import StenoIntelligence

/// Bequemlichkeits-Factory fuer Tests: haelt sinnvolle Defaults fuer
/// hosting, dialect und contextWindowTokens, damit nicht jeder bestehende
/// Testaufruf sie einzeln nennen muss. Der Produktionsinitializer bleibt
/// bewusst ohne Defaults, siehe TextModelEndpoint.swift.
func makeTextModelEndpoint(
    id: UUID = UUID(),
    name: String,
    baseURL: URL,
    modelID: String,
    requiresAPIKey: Bool,
    configurationRevision: UUID? = nil,
    hosting: TextModelHosting = .selfHosted,
    dialect: TextModelAPIDialect = .openAICompatible,
    contextWindowTokens: Int = TextModelEndpoint.defaultContextWindowTokens,
    bedrock: AmazonBedrockConfiguration? = nil
) -> TextModelEndpoint {
    TextModelEndpoint(
        id: id,
        name: name,
        baseURL: baseURL,
        modelID: modelID,
        requiresAPIKey: requiresAPIKey,
        configurationRevision: configurationRevision,
        hosting: hosting,
        dialect: dialect,
        contextWindowTokens: contextWindowTokens,
        bedrock: bedrock
    )
}
