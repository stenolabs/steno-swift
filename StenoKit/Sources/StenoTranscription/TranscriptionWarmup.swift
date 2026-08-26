import Foundation
import OSLog
import Speech
import StenoDomain

/// A provider's cheapest readiness action for launch-time warmup.
///
/// Internal on purpose: callers go through `TranscriptionWarmup`, and each
/// concrete provider owns what "ready without installing" means for it.
/// Implementations must never install, download, or ask for consent; a
/// missing piece fails exactly as it would at record time.
protocol WarmupParticipatingProvider: TranscriptionProvider {
    func preWarm(locale: Locale) async throws
}

/// Pre-touches the transcription models a planned recording will use, so the
/// first record start does not pay cold-start costs (the legacy
/// `spawnParakeetWarmup` saved roughly one second on the Parakeet path).
///
/// Guarantees:
/// - Never installs or downloads anything and never triggers a consent
///   prompt. Every action is a pure inventory check or a load of files that
///   are already on disk; missing assets are only logged and stay the job of
///   `ModelInstallationCoordinator`.
/// - Unregistered provider IDs are skipped without throwing: warmup runs at
///   bootstrap, where it must not be able to take the app down.
/// - Idempotent. There is no shared state; a second call merely re-warms the
///   same caches and is safe at any time.
/// - Cancellable. Cancellation between and inside the readiness actions
///   aborts the remaining work with `CancellationError`.
public enum TranscriptionWarmup {
    private static let logger = Logger(
        subsystem: "org.steno.Steno",
        category: "TranscriptionWarmup"
    )

    /// Resolves both planned provider IDs for the microphone track through
    /// `registry` and performs each resolved provider's cheapest readiness
    /// action (Speech asset inventory check, Parakeet model load when the
    /// model is installed). Errors are logged and swallowed; only task
    /// cancellation propagates.
    public static func preTouch(
        plan: TranscriptionPlan,
        registry: TranscriptionProviderRegistry,
        locale: Locale
    ) async {
        // Both roles may name the same provider; warming it once is enough,
        // and a second full Parakeet load would burn another second for
        // nothing.
        var providerIDs = [plan.liveProviderID]
        if plan.finalProviderID != plan.liveProviderID {
            providerIDs.append(plan.finalProviderID)
        }

        for id in providerIDs {
            guard !Task.isCancelled else { return }
            do {
                let provider = try registry.resolve(id, for: .micTrack)
                guard let participant = provider as? any WarmupParticipatingProvider else {
                    logger.info(
                        "warmup: \(id.rawValue, privacy: .private) has no readiness action"
                    )
                    continue
                }
                let clock = ContinuousClock()
                let elapsed = try await clock.measure {
                    try await participant.preWarm(locale: locale)
                }
                logger.info(
                    "warmup: \(id.rawValue, privacy: .private) ready in \(elapsed.description, privacy: .private)"
                )
            } catch is CancellationError {
                logger.info("warmup: cancelled")
                return
            } catch {
                // Best effort by contract: whatever went wrong must not
                // delay or break the bootstrap that called us.
                logger.error(
                    "warmup failed for \(id.rawValue, privacy: .private): \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }
}

extension SpeechAnalyzerProvider: WarmupParticipatingProvider {
    func preWarm(locale: Locale) async throws {
        // Inventory check only, with the same resolution and the same
        // two-source check the live session uses: a supported-but-missing
        // language surfaces in the log now instead of costing the first
        // record its setup queries - and nothing here requests an install.
        let supported = await SpeechTranscriber.supportedLocales
        guard let resolved = LocaleResolver.select(
            requested: locale,
            supported: supported
        ) else { return }
        _ = await Self.assetsAreInstalled(
            for: Self.transcriber(for: resolved),
            locale: resolved
        )
    }
}

extension ParakeetTranscriptionProvider: WarmupParticipatingProvider {
    func preWarm(locale: Locale) async throws {
        // `LocalParakeetModelLoader` verifies the checksum manifest before it
        // touches anything else, so an absent or half-written install throws
        // here instead of ever reaching FluidAudio's downloader. The load
        // itself populates CoreML's compile caches and the page cache; the
        // result is discarded because the record-time `AsrManager` rebuilds
        // its own state from the same files.
        guard let directory = warmupModelDirectory else { return }
        _ = try await LocalParakeetModelLoader.load(from: directory)
    }
}
