import Foundation
import StenoDomain

public struct TemplateRenderArtifact: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let jobID: JobID
    public let templateID: String
    public let result: TemplateResult

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        jobID: JobID,
        templateID: String,
        result: TemplateResult
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.templateID = templateID
        self.result = result
    }
}
