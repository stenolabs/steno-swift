import Foundation
import FoundationModels
import Metal
import MLX
import MLXLMCommon
import MLXNN
import Testing
@testable import StenoMLXFoundationModels

@Suite("Stored MLX language model", .serialized)
struct StoredMLXLanguageModelTests {
    @Test("stored containers have no loader or file-backed availability path")
    func storedContainerAvoidsLoaderAndDiskState() async throws {
        let fixture = try await StoredContainerFixture.make()

        #expect(fixture.model.weightsLocation == nil)
        #expect(fixture.model.modelExistsOnDisk())
        #expect(fixture.model.freeDiskSpaceBytes == nil)

        let availability = await fixture.model.availability
        if MTLCreateSystemDefaultDevice() == nil {
            #expect(availability == .unavailable(.deviceNotCapable))
        } else {
            #expect(availability == .available)
        }
    }

    @Test("stored loads preserve container identity through eviction")
    func storedContainerSurvivesEviction() async throws {
        let fixture = try await StoredContainerFixture.make()

        let initial = try await fixture.model.loadContainer()
        let repeated = try await fixture.model.loadContainer()
        #expect(initial === fixture.container)
        #expect(repeated === fixture.container)

        await fixture.model.evict()
        await MLXLanguageModel.evictAll()

        let afterEviction = try await fixture.model.loadContainer()
        #expect(afterEviction === fixture.container)
    }

