import Foundation

/// Automatic language detection outcome pinned alongside a final ASR job or
/// its processing run.
///
/// The detected locale is always an estimate (`MeetingSourceLocale` origin
/// `.estimated` semantics): it never upgrades to a user choice. Both locales
/// are recorded so a rerun can reproduce the original decision context.
public struct TranscriptionLanguageDetectionPin: Codable, Equatable, Sendable {
    /// Locale identifier the live lane started with (last explicit choice
    /// while Automatic was selected, otherwise Speech's deterministic
    /// fallback).
    public let startLocaleIdentifier: String
    /// Language code the detector decided on. nil means the evidence was
    /// inconclusive or agreed with the start locale, which is kept silently.
    public let detectedLocaleIdentifier: String?

    public init(
        startLocaleIdentifier: String,
        detectedLocaleIdentifier: String?
    ) {
        self.startLocaleIdentifier = startLocaleIdentifier
        self.detectedLocaleIdentifier = detectedLocaleIdentifier
    }
}
