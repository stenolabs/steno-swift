import Foundation
import Testing
@testable import StenoGemmaIPC
@testable import StenoGemmaServiceCore

@Suite("Gemma IPC")
struct GemmaIPCTests {
    private let pin = try! GemmaModelSnapshotPin(
        modelIdentifier: "google/gemma-4-e4b-it-4bit",
        checkpointRevision: "1111111111111111111111111111111111111111",
        adapterRevision: "37688d2cf7d3906e08c74479c9d9949ce6b81136",
        licenseIdentifier: "Apache-2.0",
        manifestSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )

    @Test("a path-free generation request round-trips with its UUID")
    func generationRequestRoundTrip() throws {
        let requestID = UUID()
        let request = try GemmaIPCRequestEnvelope(
            requestID: requestID,
            body: .generate(try GemmaIPCGenerateRequest(
                model: pin,
                prompt: "Summarize the supplied text.",
                maximumTokens: 128
            ))
        )

        let decoded = try GemmaIPCCodec.decodeRequest(GemmaIPCCodec.encode(request))

        #expect(decoded == request)
        #expect(decoded.requestID == requestID)
    }

    @Test("malformed, unknown, and oversized frames are rejected")
    func rejectsUnsafeFrames() throws {
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeRequest(Data("not-json".utf8))
        }

