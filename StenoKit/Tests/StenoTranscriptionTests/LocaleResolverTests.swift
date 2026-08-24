import Foundation
import Testing
@testable import StenoTranscription

@Suite("Transcription locale selection")
struct LocaleResolverTests {
    private let supported = [
        Locale(identifier: "de-DE"),
        Locale(identifier: "en-US"),
        Locale(identifier: "fr-FR"),
    ]

    @Test("uses an equivalent explicitly requested locale")
    func explicitEquivalentLocale() {
        let selected = LocaleResolver.select(
            requested: Locale(identifier: "de-AT"),
            supported: supported,
            automaticCandidates: [Locale(identifier: "en-US")]
        )

        #expect(selected?.identifier == "de-DE")
    }

    @Test("an unsupported explicit language does not fall back automatically")
    func unsupportedExplicitLocaleReturnsNil() {
        let selected = LocaleResolver.select(
            requested: Locale(identifier: "ja-JP"),
            supported: supported,
            automaticCandidates: [Locale(identifier: "fr-CA"), Locale(identifier: "en-US")]
        )

        #expect(selected == nil)
    }

    @Test("an auto request uses the first supported automatic candidate")
    func autoLocale() {
        let selected = LocaleResolver.select(
            requested: .transcriptionAutomatic,
            supported: supported,
            automaticCandidates: [Locale(identifier: "it-IT"), Locale(identifier: "de-AT")]
        )

        #expect(selected?.identifier == "de-DE")
    }

    @Test("uses English but does not invent an unrelated final fallback")
    func deterministicFinalFallbacks() {
        let english = LocaleResolver.select(
            requested: .transcriptionAutomatic,
            supported: supported,
            automaticCandidates: []
        )
        let first = LocaleResolver.select(
            requested: .transcriptionAutomatic,
            supported: [Locale(identifier: "es-ES"), Locale(identifier: "fr-FR")],
            automaticCandidates: []
        )

        #expect(english?.identifier == "en-US")
        #expect(first == nil)
    }

    @Test("returns nil when Speech supports no locale")
    func noSupportedLocale() {
        #expect(LocaleResolver.select(
            requested: .transcriptionAutomatic,
            supported: [],
            automaticCandidates: [Locale(identifier: "de-DE")]
        ) == nil)
    }
}

extension LocaleResolverTests {
    @Test("exact identifier equivalence ignores case and separators")
    func exactIdentifierEquivalence() {
        #expect(LocaleResolver.identifiersAreEquivalent(
            Locale(identifier: "de-DE"),
            Locale(identifier: "DE_de")
        ))
        #expect(!LocaleResolver.identifiersAreEquivalent(
            Locale(identifier: "de-DE"),
            Locale(identifier: "de_AT")
        ))
    }

    @Test("underscore identifiers from Speech match hyphenated requests exactly")
    func underscoreMatchesHyphen() {
        let supported = [
            Locale(identifier: "en_ZA"),
            Locale(identifier: "en_US"),
            Locale(identifier: "de_AT"),
            Locale(identifier: "de_DE"),
        ]
        #expect(
            LocaleResolver.select(
                requested: Locale(identifier: "en-US"),
                supported: supported
            )?.identifier == "en_US"
        )
        #expect(
            LocaleResolver.select(
                requested: Locale(identifier: "de-DE"),
                supported: supported
            )?.identifier == "de_DE"
        )
    }

    @Test("an ambiguous same-language fallback prefers Foundation's default region in every order")
    func sameLanguageFallbackIsIndependentOfSupportedOrder() {
        let firstOrder = [
            Locale(identifier: "de_AT"),
            Locale(identifier: "de_DE"),
            Locale(identifier: "de_CH"),
        ]
        let secondOrder = [
            Locale(identifier: "de_CH"),
            Locale(identifier: "de_AT"),
            Locale(identifier: "de_DE"),
        ]

        let first = LocaleResolver.select(
            requested: Locale(identifier: "de_XX"),
            supported: firstOrder
        )
        let second = LocaleResolver.select(
            requested: Locale(identifier: "de_XX"),
            supported: secondOrder
        )

        #expect(first?.identifier == "de_DE")
        #expect(second?.identifier == "de_DE")
    }
}
