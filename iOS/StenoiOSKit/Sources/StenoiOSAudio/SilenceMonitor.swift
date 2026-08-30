import Foundation

/// Watches the input level for a microphone that has gone dead.
///
/// The worst outcome of a recording app is the 70 minute recording with no
/// sound in it. The levels are available anyway, so the check costs nothing;
/// the grace period keeps a pause in
/// the conversation from crying wolf.
public struct SilenceMonitor: Equatable, Sendable {
    /// Peak below which the input counts as no signal.
    ///
    /// -60 dBFS sits under the noise floor of a quiet room but well above a
    /// disconnected input, which reads at or near the reporting floor.
    public static let defaultThreshold: Float = -60

    /// How long silence may last before it is worth saying something.
    ///
    /// Long enough that a pause between speakers stays quiet, short enough
    /// that a dead microphone is caught while the meeting can still be saved.
    public static let defaultGrace: TimeInterval = 20

    public let threshold: Float
    public let grace: TimeInterval

    private var lastSignal: Date?

    public init(
        threshold: Float = SilenceMonitor.defaultThreshold,
        grace: TimeInterval = SilenceMonitor.defaultGrace
    ) {
        self.threshold = threshold
        self.grace = grace
    }

    /// Starts the clock. Call when the capture starts.
    public mutating func begin(at now: Date) {
        lastSignal = now
    }

    public mutating func update(_ level: AudioLevel, at now: Date) {
        guard lastSignal != nil else { return }
        if level.peak > threshold {
            lastSignal = now
        }
    }

    /// Seconds since the last audible sample, or nil if not running.
    public func silentSeconds(at now: Date) -> TimeInterval? {
        guard let lastSignal else { return nil }
        return max(0, now.timeIntervalSince(lastSignal))
    }

    /// Whether the UI should point out that nothing is being heard.
    public func isAlarming(at now: Date) -> Bool {
        guard let seconds = silentSeconds(at: now) else { return false }
        return seconds >= grace
    }

    public mutating func stop() {
        lastSignal = nil
    }
}
