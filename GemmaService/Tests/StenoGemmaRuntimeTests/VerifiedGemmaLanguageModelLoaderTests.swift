import Foundation
import Testing
@testable import StenoGemmaRuntime

@Suite("Verified Gemma byte loader policy")
struct VerifiedGemmaLanguageModelLoaderTests {
    @Test("a text-only Gemma 4 configuration is accepted")
    func textOnlyGemmaConfigurationIsAccepted() throws {
        try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
            json(#"{"model_type":"gemma4"}"#)
        )
    }

    @Test("unified and nested non-text model types are rejected")
    func nonTextModelTypesAreRejected() {
        #expect(throws: GemmaLanguageModelFactoryError.unsupportedModelType("gemma4_unified")) {
            try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                json(#"{"model_type":"gemma4_unified"}"#)
            )
        }
        #expect(throws: GemmaLanguageModelFactoryError.unsupportedModelType("gemma4_unified")) {
            try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                json(
                    #"{"model_type":"gemma4","text_config":{"model_type":"gemma4_unified"}}"#
                )
            )
        }
    }

    @Test("media configuration is rejected before model construction")
    func mediaConfigurationIsRejected() {
        #expect(throws: GemmaLanguageModelFactoryError.unsupportedMediaConfiguration(
            "vision_config"
        )) {
            try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                json(#"{"model_type":"gemma4","vision_config":{}}"#)
            )
        }
    }

    @Test("duplicate configuration keys are rejected before either JSON decoder")
    func duplicateConfigurationKeysAreRejected() {
        #expect(throws: GemmaLanguageModelFactoryError.configurationMalformed) {
            try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                json(#"{"model_type":"gemma4","model_type":"gemma4_unified"}"#)
            )
        }
        #expect(throws: GemmaLanguageModelFactoryError.configurationMalformed) {
            try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                json(
                    #"{"model_type":"gemma4","rope_parameters":{"full_attention":{"rope_theta":10000,"rope_theta":-1}}}"#
                )
            )
        }
    }

    @Test("configuration values that would trap the pinned model are rejected")
    func trapProneConfigurationIsRejected() {
        #expect(throws: GemmaLanguageModelFactoryError.unsafeModelConfiguration(
            "sliding_window_pattern must be in 1...512"
        )) {
            try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                json(#"{"model_type":"gemma4","sliding_window_pattern":0}"#)
            )
        }
        #expect(throws: GemmaLanguageModelFactoryError.unsafeModelConfiguration(
            "num_kv_shared_layers must be in 0..<num_hidden_layers"
        )) {
            try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                json(
                    #"{"model_type":"gemma4","num_hidden_layers":4,"num_kv_shared_layers":4}"#
                )
            )
        }
        #expect(throws: GemmaLanguageModelFactoryError.unsafeModelConfiguration(
            "rms_norm_eps must equal 1e-6 for the pinned Gemma 4 implementation"
        )) {
            try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                json(#"{"model_type":"gemma4","rms_norm_eps":0.00001}"#)
            )
        }
        #expect(throws: GemmaLanguageModelFactoryError.unsafeModelConfiguration(
            "config.json eos_token_id must be within the model vocabulary"
        )) {
            try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                json(#"{"model_type":"gemma4","vocab_size":10,"eos_token_id":10}"#)
            )
        }
    }

    @Test("invalid quantization parameters are rejected before MLX")
    func invalidQuantizationIsRejected() {
        for quantization in [
            #"{"group_size":4294967296,"bits":4}"#,
            #"{"group_size":7,"bits":4}"#,
            #"{"group_size":32,"bits":7}"#,
            #"{"group_size":32,"bits":8,"mode":"mxfp4"}"#,
            #"{"group_size":64,"bits":4,"model.layers.0.self_attn.q_proj":{"group_size":9,"bits":4}}"#,
        ] {
            #expect(throws: GemmaLanguageModelFactoryError.self) {
                try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                    json(#"{"model_type":"gemma4","quantization":\#(quantization)}"#)
                )
            }
        }
    }

    @Test("nested text vocab does not override Gemma 4 root precedence")
    func nestedTextVocabUsesUpstreamPrecedence() throws {
        try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
            json(
                #"{"model_type":"gemma4","text_config":{"model_type":"gemma4_text","vocab_size":20000000}}"#
            )
        )
    }

    @Test("MoE construction requires every fatal-error input")
    func incompleteMoEConfigurationIsRejected() {
        #expect(throws: GemmaLanguageModelFactoryError.unsafeModelConfiguration(
            "MoE requires num_experts, top_k_experts, and moe_intermediate_size"
        )) {
            try GemmaLanguageModelFactory.validateVerifiedConfigurationForTesting(
                json(#"{"model_type":"gemma4","enable_moe_block":true}"#)
            )
        }
    }

    @Test("a multi-shard checkpoint requires an exact index")
    func multiShardIndexMustBeExact() throws {
        #expect(throws: GemmaLanguageModelFactoryError.safetensorsIndexRequired) {
            try GemmaLanguageModelFactory.validateSafetensorsIndexForTesting(
                data: nil,
                shardPaths: ["a.safetensors", "b.safetensors"],
                tensorsByShard: [:]
            )
        }

        let exactIndex = json(
            #"{"weight_map":{"a.weight":"a.safetensors","b.weight":"b.safetensors"}}"#
        )
        try GemmaLanguageModelFactory.validateSafetensorsIndexForTesting(
            data: exactIndex,
            shardPaths: ["a.safetensors", "b.safetensors"],
            tensorsByShard: [
                "a.safetensors": ["a.weight"],
                "b.safetensors": ["b.weight"],
            ]
        )

        #expect(throws: GemmaLanguageModelFactoryError.safetensorsIndexMismatch) {
            try GemmaLanguageModelFactory.validateSafetensorsIndexForTesting(
                data: exactIndex,
                shardPaths: ["a.safetensors", "b.safetensors"],
                tensorsByShard: [
                    "a.safetensors": ["b.weight"],
                    "b.safetensors": ["a.weight"],
                ]
            )
        }
    }

    @Test("media weights and sanitizer collisions are rejected")
    func unsafeWeightNamesAreRejected() {
        #expect(throws: GemmaLanguageModelFactoryError.mediaWeightRejected(
            "model.vision_tower.encoder.weight"
        )) {
            try GemmaLanguageModelFactory.validateWeightNamesForTesting([
                "model.vision_tower.encoder.weight"
            ])
        }
        #expect(throws: GemmaLanguageModelFactoryError.sanitizedWeightNameCollision("foo")) {
            try GemmaLanguageModelFactory.validateWeightNamesForTesting([
                "foo",
                "model.foo",
            ])
        }
        #expect(throws: GemmaLanguageModelFactoryError.sanitizedWeightNameCollision(
            "block.experts.switch_glu.gate_proj.weight"
        )) {
            try GemmaLanguageModelFactory.validateWeightNamesForTesting([
                "block.experts.gate_up_proj",
                "block.experts.switch_glu.gate_proj.weight",
            ])
        }
    }

    @Test("the model weight set must match before structural decoding")
    func modelWeightSetMustMatchExactly() throws {
        let expected: Set<String> = [
            "language_model.model.layers.0.self_attn.q_proj.weight"
        ]
        try GemmaLanguageModelFactory.validateModelWeightSetForTesting(
            expected: expected,
            actual: expected
        )

        #expect(throws: GemmaLanguageModelFactoryError.modelWeightSetMismatch(
            missing: 0,
            unexpected: 1
        )) {
            try GemmaLanguageModelFactory.validateModelWeightSetForTesting(
                expected: expected,
                actual: expected.union([
                    "language_model.model.layers.foo.self_attn.q_proj.weight"
                ])
            )
        }
    }

    @Test("model parameter dtypes are constrained before publication")
    func modelParameterDTypesAreConstrained() throws {
        try GemmaLanguageModelFactory.validateModelParameterDTypeForTesting(
            expectsPackedUInt32: false,
            actualSafetensorsDType: "F16"
        )
        try GemmaLanguageModelFactory.validateModelParameterDTypeForTesting(
            expectsPackedUInt32: true,
            actualSafetensorsDType: "U32"
        )
        #expect(throws: GemmaLanguageModelFactoryError.modelParameterDTypeMismatch(
            parameter: "test.parameter",
            dtype: "int8"
        )) {
            try GemmaLanguageModelFactory.validateModelParameterDTypeForTesting(
                expectsPackedUInt32: false,
                actualSafetensorsDType: "I8"
            )
        }
        #expect(throws: GemmaLanguageModelFactoryError.modelParameterDTypeMismatch(
            parameter: "test.parameter",
            dtype: "float16"
        )) {
            try GemmaLanguageModelFactory.validateModelParameterDTypeForTesting(
                expectsPackedUInt32: true,
                actualSafetensorsDType: "F16"
            )
        }
    }

    @Test("MoE tensors are shape-safe before sanitizer slicing")
    func moeTensorShapesAreValidated() throws {
        try GemmaLanguageModelFactory.validateSanitizerTensorForTesting(
            name: "model.layers.0.mlp.experts.gate_up_proj",
            shape: [4, 32, 16]
        )
        try GemmaLanguageModelFactory.validateSanitizerTensorForTesting(
            name: "model.layers.0.mlp.experts.down_proj",
            shape: [4, 16, 32]
        )

        for shape: [UInt64] in [[32], [4, 31, 16], [4, 32]] {
            #expect(throws: GemmaLanguageModelFactoryError
                .sanitizerTensorShapeMismatch(
                    "model.layers.0.mlp.experts.gate_up_proj"
                ))
            {
                try GemmaLanguageModelFactory.validateSanitizerTensorForTesting(
                    name: "model.layers.0.mlp.experts.gate_up_proj",
                    shape: shape
                )
            }
        }
    }

    @Test("tokenizer class and chat template are mandatory")
    func tokenizerMetadataIsMandatory() {
        #expect(throws: GemmaLanguageModelFactoryError.tokenizerClassMissing) {
            _ = try GemmaLanguageModelFactory.tokenizerChatTemplateForTesting(
                configurationData: json(#"{"chat_template":"base"}"#)
            )
        }
        #expect(throws: GemmaLanguageModelFactoryError.chatTemplateMissing) {
            _ = try GemmaLanguageModelFactory.tokenizerChatTemplateForTesting(
                configurationData: json(#"{"tokenizer_class":"GemmaTokenizer"}"#)
            )
        }
        #expect(throws: GemmaLanguageModelFactoryError.malformedActivationFile(
            "tokenizer_config.json"
        )) {
            _ = try GemmaLanguageModelFactory.tokenizerChatTemplateForTesting(
                configurationData: json(
                    #"{"tokenizer_class":"GemmaTokenizer","tokenizer_class":"Other","chat_template":"base"}"#
                )
            )
        }
    }

    @Test("external Jinja template has deterministic precedence")
    func jinjaTemplateHasPrecedence() throws {
        let template = try GemmaLanguageModelFactory.tokenizerChatTemplateForTesting(
            configurationData: json(
                #"{"tokenizer_class":"GemmaTokenizer","chat_template":"embedded"}"#
            ),
            jinjaData: Data("jinja".utf8),
            jsonTemplateData: json(#"{"chat_template":"json"}"#)
        )
        #expect(template == "jinja")

        #expect(throws: GemmaLanguageModelFactoryError.malformedActivationFile(
            "chat_template.jinja"
        )) {
            _ = try GemmaLanguageModelFactory.tokenizerChatTemplateForTesting(
                configurationData: json(
                    #"{"tokenizer_class":"GemmaTokenizer","chat_template":"embedded"}"#
                ),
                jinjaData: Data("   ".utf8),
                jsonTemplateData: json(#"{"chat_template":"json"}"#)
            )
        }
    }
}

private func json(_ text: String) -> Data {
    Data(text.utf8)
}
