@preconcurrency import AVFAudio
import Foundation

/// Owns the process-wide `AVAudioSession` for recording.
///
/// The Mac has no equivalent: there the engine simply runs. On iOS the session
/// is shared state that the system can revoke, so every capture goes through
/// here and every revocation surfaces as an `AudioSessionEvent` instead of a
/// silent gap in the recording.
public actor AudioSessionController {
    /// Recording mode. Which one produces better ASR and diarisation on real
    /// room recordings is measurement task R4 in `docs/PLAN-IOS.md`, not a
    /// matter of taste, so it stays configurable and defaults to the mode
    /// Apple applies when an app expresses no preference.
    public enum Mode: Sendable {
        /// System signal processing stays on. Helps distant speakers.
        case standard
        /// Signal processing off, rawest possible signal.
        case measurement

        var sessionMode: AVAudioSession.Mode {
            switch self {
            case .standard: .default
            case .measurement: .measurement
            }
        }
    }

    private let session: AVAudioSession
    private var observers: [Task<Void, Never>] = []
    private var continuations: [UUID: AsyncStream<AudioSessionEvent>.Continuation] = [:]

    public init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    /// Configures the session for recording without activating it.
    ///
    /// `.playAndRecord` rather than `.record`, because speaker review plays
    /// audio excerpts back while the library stays recordable.
    ///
    /// Bluetooth HFP is deliberately **not** allowed: it would let AirPods
    /// become the input, and HFP is a narrowband channel that would cost more
    /// transcription accuracy than the convenience is worth. The built-in
    /// microphone or a wired/USB interface is the intended source.
    public func configure(mode: Mode = .standard) throws {
        try session.setCategory(
            .playAndRecord,
            mode: mode.sessionMode,
            options: [.defaultToSpeaker]
        )
    }

    public func activate() throws {
        try session.setActive(true)
        startObservingIfNeeded()
    }

    public func deactivate() throws {
        try session.setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    /// Events for as long as the returned stream is held.
    ///
    /// Each caller gets its own stream so the recording session and the UI can
    /// both listen without one cancelling the other.
    public func events() -> AsyncStream<AudioSessionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AudioSessionEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        startObservingIfNeeded()
        return stream
    }

    /// The sample rate the hardware is actually running at.
    ///
    /// Reported for logging and for the format check when a route changes; the
    /// writer still takes its format from the engine's input node.
    public var currentSampleRate: Double {
        session.sampleRate
    }

    /// Description of the current input, for the recording UI.
    public var currentInputDescription: String? {
        session.currentRoute.inputs.first?.portName
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: AudioSessionEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func startObservingIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(
            Task { [weak self] in
                let notifications = center.notifications(
                    named: AVAudioSession.interruptionNotification
                )
                for await notification in notifications {
                    guard let event = Self.interruptionEvent(from: notification) else {
                        continue
                    }
                    await self?.emit(event)
                }
            }
        )

        observers.append(
            Task { [weak self] in
                let notifications = center.notifications(
                    named: AVAudioSession.routeChangeNotification
                )
                for await notification in notifications {
                    let reason = Self.routeChangeReason(from: notification)
                    await self?.emit(.routeChanged(reason))
                }
            }
        )

        observers.append(
            Task { [weak self] in
                let notifications = center.notifications(
                    named: AVAudioSession.mediaServicesWereResetNotification
                )
                for await _ in notifications {
                    await self?.emit(.mediaServicesWereReset)
                }
            }
        )
    }

    deinit {
        for observer in observers {
            observer.cancel()
        }
        for continuation in continuations.values {
            continuation.finish()
        }
    }
}

// Notification decoding is static and free of actor state so it can be tested
// with synthesised notifications, without a live audio session.
extension AudioSessionController {
    static func interruptionEvent(
        from notification: Notification
    ) -> AudioSessionEvent? {
        guard
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else {
            return nil
        }

        switch type {
        case .began:
            let rawReason = notification.userInfo?[
                AVAudioSessionInterruptionReasonKey
            ] as? UInt
            let reason = rawReason
                .flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
                .map(AudioInterruptionReason.from)
            return .interruptionBegan(reason ?? .other)
        case .ended:
            let rawOptions = notification.userInfo?[
                AVAudioSessionInterruptionOptionKey
            ] as? UInt
            let options = rawOptions.map(
                AVAudioSession.InterruptionOptions.init(rawValue:)
            )
            return .interruptionEnded(
                shouldResume: options?.contains(.shouldResume) ?? false
            )
        @unknown default:
            return nil
        }
    }

    static func routeChangeReason(
        from notification: Notification
    ) -> AudioRouteChangeReason {
        guard
            let raw = notification.userInfo?[
                AVAudioSessionRouteChangeReasonKey
            ] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else {
            return .unknown
        }
        return AudioRouteChangeReason.from(reason)
    }
}
