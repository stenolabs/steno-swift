import Testing
@testable import Steno

@MainActor
@Suite("Navigation router")
struct NavigationRouterTests {
    @Test("language models selection is independent for each window router")
    func languageModelsSelectionIsWindowLocal() {
        let first = NavigationRouter()
        let second = NavigationRouter()

        first.selection = .languageModels

        #expect(first.selection == .languageModels)
        #expect(second.selection == .recording)
    }
}
