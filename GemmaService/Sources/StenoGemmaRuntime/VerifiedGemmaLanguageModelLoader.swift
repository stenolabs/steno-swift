import Foundation
import FoundationModels
import Hub
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import StenoMLXFoundationModels
@_spi(StenoGemmaRuntime) import StenoGemmaIPC
@_spi(StenoGemmaRuntime) import StenoGemmaModelStore
import Tokenizers

@available(macOS 27.0, *)
extension GemmaLanguageModelFactory {
    /// Materializes Gemma 4 exclusively from one-shot, descriptor-rooted activation bytes.
    ///
    /// The returned adapter is published only after `consume` performs its final descriptor-rooted
    /// revalidation. This path has no URL, downloader, cache lookup, Ollama bridge, or system-model
    /// fallback.
    @_spi(StenoGemmaRuntime)
    public static func makeLanguageModel(
        consuming activationAssets: VerifiedGemmaModelActivationAssets,
        cancellationCheck: @escaping @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
    ) throws -> MLXLanguageModel {
        guard activationAssets.adapterRevision == GemmaServiceBuildInfo.adapterRevision else {
            throw GemmaLanguageModelFactoryError.adapterRevisionMismatch(
                expected: GemmaServiceBuildInfo.adapterRevision,
                actual: activationAssets.adapterRevision
            )
        }

        return try activationAssets.consume(cancellationCheck: cancellationCheck) { assets in
            try cancellationCheck()
            let configurationData = try requiredData("config.json", in: assets)
            let validatedConfiguration = try validateConfiguration(configurationData)
            let tokenizer = try makeTokenizer(from: assets)
            try cancellationCheck()

            return try MLX.withError {
                let model = try MLX.withError {
                    Gemma4Model(validatedConfiguration.gemmaConfiguration)
                }
                var (weights, metadata) = try loadVerifiedWeights(
                    from: assets,
                    cancellationCheck: cancellationCheck
                )
                try cancellationCheck()

                weights = try MLX.withError {
                    model.sanitize(weights: weights, metadata: metadata)
                }
                try cancellationCheck()
                guard !weights.isEmpty else {
                    throw GemmaLanguageModelFactoryError.unsafeModelConfiguration(
                        "weight sanitization produced no text-model parameters"
                    )
                }

                if let perLayerQuantization = validatedConfiguration.baseConfiguration
                    .perLayerQuantization
                {
                    try validateQuantizedModelPaths(
                        model: model,
                        weights: weights,
                        configuration: perLayerQuantization
                    )
                    try MLX.withError {
                        quantize(model: model) { path, _ in
                            guard weights["\(path).scales"] != nil else { return nil }
                            return perLayerQuantization.quantization(layer: path)?.asTuple
                        }
                    }
                }
                try cancellationCheck()

                try validateExactModelWeightSet(model: model, weights: weights)
                try validateModelParameterDTypes(model: model, weights: weights)
                let parameters = ModuleParameters.unflattened(weights)
                try model.update(parameters: parameters, verify: [.all])
                try cancellationCheck()
                try MLX.withError {
                    try model.prepare()
                    try MLX.checkedEval(model)
                }
                try cancellationCheck()

                let generationConfiguration = try generationConfiguration(
                    from: assets,
                    vocabularySize: validatedConfiguration.vocabularySize
                )
                let eosTokenIDs = generationConfiguration?.eosTokenIds.map { Set($0.values) }
                    ?? validatedConfiguration.baseConfiguration.effectiveEOSTokenIds
                let stopStrings = generationConfiguration?.stopStrings ?? []
                let modelConfiguration = ModelConfiguration(
                    id: "steno-local/\(assets.manifestSHA256)",
                    revision: assets.checkpointRevision,
                    stopStrings: stopStrings,
                    eosTokenIds: eosTokenIDs,
                    toolCallFormat: model.toolCallFormat
                )
                let messageGenerator = model.messageGenerator(tokenizer: tokenizer)
                let processor = StrictGemmaUserInputProcessor(
                    tokenizer: tokenizer,
                    messageGenerator: messageGenerator
                )
                let context = ModelContext(
                    configuration: modelConfiguration,
                    model: model,
                    processor: processor,
                    tokenizer: tokenizer
                )
                try cancellationCheck()

                return try MLXLanguageModel(
                    configuration: modelConfiguration,
                    capabilities: [.guidedGeneration, .toolCalling],
                    context: context,
                    descriptorModelType: validatedConfiguration.baseConfiguration.modelType,
                    descriptorConfigData: configurationData
                )
            }
        }
    }

    static func validateVerifiedConfigurationForTesting(_ data: Data) throws {
        _ = try validateConfiguration(data)
    }

