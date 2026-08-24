import Foundation
import StenoDomain
import StenoTranscription

struct TranscriptionLanguageSelection: Equatable {
    let locale: Locale
    let effectiveLocaleWasChosenExplicitly: Bool

    init(
        selectedIdentifier: String,
        wasChosenExplicitly: Bool,
        resolvedFallback: Locale?
    ) {
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedIdentifier: String {
        defaults.string(forKey: Self.languageKey)
            ?? Locale.transcriptionAutomatic.identifier
    }

    var wasChosenExplicitly: Bool {
        defaults.bool(forKey: Self.explicitChoiceKey)
    }

    func saveExplicitChoice(_ identifier: String) {
        defaults.set(identifier, forKey: Self.languageKey)
        defaults.set(true, forKey: Self.explicitChoiceKey)
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
