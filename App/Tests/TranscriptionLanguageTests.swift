import Foundation
import StenoDomain
import Testing
@testable import steno_macos

@Suite("Transcription language", .serialized)
@MainActor
struct TranscriptionLanguageTests {
    @Test("the same inferred value still requires an explicit confirmation")
    func inferredValueCanBeConfirmedWithoutChangingIt() {
        #expect(TranscriptionLanguageChangePolicy.shouldApply(
            identifier: "de_DE",
            selectedIdentifier: "de_DE",
            wasChosenExplicitly: false
        ))
        #expect(!TranscriptionLanguageChangePolicy.shouldApply(
            identifier: "de_DE",
            selectedIdentifier: "de_DE",
            wasChosenExplicitly: true
        ))
    }

    @Test("the explicit-choice key is independent of an existing language value")
    func explicitChoiceHasItsOwnDefaultsKey() throws {
        let suiteName = "TranscriptionLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = TranscriptionLanguagePreferences(defaults: defaults)

        defaults.set("de_DE", forKey: TranscriptionLanguagePreferences.languageKey)
        #expect(preferences.selectedIdentifier == "de_DE")
        #expect(!preferences.wasChosenExplicitly)

        preferences.saveExplicitChoice("de_DE")

        #expect(preferences.selectedIdentifier == "de_DE")
        #expect(preferences.wasChosenExplicitly)
    }

    @Test("only the effective explicitly chosen locale is persisted on a meeting")
    func meetingSourceLocaleRequiresEffectiveExplicitChoice() throws {
        let explicit = TranscriptionLanguageSelection(
            selectedIdentifier: "de-DE",
            wasChosenExplicitly: true,
            resolvedFallback: nil
        )
        let equivalent = TranscriptionLanguageSelection(
            selectedIdentifier: "de-DE",
            wasChosenExplicitly: true,
            resolvedFallback: Locale(identifier: "de_DE")
        )
        let differentFallback = TranscriptionLanguageSelection(
            selectedIdentifier: "de-DE",
            wasChosenExplicitly: true,
            resolvedFallback: Locale(identifier: "de_AT")
        )
        let inferred = TranscriptionLanguageSelection(
            selectedIdentifier: Locale.transcriptionAutomatic.identifier,
            wasChosenExplicitly: false,
            resolvedFallback: Locale(identifier: "de_DE")
        )
        let explicitAutomatic = TranscriptionLanguageSelection(
            selectedIdentifier: Locale.transcriptionAutomatic.identifier,
            wasChosenExplicitly: true,
            resolvedFallback: nil
        )

        #expect(try explicit.meetingSourceLocale()
            == MeetingSourceLocale(localeIdentifier: "de-DE", origin: .explicit))
        #expect(try equivalent.meetingSourceLocale()
            == MeetingSourceLocale(localeIdentifier: "de_DE", origin: .explicit))
        #expect(try differentFallback.meetingSourceLocale() == nil)
        #expect(try inferred.meetingSourceLocale() == nil)
        #expect(!explicitAutomatic.effectiveLocaleWasChosenExplicitly)
        #expect(try explicitAutomatic.meetingSourceLocale() == nil)
    }

    @Test("only a locale offered by Speech can be confirmed")
    func confirmableLocaleMustBeSupported() {
        let available = [
            Locale(identifier: "de_DE"),
            Locale(identifier: "en_US"),
        ]
        let automatic = TranscriptionLanguageSelection(
            selectedIdentifier: Locale.transcriptionAutomatic.identifier,
            wasChosenExplicitly: false,
            resolvedFallback: nil
        )
        let german = TranscriptionLanguageSelection(
            selectedIdentifier: "de-DE",
            wasChosenExplicitly: false,
            resolvedFallback: Locale(identifier: "de_DE")
        )

        #expect(!automatic.canBeConfirmed(in: available))
        #expect(german.canBeConfirmed(in: available))
    }
}