    static func validateSafetensorsIndexForTesting(
        data: Data?,
        shardPaths: [String],
        tensorsByShard: [String: Set<String>]
    ) throws {
        let index = try validatedIndex(data: data, shardPaths: shardPaths)
        var seen = Set<String>()
        for path in shardPaths.sorted() {
            for tensor in tensorsByShard[path, default: []] {
                guard seen.insert(tensor).inserted else {
                    throw GemmaLanguageModelFactoryError.safetensorsIndexMismatch
                }
                if let index, index.weightMap[tensor] != path {
                    throw GemmaLanguageModelFactoryError.safetensorsIndexMismatch
                }
            }
        }
        if let index, Set(index.weightMap.keys) != seen {
            throw GemmaLanguageModelFactoryError.safetensorsIndexMismatch
        }
    }

    static func validateWeightNamesForTesting(_ names: [String]) throws {
        var sanitizedNames = Set<String>()
        for name in names {
            try validateTextWeightName(name)
            for target in sanitizedTargets(for: name) {
                guard sanitizedNames.insert(target).inserted else {
                    throw GemmaLanguageModelFactoryError.sanitizedWeightNameCollision(target)
                }
            }
        }
    }

    static func validateModelWeightSetForTesting(
        expected: Set<String>,
        actual: Set<String>
    ) throws {
        try validateExactModelWeightSet(expected: expected, actual: actual)
    }

    static func validateModelParameterDTypeForTesting(
        expectsPackedUInt32: Bool,
        actualSafetensorsDType: String
    ) throws {
        guard let actual = VerifiedGemmaSafetensorsDType(
            rawValue: actualSafetensorsDType
        )?.mlxDType else {
            throw GemmaLanguageModelFactoryError.modelParameterDTypeMismatch(
                parameter: "test.parameter",
                dtype: actualSafetensorsDType
            )
        }
        try validateModelParameterDType(
            expected: expectsPackedUInt32 ? .uint32 : .float32,
            actual: actual,
            parameter: "test.parameter"
        )
    }

    static func validateSanitizerTensorForTesting(
        name: String,
        shape: [UInt64]
    ) throws {
        try validateSanitizerTensor(name: name, shape: shape)
    }

    static func tokenizerChatTemplateForTesting(
        configurationData: Data,
        jinjaData: Data? = nil,
        jsonTemplateData: Data? = nil
    ) throws -> String? {
        let object = try tokenizerConfigurationObject(
            configurationData: configurationData,
            jinjaData: jinjaData,
            jsonTemplateData: jsonTemplateData
        )
        return object["chat_template"] as? String
    }
}

@available(macOS 27.0, *)
private extension GemmaLanguageModelFactory {
    struct ValidatedConfiguration {
        let baseConfiguration: BaseConfiguration
        let gemmaConfiguration: Gemma4Configuration
        let vocabularySize: Int
    }

