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

        let isAutomatic = requested.identifier.caseInsensitiveCompare(
            Locale.transcriptionAutomatic.identifier
        ) == .orderedSame
        if !isAutomatic {
            return equivalent(to: requested, in: supported)
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
        // Ohne Treffer aus der ausdruecklichen Automatik-Kette gibt es keine
        // fachliche Grundlage, eine beliebige Sprache aus der von Speech
        // gelieferten Reihenfolge zu nehmen. Kein Transkript ist ehrlicher
        // als ein plausibel aussehendes Transkript in der falschen Sprache.
        return nil
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
        let sameLanguage = supported.filter {
            $0.language.languageCode == requestedLanguage
        }
        guard !sameLanguage.isEmpty else { return nil }

        // Die Reihenfolge ist fachlich, nicht die Reihenfolge des Arrays:
        // 1. exakt wurde oben geprueft;
        // 2. dieselbe vom Aufrufer genannte Region;
        // 3. eine regionslose Sprachkennung als neutraler Kandidat;
        // 4. die von Foundations CLDR-Likely-Subtags bestimmte Standardregion
        //    der Sprache, zum Beispiel DE fuer Deutsch und US fuer Englisch;
        // 5. genau ein verbleibender Sprachkandidat.
        // Bleiben in einer Stufe mehrere Varianten uebrig, darf nur ein
        // passendes Schriftsystem entscheiden. Sonst ist die Wahl mehrdeutig
        // und liefert nil, statt `supported.first` zur vermeintlichen
        // Sprachentscheidung zu machen.
        if let requestedRegion = requested.region,
           let sameRegion = uniqueCandidate(
               in: sameLanguage.filter { $0.region == requestedRegion },
               requestedScript: requested.language.script
           ) {
            return sameRegion
        }

        if let regionless = uniqueCandidate(
            in: sameLanguage.filter { $0.region == nil },
            requestedScript: requested.language.script
        ) {
            return regionless
        }

        let languageAndScript = [
            requestedLanguage.identifier,
            requested.language.script?.identifier,
        ].compactMap { $0 }.joined(separator: "-")
        let maximized = Locale.Language(identifier: languageAndScript).maximalIdentifier
        let defaultRegion = Locale.Language(identifier: maximized).region
        if let defaultRegion,
           let defaultRegional = uniqueCandidate(
               in: sameLanguage.filter { $0.region == defaultRegion },
               requestedScript: requested.language.script
           ) {
            return defaultRegional
        }

        return uniqueCandidate(
            in: sameLanguage,
            requestedScript: requested.language.script
        )
    }

    private static func uniqueCandidate(
        in candidates: [Locale],
        requestedScript: Locale.Script?
    ) -> Locale? {
        guard candidates.count != 1 else { return candidates[0] }
        guard let requestedScript else { return nil }
        let sameScript = candidates.filter {
            $0.language.script == requestedScript
        }
        return sameScript.count == 1 ? sameScript[0] : nil
    }

    private static func normalizedIdentifier(_ locale: Locale) -> String {
        locale.identifier
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}
