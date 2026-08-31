import CryptoKit
import Darwin
import Foundation
@testable import StenoGemmaClient
import StenoGemmaIPC
import StenoGemmaModelStore
import Testing
import XPC

@Suite("Gemma raw XPC session binding")
struct GemmaRawXPCTransportTests {
    @Test("prepared exit identity must exactly match the authenticated bind identity")
    func preparedIdentityMatchesBindIdentity() {
        let helperInstanceID = UUID()
        let bound = GemmaIPCBoundHelperIdentity(
            helperInstanceID: helperInstanceID,
            processIdentifier: 42
        )
        #expect(GemmaRawXPCIdentityValidation.matches(
            prepared: .init(helperInstanceID: helperInstanceID, processIdentifier: 42),
            bound: bound
        ))
        #expect(!GemmaRawXPCIdentityValidation.matches(
            prepared: .init(helperInstanceID: UUID(), processIdentifier: 42),
            bound: bound
        ))
        #expect(!GemmaRawXPCIdentityValidation.matches(
            prepared: .init(helperInstanceID: helperInstanceID, processIdentifier: 43),
            bound: bound
        ))
    }

    @Test("ordinary outer frames have exactly three keys")
    func ordinaryOuterFrameKeys() throws {
        let requestID = UUID()
        let message = try #require(GemmaRawXPCOuterFrame.make(
            frame: Data("frame".utf8),
            requestID: requestID,
            channel: .model
        ))

        #expect(keys(of: message) == Set(["channel", "frame", "requestID"]))
        let decoded = try #require(GemmaRawXPCOuterFrame.decode(message))
        #expect(decoded.requestID == requestID)
        #expect(decoded.channel == .model)
        #expect(decoded.frame == Data("frame".utf8))
    }

    @Test("the bind outer frame adds exactly two typed descriptor keys")
    func bindOuterFrameDescriptor() throws {
        var gateDescriptors: [Int32] = [-1, -1]
        var modelDescriptors: [Int32] = [-1, -1]
        try #require(Darwin.pipe(&gateDescriptors) == 0)
        try #require(Darwin.pipe(&modelDescriptors) == 0)
        defer {
            for descriptor in gateDescriptors + modelDescriptors {
                _ = Darwin.close(descriptor)
            }
        }

        let message = try #require(GemmaRawXPCOuterFrame.makeBindSession(
            frame: Data("bind-json".utf8),
            requestID: UUID(),
            channel: .control,
            executionGateDescriptor: gateDescriptors[0],
            modelDirectoryDescriptor: modelDescriptors[0]
        ))
        #expect(keys(of: message) == Set([
            "channel", "executionGateFD", "frame", "modelDirectoryFD", "requestID",
        ]))
        let executionGateObject = try #require(
            xpc_dictionary_get_value(message, GemmaRawXPCOuterFrame.executionGateFDKey)
        )
        let modelDirectoryObject = try #require(
            xpc_dictionary_get_value(message, GemmaRawXPCOuterFrame.modelDirectoryFDKey)
        )
        #expect(xpc_get_type(executionGateObject) == XPC_TYPE_FD)
        #expect(xpc_get_type(modelDirectoryObject) == XPC_TYPE_FD)
        #expect(GemmaRawXPCOuterFrame.isValidBindSession(message))

        for descriptorObject in [executionGateObject, modelDirectoryObject] {
            let duplicated = xpc_fd_dup(descriptorObject)
            #expect(duplicated >= 0)
            if duplicated >= 0 {
                _ = Darwin.close(duplicated)
            }
        }

        // Client replies must remain ordinary three-key frames.
        #expect(GemmaRawXPCOuterFrame.decode(message) == nil)
    }

    @Test("bind frame validation rejects a missing, extra, or numerically encoded descriptor")
    func bindFrameRejectsDescriptorSmuggling() throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(Darwin.pipe(&descriptors) == 0)
        defer {
            _ = Darwin.close(descriptors[0])
            _ = Darwin.close(descriptors[1])
        }

        let missingModelDescriptor = try #require(GemmaRawXPCOuterFrame.make(
            frame: Data("bind-json".utf8),
            requestID: UUID(),
            channel: .control
        ))
        let executionGateObject = try #require(xpc_fd_create(descriptors[0]))
        xpc_dictionary_set_value(
            missingModelDescriptor,
            GemmaRawXPCOuterFrame.executionGateFDKey,
            executionGateObject
        )
        #expect(!GemmaRawXPCOuterFrame.isValidBindSession(missingModelDescriptor))

        let missingExecutionGate = try #require(GemmaRawXPCOuterFrame.make(
            frame: Data("bind-json".utf8),
            requestID: UUID(),
            channel: .control
        ))
        let modelDirectoryObject = try #require(xpc_fd_create(descriptors[1]))
        xpc_dictionary_set_value(
            missingExecutionGate,
            GemmaRawXPCOuterFrame.modelDirectoryFDKey,
            modelDirectoryObject
        )
        #expect(!GemmaRawXPCOuterFrame.isValidBindSession(missingExecutionGate))

        let numericDescriptors = try #require(GemmaRawXPCOuterFrame.make(
            frame: Data("bind-json".utf8),
            requestID: UUID(),
            channel: .control
        ))
        xpc_dictionary_set_int64(
            numericDescriptors,
            GemmaRawXPCOuterFrame.executionGateFDKey,
            Int64(descriptors[0])
        )
        xpc_dictionary_set_int64(
            numericDescriptors,
            GemmaRawXPCOuterFrame.modelDirectoryFDKey,
            Int64(descriptors[1])
        )
        #expect(!GemmaRawXPCOuterFrame.isValidBindSession(numericDescriptors))

        let extraKey = try #require(GemmaRawXPCOuterFrame.makeBindSession(
            frame: Data("bind-json".utf8),
            requestID: UUID(),
            channel: .control,
            executionGateDescriptor: descriptors[0],
            modelDirectoryDescriptor: descriptors[1]
        ))
        xpc_dictionary_set_bool(extraKey, "unexpected", true)
        #expect(!GemmaRawXPCOuterFrame.isValidBindSession(extraKey))
    }

    @Test("factory accepts only a fresh capability with all five exact pin fields")
    func exactModelProvenanceAndMismatchClose() throws {
        let fixture = try RawModelFixture.make()
        let expected = try fixture.pin()
        let matching = try fixture.capability()

        let resolved = try GemmaRawXPCTransportFactory.resolveAndValidateModelDirectory(
            for: expected,
            using: { suppliedPin in
                #expect(suppliedPin == expected)
                return matching
            }
        )
        #expect(resolved === matching)
        #expect(resolved.withBorrowedFileDescriptor { $0 } != nil)
        resolved.close()

        let mismatches = try [
            fixture.pin(modelIdentifier: "different/model"),
            fixture.pin(checkpointRevision: String(repeating: "a", count: 40)),
            fixture.pin(adapterRevision: String(repeating: "b", count: 40)),
            fixture.pin(licenseIdentifier: "Different-License"),
            fixture.pin(manifestSHA256: String(repeating: "c", count: 64)),
        ]
        for mismatch in mismatches {
            let capability = try fixture.capability()
            #expect(throws: GemmaRawXPCTransportError.modelProvenanceMismatch) {
                _ = try GemmaRawXPCTransportFactory.resolveAndValidateModelDirectory(
                    for: mismatch,
                    using: { _ in capability }
                )
            }
            let borrowed: Int32? = capability.withBorrowedFileDescriptor { $0 }
            #expect(borrowed == nil)
        }
    }

    @Test("bind acknowledgement must echo the exact pin and root identity")
    func bindAcknowledgementExactEcho() throws {
        let fixture = try RawModelFixture.make()
        let binding = GemmaIPCBindSessionRequest(
            model: try fixture.pin(),
            expectedModelRootIdentity: try GemmaIPCModelRootIdentity(deviceID: 4, fileID: 8)
        )
        let helperIdentity = GemmaIPCBoundHelperIdentity(
            helperInstanceID: UUID(),
            processIdentifier: 42
        )
        let requestID = UUID()
        let exact = try GemmaXPCControlCodec.encode(GemmaXPCControlResponseEnvelope(
            requestID: requestID,
            body: .sessionBound(.init(binding: binding, helperIdentity: helperIdentity))
        ))
        #expect(try GemmaXPCControlCodec.decodeBindSessionResponse(
            exact,
            expectedRequestID: requestID,
            expectedBinding: binding
        ).helperIdentity == helperIdentity)

        let wrongPin = GemmaIPCBindSessionRequest(
            model: try fixture.pin(adapterRevision: String(repeating: "b", count: 40)),
            expectedModelRootIdentity: binding.expectedModelRootIdentity
        )
        let wrongPinResponse = try GemmaXPCControlCodec.encode(
            GemmaXPCControlResponseEnvelope(
                requestID: requestID,
                body: .sessionBound(.init(binding: wrongPin, helperIdentity: helperIdentity))
            )
        )
        #expect(throws: GemmaIPCCodecError.self) {
            _ = try GemmaXPCControlCodec.decodeBindSessionResponse(
                wrongPinResponse,
                expectedRequestID: requestID,
                expectedBinding: binding
            )
        }

        let wrongRoot = GemmaIPCBindSessionRequest(
            model: binding.model,
            expectedModelRootIdentity: try GemmaIPCModelRootIdentity(deviceID: 4, fileID: 9)
        )
        let wrongRootResponse = try GemmaXPCControlCodec.encode(
            GemmaXPCControlResponseEnvelope(
                requestID: requestID,
                body: .sessionBound(.init(binding: wrongRoot, helperIdentity: helperIdentity))
            )
        )
        #expect(throws: GemmaIPCCodecError.self) {
            _ = try GemmaXPCControlCodec.decodeBindSessionResponse(
                wrongRootResponse,
                expectedRequestID: requestID,
                expectedBinding: binding
            )
        }
    }

    @Test("reply decoding rejects every extra outer key")
    func replyRejectsExtraOuterKey() throws {
        let message = try #require(GemmaRawXPCOuterFrame.make(
            frame: Data(),
            requestID: UUID(),
            channel: .control
        ))
        xpc_dictionary_set_bool(message, "unexpected", true)
        #expect(GemmaRawXPCOuterFrame.decode(message) == nil)
    }

    private func keys(of dictionary: xpc_object_t) -> Set<String> {
        var result = Set<String>()
        _ = xpc_dictionary_apply(dictionary) { key, _ in
            result.insert(String(cString: key))
            return true
        }
        return result
    }
}