    struct RootConfiguration: Decodable {
        let modelType: String
        let vocabSize: Int?
        let textConfiguration: TextConfiguration?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case vocabSize = "vocab_size"
            case textConfiguration = "text_config"
        }
    }

    struct TextConfiguration: Decodable {
        let modelType: String?
        let hiddenSize: Int?
        let numHiddenLayers: Int?
        let intermediateSize: Int?
        let numAttentionHeads: Int?
        let headDimension: Int?
        let globalHeadDimension: Int?
        let globalPartialRotaryFactor: Double?
        let rmsNormEpsilon: Double?
        let vocabSize: Int?
        let vocabSizePerLayerInput: Int?
        let numKeyValueHeads: Int?
        let numGlobalKeyValueHeads: Int?
        let numKVSharedLayers: Int?
        let hiddenSizePerLayerInput: Int?
        let slidingWindow: Int?
        let slidingWindowPattern: Int?
        let maxPositionEmbeddings: Int?
        let finalLogitSoftcapping: Double?
        let enableMoEBlock: Bool?
        let numExperts: Int?
        let topKExperts: Int?
        let moeIntermediateSize: Int?
        let layerTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case hiddenSize = "hidden_size"
            case numHiddenLayers = "num_hidden_layers"
            case intermediateSize = "intermediate_size"
            case numAttentionHeads = "num_attention_heads"
            case headDimension = "head_dim"
            case globalHeadDimension = "global_head_dim"
            case globalPartialRotaryFactor = "global_partial_rotary_factor"
            case rmsNormEpsilon = "rms_norm_eps"
            case vocabSize = "vocab_size"
            case vocabSizePerLayerInput = "vocab_size_per_layer_input"
            case numKeyValueHeads = "num_key_value_heads"
            case numGlobalKeyValueHeads = "num_global_key_value_heads"
            case numKVSharedLayers = "num_kv_shared_layers"
            case hiddenSizePerLayerInput = "hidden_size_per_layer_input"
            case slidingWindow = "sliding_window"
            case slidingWindowPattern = "sliding_window_pattern"
            case maxPositionEmbeddings = "max_position_embeddings"
            case finalLogitSoftcapping = "final_logit_softcapping"
            case enableMoEBlock = "enable_moe_block"
            case numExperts = "num_experts"
            case topKExperts = "top_k_experts"
            case moeIntermediateSize = "moe_intermediate_size"
            case layerTypes = "layer_types"
        }
    }

    struct SafetensorsIndex: Decodable {
        let weightMap: [String: String]

        enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
    }

    static func validateConfiguration(_ data: Data) throws -> ValidatedConfiguration {
        do {
            try GemmaStrictJSONValidation.validateNoDuplicateObjectKeys(data)
        } catch {
            throw GemmaLanguageModelFactoryError.configurationMalformed
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GemmaLanguageModelFactoryError.configurationMalformed
        }
        guard let rootObject = object as? [String: Any] else {
            throw GemmaLanguageModelFactoryError.configurationMalformed
        }
        if let mediaKey = firstMediaConfigurationKey(in: rootObject) {
            throw GemmaLanguageModelFactoryError.unsupportedMediaConfiguration(mediaKey)
        }
        if let architectures = rootObject["architectures"] as? [String],
           architectures.contains(where: {
               $0.localizedCaseInsensitiveContains("ConditionalGeneration")
           })
        {
            throw GemmaLanguageModelFactoryError.unsupportedMediaConfiguration("architectures")
        }

        let decoder = JSONDecoder.json5()
        let root: RootConfiguration
        do {
            root = try decoder.decode(RootConfiguration.self, from: data)
        } catch {
            throw GemmaLanguageModelFactoryError.configurationMalformed
        }
        guard root.modelType == "gemma4" else {
            throw GemmaLanguageModelFactoryError.unsupportedModelType(root.modelType)
        }
        if let nestedType = root.textConfiguration?.modelType,
           nestedType != "gemma4_text"
        {
            throw GemmaLanguageModelFactoryError.unsupportedModelType(nestedType)
        }

        let text: TextConfiguration
        if let nested = root.textConfiguration {
            text = nested
        } else {
            do {
                text = try decoder.decode(TextConfiguration.self, from: data)
            } catch {
                throw GemmaLanguageModelFactoryError.configurationMalformed
            }
        }
        let vocabularySize = try validateTextConfiguration(
            text,
            rootVocabSize: root.vocabSize,
            hasNestedTextConfiguration: root.textConfiguration != nil,
            rawObject: rootObject
        )

        let base: BaseConfiguration
        let gemma: Gemma4Configuration
        do {
            base = try decoder.decode(BaseConfiguration.self, from: data)
            gemma = try decoder.decode(Gemma4Configuration.self, from: data)
        } catch {
            throw GemmaLanguageModelFactoryError.configurationMalformed
        }
        try validateQuantizationConfiguration(base.perLayerQuantization)
        try validateEOSTokenIDs(
            base.effectiveEOSTokenIds,
            vocabularySize: vocabularySize,
            source: "config.json"
        )
        return ValidatedConfiguration(
            baseConfiguration: base,
            gemmaConfiguration: gemma,
            vocabularySize: vocabularySize
        )
    }

    static func validateTextConfiguration(
        _ text: TextConfiguration,
        rootVocabSize: Int?,
        hasNestedTextConfiguration: Bool,
        rawObject: [String: Any]
    ) throws -> Int {
        let hiddenSize = text.hiddenSize ?? 1536
        let layerCount = text.numHiddenLayers ?? 35
        let intermediateSize = text.intermediateSize ?? 6144
        let attentionHeads = text.numAttentionHeads ?? 8
        let headDimension = text.headDimension ?? 256
        let globalHeadDimension = text.globalHeadDimension ?? 512
        let keyValueHeads = text.numKeyValueHeads ?? 1
        let globalKeyValueHeads = text.numGlobalKeyValueHeads
        let sharedLayerCount = text.numKVSharedLayers ?? 20
        let perLayerInputSize = text.hiddenSizePerLayerInput ?? 256
        let perLayerVocabSize = text.vocabSizePerLayerInput ?? 262_144
        let vocabSize = hasNestedTextConfiguration
            ? (rootVocabSize ?? 262_144)
            : (text.vocabSize ?? 262_144)
        let slidingWindow = text.slidingWindow ?? 512
        let slidingPattern = text.slidingWindowPattern ?? 5
        let maximumPositions = text.maxPositionEmbeddings ?? 131_072
        let epsilon = text.rmsNormEpsilon ?? 1e-6
        let softcap = text.finalLogitSoftcapping ?? 30
        let partialRotaryFactor = text.globalPartialRotaryFactor ?? 0.25

        try requirePositive(hiddenSize, name: "hidden_size", maximum: 1_048_576)
        try requirePositive(layerCount, name: "num_hidden_layers", maximum: 512)
        try requirePositive(intermediateSize, name: "intermediate_size", maximum: 4_194_304)
        try requirePositive(attentionHeads, name: "num_attention_heads", maximum: 4096)
        try requirePositive(headDimension, name: "head_dim", maximum: 1_048_576)
        try requirePositive(globalHeadDimension, name: "global_head_dim", maximum: 1_048_576)
        try requirePositive(keyValueHeads, name: "num_key_value_heads", maximum: 4096)
        try requirePositive(vocabSize, name: "vocab_size", maximum: 16_777_216)
        try requirePositive(slidingWindow, name: "sliding_window", maximum: Int.max)
        try requirePositive(maximumPositions, name: "max_position_embeddings", maximum: Int.max)
        guard attentionHeads.isMultiple(of: keyValueHeads) else {
            throw unsafe("num_attention_heads must be divisible by num_key_value_heads")
        }
        if let globalKeyValueHeads {
            try requirePositive(
                globalKeyValueHeads,
                name: "num_global_key_value_heads",
                maximum: 4096
            )
            guard attentionHeads.isMultiple(of: globalKeyValueHeads) else {
                throw unsafe(
                    "num_attention_heads must be divisible by num_global_key_value_heads"
                )
            }
        }
        guard sharedLayerCount >= 0, sharedLayerCount < layerCount else {
            throw unsafe("num_kv_shared_layers must be in 0..<num_hidden_layers")
        }
        guard perLayerInputSize >= 0, perLayerInputSize <= 1_048_576 else {
            throw unsafe("hidden_size_per_layer_input is outside the supported range")
        }
        if perLayerInputSize > 0 {
            try requirePositive(
                perLayerVocabSize,
                name: "vocab_size_per_layer_input",
                maximum: 16_777_216
            )
        }
        guard Float(epsilon) == Float(1e-6) else {
            throw unsafe("rms_norm_eps must equal 1e-6 for the pinned Gemma 4 implementation")
        }
        guard softcap.isFinite, softcap > 0 else {
            throw unsafe("final_logit_softcapping must be finite and positive")
        }
        guard partialRotaryFactor.isFinite,
              partialRotaryFactor > 0,
              partialRotaryFactor <= 1
        else {
            throw unsafe("global_partial_rotary_factor must be in (0, 1]")
        }

        _ = try checkedProduct(hiddenSize, vocabSize, name: "token embedding")
        _ = try checkedProduct(attentionHeads, headDimension, name: "attention projection")
        _ = try checkedProduct(
            attentionHeads,
            globalHeadDimension,
            name: "global attention projection"
        )
        if perLayerInputSize > 0 {
            _ = try checkedProduct(layerCount, perLayerInputSize, name: "per-layer input")
        }

        let layerTypes: [String]
        if let configured = text.layerTypes {
            guard configured.count == layerCount else {
                throw unsafe("layer_types must contain exactly num_hidden_layers entries")
            }
            layerTypes = configured
        } else {
            try requirePositive(slidingPattern, name: "sliding_window_pattern", maximum: 512)
            layerTypes = (0 ..< layerCount).map { index in
                (index + 1).isMultiple(of: slidingPattern)
                    ? "full_attention"
                    : "sliding_attention"
            }
        }
        guard layerTypes.allSatisfy({
            $0 == "full_attention" || $0 == "sliding_attention"
        }) else {
            throw unsafe("layer_types contains an unsupported attention type")
        }
        if sharedLayerCount > 0 {
            let firstShared = layerCount - sharedLayerCount
            let sourceTypes = Set(layerTypes[..<firstShared])
            guard layerTypes[firstShared...].allSatisfy(sourceTypes.contains) else {
                throw unsafe("every KV-shared layer requires an earlier layer of the same type")
            }
        }

        if text.enableMoEBlock == true {
            guard let experts = text.numExperts,
                  let topK = text.topKExperts,
                  let moeIntermediateSize = text.moeIntermediateSize
            else {
                throw unsafe(
                    "MoE requires num_experts, top_k_experts, and moe_intermediate_size"
                )
            }
            try requirePositive(experts, name: "num_experts", maximum: 65_536)
            try requirePositive(topK, name: "top_k_experts", maximum: experts)
            try requirePositive(
                moeIntermediateSize,
                name: "moe_intermediate_size",
                maximum: 4_194_304
            )
        }

        let textObject = (rawObject["text_config"] as? [String: Any]) ?? rawObject
        if let rope = textObject["rope_parameters"] as? [String: Any] {
            for attentionType in ["sliding_attention", "full_attention"] {
                guard let values = rope[attentionType] as? [String: Any] else { continue }
                if let theta = numericValue(values["rope_theta"]),
                   (!theta.isFinite || theta <= 0)
                {
                    throw unsafe("\(attentionType).rope_theta must be finite and positive")
                }
                if attentionType == "full_attention",
                   let factor = numericValue(values["partial_rotary_factor"]),
                   (!factor.isFinite || factor <= 0 || factor > 1)
                {
                    throw unsafe(
                        "full_attention.partial_rotary_factor must be in (0, 1]"
                    )
                }
            }
        }
        return vocabSize
    }

    static func validateQuantizationConfiguration(
        _ configuration: BaseConfiguration.PerLayerQuantization?
    ) throws {
        guard let configuration else { return }
        if let quantization = configuration.quantization {
            try validateQuantization(quantization, path: "quantization")
        }
        for (path, option) in configuration.perLayerQuantization {
            guard !path.isEmpty else {
                throw unsafe("quantization contains an empty layer path")
            }
            if case .quantize(let quantization) = option {
                try validateQuantization(
                    quantization,
                    path: "quantization.\(path)"
                )
            }
        }
    }

    static func validateQuantization(
        _ quantization: BaseConfiguration.Quantization,
        path: String
    ) throws {
        let valid: Bool
        switch quantization.mode {
        case .affine:
            valid = [32, 64, 128].contains(quantization.groupSize)
                && [2, 3, 4, 5, 6, 8].contains(quantization.bits)
        case .mxfp4:
            valid = quantization.groupSize == 32 && quantization.bits == 4
        case .mxfp8:
            valid = quantization.groupSize == 32 && quantization.bits == 8
        case .nvfp4:
            valid = quantization.groupSize == 16 && quantization.bits == 4
        }
        guard valid else {
            throw unsafe("\(path) uses unsupported group_size, bits, or mode")
        }
    }

    static func validateQuantizedModelPaths(
        model: Module,
        weights: [String: MLXArray],
        configuration: BaseConfiguration.PerLayerQuantization
    ) throws {
        for (path, module) in model.leafModules().flattened() {
            guard weights["\(path).scales"] != nil else { continue }
            guard let quantization = configuration.quantization(layer: path) else {
                throw unsafe("checkpoint quantizes a layer skipped by config.json: \(path)")
            }
            try validateQuantization(quantization, path: "quantization.\(path)")
            guard module is any Quantizable,
                  let weight = module.parameters().flattened().first(where: {
                      $0.0 == "weight"
                  })?.1,
                  weight.ndim >= 2,
                  let inputDimension = weight.shape.last,
                  inputDimension.isMultiple(of: quantization.groupSize)
            else {
                throw unsafe(
                    "quantization group_size is incompatible with layer \(path)"
                )
            }
        }
    }

    static func validateExactModelWeightSet(
        model: Module,
        weights: [String: MLXArray]
    ) throws {
        let expected = Set(model.parameters().flattened().map(\.0))
        try validateExactModelWeightSet(expected: expected, actual: Set(weights.keys))
    }

    static func validateExactModelWeightSet(
        expected: Set<String>,
        actual: Set<String>
    ) throws {
        let missing = expected.subtracting(actual)
        let unexpected = actual.subtracting(expected)
        guard missing.isEmpty, unexpected.isEmpty else {
            throw GemmaLanguageModelFactoryError.modelWeightSetMismatch(
                missing: missing.count,
                unexpected: unexpected.count
            )
        }
    }

    static func validateModelParameterDTypes(
        model: Module,
        weights: [String: MLXArray]
    ) throws {
        let expected = Dictionary(
            uniqueKeysWithValues: model.parameters().flattened()
        )
        for (parameter, actual) in weights {
            guard let expectedParameter = expected[parameter] else {
                throw GemmaLanguageModelFactoryError.modelWeightSetMismatch(
                    missing: 0,
                    unexpected: 1
                )
            }
            try validateModelParameterDType(
                expected: expectedParameter.dtype,
                actual: actual.dtype,
                parameter: parameter
            )
        }
    }

    static func validateModelParameterDType(
        expected: DType,
        actual: DType,
        parameter: String
    ) throws {
        let isAllowed: Bool
        switch expected {
        case .uint32:
            isAllowed = actual == .uint32
        case .float16, .bfloat16, .float32:
            isAllowed = [.float16, .bfloat16, .float32].contains(actual)
        default:
            isAllowed = actual == expected
        }
        guard isAllowed else {
            throw GemmaLanguageModelFactoryError.modelParameterDTypeMismatch(
                parameter: parameter,
                dtype: String(describing: actual)
            )
        }
    }

    static func makeTokenizer(
        from assets: BorrowedGemmaModelActivationAssets
    ) throws -> any MLXLMCommon.Tokenizer {
        let tokenizerData = try requiredData("tokenizer.json", in: assets)
        let tokenizerConfigurationData = try requiredData(
            "tokenizer_config.json",
            in: assets
        )
        let configurationObject = try tokenizerConfigurationObject(
            configurationData: tokenizerConfigurationData,
            jinjaData: assets.data(forRelativePath: "chat_template.jinja"),
            jsonTemplateData: assets.data(forRelativePath: "chat_template.json")
        )
        let tokenizerObject = try jsonDictionary(tokenizerData, path: "tokenizer.json")

        let upstream: Tokenizers.Tokenizer
        do {
            upstream = try AutoTokenizer.from(
                tokenizerConfig: Config(nsDictionary(configurationObject)),
                tokenizerData: Config(nsDictionary(tokenizerObject)),
                strict: true
            )
        } catch {
            throw GemmaLanguageModelFactoryError.malformedActivationFile("tokenizer.json")
        }
        let tokenizer = #adaptHuggingFaceTokenizer(upstream)
        let probe: Message = [
            "role": "user",
            "content": "Steno activation check",
        ]
        do {
            _ = try tokenizer.applyChatTemplate(
                messages: [probe],
                tools: nil,
                additionalContext: nil
            )
        } catch {
            throw GemmaLanguageModelFactoryError.chatTemplateApplicationFailed
        }
        return tokenizer
    }

    static func tokenizerConfigurationObject(
        configurationData: Data,
        jinjaData: Data?,
        jsonTemplateData: Data?
    ) throws -> [String: Any] {
        var configurationObject = try jsonDictionary(
            configurationData,
            path: "tokenizer_config.json"
        )
        guard let tokenizerClass = configurationObject["tokenizer_class"] as? String,
              !tokenizerClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw GemmaLanguageModelFactoryError.tokenizerClassMissing
        }

        if let jinjaData {
            guard let template = String(data: jinjaData, encoding: .utf8),
                  !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw GemmaLanguageModelFactoryError.malformedActivationFile(
                    "chat_template.jinja"
                )
            }
            configurationObject["chat_template"] = template
        } else if let jsonTemplateData {
            let templateObject = try jsonDictionary(
                jsonTemplateData,
                path: "chat_template.json"
            )
            guard let template = templateObject["chat_template"] as? String,
                  !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw GemmaLanguageModelFactoryError.malformedActivationFile(
                    "chat_template.json"
                )
            }
            configurationObject["chat_template"] = template
        }
        guard hasUsableChatTemplate(configurationObject["chat_template"]) else {
            throw GemmaLanguageModelFactoryError.chatTemplateMissing
        }
        return configurationObject
    }

    static func generationConfiguration(
        from assets: BorrowedGemmaModelActivationAssets,
        vocabularySize: Int
    ) throws -> GenerationConfigFile? {
        guard let data = assets.data(forRelativePath: "generation_config.json") else {
            return nil
        }
        do {
            try GemmaStrictJSONValidation.validateNoDuplicateObjectKeys(data)
            let configuration = try JSONDecoder.json5().decode(
                GenerationConfigFile.self,
                from: data
            )
            if let eosTokenIDs = configuration.eosTokenIds,
               eosTokenIDs.values.isEmpty
            {
                throw unsafe("generation_config.json eos_token_id must not be empty")
            }
            try validateEOSTokenIDs(
                Set(configuration.eosTokenIds?.values ?? []),
                vocabularySize: vocabularySize,
                source: "generation_config.json"
            )
            return configuration
        } catch let error as GemmaLanguageModelFactoryError {
            throw error
        } catch {
            throw GemmaLanguageModelFactoryError.malformedActivationFile(
                "generation_config.json"
            )
        }
    }

    static func loadVerifiedWeights(
        from assets: BorrowedGemmaModelActivationAssets,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) throws -> ([String: MLXArray], [String: String]) {
        let shardPaths = assets.safetensorsRelativePaths.sorted()
        guard !shardPaths.isEmpty else {
            throw GemmaLanguageModelFactoryError.safetensorsIndexMismatch
        }
        let index = try validatedIndex(
            data: assets.data(forRelativePath: "model.safetensors.index.json"),
            shardPaths: shardPaths
        )
        var weights: [String: MLXArray] = [:]
        var seenTensorNames = Set<String>()
        var sanitizedNames = Set<String>()
        var canonicalMetadata: [String: String]?

        try assets.consumeSafetensorsFiles(cancellationCheck: cancellationCheck) { shard in
            try cancellationCheck()
            let expectedNames = Set(shard.tensors.map(\.name))
            for tensor in shard.tensors {
                guard seenTensorNames.insert(tensor.name).inserted else {
                    throw GemmaLanguageModelFactoryError.safetensorsIndexMismatch
                }
                if let index, index.weightMap[tensor.name] != shard.relativePath {
                    throw GemmaLanguageModelFactoryError.safetensorsIndexMismatch
                }
                try validateTextWeightName(tensor.name)
                try validateSanitizerTensor(name: tensor.name, shape: tensor.shape)
                for name in sanitizedTargets(for: tensor.name) {
                    guard sanitizedNames.insert(name).inserted else {
                        throw GemmaLanguageModelFactoryError.sanitizedWeightNameCollision(name)
                    }
                }
                guard tensor.dtype.mlxDType != nil else {
                    throw GemmaLanguageModelFactoryError.unsupportedSafetensorsDType(
                        path: shard.relativePath,
                        tensor: tensor.name,
                        dtype: tensor.dtype.rawValue
                    )
                }
            }

            let loaded: [String: MLXArray]
            let loadedMetadata: [String: String]
            do {
                (loaded, loadedMetadata) = try MLX.loadArraysAndMetadata(data: shard.data)
            } catch {
                throw GemmaLanguageModelFactoryError.malformedActivationFile(
                    shard.relativePath
                )
            }
            guard Set(loaded.keys) == expectedNames,
                  loadedMetadata == shard.metadata
            else {
                throw GemmaLanguageModelFactoryError.safetensorsTensorMismatch(
                    path: shard.relativePath,
                    tensor: "<metadata-or-name-set>"
                )
            }
            for descriptor in shard.tensors {
                guard let array = loaded[descriptor.name],
                      array.dtype == descriptor.dtype.mlxDType,
                      descriptor.shape.compactMap(Int.init(exactly:)).count
                        == descriptor.shape.count,
                      array.shape == descriptor.shape.compactMap(Int.init(exactly:))
                else {
                    throw GemmaLanguageModelFactoryError.safetensorsTensorMismatch(
                        path: shard.relativePath,
                        tensor: descriptor.name
                    )
                }
            }
            try MLX.checkedEval(Array(loaded.values))
            try cancellationCheck()

            if !loadedMetadata.isEmpty {
                if let canonicalMetadata, canonicalMetadata != loadedMetadata {
                    throw GemmaLanguageModelFactoryError.inconsistentSafetensorsMetadata(
                        shard.relativePath
                    )
                }
                if canonicalMetadata == nil {
                    canonicalMetadata = loadedMetadata
                }
            }
            for (name, array) in loaded {
                weights[name] = array
            }
        }
        if let index, Set(index.weightMap.keys) != seenTensorNames {
            throw GemmaLanguageModelFactoryError.safetensorsIndexMismatch
        }
        return (weights, canonicalMetadata ?? [:])
    }

    static func validatedIndex(
        data: Data?,
        shardPaths: [String]
    ) throws -> SafetensorsIndex? {
        guard let data else {
            guard shardPaths.count == 1 else {
                throw GemmaLanguageModelFactoryError.safetensorsIndexRequired
            }
            return nil
        }
        let index: SafetensorsIndex
        do {
            try GemmaStrictJSONValidation.validateNoDuplicateObjectKeys(data)
            index = try JSONDecoder().decode(SafetensorsIndex.self, from: data)
        } catch {
            throw GemmaLanguageModelFactoryError.malformedActivationFile(
                "model.safetensors.index.json"
            )
        }
        guard !index.weightMap.isEmpty,
              Set(index.weightMap.values) == Set(shardPaths)
        else {
            throw GemmaLanguageModelFactoryError.safetensorsIndexMismatch
        }
        return index
    }

    static func validateTextWeightName(_ rawName: String) throws {
        let name = rawName.hasPrefix("model.") ? String(rawName.dropFirst(6)) : rawName
        let mediaPrefixes = [
            "vision_tower",
            "multi_modal_projector",
            "audio_tower",
            "embed_audio",
            "embed_vision",
            "vision_embedder",
        ]
        if mediaPrefixes.contains(where: {
            name == $0
                || name.hasPrefix("\($0).")
                || name.contains(".\($0).")
                || name.hasSuffix(".\($0)")
        }) {
            throw GemmaLanguageModelFactoryError.mediaWeightRejected(rawName)
        }
    }

    static func validateSanitizerTensor(
        name: String,
        shape: [UInt64]
    ) throws {
        if name.hasSuffix(".experts.gate_up_proj") {
            guard shape.count == 3,
                  shape[1] > 0,
                  shape[1].isMultiple(of: 2)
            else {
                throw GemmaLanguageModelFactoryError.sanitizerTensorShapeMismatch(name)
            }
        } else if name.hasSuffix(".experts.down_proj") {
            guard shape.count == 3 else {
                throw GemmaLanguageModelFactoryError.sanitizerTensorShapeMismatch(name)
            }
        }
    }

    static func sanitizedTargets(for rawName: String) -> [String] {
        let hadModelPrefix = rawName.hasPrefix("model.")
        var name = hadModelPrefix ? String(rawName.dropFirst(6)) : rawName
        if hadModelPrefix, name.hasPrefix("language_model.") {
            name = "language_model.model." + name.dropFirst("language_model.".count)
        }
        if name.hasSuffix(".experts.down_proj") {
            return [name.replacingOccurrences(
                of: ".experts.down_proj",
                with: ".experts.switch_glu.down_proj.weight"
            )]
        }
        if name.hasSuffix(".experts.gate_up_proj") {
            let prefix = String(name.dropLast(".experts.gate_up_proj".count))
            return [
                "\(prefix).experts.switch_glu.gate_proj.weight",
                "\(prefix).experts.switch_glu.up_proj.weight",
            ]
        }
        return [name]
    }

    static func requiredData(
        _ path: String,
        in assets: BorrowedGemmaModelActivationAssets
    ) throws -> Data {
        guard let data = assets.data(forRelativePath: path) else {
            throw GemmaLanguageModelFactoryError.requiredActivationFileMissing(path)
        }
        return data
    }

    static func jsonDictionary(_ data: Data, path: String) throws -> [String: Any] {
        do {
            try GemmaStrictJSONValidation.validateNoDuplicateObjectKeys(data)
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw GemmaLanguageModelFactoryError.malformedActivationFile(path)
            }
            return dictionary
        } catch let error as GemmaLanguageModelFactoryError {
            throw error
        } catch {
            throw GemmaLanguageModelFactoryError.malformedActivationFile(path)
        }
    }

    static func nsDictionary(_ dictionary: [String: Any]) -> [NSString: Any] {
        Dictionary(uniqueKeysWithValues: dictionary.map { (NSString(string: $0.key), $0.value) })
    }

    static func hasUsableChatTemplate(_ value: Any?) -> Bool {
        if let template = value as? String {
            return !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let templates = value as? [String: Any] {
            return !templates.isEmpty && templates.values.allSatisfy {
                guard let template = $0 as? String else { return false }
                return !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return false
    }

    static func firstMediaConfigurationKey(in value: Any, path: String = "") -> String? {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                let lower = key.lowercased()
                if ["vision", "audio", "image", "video", "multimodal", "multi_modal"]
                    .contains(where: lower.contains)
                {
                    return path.isEmpty ? key : "\(path).\(key)"
                }
                if let nested = firstMediaConfigurationKey(
                    in: dictionary[key] as Any,
                    path: path.isEmpty ? key : "\(path).\(key)"
                ) {
                    return nested
                }
            }
        } else if let array = value as? [Any] {
            for (index, element) in array.enumerated() {
                if let nested = firstMediaConfigurationKey(
                    in: element,
                    path: "\(path)[\(index)]"
                ) {
                    return nested
                }
            }
        }
        return nil
    }

    static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func requirePositive(
        _ value: Int,
        name: String,
        maximum: Int
    ) throws {
        guard value > 0, value <= maximum else {
            throw unsafe("\(name) must be in 1...\(maximum)")
        }
    }

    static func checkedProduct(_ lhs: Int, _ rhs: Int, name: String) throws -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow, product > 0 else {
            throw unsafe("\(name) dimensions overflow")
        }
        return product
    }

    static func validateEOSTokenIDs(
        _ tokenIDs: Set<Int>,
        vocabularySize: Int,
        source: String
    ) throws {
        guard tokenIDs.allSatisfy({ $0 >= 0 && $0 < vocabularySize }) else {
            throw unsafe("\(source) eos_token_id must be within the model vocabulary")
        }
    }

    static func unsafe(_ reason: String) -> GemmaLanguageModelFactoryError {
        .unsafeModelConfiguration(reason)
    }
}

