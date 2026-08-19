import Foundation
import Observation
import StenoPipeline

/// Nur die Speicherung und die Anbindung an die Ansichten. Die Seitenfolge
/// steht in `OnboardingFlow`, damit sie geprueft werden kann und die spaetere
/// iOS-App sie unveraendert erbt. Hier faellt bewusst keine Entscheidung.
@MainActor
@Observable
final class OnboardingModel {
    private static let finishedKey = "org.steno.onboardingFinished"

    private(set) var flow: OnboardingFlow

    /// Ein fehlender Schluessel liest sich als `false`: der erste Start hat
    /// den Wizard noch nicht hinter sich.
    init() {
        flow = OnboardingFlow(
            isFinished: UserDefaults.standard.bool(forKey: Self.finishedKey)
        )
    }

    var page: OnboardingFlow.Page { flow.page }
    var isFinished: Bool { flow.isFinished }
    var isLastPage: Bool { flow.isLastPage }

    func advance() {
        flow.advance()
        persist()
    }

    func skip() {
        flow.skip()
        persist()
    }

    func abort() {
        flow.abort()
        persist()
    }

    func reopen() {
        flow.reopen()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(flow.isFinished, forKey: Self.finishedKey)
    }
}
