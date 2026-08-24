import Foundation
import StenoDomain
import Testing
@testable import StenoIntelligence

@Suite("Text model endpoint hosting and dialect classification")
struct TextModelEndpointClassificationTests {
    @Test(
        "only provable loopback infers as self-hosted; everything else, including RFC1918, stays cloud",
        arguments: [
            ("http://localhost:1234/v1", TextModelHosting.selfHosted),
            ("http://127.0.0.1:1234/v1", TextModelHosting.selfHosted),
            ("http://127.42.0.1:1234/v1", TextModelHosting.selfHosted),
            ("http://[::1]:1234/v1", TextModelHosting.selfHosted),
            ("http://192.168.1.10:1234/v1", TextModelHosting.cloud),
            ("http://10.0.0.5:1234/v1", TextModelHosting.cloud),
            ("http://172.16.0.1:1234/v1", TextModelHosting.cloud),
            ("http://100.64.0.1:1234/v1", TextModelHosting.cloud),
            ("http://studio.local:1234/v1", TextModelHosting.cloud),
            ("http://macbook:1234/v1", TextModelHosting.cloud),
            ("http://[fc00::1]:1234/v1", TextModelHosting.cloud),
            ("https://api.openai.com/v1", TextModelHosting.cloud),
            ("https://models.example.com/v1", TextModelHosting.cloud),
        ]
    )
    func inferredHostingIsConservative(url: String, expected: TextModelHosting) throws {
        let endpoint = try #require(URL(string: url))

        #expect(TextModelEndpointPolicy.inferredHosting(for: endpoint) == expected)
    }

    @Test(
        "a host that only looks like loopback stays cloud",
        arguments: [
            // Der Praefix taeuscht: der eigentliche Host ist fremd.
            "http://127.0.0.1.example.com:1234/v1",
            "http://localhost.example.com:1234/v1",
            // Alternative Zahlenschreibweisen fuer 127.0.0.1. Sie werden nicht
            // als Adresse erkannt und fallen damit auf cloud, statt als lokal
            // durchzugehen.
            "http://0x7f.0.0.1:1234/v1",
            "http://2130706433:1234/v1",
            "http://127.1:1234/v1",
            // Ein Nutzername vor dem @ verschiebt den Host nach hinten.
            "http://127.0.0.1@example.com:1234/v1",
        ]
    )
    func lookalikeHostsStayCloud(url: String) throws {
        let endpoint = try #require(URL(string: url))

        #expect(TextModelEndpointPolicy.inferredHosting(for: endpoint) == .cloud)
    }

    @Test("a URL without a host infers as cloud, never as a guess")
    func missingHostInfersAsCloud() throws {
        let endpoint = try #require(URL(string: "file:///v1"))

        #expect(TextModelEndpointPolicy.inferredHosting(for: endpoint) == .cloud)
    }

    @Test("a stored endpoint missing hosting, dialect, contextWindowTokens and bedrock decodes conservatively")
    func legacyEndpointDecodesConservatively() throws {
        let json = """
        {
          "id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "name":"Legacy",
          "baseURL":"http://localhost:11434/v1",
          "modelID":"model",
          "requiresAPIKey":false
        }
        """

        let endpoint = try JSONDecoder().decode(
            TextModelEndpoint.self,
            from: Data(json.utf8)
        )

        #expect(endpoint.hosting == .selfHosted)
        #expect(endpoint.dialect == .openAICompatible)
        #expect(endpoint.contextWindowTokens == TextModelEndpoint.defaultContextWindowTokens)
        #expect(endpoint.bedrock == nil)
    }

    @Test("a legacy endpoint on a non-loopback host decodes as cloud, not a guess")
    func legacyEndpointOnRemoteHostDecodesAsCloud() throws {
        let json = """
        {
          "id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "name":"Legacy remote",
          "baseURL":"https://models.example.com/v1",
          "modelID":"model",
          "requiresAPIKey":false
        }
        """

        let endpoint = try JSONDecoder().decode(
            TextModelEndpoint.self,
            from: Data(json.utf8)
        )

        #expect(endpoint.hosting == .cloud)
    }

    @Test("an explicitly stored hosting and dialect round-trip without re-inference")
    func explicitFieldsRoundTrip() throws {
        let endpoint = TextModelEndpoint(
            name: "Explicit",
            baseURL: URL(string: "http://192.168.1.10:1234/v1")!,
            modelID: "model",
            requiresAPIKey: false,
            hosting: .selfHosted,
            dialect: .openAICompatible,
            contextWindowTokens: 8_192
        )

        let decoded = try JSONDecoder().decode(
            TextModelEndpoint.self,
            from: JSONEncoder().encode(endpoint)
        )

        #expect(decoded == endpoint)
        #expect(decoded.hosting == .selfHosted)
        #expect(decoded.contextWindowTokens == 8_192)
    }

