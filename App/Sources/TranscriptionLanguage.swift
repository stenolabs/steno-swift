import Foundation
import StenoDomain
import StenoTranscription

struct TranscriptionLanguageSelection: Equatable {
    /// The stored sentinel naming the Automatic option (`Locale("auto")`).
    static let automaticIdentifier = Locale.transcriptionAutomatic.identifier

    let locale: Locale
    /// The unpicked-down identifier as stored ("auto" sentinel or a BCP 47
    /// tag); `locale` alone cannot express an Automatic opt-in because the
    /// resolver immediately falls back to a concrete language.
    let rawSelectedIdentifier: String
    let effectiveLocaleWasChosenExplicitly: Bool

    init(
        selectedIdentifier: String,
        wasChosenExplicitly: Bool,
        resolvedFallback: Locale?
    ) {
        self.rawSelectedIdentifier = selectedIdentifier
        locale = resolvedFallback ?? Locale(identifier: selectedIdentifier)
        effectiveLocaleWasChosenExplicitly = wasChosenExplicitly
            // "auto" beschreibt eine Ableitung, nie eine gesprochene Sprache.
            // Auch ein alter Defaults-Eintrag darf daraus keine Tatsache machen.
            && !LocaleResolver.identifiersAreEquivalent(
                locale,
                .transcriptionAutomatic
            )
            && LocaleResolver.identifiersAreEquivalent(
                locale,
                Locale(identifier: selectedIdentifier)
            )
    }

    /// Whether the user opted into Automatic language detection.
    var selectsAutomatic: Bool {
        LocaleResolver.identifiersAreEquivalent(
            locale,
            .transcriptionAutomatic
        ) || LocaleResolver.identifiersAreEquivalent(
            Locale(identifier: rawSelectedIdentifier),
            .transcriptionAutomatic
        )
    }

    func canBeConfirmed(in available: [Locale]) -> Bool {
        guard !LocaleResolver.identifiersAreEquivalent(
            locale,
            .transcriptionAutomatic
        ) else { return false }
        return available.contains {
            LocaleResolver.identifiersAreEquivalent($0, locale)
        }
    }

    func meetingSourceLocale() throws -> MeetingSourceLocale? {
        guard effectiveLocaleWasChosenExplicitly else { return nil }
        return try MeetingSourceLocale(
            localeIdentifier: locale.identifier,
            origin: .explicit
        )
    }
}

struct TranscriptionLanguagePreferences {
    static let languageKey = "steno.transcription.language"
    static let explicitChoiceKey = "steno.transcription.language.chosen"
    /// Last explicitly chosen concrete language; the live lane starts with it
    /// while Automatic detection is active.
    static let lastExplicitLanguageKey = "steno.transcription.language.lastExplicit"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Absent key = explicit English. Automatic detection is strictly opt-in:
    /// a fresh install must never silently run detection. English matches the
    /// old effective behaviour, where the "auto" placeholder resolved through
    /// Speech's deterministic (English-first) fallback.
    static let defaultIdentifier = "en-US"

    var selectedIdentifier: String {
        defaults.string(forKey: Self.languageKey)
            ?? Self.defaultIdentifier
    }

    var wasChosenExplicitly: Bool {
        defaults.bool(forKey: Self.explicitChoiceKey)
    }

    /// Whether the persisted choice names the Automatic option. Opt-in only:
    /// an absent key never means automatic.
    var selectsAutomatic: Bool {
        guard let identifier = defaults.string(forKey: Self.languageKey) else {
            return false
        }
        return LocaleResolver.identifiersAreEquivalent(
            Locale(identifier: identifier),
            .transcriptionAutomatic
        )
    }

    /// The last concrete language the user chose explicitly, if any.
    var lastUsedExplicitIdentifier: String? {
        defaults.string(forKey: Self.lastExplicitLanguageKey)
    }

    func saveExplicitChoice(_ identifier: String) {
        defaults.set(identifier, forKey: Self.languageKey)
        defaults.set(true, forKey: Self.explicitChoiceKey)
        if !LocaleResolver.identifiersAreEquivalent(
            Locale(identifier: identifier),
            .transcriptionAutomatic
        ) {
            defaults.set(identifier, forKey: Self.lastExplicitLanguageKey)
        }
    }
}

/// Resolves the locale a recording starts its live lane with while Automatic
/// detection is active: the last explicitly used language when Speech still
/// offers it, otherwise Speech's own deterministic default (English first).
enum AutomaticStartLanguageResolver {
    static func startLocaleIdentifier(
        lastUsedExplicit: String?,
        supported: [Locale]
    ) -> String? {
        if let lastUsedExplicit,
           let resolved = LocaleResolver.select(
            requested: Locale(identifier: lastUsedExplicit),
            supported: supported
           ) {
            return resolved.identifier
        }
        return LocaleResolver.select(
            requested: .transcriptionAutomatic,
            supported: supported
        )?.identifier
    }
}

enum TranscriptionLanguageChangePolicy {
    static func shouldApply(
        identifier: String,
        selectedIdentifier: String,
        wasChosenExplicitly: Bool
    ) -> Bool {
        identifier != selectedIdentifier || !wasChosenExplicitly
    }
}
