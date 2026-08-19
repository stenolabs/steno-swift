import Foundation
import Speech
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
            && LocaleResolver.identifiersAreEquivalent(
                locale,
                Locale(identifier: selectedIdentifier)
            )
    }
}

/// The language the recogniser is told to use.
///
/// Explicit and persisted, never simply `Locale.current`. The Mac learned this
/// the hard way (`steno-macos/App/Sources/AppModel.swift:176-178`): an English
/// system with German speech transcribes German as English, and the result
/// looks plausible enough that nobody notices until they read it. A phone set
/// to English in Germany reports `en_DE`, so the same trap is here.
@MainActor
@Observable
final class TranscriptionLanguage {
    private static let defaultsKey = "steno.transcription.language"
    /// Getrennt vom Wert selbst, weil unter `defaultsKey` auch Ableitungen
    /// aelterer Fassungen liegen.
    private static let explicitChoiceKey = "steno.transcription.language.chosen"

    private(set) var available: [Locale] = []
    private(set) var selectedID: String = UserDefaults.standard
        .string(forKey: TranscriptionLanguage.defaultsKey)
        ?? Locale.transcriptionAutomatic.identifier

    /// Ob der Nutzer die Sprache je selbst gewaehlt hat.
    ///
    /// Der Unterschied ist der ganze Punkt dieser Klasse: eine abgeleitete
    /// Sprache **sieht aus wie** eine gewaehlte, und ein englisches Telefon
    /// in Deutschland transkribiert Deutsch dann plausibel falsch. Vorher
    /// schrieb `refresh()` die Ableitung in die Voreinstellungen und machte
    /// sie damit ununterscheidbar von einer Wahl.
    ///
    /// **Eigener Schluessel, nicht die Existenz von `defaultsKey`.** Genau
    /// dort steht auf jeder bestehenden Installation schon eine abgeleitete
    /// Sprache, weil die alte Fassung sie ueber `select()` gespeichert hat.
    /// An der Existenz zu haengen wuerde jede solche Installation als
    /// "hat gewaehlt" einstufen, beide Warnungen unterdruecken und die aus
    /// dem Systemgebiet abgeleitete Sprache festschreiben - also genau den
    /// Fehler bewahren, den diese Aenderung beseitigen soll.
    private(set) var wasChosenExplicitly = UserDefaults.standard
        .bool(forKey: TranscriptionLanguage.explicitChoiceKey)

    /// Was der Erkenner benutzt, solange niemand gewaehlt hat.
    ///
    /// Bewusst nicht gespeichert: die Aufnahme darf nie an einer offenen
    /// Sprachfrage scheitern, aber die Ableitung soll auch nie zur Wahl
    /// erstarken.
    private(set) var resolvedFallback: Locale?

    /// Was der Erkenner bekommt.
    ///
    /// Der Fallback greift auch bei einer ausdruecklichen Wahl, sobald deren
    /// Kennung nicht mehr in `available` steht - etwa wenn dieselbe Sprache
    /// als `de_DE` statt `de-DE` gemeldet wird. Die Wahl unveraendert
    /// weiterzureichen liesse Live- und Finallauf ins Leere greifen, waehrend
    /// der Picker keinen passenden Eintrag mehr haette.
    var locale: Locale {
        resolvedFallback ?? Locale(identifier: selectedID)
    }

    /// Effective language plus the provenance of that exact value.
    ///
    /// A historical explicit choice does not make a later resolved fallback
    /// explicit. Recording and persistence must consume these two values as
    /// one snapshot so their provenance cannot drift apart.
    var recordingSelection: TranscriptionLanguageSelection {
        TranscriptionLanguageSelection(
            selectedIdentifier: selectedID,
            wasChosenExplicitly: wasChosenExplicitly,
            resolvedFallback: resolvedFallback
        )
    }

    /// Whether the recogniser exists on this device at all.
    ///
    /// False in the iOS Simulator, which reports zero supported languages.
    private(set) var isAvailable = false

    func refresh() async {
        isAvailable = SpeechTranscriber.isAvailable
        available = await SpeechTranscriber.supportedLocales.sorted {
            displayName($0) < displayName($1)
        }

        // Ohne eigene Wahl wird nur abgeleitet, nicht festgeschrieben.
        // LocaleResolver weiss, dass SpeechTranscriber "en_US" meldet, wo
        // Aufrufer "en-US" schreiben - eine Abweichung, die frueher still
        // en_ZA und de_AT erzeugte.
        guard !available.isEmpty else { return }
        let alreadyValid = available.contains {
            $0.identifier.caseInsensitiveCompare(selectedID) == .orderedSame
        }
        guard !alreadyValid else {
            // Die gespeicherte Kennung wird so gemeldet, wie sie dasteht.
            resolvedFallback = nil
            return
        }
        // Sonst aufloesen, und zwar auch bei einer ausdruecklichen Wahl: die
        // Liste des Geraets kann sich aendern, und eine nicht mehr gemeldete
        // Kennung ist fuer den Erkenner wertlos.
        resolvedFallback = LocaleResolver.select(
            requested: Locale(identifier: selectedID),
            supported: available
        )
    }

    /// Die ausdrueckliche Wahl des Nutzers. Erst sie wird gespeichert.
    func select(_ identifier: String) {
        selectedID = identifier
        wasChosenExplicitly = true
        resolvedFallback = nil
        UserDefaults.standard.set(identifier, forKey: Self.defaultsKey)
        UserDefaults.standard.set(true, forKey: Self.explicitChoiceKey)
    }

    func displayName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    var selectedDisplayName: String {
        displayName(locale)
    }
}