    @Test("onDevice hosting is rejected for any configured endpoint")
    func onDeviceHostingIsRejected() {
        let endpoint = TextModelEndpoint(
            name: "Invalid",
            baseURL: URL(string: "https://models.example.com/v1")!,
            modelID: "model",
            requiresAPIKey: false,
            hosting: .onDevice,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )

        #expect(throws: TextModelEndpointPolicyError.invalidHosting) {
            try TextModelEndpointPolicy.validate(endpoint)
        }
    }

    @Test("a Bedrock configuration is rejected outside the Bedrock dialect")
    func bedrockConfigurationIsProviderScoped() {
        let endpoint = TextModelEndpoint(
            name: "Invalid",
            baseURL: URL(string: "https://models.example.com/v1")!,
            modelID: "model",
            requiresAPIKey: false,
            hosting: .cloud,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens,
            bedrock: AmazonBedrockConfiguration(region: "eu-central-1", inferenceProfile: nil)
        )

        #expect(throws: TextModelEndpointPolicyError.invalidProviderConfiguration) {
            try TextModelEndpointPolicy.validate(endpoint)
        }
    }

    @Test(
        "the local dialects unlocked in S5 pass validation",
        arguments: [TextModelAPIDialect.ollama, .lmStudio]
    )
    func localDialectsAreSupported(_ dialect: TextModelAPIDialect) throws {
        let endpoint = TextModelEndpoint(
            name: "Local",
            baseURL: URL(string: "http://localhost:11434")!,
            modelID: "model",
            requiresAPIKey: false,
            hosting: .selfHosted,
            dialect: dialect,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )

        let validated = try TextModelEndpointPolicy.validate(endpoint)
        #expect(validated.dialect == dialect)
    }

    @Test(
        "the cloud dialects unlocked in S6 pass validation",
        arguments: [TextModelAPIDialect.openAI, .anthropic]
    )
    func officialCloudDialectsAreSupported(_ dialect: TextModelAPIDialect) throws {
        let endpoint = TextModelEndpoint(
            name: "Cloud",
            baseURL: URL(string: "https://models.example.com/v1")!,
            modelID: "model",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: dialect,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )

        let validated = try TextModelEndpointPolicy.validate(endpoint)
        #expect(validated.dialect == dialect)
    }

    @Test("Amazon Bedrock with a matching configuration passes validation")
    func bedrockDialectWithConfigurationIsSupported() throws {
        let endpoint = TextModelEndpoint(
            name: "Bedrock",
            baseURL: URL(string: "https://bedrock-runtime.eu-central-1.amazonaws.com")!,
            modelID: "anthropic.claude-3",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: .amazonBedrock,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens,
            bedrock: AmazonBedrockConfiguration(region: "eu-central-1", inferenceProfile: nil)
        )

        let validated = try TextModelEndpointPolicy.validate(endpoint)
        #expect(validated.dialect == .amazonBedrock)
    }

    @Test("Amazon Bedrock without a bedrock configuration fails closed")
    func bedrockDialectWithoutConfigurationIsRejected() {
        let endpoint = TextModelEndpoint(
            name: "Bedrock",
            baseURL: URL(string: "https://bedrock-runtime.eu-central-1.amazonaws.com")!,
            modelID: "anthropic.claude-3",
            requiresAPIKey: true,
            hosting: .cloud,
            dialect: .amazonBedrock,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens,
            bedrock: nil
        )

        #expect(throws: TextModelEndpointPolicyError.invalidProviderConfiguration) {
            try TextModelEndpointPolicy.validate(endpoint)
        }
    }

    @Test(
        "context windows outside the supported range fail closed",
        arguments: [0, 1_024, 4_095, 1_048_577]
    )
    func rejectsInvalidContextWindows(tokens: Int) {
        let endpoint = TextModelEndpoint(
            name: "Local",
            baseURL: URL(string: "http://localhost:1234/v1")!,
            modelID: "model",
            requiresAPIKey: false,
            hosting: .selfHosted,
            dialect: .openAICompatible,
            contextWindowTokens: tokens
        )

        #expect(throws: TextModelEndpointPolicyError.invalidContextWindow) {
            try TextModelEndpointPolicy.validate(endpoint)
        }
    }
}