    @Test("stored instances with the same model ID own distinct derived caches")
    func storedModelsDoNotShareDerivedArtifacts() async throws {
        let first = try await StoredContainerFixture.make()
        let second = try await StoredContainerFixture.make()

        #expect(first.model.modelID == second.model.modelID)
        #expect(first.model.storedDerivedArtifactCacheIdentity != nil)
        #expect(first.model.storedDerivedArtifactCacheIdentity
            != second.model.storedDerivedArtifactCacheIdentity)
        #expect(!first.model.usesDeferredModelCache)
        #expect(!first.model.shouldConfigureGPUCacheOnLoad)
    }

    @Test("stored eviction does not mutate deferred state with the same model ID")
    func storedEvictionDoesNotTouchDeferredState() async throws {
        let stored = try await StoredContainerFixture.make()
        let deferred = MLXLanguageModel(
            configuration: .init(id: stored.model.modelID),
            weightsLocation: { _ in URL(fileURLWithPath: "/unused") },
            load: { _, _ in throw DeferredFixtureError.unexpectedLoad })

        await deferred.evict()
        let before = await MLXLanguageModel.deferredCacheMutationGeneration()
        await stored.model.evict()
        let after = await MLXLanguageModel.deferredCacheMutationGeneration()

        #expect(deferred.usesDeferredModelCache)
        #expect(before == after)
    }

    @Test(
        "opt-in Metal-host sentinel: stored loads preserve MLX cache policy",
        .enabled(
            if: ProcessInfo.processInfo.environment["STENO_RUN_MLX_MEMORY_SENTINEL"] == "1",
            "Requires a Metal-ready MLX test host and explicit opt-in"
        )
    )
    func optInMetalHostMemoryPolicySentinel() async throws {
        // This is deliberately not part of the ordinary focused test proof.
        // The local Xcode 27 test host lacks MLX's default metallib. Run only
        // on a Metal-ready host with STENO_RUN_MLX_MEMORY_SENTINEL=1.
        let fixture = try await StoredContainerFixture.make()
        let originalLimit = MLX.Memory.cacheLimit
        defer { MLX.Memory.cacheLimit = originalLimit }
        MLX.Memory.cacheLimit = 17 * 1024 * 1024

        _ = try await fixture.model.loadContainer()
        try await fixture.model.preload()

        #expect(MLX.Memory.cacheLimit == 17 * 1024 * 1024)
    }

    @Test("stored descriptors are used verbatim without resolving config.json")
    func storedDescriptorIsVerbatim() async throws {
        let fixture = try await StoredContainerFixture.make()
        let poisonCounter = fixture.counter

        let descriptor = MLXLanguageModel.descriptor(
            for: fixture.context,
            modelID: "different/model-id",
            storedDescriptor: fixture.model.storedDescriptor,
            weightsLocation: { _ in
                poisonCounter.recordCall()
                return URL(fileURLWithPath: "/poison")
            })

        #expect(descriptor.modelId == fixture.descriptor.modelId)
        #expect(descriptor.modelType == fixture.descriptor.modelType)
        #expect(descriptor.configData == fixture.descriptor.configData)
        #expect(fixture.counter.calls == 0)
    }

    @Test("framework prewarm is a no-op for stored containers")
    func frameworkPrewarmDoesNoWork() async throws {
        let fixture = try await StoredContainerFixture.make()
        let executor = try MLXLanguageModel.Executor(
            configuration: .init(modelID: fixture.model.modelID))

        #expect(!fixture.model.shouldScheduleFrameworkPrewarm)
        executor.prewarm(model: fixture.model, transcript: Transcript())
        for _ in 0 ..< 8 {
            await Task.yield()
        }

        #expect(fixture.counter.calls == 0)
    }

    @Test("stored container configuration must exactly match adapter configuration")
    func storedContainerConfigurationMismatchIsRejected() async throws {
        let fixture = try await StoredContainerFixture.make()

        await #expect(throws: MLXLanguageModel.StoredContainerInitializationError
            .containerConfigurationMismatch)
        {
            _ = try await MLXLanguageModel(
                configuration: ModelConfiguration(id: "test/other-container"),
                container: fixture.container,
                descriptorModelType: fixture.descriptor.modelType,
                descriptorConfigData: fixture.descriptor.configData)
        }

        var sameIDDifferentPrompt = fixture.model.configuration
        sameIDDifferentPrompt.defaultPrompt = "different default prompt"
        #expect(sameIDDifferentPrompt.name == fixture.model.modelID)
        await #expect(throws: MLXLanguageModel.StoredContainerInitializationError
            .containerConfigurationMismatch)
        {
            _ = try await MLXLanguageModel(
                configuration: sameIDDifferentPrompt,
                container: fixture.container,
                descriptorModelType: fixture.descriptor.modelType,
                descriptorConfigData: fixture.descriptor.configData)
        }
    }

    @Test("activation initializer synchronously consumes one correlated context")
    func activationInitializerConsumesCorrelatedContext() async throws {
        let configuration = ModelConfiguration(id: "test/activation-context")
        let counter = InvocationCounter()
        let context = ModelContext(
            configuration: configuration,
            model: StoredTestModel(counter: counter),
            processor: CountingProcessor(counter: counter),
            tokenizer: StoredTokenizer()
        )

        let model = try MLXLanguageModel(
            configuration: configuration,
            context: context,
            descriptorModelType: "gemma4",
            descriptorConfigData: Data("verified-config".utf8)
        )
        let container = try await model.loadContainer()
        #expect(await container.configuration == configuration)
        #expect(model.storedDescriptor?.modelType == "gemma4")
        #expect(model.storedDescriptor?.configData == Data("verified-config".utf8))
        #expect(model.weightsLocation == nil)

        let mismatchedContext = ModelContext(
            configuration: configuration,
            model: StoredTestModel(counter: counter),
            processor: CountingProcessor(counter: counter),
            tokenizer: StoredTokenizer()
        )
        #expect(throws: MLXLanguageModel.StoredContainerInitializationError
            .containerConfigurationMismatch)
        {
            _ = try MLXLanguageModel(
                configuration: ModelConfiguration(id: "test/different-activation-context"),
                context: mismatchedContext,
                descriptorModelType: "gemma4",
                descriptorConfigData: nil
            )
        }
    }

    @Test("generation routing and framed protocol gates follow the active path")
    func generationRouteAndFramedProtocolGate() throws {
        #expect(MLXLanguageModel.generationRoute(
            hasEnabledTools: true,
            usesAllowedToolBehavior: true,
            hasSchema: true,
            usesReasoning: true) == .allowedTools)
        #expect(MLXLanguageModel.generationRoute(
            hasEnabledTools: true,
            usesAllowedToolBehavior: false,
            hasSchema: true,
            usesReasoning: true) == .requiredTools)
        #expect(MLXLanguageModel.generationRoute(
            hasEnabledTools: false,
            usesAllowedToolBehavior: true,
            hasSchema: true,
            usesReasoning: true) == .schema)
        #expect(MLXLanguageModel.generationRoute(
            hasEnabledTools: false,
            usesAllowedToolBehavior: true,
            hasSchema: false,
            usesReasoning: true) == .reasoning)
        #expect(MLXLanguageModel.generationRoute(
            hasEnabledTools: false,
            usesAllowedToolBehavior: true,
            hasSchema: false,
            usesReasoning: false) == .plain)

        #expect(throws: MLXLanguageModel.UnsupportedProtocolError.framedToolProtocol(.gptOSS)) {
            try MLXLanguageModel.rejectUnsupportedFramedProtocol(.gptOSS, for: .allowedTools)
        }
        #expect(throws: MLXLanguageModel.UnsupportedProtocolError.framedToolProtocol(.atem)) {
            try MLXLanguageModel.rejectUnsupportedFramedProtocol(.atem, for: .requiredTools)
        }
        #expect(throws: MLXLanguageModel.UnsupportedProtocolError.framedToolProtocol(.gptOSS)) {
            try MLXLanguageModel.rejectUnsupportedFramedProtocol(.gptOSS, for: .reasoning)
        }
        try MLXLanguageModel.rejectUnsupportedFramedProtocol(.gptOSS, for: .schema)
        try MLXLanguageModel.rejectUnsupportedFramedProtocol(.atem, for: .plain)
        try MLXLanguageModel.rejectUnsupportedFramedProtocol(.json, for: .allowedTools)
        try MLXLanguageModel.rejectUnsupportedFramedProtocol(nil, for: .reasoning)
    }
}

