import Foundation

public enum LiveBenchmarkUpdateKind: String, Codable, Equatable, Sendable {
    case volatile
    case final
}

public enum LiveBenchmarkMode: String, Codable, Equatable, Sendable {
    case fast
    case realtime
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

public struct LiveBenchmarkMetrics: Codable, Equatable, Sendable {
    public let timeToFirstTextSeconds: TimeInterval?
    public let firstTextAudioSecondsFed: TimeInterval?
    public let updateCount: Int

    public init(
        timeToFirstTextSeconds: TimeInterval?,
        firstTextAudioSecondsFed: TimeInterval?,
        updateCount: Int
    ) {
        self.timeToFirstTextSeconds = timeToFirstTextSeconds
        self.firstTextAudioSecondsFed = firstTextAudioSecondsFed
        self.updateCount = updateCount
    }
}

public struct LiveBenchmarkResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let engine: LiveBenchmarkEngine
    public let locale: String
    public let mode: LiveBenchmarkMode
    public let chunkMilliseconds: Int
    public let audioDurationSeconds: TimeInterval
    public let wallSeconds: TimeInterval
    public let realTimeFactor: Double?
    public let text: String
    public let updates: [LiveBenchmarkUpdate]
    public let metrics: LiveBenchmarkMetrics

    public init(
        schemaVersion: Int = 1,
        engine: LiveBenchmarkEngine,
        locale: String,
        mode: LiveBenchmarkMode,
        chunkMilliseconds: Int,
        audioDurationSeconds: TimeInterval,
        wallSeconds: TimeInterval,
        realTimeFactor: Double?,
        text: String,
        updates: [LiveBenchmarkUpdate],
        metrics: LiveBenchmarkMetrics
    ) {
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.locale = locale
        self.mode = mode
        self.chunkMilliseconds = chunkMilliseconds
        self.audioDurationSeconds = audioDurationSeconds
        self.wallSeconds = wallSeconds
        self.realTimeFactor = realTimeFactor
        self.text = text
        self.updates = updates
        self.metrics = metrics
    }
}

public actor LiveBenchmarkRecorder {
    private let now: @Sendable () -> TimeInterval
    private let startedAt: TimeInterval
    private var audioSecondsFed: TimeInterval = 0
    private var recordedUpdates: [LiveBenchmarkUpdate] = []
    private var lastText: String?

    public init(now: @escaping @Sendable () -> TimeInterval) {
        self.now = now
        startedAt = now()
    }

    public func setAudioSecondsFed(_ seconds: TimeInterval) {
        audioSecondsFed = max(audioSecondsFed, seconds)
    }

    public func record(kind: LiveBenchmarkUpdateKind, text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != lastText else { return }
        lastText = normalized
        recordedUpdates.append(LiveBenchmarkUpdate(
            kind: kind,
            wallSeconds: max(0, now() - startedAt),
            audioSecondsFed: audioSecondsFed,
            text: normalized
        ))
    }

    public func updates() -> [LiveBenchmarkUpdate] {
        recordedUpdates
    }

    public func result(
        engine: LiveBenchmarkEngine,
        locale: String,
        mode: LiveBenchmarkMode,
        chunkMilliseconds: Int,
        audioDurationSeconds: TimeInterval,
        finalText: String
    ) -> LiveBenchmarkResult {
        let wallSeconds = max(0, now() - startedAt)
        let first = recordedUpdates.first
        return LiveBenchmarkResult(
            engine: engine,
            locale: locale,
            mode: mode,
            chunkMilliseconds: chunkMilliseconds,
            audioDurationSeconds: audioDurationSeconds,
            wallSeconds: wallSeconds,
            realTimeFactor: audioDurationSeconds > 0 ? wallSeconds / audioDurationSeconds : nil,
            text: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
            updates: recordedUpdates,
            metrics: LiveBenchmarkMetrics(
                timeToFirstTextSeconds: first?.wallSeconds,
                firstTextAudioSecondsFed: first?.audioSecondsFed,
                updateCount: recordedUpdates.count
            )
        )
    }
}

public func monotonicSeconds() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}
