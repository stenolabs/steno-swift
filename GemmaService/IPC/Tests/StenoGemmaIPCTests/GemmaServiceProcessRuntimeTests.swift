import Foundation
import StenoGemmaIPC
import Testing
@testable import StenoGemmaServiceCore

@Suite("Gemma service process runtime")
struct GemmaServiceProcessRuntimeTests {
    @Test("an executor binds once before runtime access")
    func executorBindsBeforeRuntimeAccess() async throws {
        let runtime = makeRuntime()
        let pin = try makePin()
        let executor = GemmaBoundModelExecutor(model: pin, executor: RuntimeExecutor())

        #expect(runtime.bindModelExecutor(executor))
        #expect(!runtime.bindModelExecutor(executor))

        let response = try await handshake(from: runtime.core, model: pin)
        #expect(response == .handshake(.init(
            serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
            adapterRevision: GemmaIPCBuildInfo.adapterRevision,
            supportedOperations: [.handshake, .countTokens, .generate, .cancel, .shutdown]
        )))
    }

    @Test("early runtime access permanently keeps that helper model-free")
    func earlyAccessPreventsLaterBinding() async throws {
        let runtime = makeRuntime()
        let core = runtime.core
        let pin = try makePin()
        let executor = GemmaBoundModelExecutor(model: pin, executor: RuntimeExecutor())

        #expect(!runtime.bindModelExecutor(executor))
        let response = try await handshake(from: core, model: pin)
        #expect(response == .handshake(.init(
            serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
            adapterRevision: GemmaIPCBuildInfo.adapterRevision,
            supportedOperations: [.handshake, .cancel, .shutdown]
        )))
    }

    @Test("shutdown inspection does not force model-free runtime creation")
    func shutdownInspectionDoesNotCreateRuntime() throws {
        let runtime = makeRuntime()
        runtime.closeAdmissionIfCreated()
        #expect(!runtime.markTerminatingAndReturnWasArmedIfCreated())

        let executor = GemmaBoundModelExecutor(
            model: try makePin(),
            executor: RuntimeExecutor()
        )
        #expect(runtime.bindModelExecutor(executor))
    }

    private func makeRuntime() -> GemmaServiceProcessRuntime {
        GemmaServiceProcessRuntime(boundHelperIdentity: .init(
            helperInstanceID: UUID(),
            processIdentifier: 42
        ))
    }

    private func makePin() throws -> GemmaModelSnapshotPin {
        try GemmaModelSnapshotPin(
            modelIdentifier: "test/gemma-4",
            checkpointRevision: String(repeating: "1", count: 40),
            adapterRevision: GemmaIPCBuildInfo.adapterRevision,
            licenseIdentifier: "Apache-2.0",
            manifestSHA256: String(repeating: "2", count: 64)
        )
    }

    private func handshake(
        from core: GemmaServiceCore,
        model: GemmaModelSnapshotPin
    ) async throws -> GemmaIPCResponseBody {
        let request = try GemmaIPCRequestEnvelope(body: .handshake(.init(model: model)))
        let response = await core.handle(
            encodedRequest: try GemmaIPCCodec.encode(request),
            expectedRequestID: request.requestID
        )
        return try GemmaIPCCodec.decodeResponse(
            response,
            expectedRequestID: request.requestID,
            expectedOperation: .handshake
        ).body
    }
}

private struct RuntimeExecutor: GemmaModelExecuting {
    func countTokens(in text: String) async throws -> Int { text.count }

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        String(prompt.prefix(maximumTokens))
    }
}