private final class RawModelFixture {
    private static let modelIdentifier = "mlx-community/gemma-4-2b-it-4bit"
    private static let checkpointRevision = "0123456789abcdef0123456789abcdef01234567"
    private static let adapterRevision = "37688d2cf7d3906e08c74479c9d9949ce6b81136"
    private static let licenseIdentifier = "Gemma"

    private let root: URL
    private let manifestSHA256: String
    private let verifier: GemmaModelVerifier

    private init(root: URL, manifestSHA256: String, verifier: GemmaModelVerifier) {
        self.root = root
        self.manifestSHA256 = manifestSHA256
        self.verifier = verifier
    }

    deinit {
        Self.makeWritableRecursively(root)
        try? FileManager.default.removeItem(at: root)
    }

    static func make() throws -> RawModelFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let weights = Data("synthetic-weights".utf8)
        let weightsURL = root.appendingPathComponent("weights.bin")
        try weights.write(to: weightsURL)
        let manifest = GemmaModelManifest(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            files: [
                .init(
                    relativePath: "weights.bin",
                    size: Int64(weights.count),
                    sha256: sha256(weights)
                ),
            ]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: root.appendingPathComponent("gemma-model-manifest.json"))
        try chmod(root.appendingPathComponent("weights.bin"), 0o400)
        try chmod(root.appendingPathComponent("gemma-model-manifest.json"), 0o400)
        try chmod(root, 0o500)

        let digest = sha256(manifestData)
        let requirements = try GemmaModelRequirements(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            expectedManifestSHA256: digest
        )
        return RawModelFixture(
            root: root,
            manifestSHA256: digest,
            verifier: GemmaModelVerifier(requirements: requirements)
        )
    }

    func capability() throws -> VerifiedGemmaModelDirectory {
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        return try verifier.verify(adoptingDirectoryDescriptor: descriptor)
    }

    func pin(
        modelIdentifier: String = RawModelFixture.modelIdentifier,
        checkpointRevision: String = RawModelFixture.checkpointRevision,
        adapterRevision: String = RawModelFixture.adapterRevision,
        licenseIdentifier: String = RawModelFixture.licenseIdentifier,
        manifestSHA256: String? = nil
    ) throws -> GemmaModelSnapshotPin {
        try GemmaModelSnapshotPin(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            manifestSHA256: manifestSHA256 ?? self.manifestSHA256
        )
    }

    private static func chmod(_ url: URL, _ mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeWritableRecursively(_ root: URL) {
        _ = Darwin.chmod(root.path, 0o700)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                _ = Darwin.chmod(url.path, isDirectory.boolValue ? 0o700 : 0o600)
            }
        }
    }
}
