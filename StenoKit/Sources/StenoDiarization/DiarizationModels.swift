import Foundation
import StenoDomain

public struct DiarizationHints: Codable, Equatable, Sendable {
    public let minimumSpeakerCount: Int?

    public init(minimumSpeakerCount: Int? = nil) {
        self.minimumSpeakerCount = minimumSpeakerCount
    }
}

public struct DiarizationSegment: Codable, Equatable, Sendable {
    public let clusterID: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(clusterID: String, start: TimeInterval, end: TimeInterval) {
        self.clusterID = clusterID
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval {
        end - start
    }
}

public struct DiarizationOutput: Codable, Equatable, Sendable {
    public let segments: [DiarizationSegment]
    public let embeddings: [String: [Float]]
    public let engine: EngineDescriptor

    public init(
        segments: [DiarizationSegment],
        embeddings: [String: [Float]],
        engine: EngineDescriptor
    ) {
        self.segments = segments
        self.embeddings = embeddings
        self.engine = engine
    }
}

public protocol DiarizationProvider: Sendable {
    var descriptor: EngineDescriptor { get }
    func diarize(_ url: URL, hints: DiarizationHints) async throws -> DiarizationOutput
}

public enum DiarizationComputeUnits: String, Codable, CaseIterable, Sendable {
    case all
    case cpuAndGPU
    case cpuOnly
    case cpuAndNeuralEngine
}

public enum DiarizationError: Error, Equatable, LocalizedError, Sendable {
    case audioDecodingFailed(String)
    case emptyAudio
    case modelsNotInstalled(missing: [String])
    case modelInstallationFailed(String)
    case modelLoadingFailed(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .audioDecodingFailed(let reason):
            return "Could not decode audio as 16 kHz mono Float: \(reason)"
        case .emptyAudio:
            return "The audio file contains no decodable samples."
        case .modelsNotInstalled(let missing):
            return "The speaker separation models are not installed yet (missing: \(missing.joined(separator: ", "))). Install them in Steno's settings."
        case .modelInstallationFailed(let reason):
            return "Diarization model installation failed: \(reason)"
        case .modelLoadingFailed(let reason):
            return "Installed diarization models could not be loaded: \(reason)"
        case .inferenceFailed(let reason):
            return "FluidAudio diarization failed: \(reason)"
        }
    }
}