private enum DeferredFixtureError: Error {
    case unexpectedLoad
}

private final class StoredContainerFixture {
    let counter: InvocationCounter
    let context: ModelContext
    let container: ModelContainer
    let descriptor: ModelDescriptor
    let model: MLXLanguageModel

    private init(
        counter: InvocationCounter,
        context: ModelContext,
        container: ModelContainer,
        descriptor: ModelDescriptor,
        model: MLXLanguageModel
    ) {
        self.counter = counter
        self.context = context
        self.container = container
        self.descriptor = descriptor
        self.model = model
    }

    static func make() async throws -> StoredContainerFixture {
        let configuration = ModelConfiguration(id: "test/stored-container")
        let counter = InvocationCounter()
        let tokenizer = StoredTokenizer()
        let context = ModelContext(
            configuration: configuration,
            model: StoredTestModel(counter: counter),
            processor: CountingProcessor(counter: counter),
            tokenizer: tokenizer)
        let container = ModelContainer(context: context)
        let model = try await MLXLanguageModel(
            configuration: configuration,
            container: container,
            descriptorModelType: "stored-test",
            descriptorConfigData: Data("descriptor-only".utf8))
        guard let descriptor = model.storedDescriptor else {
            fatalError("Stored initializer must retain its internally derived descriptor")
        }
        return StoredContainerFixture(
            counter: counter,
            context: context,
            container: container,
            descriptor: descriptor,
            model: model)
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var calls: Int {
        lock.withLock { value }
    }

    func recordCall() {
        lock.withLock { value += 1 }
    }
}

private final class StoredTestModel: Module, MLXLMCommon.LanguageModel,
    KVCacheDimensionProvider
{
    private let counter: InvocationCounter
    let kvHeads: [Int] = []

    init(counter: InvocationCounter) {
        self.counter = counter
        super.init()
    }

    func prepare() throws {}

    func prepare(
        _ input: LMInput,
        cache: [KVCache],
        state: MLXLMCommon.LMOutput.State?,
        prefill: PrefillParameters
    ) throws -> PrepareResult {
        .tokens(input.text)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        counter.recordCall()
        return MLXArray.zeros([inputs.dim(0), inputs.dim(1), 1])
    }
}

private struct CountingProcessor: UserInputProcessor {
    let counter: InvocationCounter

    func prepare(input: UserInput) async throws -> LMInput {
        counter.recordCall()
        throw ProcessorError.unexpectedWork
    }

    private enum ProcessorError: Error {
        case unexpectedWork
    }
}

private struct StoredTokenizer: Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}
