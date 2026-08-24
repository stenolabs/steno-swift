import Foundation
import Observation
import StenoDomain

/// Nur die Speicherung. Die Regeln stehen in `OperatorIdentity`, damit sie
/// geprueft werden koennen und die spaetere iOS-App sie unveraendert erbt.
@MainActor
@Observable
final class OperatorProfile {
    /// Eine einzige Instanz, weil zwei Leser derselben Schluessel
    /// auseinanderdriften wuerden: im Protokoll stuende dann ein anderer Name
    /// als in den Einstellungen. Die Ansichten bekommen sie ueber die
    /// Umgebung, `AppModel` greift direkt zu, weil es keine Ansicht ist.
    static let shared = OperatorProfile()

    /// Der Hinweis unter den Profilfeldern, aus einer Quelle fuer
    /// Einstellungen und Wizard. Zwei Kopien hatten schon eine Luecke: im
    /// Wizard fehlte der Satz zur Uebertragung, und wer den Namen nur dort
    /// eintrug, erfuhr nie, was mit ihm geschieht.
    ///
    /// Der zweite Satz gehoert dazu: ohne ihn liest sich der erste wie ein
    /// Versprechen, der Name bleibe unter allen Umstaenden hier. Ueber die
    /// Teilnehmerliste geht er sehr wohl mit - nur eben, weil der Nutzer es
    /// so eingetragen hat.
    static let fieldNote: LocalizedStringResource = "Appears in the header of exported Markdown and stays on this Mac; this field is never sent to a language model. If you took part yourself, add yourself to that meeting's participants - that list does go to the model."
    static let onboardingFieldNote: LocalizedStringResource = "Appears in the header of exported Markdown and stays on this Mac; this field is never sent to a language model. If you took part yourself, add yourself to that meeting's participants - that list does go to the model. You can skip this and add it later in Settings."

    private static let nameKey = "org.steno.operatorName"
    private static let organizationKey = "org.steno.operatorOrganization"

    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: Self.nameKey) }
    }

    var organization: String {
        didSet { UserDefaults.standard.set(organization, forKey: Self.organizationKey) }
    }

    private init() {
        name = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
        organization = UserDefaults.standard.string(forKey: Self.organizationKey) ?? ""
    }

    var identity: OperatorIdentity {
        OperatorIdentity(name: name, organization: organization)
    }

    var authorLine: String? { identity.authorLine }
}
