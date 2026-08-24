import Foundation
import NemotronBenchmarkSupport
import Testing

@Suite("Nemotron live benchmark configuration")
struct NemotronBenchmarkConfigurationTests {
    @Test("requires an explicit language and supported latency tier")
    func validatesConfiguration() throws {
        let configuration = try NemotronBenchmarkConfiguration(
            language: "de-DE",
            chunkMilliseconds: 2_240,
            feedChunkMilliseconds: 20,
            realtime: true
        )

        #expect(configuration.language == "de-DE")
        #expect(configuration.chunkMilliseconds == 2_240)
        #expect(configuration.feedChunkMilliseconds == 20)
        #expect(configuration.realtime)
    }

    @Test("rejects auto language because Steno never infers spoken language")
    func rejectsAutomaticLanguage() {
        #expect(throws: NemotronBenchmarkConfigurationError.explicitLanguageRequired) {
            try NemotronBenchmarkConfiguration(
                language: "auto",
                chunkMilliseconds: 2_240,
                feedChunkMilliseconds: 20,
                realtime: false
            )
        }
    }

    @Test("rejects model tiers that are not distributed")
    func rejectsUnknownTier() {
        #expect(throws: NemotronBenchmarkConfigurationError.unsupportedChunkMilliseconds(999)) {
            try NemotronBenchmarkConfiguration(
                language: "de-DE",
                chunkMilliseconds: 999,
                feedChunkMilliseconds: 20,
                realtime: false
            )
        }
    }

    @Test("encodes the same top-level text and locale contract as the ASR scorer")
    func encodesScorerContract() throws {
        let result = LiveBenchmarkResult(
            engine: LiveBenchmarkEngine(id: "nemotron", version: "abc", model: "de/2240"),
            locale: "de-DE",
            mode: "realtime",
            chunkMilliseconds: 20,
            audioDurationSeconds: 2,
            wallSeconds: 2.5,
            text: "Stadt Musterstadt",
            updates: [LiveBenchmarkUpdate(
                kind: .volatile,
                wallSeconds: 1.1,
                audioSecondsFed: 0.9,
                text: "Stadt"
            )]
        )

        let document = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        )
        #expect(document["schemaVersion"] as? Int == 1)
        #expect(document["locale"] as? String == "de-DE")
        #expect(document["text"] as? String == "Stadt Musterstadt")
        #expect((document["metrics"] as? [String: Any])?["updateCount"] as? Int == 1)
    }
}
