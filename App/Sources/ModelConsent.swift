import Foundation
import Observation
import StenoDomain

/// Die Zustimmung zum Nachladen der Modelle.
///
/// Sie liegt bewusst hier und nicht in der Bibliothek: Sie ist eine
/// Entscheidung ueber diesen Rechner und sein Netz, keine Eigenschaft der
/// Meetings, und darf nicht mitwandern, wenn die Bibliothek den Mac wechselt.
///
/// Gespeichert wird kein nacktes Ja, sondern Zeitpunkt und benannte Quellen:
/// im Behoerdenumfeld ist die Nachvollziehbarkeit der halbe Wert.
@Observable
final class ModelConsent {
    private static let key = "org.steno.modelConsent"

    struct Record: Codable, Equatable {
        let grantedAt: Date
        let sources: [String]
    }

    private(set) var record: Record?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            record = try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    var isGranted: Bool { record != nil }

    func grant(sources: [ModelSource]) {
        // Der Zeitpunkt der ersten Zustimmung bleibt stehen. Ein zweiter
        // Klick nach einem Fehlschlag ist derselbe Entschluss, kein neuer,
        // und genau der erste Zeitpunkt ist das, was im Behoerdenumfeld
        // nachvollziehbar sein muss. Erst ein Widerruf loescht den Eintrag,
        // danach beginnt die Zaehlung neu.
        let value = Record(
            grantedAt: record?.grantedAt ?? Date(),
            sources: sources.map(\.displayHost)
        )
        record = value
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: Self.key)
    }

    /// Widerruf heisst: es wird nichts mehr geladen. Bereits installierte
    /// Modelle bleiben nutzbar, Apple-Assets sind ohnehin systemweit und von
    /// Steno nicht entfernbar. Der Text im Fenster muss das so sagen.
    func revoke() {
        record = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