@available(macOS 27.0, *)
private struct StrictGemmaUserInputProcessor: UserInputProcessor {
    let tokenizer: any MLXLMCommon.Tokenizer
    let messageGenerator: any MessageGenerator

    func prepare(input: UserInput) async throws -> LMInput {
        guard input.images.isEmpty, input.videos.isEmpty, input.audios.isEmpty else {
            throw GemmaLanguageModelFactoryError.mediaInputRejected
        }
        do {
            let tokens = try tokenizer.applyChatTemplate(
                messages: messageGenerator.generate(from: input),
                tools: input.tools,
                additionalContext: input.additionalContext
            )
            return LMInput(tokens: MLXArray(tokens))
        } catch {
            throw GemmaLanguageModelFactoryError.chatTemplateApplicationFailed
        }
    }
}

private extension VerifiedGemmaSafetensorsDType {
    var mlxDType: DType? {
        switch self {
        case .float16: .float16
        case .bfloat16: .bfloat16
        case .float32: .float32
        case .bool: .bool
        case .int8: .int8
        case .int16: .int16
        case .int32: .int32
        case .int64: .int64
        case .uint8: .uint8
        case .uint16: .uint16
        case .uint32: .uint32
        case .uint64: .uint64
        case .complex64: .complex64
        case .float8E4M3: nil
        }
    }
}
