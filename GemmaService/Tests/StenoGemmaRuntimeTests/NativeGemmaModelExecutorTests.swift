import Foundation
import FoundationModels
@_spi(StenoGemmaRuntime) import StenoGemmaIPC
@_spi(StenoGemmaRuntime) import StenoGemmaModelStore
import StenoGemmaServiceCore
import Testing
@_spi(StenoGemmaRuntime) @testable import StenoGemmaRuntime

@Suite("Native Gemma activation policy")
struct NativeGemmaActivationPolicyTests {
    @Test("the production helper catalog remains empty")
    func productionCatalogIsEmpty() throws {
        #expect(NativeGemmaActivationCatalog.production.profile(for: try pin()) == nil)
    }

    @Test("an exact unique pin selects its reviewed activation profile")
    func exactUniquePinSelectsProfile() throws {
        let expected = try profile()
        let catalog = NativeGemmaActivationCatalog(profiles: [expected])

        #expect(catalog.profile(for: expected.pin) == expected)
        #expect(catalog.profile(for: try pin(modelIdentifier: "test/other-gemma")) == nil)
    }

    @Test("duplicate exact entries fail closed")
    func duplicateEntriesFailClosed() throws {
        let expected = try profile()
        let catalog = NativeGemmaActivationCatalog(profiles: [expected, expected])

        #expect(catalog.profile(for: expected.pin) == nil)
    }

    @Test("profiles reject another adapter revision and empty prompt budgets")
    func invalidProfilesAreRejected() throws {
        #expect(throws: NativeGemmaActivationProfileError.adapterRevisionMismatch(
            expected: GemmaIPCBuildInfo.adapterRevision,
            actual: String(repeating: "0", count: 40)
        )) {
            _ = try profile(pin: pin(adapterRevision: String(repeating: "0", count: 40)))
        }
        #expect(throws: NativeGemmaActivationProfileError.invalidMaximumPromptTokens) {
            _ = try profile(maximumPromptTokens: 0)
        }
    }

    private func profile(
        pin: GemmaModelSnapshotPin? = nil,
        maximumPromptTokens: Int = 8_192
    ) throws -> NativeGemmaActivationProfile {
        try NativeGemmaActivationProfile(
            pin: pin ?? self.pin(),
            activationLimits: VerifiedGemmaModelActivationLimits(
                maximumSmallFileByteCount: 1_024,
                maximumTotalSmallFileByteCount: 4_096,
                maximumSafetensorsFileCount: 2,
                maximumSafetensorsFileByteCount: 1_024,
                maximumTotalSafetensorsByteCount: 2_048
            ),
            maximumPromptTokens: maximumPromptTokens
        )
    }

    private func pin(
        modelIdentifier: String = "test/gemma-4",
        adapterRevision: String = GemmaIPCBuildInfo.adapterRevision
    ) throws -> GemmaModelSnapshotPin {
        try GemmaModelSnapshotPin(
            modelIdentifier: modelIdentifier,
            checkpointRevision: String(repeating: "1", count: 40),
            adapterRevision: adapterRevision,
            licenseIdentifier: "Apache-2.0",
            manifestSHA256: String(repeating: "2", count: 64)
        )
    }
}

@Suite("Native Gemma model executor")
struct NativeGemmaModelExecutorTests {
    @Test("counting and generation use the exact same prompt text")
    func countAndGenerationSharePrompt() async throws {
        let calls = ExecutorCalls()
        let executor = NativeGemmaModelExecutor(
            maximumPromptTokens: 32,
            countPreparedTokens: { prompt in
                await calls.recordCount(prompt)
                return 7
            },
            generateResponse: { prompt, maximumTokens in
                await calls.recordGeneration(prompt, maximumTokens: maximumTokens)
                return "result"
            }
        )

        #expect(try await executor.countTokens(in: "same prompt") == 7)
        #expect(try await executor.generate(prompt: "same prompt", maximumTokens: 12) == "result")
        #expect(await calls.countPrompts == ["same prompt", "same prompt"])
        #expect(await calls.generations == [.init(prompt: "same prompt", maximumTokens: 12)])
    }

    @Test("an oversized prepared prompt fails before Foundation Models generation")
    func oversizedPromptFailsBeforeGeneration() async {
        let calls = ExecutorCalls()
        let executor = NativeGemmaModelExecutor(
            maximumPromptTokens: 4,
            countPreparedTokens: { _ in 5 },
            generateResponse: { prompt, maximumTokens in
                await calls.recordGeneration(prompt, maximumTokens: maximumTokens)
                return "must not run"
            }
        )

        await #expect(throws: GemmaModelExecutionError.contextWindowExceeded) {
            _ = try await executor.generate(prompt: "too large", maximumTokens: 1)
        }
        #expect(await calls.generations.isEmpty)
    }

    @Test("Foundation Models context errors map to the fixed IPC vocabulary")
    func foundationModelsContextErrorMapsExactly() async {
        let executor = NativeGemmaModelExecutor(
            maximumPromptTokens: 4,
            countPreparedTokens: { _ in 1 },
            generateResponse: { _, _ in
                throw LanguageModelError.contextSizeExceeded(.init(
                    contextSize: 4,
                    tokenCount: 5,
                    debugDescription: "private detail"
                ))
            }
        )

        await #expect(throws: GemmaModelExecutionError.contextWindowExceeded) {
            _ = try await executor.generate(prompt: "prompt", maximumTokens: 1)
        }
    }

    @Test("cancellation and unknown failures map without exposing details")
    func errorsMapToClosedVocabulary() async {
        let cancelled = NativeGemmaModelExecutor(
            maximumPromptTokens: 4,
            countPreparedTokens: { _ in 1 },
            generateResponse: { _, _ in throw CancellationError() }
        )
        await #expect(throws: GemmaModelExecutionError.cancelled) {
            _ = try await cancelled.generate(prompt: "prompt", maximumTokens: 1)
        }

        let failed = NativeGemmaModelExecutor(
            maximumPromptTokens: 4,
            countPreparedTokens: { _ in 1 },
            generateResponse: { _, _ in throw TestGenerationError.privateFailure }
        )
        await #expect(throws: GemmaModelExecutionError.generationFailed) {
            _ = try await failed.generate(prompt: "prompt", maximumTokens: 1)
        }
    }
}

private actor ExecutorCalls {
    struct Generation: Equatable {
        let prompt: String
        let maximumTokens: Int
    }

    private(set) var countPrompts: [String] = []
    private(set) var generations: [Generation] = []

    func recordCount(_ prompt: String) {
        countPrompts.append(prompt)
    }

    func recordGeneration(_ prompt: String, maximumTokens: Int) {
        generations.append(.init(prompt: prompt, maximumTokens: maximumTokens))
    }
}

private enum TestGenerationError: Error {
    case privateFailure
}
