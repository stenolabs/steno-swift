import Foundation

public enum AmazonBedrockEndpointPolicy {
    public static let supportedRegions: [String] = [
        "ap-northeast-1", "ap-northeast-2", "ap-south-1",
        "ap-southeast-1", "ap-southeast-2",
        "ca-central-1",
        "eu-central-1", "eu-central-2", "eu-north-1",
        "eu-west-1", "eu-west-2", "eu-west-3",
        "sa-east-1",
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
    ]

    public static func baseURL(region: String) throws -> URL {
        guard supportedRegions.contains(region),
              let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com")
        else {
            throw TextModelEndpointPolicyError.invalidProviderConfiguration
        }
        return url
    }

    public static func modelReference(for endpoint: TextModelEndpoint) throws -> String {
        guard let configuration = endpoint.bedrock else {
            throw TextModelEndpointPolicyError.invalidProviderConfiguration
        }
        let candidate = configuration.inferenceProfile?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate, !candidate.isEmpty {
            return candidate
        }
        let model = endpoint.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw TextModelEndpointPolicyError.invalidProviderConfiguration
        }
        return model
    }
}
