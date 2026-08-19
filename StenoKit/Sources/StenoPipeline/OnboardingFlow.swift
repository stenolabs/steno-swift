import Foundation

/// Zustand und Seitenfolge des Erstlauf-Wizards. Bewusst ohne Fenster und
/// ohne UserDefaults: die Speicherung liegt in der App, damit dieser Typ
/// auf jeder Plattform gilt.
public struct OnboardingFlow: Equatable, Sendable {
    /// Reihenfolge ist bindend: Sprache steht vor den Modellen, weil die
    /// Sprachassets an die Locale gebunden und reserviert werden. Ohne
    /// gewaehlte Sprache wuerde das Falsche geladen.
    public enum Page: Int, CaseIterable, Sendable {
        case welcome
        case profile
        case language
        case models
        case permissions
    }

    public private(set) var page: Page
    public private(set) var isFinished: Bool

    public init(page: Page = .welcome, isFinished: Bool = false) {
        self.page = page
        self.isFinished = isFinished
    }

    public var isLastPage: Bool { page == Page.allCases.last }

    public mutating func advance() {
        guard let next = Page(rawValue: page.rawValue + 1) else {
            isFinished = true
            return
        }
        page = next
    }

    /// Ueberspringen und Weitergehen sind derselbe Schritt: der Unterschied
    /// liegt darin, ob die Seite etwas gespeichert hat, nicht in der Folge.
    public mutating func skip() { advance() }

    /// Auch der bewusste Abbruch gilt als erledigt: wer den Wizard wegklickt,
    /// soll ihn nicht bei jedem Start wiedersehen. Erneut zu oeffnen ueber
    /// das Hilfe-Menue.
    public mutating func abort() { isFinished = true }

    public mutating func reopen() {
        page = .welcome
        isFinished = false
    }
}
