import Foundation

/// Configuration for automatically stopping a recording after a sustained
/// stretch of silence.
///
/// Deliberately diverges from the legacy stenoai default: there
/// `silence_auto_stop_enabled` defaulted to `true`. Steno ships it off by
/// default so an unnoticed setting can never silently truncate a recording;
/// users must opt in.
public struct SilenceAutoStopConfig: Equatable, Sendable {
    public var isEnabled: Bool
    public var thresholdDBFS: Double
    public var interval: TimeInterval

    public static let minimumInterval: TimeInterval = 10

    public init(
        isEnabled: Bool = false,
        thresholdDBFS: Double = -50.0,
        interval: TimeInterval = 300
    ) {
        self.isEnabled = isEnabled
        // Guard against nonsensical thresholds from stale settings storage:
        // everything at or below full-scale digital silence down to -120 dBFS
        // is representable; anything quieter than that is indistinguishable.
        self.thresholdDBFS = min(max(thresholdDBFS, -120), 0)
        self.interval = max(interval, Self.minimumInterval)
    }

    /// Whether a level measurement counts as silence.
    ///
    /// Exactly-at-threshold counts as silent (`<=`), mirroring the legacy
    /// comparison so boundary behavior matches stenoai.
    public func isSilent(_ levels: AudioLevels) -> Bool {
        Self.dbfs(levels.rms) <= thresholdDBFS
    }

    /// Converts a linear RMS amplitude to dBFS, clamping digital silence to
    /// -200 dBFS so comparisons stay finite.
    public static func dbfs(_ linear: Float) -> Double {
        guard linear > 0 else { return -200 }
        return Double(20 * log10(linear))
    }
}

/// Watches incoming audio levels and fires once after the configured interval
/// of continuous below-threshold audio.
///
/// State confinement: this is an actor because its consumers mirror how
/// `RecordingSession.updateLevels` is reached - from arbitrary writer tasks
/// hopping onto the session actor via `await`. An actor gives the silence
/// bookkeeping (`silenceStartedAt`, `episodeFired`) the same serialization
/// guarantees without locks, so `ingest` calls from any task cannot race an
/// episode reset.
///
/// Firing semantics: `onSilenceTimeout` runs exactly once per silence
/// episode. Any above-threshold sample instantly ends the episode (timer and
/// fired flag reset), and a fresh interval of silence re-arms the monitor.
public actor SilenceAutoStopMonitor {
    private let config: SilenceAutoStopConfig
    private let onSilenceTimeout: @Sendable () async -> Void

    private var silenceStartedAt: ContinuousClock.Instant?
    private var episodeFired = false

    public init(
        config: SilenceAutoStopConfig,
        onSilenceTimeout: @escaping @Sendable () async -> Void
    ) {
        self.config = config
        self.onSilenceTimeout = onSilenceTimeout
    }

    /// Feeds one round of level measurements taken at `instant`.
    ///
    /// Pass one entry per tracked input; the monitor treats the sample as
    /// silent only when every entry is below the threshold (bilateral
    /// silence, matching legacy behavior).
    ///
    /// Returns whether the timeout fired during this call.
    @discardableResult
    public func ingest(
        _ levelsByTrack: [AudioTrack: AudioLevels],
        at instant: ContinuousClock.Instant
    ) async -> Bool {
        let isActive = !levelsByTrack.isEmpty
            && levelsByTrack.values.contains { !config.isSilent($0) }
        // A disabled monitor never opens an episode and never stops the
        // recording; callers may keep feeding levels without guarding.
        guard config.isEnabled else { return false }

        if isActive {
            // Activity: end the episode instantly, re-arming the monitor.
            silenceStartedAt = nil
            episodeFired = false
            return false
        }

        let startedAt = silenceStartedAt ?? instant
        silenceStartedAt = startedAt
        // `onSilenceTimeout` is awaited, so a reentrant `ingest` can run
        // while it is still in flight; the fired flag keeps that from
        // triggering a second stop for the same episode.
        guard !episodeFired,
              startedAt.duration(to: instant) >= .seconds(config.interval)
        else { return false }

        episodeFired = true
        await onSilenceTimeout()
        return true
    }

    /// Ends the current silence episode without waiting for audio activity.
    public func reset() {
        silenceStartedAt = nil
        episodeFired = false
    }
}