        let unknownOperation = Data("""
        {"protocolVersion":1,"requestID":"00000000-0000-0000-0000-000000000001","body":{"operation":"loadModel","payload":{}}}
        """.utf8)
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeRequest(unknownOperation)
        }

        let valid = try GemmaIPCRequestEnvelope(body: .handshake(.init(model: pin)))
        var object = try #require(
            JSONSerialization.jsonObject(with: GemmaIPCCodec.encode(valid))
                as? [String: Any]
        )
        object["unexpected"] = true
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeRequest(
                JSONSerialization.data(withJSONObject: object)
            )
        }

        let validData = try GemmaIPCCodec.encode(valid)
        #expect(validData.first == 0x7B)
        var duplicateKey = Data("{\"protocolVersion\":1,".utf8)
        duplicateKey.append(validData.dropFirst())
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeRequest(duplicateKey)
        }

        var nestedEnvelope = try #require(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        var nestedBody = try #require(nestedEnvelope["body"] as? [String: Any])
        var nestedPayload = try #require(nestedBody["payload"] as? [String: Any])
        var nestedModel = try #require(nestedPayload["model"] as? [String: Any])
        nestedModel["localPath"] = "/tmp/model"
        nestedPayload["model"] = nestedModel
        nestedBody["payload"] = nestedPayload
        nestedEnvelope["body"] = nestedBody
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeRequest(
                JSONSerialization.data(withJSONObject: nestedEnvelope)
            )
        }

        let response = GemmaIPCResponseEnvelope(
            requestID: valid.requestID,
            body: .failure(.init(code: .invalidRequest))
        )
        var responseEnvelope = try #require(
            JSONSerialization.jsonObject(with: GemmaIPCCodec.encode(response))
                as? [String: Any]
        )
        var responseBody = try #require(responseEnvelope["body"] as? [String: Any])
        var responsePayload = try #require(responseBody["payload"] as? [String: Any])
        responsePayload["detail"] = "not allowed"
        responseBody["payload"] = responsePayload
        responseEnvelope["body"] = responseBody
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeResponse(
                JSONSerialization.data(withJSONObject: responseEnvelope),
                expectedRequestID: valid.requestID,
                expectedOperation: .handshake
            )
        }

        let oversized = Data(repeating: 0x41, count: GemmaIPCProtocol.maximumEncodedMessageBytes + 1)
        #expect(throws: GemmaIPCCodecError.oversizedMessage(
            limit: GemmaIPCProtocol.maximumEncodedMessageBytes,
            actual: oversized.count
        )) {
            _ = try GemmaIPCCodec.decodeRequest(oversized)
        }
    }

    @Test("invalid local model pins and generation limits are rejected before IPC")
    func rejectsInvalidInputs() throws {
        #expect(throws: GemmaIPCValidationError.invalidManifestSHA256) {
            _ = try GemmaModelSnapshotPin(
                modelIdentifier: "google/gemma-4-e4b-it-4bit",
                checkpointRevision: String(repeating: "1", count: 40),
                adapterRevision: GemmaIPCBuildInfo.adapterRevision,
                licenseIdentifier: "Apache-2.0",
                manifestSHA256: "not-a-digest"
            )
        }
        #expect(throws: GemmaIPCValidationError.invalidPinValue("modelIdentifier")) {
            _ = try GemmaModelSnapshotPin(
                modelIdentifier: "file:///tmp/model",
                checkpointRevision: String(repeating: "1", count: 40),
                adapterRevision: GemmaIPCBuildInfo.adapterRevision,
                licenseIdentifier: "Apache-2.0",
                manifestSHA256: String(repeating: "a", count: 64)
            )
        }
        #expect(throws: GemmaIPCValidationError.invalidPinValue("checkpointRevision")) {
            _ = try GemmaModelSnapshotPin(
                modelIdentifier: "google/gemma-4-e4b-it-4bit",
                checkpointRevision: "main",
                adapterRevision: GemmaIPCBuildInfo.adapterRevision,
                licenseIdentifier: "Apache-2.0",
                manifestSHA256: String(repeating: "a", count: 64)
            )
        }
        #expect(throws: GemmaIPCValidationError.invalidMaximumGenerationTokens) {
            _ = try GemmaIPCGenerateRequest(model: pin, prompt: "test", maximumTokens: 0)
        }
    }

    @Test("responses require the expected UUID, protocol, and semantic values")
    func rejectsInvalidResponses() throws {
        let requestID = UUID()
        let failure = GemmaIPCResponseEnvelope(
            requestID: requestID,
            body: .failure(.init(code: .invalidRequest))
        )
        let failureData = try GemmaIPCCodec.encode(failure)
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeResponse(
                failureData,
                expectedRequestID: UUID(),
                expectedOperation: .handshake
            )
        }

        let incompatible = GemmaIPCResponseEnvelope(
            protocolVersion: GemmaIPCProtocol.currentVersion + 1,
            requestID: requestID,
            body: .failure(.init(code: .protocolMismatch))
        )
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeResponse(
                GemmaIPCCodec.encode(incompatible),
                expectedRequestID: requestID,
                expectedOperation: .handshake
            )
        }

        let invalidHandshake = GemmaIPCResponseEnvelope(
            requestID: requestID,
            body: .handshake(.init(
                serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
                protocolVersion: GemmaIPCProtocol.currentVersion + 1,
                adapterRevision: GemmaIPCBuildInfo.adapterRevision,
                supportedOperations: [.handshake, .cancel, .shutdown]
            ))
        )
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeResponse(
                GemmaIPCCodec.encode(invalidHandshake),
                expectedRequestID: requestID,
                expectedOperation: .handshake
            )
        }

        let negativeCount = GemmaIPCResponseEnvelope(
            requestID: requestID,
            body: .tokenCount(.init(tokenCount: -1))
        )
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeResponse(
                GemmaIPCCodec.encode(negativeCount),
                expectedRequestID: requestID,
                expectedOperation: .countTokens
            )
        }

        let countForGenerate = GemmaIPCResponseEnvelope(
            requestID: requestID,
            body: .tokenCount(.init(tokenCount: 1))
        )
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeResponse(
                GemmaIPCCodec.encode(countForGenerate),
                expectedRequestID: requestID,
                expectedOperation: .generate
            )
        }

        let shutdownForCancel = GemmaIPCResponseEnvelope(
            requestID: requestID,
            body: .acknowledgement(.init(kind: .shutdown, didChangeState: true))
        )
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaIPCCodec.decodeResponse(
                GemmaIPCCodec.encode(shutdownForCancel),
                expectedRequestID: requestID,
                expectedOperation: .cancel
            )
        }
    }

    @Test("the model-free core handshakes and refuses inference")
    func coreHandshakesAndFailsClosedForInference() async throws {
        let core = GemmaServiceCore(buildInfo: .current)

        let handshake = try GemmaIPCRequestEnvelope(body: .handshake(.init(model: pin)))
        let handshakeResponse = try GemmaIPCCodec.decodeResponse(
            await core.handle(
                encodedRequest: GemmaIPCCodec.encode(handshake),
                expectedRequestID: handshake.requestID
            ),
            expectedRequestID: handshake.requestID,
            expectedOperation: .handshake
        )
        #expect(handshakeResponse.requestID == handshake.requestID)
        #expect(handshakeResponse.body == .handshake(.init(
            serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
            adapterRevision: pin.adapterRevision,
            supportedOperations: [.handshake, .cancel, .shutdown]
        )))

        let generate = try GemmaIPCRequestEnvelope(body: .generate(try .init(
            model: pin,
            prompt: "Do not run this model.",
            maximumTokens: 32
        )))
        let generateResponse = try GemmaIPCCodec.decodeResponse(
            await core.handle(
                encodedRequest: GemmaIPCCodec.encode(generate),
                expectedRequestID: generate.requestID
            ),
            expectedRequestID: generate.requestID,
            expectedOperation: .generate
        )
        #expect(generateResponse.body == .failure(.init(code: .modelUnavailable)))

        let countTokens = try GemmaIPCRequestEnvelope(
            body: .countTokens(try .init(model: pin, text: "Count nothing yet."))
        )
        let countResponse = try GemmaIPCCodec.decodeResponse(
            await core.handle(
                encodedRequest: GemmaIPCCodec.encode(countTokens),
                expectedRequestID: countTokens.requestID
            ),
            expectedRequestID: countTokens.requestID,
            expectedOperation: .countTokens
        )
        #expect(countResponse.body == .failure(.init(code: .modelUnavailable)))
    }

    @Test("the core rejects malformed, oversized, and incompatible requests")
    func coreRejectsUnsafeRequests() async throws {
        let core = GemmaServiceCore(buildInfo: .current)

        let malformedID = UUID()
        let malformed = try GemmaIPCCodec.decodeResponse(
            await core.handle(
                encodedRequest: Data("not-json".utf8),
                expectedRequestID: malformedID
            ),
            expectedRequestID: malformedID,
            expectedOperation: .handshake
        )
        #expect(malformed.body == .failure(.init(code: .invalidRequest)))

        let oversizedID = UUID()
        let oversized = try GemmaIPCCodec.decodeResponse(
            await core.handle(
                encodedRequest: Data(
                    repeating: 0x41,
                    count: GemmaIPCProtocol.maximumEncodedMessageBytes + 1
                ),
                expectedRequestID: oversizedID
            ),
            expectedRequestID: oversizedID,
            expectedOperation: .handshake
        )
        #expect(oversized.body == .failure(.init(code: .requestTooLarge)))

        let incompatible = try GemmaIPCRequestEnvelope(
            protocolVersion: GemmaIPCProtocol.currentVersion + 1,
            body: .handshake(.init(model: pin))
        )
        let incompatibleResponse = try GemmaIPCCodec.decodeResponse(
            await core.handle(
                encodedRequest: GemmaIPCCodec.encode(incompatible),
                expectedRequestID: incompatible.requestID
            ),
            expectedRequestID: incompatible.requestID,
            expectedOperation: .handshake
        )
        #expect(incompatibleResponse.requestID == incompatible.requestID)
        #expect(incompatibleResponse.body == .failure(.init(code: .protocolMismatch)))

        let request = try GemmaIPCRequestEnvelope(body: .handshake(.init(model: pin)))
        let outerID = UUID()
        let mismatched = try GemmaIPCCodec.decodeResponse(
            await core.handle(
                encodedRequest: GemmaIPCCodec.encode(request),
                expectedRequestID: outerID
            ),
            expectedRequestID: outerID,
            expectedOperation: .handshake
        )
        #expect(mismatched.requestID == outerID)
        #expect(mismatched.body == .failure(.init(code: .invalidRequest)))
    }

    @Test("handshake rejects an adapter revision that differs from the helper build")
    func handshakeRejectsAdapterMismatch() async throws {
        let core = GemmaServiceCore(buildInfo: .init(
            serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
            adapterRevision: String(repeating: "2", count: 40)
        ))
        let handshake = try GemmaIPCRequestEnvelope(body: .handshake(.init(model: pin)))
        let response = try GemmaIPCCodec.decodeResponse(
            await core.handle(
                encodedRequest: GemmaIPCCodec.encode(handshake),
                expectedRequestID: handshake.requestID
            ),
            expectedRequestID: handshake.requestID,
            expectedOperation: .handshake
        )

        #expect(response.body == .failure(.init(code: .adapterMismatch)))
    }

    @Test("the model core rejects lifecycle requests owned by the process registry")
    func coreRejectsRegistryLifecycleRequests() async throws {
        let core = GemmaServiceCore(buildInfo: .current)
        let requests = try [
            GemmaIPCRequestEnvelope(body: .cancel(.init(targetRequestID: UUID()))),
            GemmaIPCRequestEnvelope(body: .shutdown),
        ]

        for request in requests {
            let response = try GemmaIPCCodec.decodeResponse(
                await core.handle(
                    encodedRequest: GemmaIPCCodec.encode(request),
                    expectedRequestID: request.requestID
                ),
                expectedRequestID: request.requestID,
                expectedOperation: request.body.operation
            )
            #expect(response.body == .failure(.init(code: .invalidRequest)))
        }
    }

    @Test("protocol v4 atomically binds a model session and requires an exact response mirror")
    func controlFramesRoundTrip() throws {
        let identity = GemmaIPCBoundHelperIdentity(
            helperInstanceID: UUID(),
            processIdentifier: 42
        )
        let binding = GemmaIPCBindSessionRequest(
            model: pin,
            expectedModelRootIdentity: try GemmaIPCModelRootIdentity(
                deviceID: 17,
                fileID: 23
            )
        )
        let prepared = GemmaIPCPreparedHelperExit(
            helperInstanceID: identity.helperInstanceID,
            processIdentifier: identity.processIdentifier
        )

        let bindRequest = GemmaXPCControlRequestEnvelope(body: .bindSession(binding))
        #expect(try GemmaXPCControlCodec.decodeRequest(
            GemmaXPCControlCodec.encode(bindRequest)
        ) == bindRequest)
        let bindResponse = GemmaXPCControlResponseEnvelope(
            requestID: bindRequest.requestID,
            body: .sessionBound(.init(binding: binding, helperIdentity: identity))
        )
        #expect(try GemmaXPCControlCodec.decodeResponse(
            GemmaXPCControlCodec.encode(bindResponse),
            expectedRequestID: bindRequest.requestID,
            expectedOperation: .bindSession
        ) == bindResponse)
        #expect(try GemmaXPCControlCodec.decodeBindSessionResponse(
            GemmaXPCControlCodec.encode(bindResponse),
            expectedRequestID: bindRequest.requestID,
            expectedBinding: binding
        ) == .init(binding: binding, helperIdentity: identity))

        let prepareRequest = GemmaXPCControlRequestEnvelope(body: .prepareForExit)
        #expect(try GemmaXPCControlCodec.decodeRequest(
            GemmaXPCControlCodec.encode(prepareRequest)
        ) == prepareRequest)
        let prepareResponse = GemmaXPCControlResponseEnvelope(
            requestID: prepareRequest.requestID,
            body: .prepared(prepared)
        )
        #expect(try GemmaXPCControlCodec.decodeResponse(
            GemmaXPCControlCodec.encode(prepareResponse),
            expectedRequestID: prepareRequest.requestID,
            expectedOperation: .prepareForExit
        ) == prepareResponse)

        let armRequest = GemmaXPCControlRequestEnvelope(
            body: .armAndExit(.init(preparedHelper: prepared))
        )
        #expect(try GemmaXPCControlCodec.decodeRequest(
            GemmaXPCControlCodec.encode(armRequest)
        ) == armRequest)

        let armResponse = GemmaXPCControlResponseEnvelope(
            requestID: armRequest.requestID,
            body: .armed(prepared)
        )
        #expect(try GemmaXPCControlCodec.decodeResponse(
            GemmaXPCControlCodec.encode(armResponse),
            expectedRequestID: armRequest.requestID,
            expectedOperation: .armAndExit
        ) == armResponse)
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaXPCControlCodec.decodeResponse(
                GemmaXPCControlCodec.encode(armResponse),
                expectedRequestID: UUID(),
                expectedOperation: .armAndExit
            )
        }

        let mismatches: [(GemmaXPCControlOperation, GemmaXPCControlResponseBody)] = [
            (.bindSession, .prepared(prepared)),
            (.prepareForExit, .sessionBound(.init(binding: binding, helperIdentity: identity))),
            (.armAndExit, .prepared(prepared)),
        ]
        for (expectedOperation, wrongBody) in mismatches {
            let wrongResponse = GemmaXPCControlResponseEnvelope(
                requestID: armRequest.requestID,
                body: wrongBody
            )
            #expect(throws: GemmaIPCCodecError.malformedMessage) {
                _ = try GemmaXPCControlCodec.decodeResponse(
                    GemmaXPCControlCodec.encode(wrongResponse),
                    expectedRequestID: armRequest.requestID,
                    expectedOperation: expectedOperation
                )
            }
        }

        for operation in [
            GemmaXPCControlOperation.bindSession,
            .prepareForExit,
            .armAndExit,
        ] {
            let failure = GemmaXPCControlResponseEnvelope(
                requestID: armRequest.requestID,
                body: .failure(.init(code: .shuttingDown))
            )
            #expect(try GemmaXPCControlCodec.decodeResponse(
                GemmaXPCControlCodec.encode(failure),
                expectedRequestID: armRequest.requestID,
                expectedOperation: operation
            ) == failure)
        }

        #expect(GemmaXPCChannel.model.rawValue == "model")
        #expect(GemmaXPCChannel.control.rawValue == "control")
    }

    @Test("control bind JSON requires exact keys and rejects malformed fields")
    func controlFramesRequireExactJSONKeys() throws {
        let requestID = UUID()
        let binding = GemmaIPCBindSessionRequest(
            model: pin,
            expectedModelRootIdentity: try GemmaIPCModelRootIdentity(
                deviceID: 17,
                fileID: 23
            )
        )
        let bindRequest = GemmaXPCControlRequestEnvelope(
            requestID: requestID,
            body: .bindSession(binding)
        )
        let requestData = try GemmaXPCControlCodec.encode(bindRequest)
        let requestObject = try #require(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        #expect(Set(requestObject.keys) == ["protocolVersion", "requestID", "body"])
        let requestBody = try #require(requestObject["body"] as? [String: Any])
        #expect(Set(requestBody.keys) == ["operation", "payload"])
        let requestPayload = try #require(requestBody["payload"] as? [String: Any])
        #expect(Set(requestPayload.keys) == ["model", "expectedModelRootIdentity"])
        #expect(Set(try #require(requestPayload["model"] as? [String: Any]).keys) == [
            "modelIdentifier", "checkpointRevision", "adapterRevision", "licenseIdentifier", "manifestSHA256",
        ])
        #expect(Set(try #require(requestPayload["expectedModelRootIdentity"] as? [String: Any]).keys) == [
            "deviceID", "fileID",
        ])

        var requestWithExtraPayloadKey = requestObject
        var extraRequestBody = requestBody
        var extraRequestPayload = requestPayload
        extraRequestPayload["executionGateFD"] = 7
        extraRequestBody["payload"] = extraRequestPayload
        requestWithExtraPayloadKey["body"] = extraRequestBody
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaXPCControlCodec.decodeRequest(
                JSONSerialization.data(withJSONObject: requestWithExtraPayloadKey)
            )
        }

        var requestMissingModel = requestObject
        var missingModelBody = requestBody
        var missingModelPayload = requestPayload
        missingModelPayload.removeValue(forKey: "model")
        missingModelBody["payload"] = missingModelPayload
        requestMissingModel["body"] = missingModelBody
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaXPCControlCodec.decodeRequest(
                JSONSerialization.data(withJSONObject: requestMissingModel)
            )
        }

        var requestWithInvalidRoot = requestObject
        var invalidRootBody = requestBody
        var invalidRootPayload = requestPayload
        var invalidRoot = try #require(invalidRootPayload["expectedModelRootIdentity"] as? [String: Any])
        invalidRoot["fileID"] = 0
        invalidRootPayload["expectedModelRootIdentity"] = invalidRoot
        invalidRootBody["payload"] = invalidRootPayload
        requestWithInvalidRoot["body"] = invalidRootBody
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaXPCControlCodec.decodeRequest(
                JSONSerialization.data(withJSONObject: requestWithInvalidRoot)
            )
        }

        let duplicateOperation = Data("""
        {"protocolVersion":\(GemmaIPCProtocol.currentVersion),"requestID":"\(requestID.uuidString)","body":{"operation":"bindSession","operation":"prepareForExit","payload":{}}}
        """.utf8)
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaXPCControlCodec.decodeRequest(duplicateOperation)
        }

        let identity = GemmaIPCBoundHelperIdentity(
            helperInstanceID: UUID(),
            processIdentifier: 42
        )
        let response = GemmaXPCControlResponseEnvelope(
            requestID: requestID,
            body: .sessionBound(.init(binding: binding, helperIdentity: identity))
        )
        let responseData = try GemmaXPCControlCodec.encode(response)
        var responseObject = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        #expect(Set(responseObject.keys) == ["protocolVersion", "requestID", "body"])
        var responseBody = try #require(responseObject["body"] as? [String: Any])
        #expect(Set(responseBody.keys) == ["kind", "payload"])
        var responsePayload = try #require(responseBody["payload"] as? [String: Any])
        #expect(Set(responsePayload.keys) == ["model", "expectedModelRootIdentity", "helperIdentity"])
        var helperIdentity = try #require(responsePayload["helperIdentity"] as? [String: Any])
        #expect(Set(helperIdentity.keys) == ["helperInstanceID", "processIdentifier"])
        helperIdentity["path"] = "/tmp/not-allowed"
        responsePayload["helperIdentity"] = helperIdentity
        responseBody["payload"] = responsePayload
        responseObject["body"] = responseBody
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaXPCControlCodec.decodeResponse(
                JSONSerialization.data(withJSONObject: responseObject),
                expectedRequestID: requestID,
                expectedOperation: .bindSession
            )
        }

        let mismatchedBinding = GemmaIPCBindSessionRequest(
            model: pin,
            expectedModelRootIdentity: try GemmaIPCModelRootIdentity(deviceID: 17, fileID: 24)
        )
        let mismatchedResponse = GemmaXPCControlResponseEnvelope(
            requestID: requestID,
            body: .sessionBound(.init(binding: mismatchedBinding, helperIdentity: identity))
        )
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaXPCControlCodec.decodeBindSessionResponse(
                GemmaXPCControlCodec.encode(mismatchedResponse),
                expectedRequestID: requestID,
                expectedBinding: binding
            )
        }

        let duplicateKind = Data("""
        {"protocolVersion":\(GemmaIPCProtocol.currentVersion),"requestID":"\(requestID.uuidString)","body":{"kind":"sessionBound","kind":"failure","payload":{}}}
        """.utf8)
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaXPCControlCodec.decodeResponse(
                duplicateKind,
                expectedRequestID: requestID,
                expectedOperation: .bindSession
            )
        }
    }

    @Test("control protocol v4 rejects request and response version skew")
    func controlFramesRejectVersionSkew() throws {
        #expect(GemmaIPCProtocol.currentVersion == 4)

        let binding = GemmaIPCBindSessionRequest(
            model: pin,
            expectedModelRootIdentity: try GemmaIPCModelRootIdentity(
                deviceID: 17,
                fileID: 23
            )
        )

        let incompatible = GemmaXPCControlRequestEnvelope(
            protocolVersion: GemmaIPCProtocol.currentVersion - 1,
            body: .bindSession(binding)
        )
        #expect(throws: GemmaIPCCodecError.protocolMismatch) {
            _ = try GemmaXPCControlCodec.decodeRequest(
                GemmaXPCControlCodec.encode(incompatible)
            )
        }

        let requestID = UUID()
        let incompatibleResponse = GemmaXPCControlResponseEnvelope(
            protocolVersion: GemmaIPCProtocol.currentVersion + 1,
            requestID: requestID,
            body: .sessionBound(.init(
                binding: binding,
                helperIdentity: .init(helperInstanceID: UUID(), processIdentifier: 42)
            ))
        )
        #expect(throws: GemmaIPCCodecError.malformedMessage) {
            _ = try GemmaXPCControlCodec.decodeResponse(
                GemmaXPCControlCodec.encode(incompatibleResponse),
                expectedRequestID: requestID,
                expectedOperation: .bindSession
            )
        }
    }
}
