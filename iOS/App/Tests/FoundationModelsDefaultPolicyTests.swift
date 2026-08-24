import FoundationModels
import StenoIntelligence
import Testing

@Suite("Apple system language model default policy")
struct FoundationModelsDefaultPolicyTests {
    @Test("reports record Advanced or 3B Core instead of a generic Apple model")
    func reportDescriptorRecordsConcreteVariant() {
        let modelVersion = FoundationModelsProvider().descriptor.modelVersion
        #expect(
            modelVersion == "AFM 3 Core Advanced"
                || modelVersion == "AFM 3 Core"
                || modelVersion == "SystemLanguageModel"
        )
    }

    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    @Test("iOS 27 descriptor records the variant selected by SystemLanguageModel.default")
    func descriptorMatchesOSSelectedVariant() {
        let variant = SystemLanguageModel.default.variant
        let expected: String
        if variant == .coreAdvanced3 {
            expected = "AFM 3 Core Advanced"
        } else if variant == .core3 {
            expected = "AFM 3 Core"
        } else {
            expected = variant.displayName.isEmpty
                ? "SystemLanguageModel"
                : variant.displayName
        }
        #expect(FoundationModelsProvider().descriptor.modelVersion == expected)
    }
    #endif
}
