import Foundation

public extension Locale {
    static var transcriptionAutomatic: Locale {
        Locale(identifier: "auto")
    }
}

public enum LocaleResolver {
    /// Whether two identifiers name the same exact locale while differing
    /// only in Speech's separator or in letter case.
    public static func identifiersAreEquivalent(
        _ first: Locale,
        _ second: Locale
    ) -> Bool {
        normalizedIdentifier(first) == normalizedIdentifier(second)
    }

    public static func select(
        requested: Locale,
        supported: [Locale],
        automaticCandidates: [Locale] = [.autoupdatingCurrent, .current]
    ) -> Locale? {
        guard !supported.isEmpty else { return nil }

        if requested.identifier.caseInsensitiveCompare(
            Locale.transcriptionAutomatic.identifier
        ) != .orderedSame,
           let requestedMatch = equivalent(to: requested, in: supported) {
            return requestedMatch
        }

        for candidate in automaticCandidates {
            if let match = equivalent(to: candidate, in: supported) {
                return match
            }
        }

        if let english = equivalent(
            to: Locale(identifier: "en-US"),
            in: supported
        ) {
            return english
        }
        return supported.first
    }

    private static func equivalent(
        to requested: Locale,
        in supported: [Locale]
    ) -> Locale? {
        // SpeechTranscriber meldet Identifier mit Unterstrich ("en_US"),
        // Aufrufer schreiben BCP-47 mit Bindestrich ("en-US"). Ein reiner
        // Identifier-Vergleich verfehlte deshalb den exakten Treffer und
        // fiel auf die erstbeste gleiche Sprache zurück (real passiert:
        // en-US -> en_ZA, de-DE -> de_AT).
        if let exact = supported.first(where: {
            identifiersAreEquivalent($0, requested)
        }) {
            return exact
        }
        guard let requestedLanguage = requested.language.languageCode else {
            return nil
        }
        if let sameRegion = supported.first(where: {
            $0.language.languageCode == requestedLanguage
                && $0.region != nil
                && $0.region == requested.region
        }) {
            return sameRegion
        }
        return supported.first {
            $0.language.languageCode == requestedLanguage
        }
    }

    private static func normalizedIdentifier(_ locale: Locale) -> String {
        locale.identifier
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}
