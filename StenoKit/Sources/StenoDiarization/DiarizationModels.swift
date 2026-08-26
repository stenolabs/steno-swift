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

public enum DiarizationProgressPhase: String, Equatable, Sendable {
    case loadingAudio
    case segmenting
    case clustering
    case writing
}

public struct DiarizationProgress: Equatable, Sendable {
    public let phase: DiarizationProgressPhase
    /// Completion ratio in 0...1 where computable; nil while the underlying
    /// call (e.g. one opaque CoreML segmentation pass) exposes no progress.
    public let fraction: Double?
    /// Monotonic seconds since the diarize call started.
    public let elapsed: TimeInterval

    public init(phase: DiarizationProgressPhase, fraction: Double?, elapsed: TimeInterval) {
        self.phase = phase
        self.fraction = fraction
        self.elapsed = elapsed
    }
}

public typealias DiarizationProgressHandler = @Sendable (DiarizationProgress) -> Void


/// Drives `DiarizationProgress` emission for a single diarize run.
///
/// Time source and sleep are injected so tests can produce ordered phases
/// and segmenting heartbeats with fake ticks instead of wall-clock waits.
struct DiarizationProgressEmitter: Sendable {
    let handler: DiarizationProgressHandler?
    let now: @Sendable () -> TimeInterval
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let heartbeatInterval: TimeInterval

    init(
        handler: DiarizationProgressHandler?,
        now: @escaping @Sendable () -> TimeInterval = { Self.monotonicNow() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        },
        heartbeatInterval: TimeInterval = 2.0
    ) {
        self.handler = handler
        self.now = now
        self.sleep = sleep
        self.heartbeatInterval = heartbeatInterval
    }

    static func monotonicNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func emit(_ phase: DiarizationProgressPhase, fraction: Double? = nil) {
        guard let handler else { return }
        handler(
            DiarizationProgress(
                phase: phase,
                fraction: fraction,
                elapsed: now()
            )
        )
    }

    /// Runs the opaque segmentation call while emitting an initial
    /// `.segmenting` event and time-based heartbeats every ~2 s. Heartbeats
    /// stop before `body` returns so later phases stay strictly ordered.
    func withSegmentingHeartbeats(_ body: () async throws -> Void) async rethrows {
        guard handler != nil else {
            return try await body()
        }
        let startedAt = now()
        emit(.segmenting)
        let heartbeats = Task {
            while !Task.isCancelled {
                do {
                    try await sleep(heartbeatInterval)
                } catch {
                    break
                }
                handler?(
                    DiarizationProgress(
                        phase: .segmenting,
                        fraction: nil,
                        elapsed: now() - startedAt
                    )
                )
            }
        }
        do {
            try await body()
        } catch {
            heartbeats.cancel()
            _ = await heartbeats.value
            throw error
        }
        heartbeats.cancel()
        // Join the task: guarantees no heartbeat is emitted after `body`
        // returned, keeping later phases strictly ordered.
        _ = await heartbeats.value
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

    /// Progress-reporting variant. `progress` receives ordered
    /// `DiarizationProgress` events and is invoked from an arbitrary task, so
    /// it must be `@Sendable` and cheap.
    func diarize(
        _ url: URL,
        hints: DiarizationHints,
        progress: DiarizationProgressHandler?
    ) async throws -> DiarizationOutput
}

public extension DiarizationProvider {
    /// Bridge for providers without native progress support: existing
    func diarize(
        _ url: URL,
        hints: DiarizationHints,
        progress: DiarizationProgressHandler?
    ) async throws -> DiarizationOutput {
        _ = progress
        return try await diarize(url, hints: hints)
    }
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
