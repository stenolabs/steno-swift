import FoundationModels
import Testing
@testable import StenoIntelligence

@Suite("Apple Foundation Models text provider")
struct FoundationModelsProviderTests {
    @Test("context budget reserves output and safety tokens")
    func contextBudgetReservesOutputAndSafetyTokens() {
        let window = TextModelContextWindow(
            maximumTokens: 4_096,
            reservedResponseTokens: 1_024,
            safetyTokens: 128
        )

        #expect(window.maximumInputTokens == 2_944)
    }

    @Test("pre-26.4 token estimates are conservative for UTF-8 input")
    func conservativeTokenEstimate() {
        #expect(FoundationModelsProvider.conservativeTokenCount("abc") == 2)
        #expect(FoundationModelsProvider.conservativeTokenCount("ä") == 1)
        #expect(FoundationModelsProvider.conservativeTokenCount("") == 1)
    }

    @Test("Apple context overflow maps to the shared adaptive-rendering error")
    func contextOverflowMapping() {
        let context = LanguageModelSession.GenerationError.Context(
            debugDescription: "test overflow"
        )

        #expect(FoundationModelsProvider.isContextWindowError(
            LanguageModelSession.GenerationError.exceededContextWindowSize(context)
        ))
        #expect(!FoundationModelsProvider.isContextWindowError(
            LanguageModelSession.GenerationError.rateLimited(context)
        ))
    }

    @Test("prompt timestamps are rounded to milliseconds")
    func promptTimestampsAreRounded() {
        #expect(FoundationModelsProvider.formattedTimestamp(3.4200000000000004) == "3.420")
        #expect(FoundationModelsProvider.formattedTimestamp(12.0) == "12.000")
    }
}
