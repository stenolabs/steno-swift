import Foundation
import StenoDomain
@testable import StenoIntelligence
import Testing

@Suite("Amazon Bedrock endpoint policy")
struct AmazonBedrockEndpointPolicyTests {
    @Test("supported regions produce the exact AWS runtime host")
    func supportedRegionProducesCanonicalURL() throws {
        #expect(
            try AmazonBedrockEndpointPolicy.baseURL(region: "eu-central-1")
                .absoluteString
                == "https://bedrock-runtime.eu-central-1.amazonaws.com"
        )
    }

    @Test(
        "region values cannot escape the fixed AWS host",
        arguments: [
            "eu-central-1.example.com",
            "https://eu-central-1",
            "eu-central-1:443",
            "eu-central-1/path",
            "EU-CENTRAL-1",
            "",
        ]
    )
    func unsafeRegionIsRejected(_ region: String) {
        #expect(throws: TextModelEndpointPolicyError.invalidProviderConfiguration) {
            try AmazonBedrockEndpointPolicy.baseURL(region: region)
        }
    }

    @Test("persisted Bedrock URL must match its region")
    func persistedURLMustMatchRegion() {
        let endpoint = makeTextModelEndpoint(
            name: "Bedrock",
            baseURL: URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com")!,
            modelID: "model",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: .amazonBedrock,
            contextWindowTokens: 16_384,
            bedrock: AmazonBedrockConfiguration(
                region: "eu-central-1",
                inferenceProfile: nil
            )
        )

        #expect(throws: TextModelEndpointPolicyError.invalidProviderConfiguration) {
            try TextModelEndpointPolicy.validate(endpoint)
        }
    }

    @Test("inference profile takes precedence over the model ID")
    func inferenceProfileIsTheModelReference() throws {
        let endpoint = makeTextModelEndpoint(
            name: "Bedrock",
            baseURL: try AmazonBedrockEndpointPolicy.baseURL(region: "eu-central-1"),
            modelID: "fallback-model",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: .amazonBedrock,
            contextWindowTokens: 16_384,
            bedrock: AmazonBedrockConfiguration(
                region: "eu-central-1",
                inferenceProfile: "profile/with spaces"
            )
        )

        #expect(
            try AmazonBedrockEndpointPolicy.modelReference(for: endpoint)
                == "profile/with spaces"
        )
    }

    @Test("without an inference profile, the model ID is the model reference")
    func modelIDIsTheModelReferenceWhenNoProfileIsSet() throws {
        let endpoint = makeTextModelEndpoint(
            name: "Bedrock",
            baseURL: try AmazonBedrockEndpointPolicy.baseURL(region: "eu-central-1"),
            modelID: "anthropic.claude-3",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: .amazonBedrock,
            contextWindowTokens: 16_384,
            bedrock: AmazonBedrockConfiguration(region: "eu-central-1", inferenceProfile: nil)
        )

        #expect(
            try AmazonBedrockEndpointPolicy.modelReference(for: endpoint)
                == "anthropic.claude-3"
        )
    }

    @Test("modelReference fails closed without a Bedrock configuration")
    func modelReferenceRequiresBedrockConfiguration() {
        let endpoint = makeTextModelEndpoint(
            name: "Not Bedrock",
            baseURL: URL(string: "https://models.example.com/v1")!,
            modelID: "model",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: .openAICompatible,
            contextWindowTokens: 16_384
        )

        #expect(throws: TextModelEndpointPolicyError.invalidProviderConfiguration) {
            try AmazonBedrockEndpointPolicy.modelReference(for: endpoint)
        }
    }
}
