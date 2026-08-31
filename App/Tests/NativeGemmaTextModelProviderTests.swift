#if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
import Foundation
import StenoDomain
import StenoGemmaClient
import StenoGemmaIPC
import StenoIntelligence
import Testing
@testable import steno_macos

@Suite("Native Gemma text-model provider")
struct NativeGemmaTextModelProviderTests {
    @Test("production remains unavailable while every native catalog is empty")
    func productionCatalogIsEmpty() throws {
        #expect(throws: NativeGemmaTextModelProviderError.modelNotApproved) {
            _ = try NativeGemmaTextModelProvider(snapshot: snapshot())
        }
    }

    @Test("one render uses one exact helper session for counts and generation")
    func renderUsesOneExactSession() async throws {
        let snapshot = snapshot()
        let profile = try NativeGemmaProviderProfile(
            snapshot: snapshot,
            maximumPromptTokens: 2_048,
            maximumResponseTokens: 256
        )
        let response = try responseText(for: .meetingMinutes)
        let coordinator = NativeGemmaProviderCoordinatorProbe(responseText: response)
        let provider = try NativeGemmaTextModelProvider(
            snapshot: snapshot,
            catalog: NativeGemmaProviderCatalog(profiles: [profile]),
            coordinator: coordinator
        )
        let transcript = TranscriptRevision(
            meetingID: MeetingID(),
            origin: .liveProvisional,
            turns: [
                TranscriptTurn(
                    speaker: .channel("Speaker 1"),
                    start: 0,
                    end: 1,
                    segments: [
                        TranscriptSegment(
                            text: "Budget approved.",
                            start: 0,
                            end: 1,
                            words: []
                        ),
                    ]
                ),
            ]
        )

        let result = try await provider.render(
            template: .meetingMinutes,
            transcript: transcript,
            participants: ["Ada Lovelace"],
            context: RenderContext(outputLocaleIdentifier: "en-GB")
        )

        #expect(provider.descriptor == .mlxGemma(snapshot: snapshot))
        #expect(result.engine == provider.descriptor)
        #expect(await coordinator.sessionCount() == 1)
        let prompts = await coordinator.prompts()
        #expect(!prompts.generated.isEmpty)
        #expect(prompts.generated.allSatisfy(prompts.counted.contains))
        #expect(prompts.generated.allSatisfy { $0.contains("en-GB") })
    }

    @Test("duplicate exact profiles fail closed")
    func duplicateProfileFailsClosed() throws {
        let snapshot = snapshot()
        let profile = try NativeGemmaProviderProfile(
            snapshot: snapshot,
            maximumPromptTokens: 2_048,
            maximumResponseTokens: 256
        )

        #expect(throws: NativeGemmaTextModelProviderError.modelNotApproved) {
            _ = try NativeGemmaTextModelProvider(
                snapshot: snapshot,
                catalog: NativeGemmaProviderCatalog(profiles: [profile, profile]),
                coordinator: NativeGemmaProviderCoordinatorProbe(responseText: "")
            )
        }
    }

    private func snapshot() -> NativeGemmaModelSnapshot {
        NativeGemmaModelSnapshot(
            modelIdentifier: "google/gemma-4-test",
            checkpointRevision: String(repeating: "a", count: 40),
            adapterRevision: GemmaIPCBuildInfo.adapterRevision,
            licenseIdentifier: "Gemma-Terms",
            manifestSHA256: String(repeating: "c", count: 64)
        )
    }

    private func responseText(for template: Template) throws -> String {
        let sections = Dictionary(
            uniqueKeysWithValues: template.generatedSections.map {
                ($0.id, "value for \($0.id)")
            }
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["sections": sections],
            options: [.sortedKeys]
        )
        return try #require(String(data: data, encoding: .utf8))
    }
}

private actor NativeGemmaProviderCoordinatorProbe: NativeGemmaCoordinator {
    private let responseText: String
    private var sessions = 0
    private var countedPrompts: [String] = []
    private var generatedPrompts: [String] = []

    init(responseText: String) {
        self.responseText = responseText
    }

    func acquire() throws {}

    func release() throws {}

    func performModelImport(
        _ operation: @escaping @Sendable () async throws -> NativeGemmaModelSnapshot
    ) async throws -> NativeGemmaModelSnapshot {
        try await operation()
    }

    func send(_ body: GemmaIPCRequestBody) async throws -> GemmaIPCResponseBody {
        try respond(to: body)
    }

    func withNativeModelSession<Value: Sendable>(
        model: GemmaModelSnapshotPin,
        _ operation: @escaping @Sendable (NativeGemmaClientModelSession) async throws -> Value
    ) async throws -> Value {
        sessions += 1
        let session = NativeGemmaClientModelSession(
            model: model,
            sender: { body in try await self.respond(to: body) }
        )
        return try await operation(session)
    }

    func sessionCount() -> Int {
        sessions
    }

    func prompts() -> (counted: [String], generated: [String]) {
        (countedPrompts, generatedPrompts)
    }

    private func respond(
        to body: GemmaIPCRequestBody
    ) throws -> GemmaIPCResponseBody {
        switch body {
        case .countTokens(let request):
            countedPrompts.append(request.text)
            return .tokenCount(.init(tokenCount: 16))
        case .generate(let request):
            generatedPrompts.append(request.prompt)
            return .generate(.init(text: responseText))
        case .handshake, .cancel, .shutdown:
            throw NativeGemmaTextModelProviderError.unexpectedHelperResponse
        }
    }
}
#endif
