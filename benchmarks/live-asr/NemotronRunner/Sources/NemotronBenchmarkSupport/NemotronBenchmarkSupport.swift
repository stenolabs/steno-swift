import Foundation

public enum NemotronBenchmarkConfigurationError: Error, Equatable, Sendable {
    case explicitLanguageRequired
    case unsupportedChunkMilliseconds(Int)
    case invalidFeedChunkMilliseconds(Int)
}

public struct NemotronBenchmarkConfiguration: Equatable, Sendable {
    public let language: String
    public let chunkMilliseconds: Int
    public let feedChunkMilliseconds: Int
    public let realtime: Bool

    public init(
        language: String,
        chunkMilliseconds: Int,
        feedChunkMilliseconds: Int,
        realtime: Bool
    ) throws {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.caseInsensitiveCompare("auto") != .orderedSame else {
            throw NemotronBenchmarkConfigurationError.explicitLanguageRequired
        }
        guard [560, 1_120, 2_240, 4_480].contains(chunkMilliseconds) else {
            throw NemotronBenchmarkConfigurationError.unsupportedChunkMilliseconds(
                chunkMilliseconds
            )
        }
        guard feedChunkMilliseconds > 0 else {
            throw NemotronBenchmarkConfigurationError.invalidFeedChunkMilliseconds(
                feedChunkMilliseconds
            )
        }
        self.language = normalized
        self.chunkMilliseconds = chunkMilliseconds
        self.feedChunkMilliseconds = feedChunkMilliseconds
        self.realtime = realtime
    }
}

public enum LiveBenchmarkUpdateKind: String, Codable, Equatable, Sendable {
    case volatile
    case final
}

public struct LiveBenchmarkUpdate: Codable, Equatable, Sendable {
    public let kind: LiveBenchmarkUpdateKind
    public let wallSeconds: TimeInterval
    public let audioSecondsFed: TimeInterval
    public let text: String

    public init(
        kind: LiveBenchmarkUpdateKind,
        wallSeconds: TimeInterval,
        audioSecondsFed: TimeInterval,
        text: String
    ) {
        self.kind = kind
        self.wallSeconds = wallSeconds
        self.audioSecondsFed = audioSecondsFed
        self.text = text
    }
}

public struct LiveBenchmarkEngine: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let model: String

    public init(id: String, version: String, model: String) {
        self.id = id
        self.version = version
        self.model = model
    }
}

public struct LiveBenchmarkMetrics: Codable, Equatable, Sendable {
    public let timeToFirstTextSeconds: TimeInterval?
    public let firstTextAudioSecondsFed: TimeInterval?
    public let updateCount: Int
}

public struct LiveBenchmarkResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let engine: LiveBenchmarkEngine
    public let locale: String
    public let mode: String
    public let chunkMilliseconds: Int
    public let audioDurationSeconds: TimeInterval
    public let wallSeconds: TimeInterval
    public let realTimeFactor: Double?
    public let text: String
    public let updates: [LiveBenchmarkUpdate]
    public let metrics: LiveBenchmarkMetrics

    public init(
        engine: LiveBenchmarkEngine,
        locale: String,
        mode: String,
        chunkMilliseconds: Int,
        audioDurationSeconds: TimeInterval,
        wallSeconds: TimeInterval,
        text: String,
        updates: [LiveBenchmarkUpdate]
    ) {
        schemaVersion = 1
        self.engine = engine
        self.locale = locale
        self.mode = mode
        self.chunkMilliseconds = chunkMilliseconds
        self.audioDurationSeconds = audioDurationSeconds
        self.wallSeconds = wallSeconds
        realTimeFactor = audioDurationSeconds > 0 ? wallSeconds / audioDurationSeconds : nil
        self.text = text
        self.updates = updates
        metrics = LiveBenchmarkMetrics(
            timeToFirstTextSeconds: updates.first?.wallSeconds,
            firstTextAudioSecondsFed: updates.first?.audioSecondsFed,
            updateCount: updates.count
        )
    }
}

public actor LiveBenchmarkRecorder {
    private let startedAt: TimeInterval
    private var audioSecondsFed: TimeInterval = 0
    private var recorded: [LiveBenchmarkUpdate] = []
    private var lastText: String?

    public init(startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.startedAt = startedAt
    }

    public func setAudioSecondsFed(_ seconds: TimeInterval) {
        audioSecondsFed = max(audioSecondsFed, seconds)
    }

    public func record(
        kind: LiveBenchmarkUpdateKind,
        text: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != lastText else { return }
        lastText = normalized
        recorded.append(LiveBenchmarkUpdate(
            kind: kind,
            wallSeconds: max(0, now - startedAt),
            audioSecondsFed: audioSecondsFed,
            text: normalized
        ))
    }

    public func updates() -> [LiveBenchmarkUpdate] { recorded }
}
