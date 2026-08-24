import Foundation
import Observation
import StenoDomain
import StenoTranscription

/// Die vom Nutzer ausdruecklich gewaehlten Live- und Final-Provider.
///
/// Eine Wahl hier ist eine Absicht, keine Zusicherung der Verfuegbarkeit:
/// ob ein Provider tatsaechlich installiert ist, entscheidet
/// `ModelInstallationCoordinator` zur Laufzeit. Die Oberflaeche zeigt ein
/// nicht installiertes Modell deshalb als nicht installiert und nicht als
/// waehlbar an (siehe `TranscriptionModelSettingsView`), waehlt aber nie
/// selbst um - "Modelle laden nicht von selbst" gilt auch fuer die Auswahl.
@MainActor
@Observable
final class TranscriptionModelSettings {
    private static let liveDefaultsKey = "steno.transcription.model.live"
    private static let finalDefaultsKey = "steno.transcription.model.final"
    private static let liveExperimentalKey = "steno.transcription.model.liveExperimental"

    private let defaults: UserDefaults
    private let catalog: TranscriptionModelCatalog

    private(set) var liveProviderID: TranscriptionProviderID
    private(set) var finalProviderID: TranscriptionProviderID

    /// Ob der noch unfertige Live-Adapter benutzt werden darf.
    ///
    /// Standardmaessig aus. Die Live-Transkription ist der empfindlichste Pfad
    /// der App: sie laeuft waehrend der Aufnahme, und die Aufnahme ist das
    /// einzige unersetzliche Artefakt. Wer den Schalter umlegt, tut das
    /// ausdruecklich und sieht in der Oberflaeche, worauf er sich einlaesst.
    private(set) var liveExperimentalEnabled: Bool

    init(
        defaults: UserDefaults = .standard,
        catalog: TranscriptionModelCatalog = .standard
    ) {
        self.defaults = defaults
        self.catalog = catalog
        liveProviderID = Self.storedSelection(
            key: Self.liveDefaultsKey,
            defaults: defaults,
            catalog: catalog,
            use: .live
        )
        finalProviderID = Self.storedSelection(
            key: Self.finalDefaultsKey,
            defaults: defaults,
            catalog: catalog,
            use: .final
        )
        liveExperimentalEnabled = defaults.bool(forKey: Self.liveExperimentalKey)
    }

    func select(_ id: TranscriptionProviderID, for use: TranscriptionUse) {
        switch use {
        case .live:
            liveProviderID = id
            defaults.set(id.rawValue, forKey: Self.liveDefaultsKey)
        case .final:
            finalProviderID = id
            defaults.set(id.rawValue, forKey: Self.finalDefaultsKey)
        }
    }


    func setLiveExperimentalEnabled(_ enabled: Bool) {
        liveExperimentalEnabled = enabled
        defaults.set(enabled, forKey: Self.liveExperimentalKey)
        // Faellt die Freischaltung weg, darf keine Wahl stehen bleiben, die
        // ohne sie gar nicht laufen kann.
        if !enabled, catalog.descriptor(for: liveProviderID)?.maturity == .experimental {
            select(catalog.defaultProvider(for: .live), for: .live)
        }
    }

    /// Die Feature-Schalter, die zur aktuellen Wahl gehoeren.
    var experimentalFeatures: TranscriptionExperimentalFeatures {
        TranscriptionExperimentalFeatures(parakeetLiveEnabled: liveExperimentalEnabled)
    }

    private static func storedSelection(
        key: String,
        defaults: UserDefaults,
        catalog: TranscriptionModelCatalog,
        use: TranscriptionUse
    ) -> TranscriptionProviderID {
        guard let raw = defaults.string(forKey: key) else {
            return catalog.defaultProvider(for: use)
        }
        let id = TranscriptionProviderID(rawValue: raw)
        // Eine gespeicherte Kennung, die der Katalog nicht mehr kennt, faellt
        // auf den Standard zurueck statt auf ein totes Modell zu zeigen.
        guard catalog.descriptor(for: id) != nil else {
            return catalog.defaultProvider(for: use)
        }
        return id
    }
}
