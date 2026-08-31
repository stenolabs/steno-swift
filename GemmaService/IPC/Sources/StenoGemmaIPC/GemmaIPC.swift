import Foundation

/// The canonical version of Steno's narrow, local-only Gemma helper protocol.
public enum GemmaIPCProtocol {
    /// Version 5 atomically binds the exact model pin, verified root identity, file manifest,
    /// and helper identity.
    public static let currentVersion = 5
    public static let maximumEncodedMessageBytes = 256 * 1024
    public static let maximumTextBytes = 128 * 1024
    public static let maximumGenerationTokens = 4_096
}

/// Separates model work from process-lifecycle control at the raw XPC envelope.
///
/// The discriminator is outside JSON so a malformed control frame can never be
/// reinterpreted as a model request with a different failure schema.
public enum GemmaXPCChannel: String, Sendable, Equatable, Hashable {
    case model
    case control
}

/// Compile-time identity shared by the app-facing IPC client and the helper.
/// Keeping the adapter revision here avoids linking MLX into the model-free XPC shell.
public enum GemmaIPCBuildInfo {
    public static let serviceIdentifier = "steno-gemma-xpc"
    public static let adapterRevision = "37688d2cf7d3906e08c74479c9d9949ce6b81136"
}

/// A stable operation name for the one-request, one-response helper protocol.
public enum GemmaIPCOperation: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case handshake
    case countTokens
    case generate
    case cancel
    case shutdown
}

/// Fixed errors that are safe to return across the helper boundary.
///
/// No case contains a path, prompt, meeting identifier, run identifier, URL, or secret.
public enum GemmaIPCErrorCode: String, Codable, Sendable, Equatable {
    case invalidRequest
    case requestTooLarge
    case protocolMismatch
    case modelUnavailable
    case modelIntegrityFailure
    case adapterMismatch
    case unsupportedModel
    case contextWindowExceeded
    case responseTruncated
    case cancelled
    case busy
    case shuttingDown
    case generationFailed
    case internalFailure
}

/// An immutable, path-free identity for a previously verified local model snapshot.
public struct GemmaModelSnapshotPin: Codable, Sendable, Equatable {
    public let modelIdentifier: String
    public let checkpointRevision: String
    public let adapterRevision: String
    public let licenseIdentifier: String
    public let manifestSHA256: String

    public init(
        modelIdentifier: String,
        checkpointRevision: String,
        adapterRevision: String,
        licenseIdentifier: String,
        manifestSHA256: String
    ) throws {
        guard Self.isModelIdentifier(modelIdentifier) else {
            throw GemmaIPCValidationError.invalidPinValue("modelIdentifier")
        }
        guard Self.isRevision(checkpointRevision) else {
            throw GemmaIPCValidationError.invalidPinValue("checkpointRevision")
        }
        guard Self.isRevision(adapterRevision) else {
            throw GemmaIPCValidationError.invalidPinValue("adapterRevision")
        }
        guard Self.isLicenseIdentifier(licenseIdentifier) else {
            throw GemmaIPCValidationError.invalidPinValue("licenseIdentifier")
        }
        guard Self.isSHA256(manifestSHA256) else {
            throw GemmaIPCValidationError.invalidManifestSHA256
        }

        self.modelIdentifier = modelIdentifier
        self.checkpointRevision = checkpointRevision
        self.adapterRevision = adapterRevision
        self.licenseIdentifier = licenseIdentifier
        self.manifestSHA256 = manifestSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case modelIdentifier
        case checkpointRevision
        case adapterRevision
        case licenseIdentifier
        case manifestSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelIdentifier: container.decode(String.self, forKey: .modelIdentifier),
            checkpointRevision: container.decode(String.self, forKey: .checkpointRevision),
            adapterRevision: container.decode(String.self, forKey: .adapterRevision),
            licenseIdentifier: container.decode(String.self, forKey: .licenseIdentifier),
            manifestSHA256: container.decode(String.self, forKey: .manifestSHA256)
        )
    }

    private static func isModelIdentifier(_ value: String) -> Bool {
        guard value.utf8.count <= 256,
              !value.contains("://"),
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\")
        else { return false }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(components.count) else { return false }
        return components.allSatisfy { component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && component.utf8.allSatisfy(Self.isIdentifierByte)
        }
    }

    private static func isRevision(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy(Self.isLowercaseHexByte)
    }

    private static func isLicenseIdentifier(_ value: String) -> Bool {
        guard (1 ... 128).contains(value.utf8.count),
              let first = value.utf8.first,
              Self.isASCIIAlphaNumeric(first)
        else { return false }
        return value.utf8.allSatisfy { byte in
            Self.isASCIIAlphaNumeric(byte) || [43, 45, 46, 95].contains(byte)
        }
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(Self.isLowercaseHexByte)
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        Self.isASCIIAlphaNumeric(byte) || [45, 46, 95].contains(byte)
    }

    private static func isLowercaseHexByte(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte)
            || (65 ... 90).contains(byte)
            || (97 ... 122).contains(byte)
    }
}

public enum GemmaIPCValidationError: Error, Equatable, Sendable {
    case invalidPinValue(String)
    case invalidManifestSHA256
    case invalidModelRootIdentity
    case invalidModelFileMetadata(String)
    case invalidModelFileMetadataOrder
    case textTooLarge(limit: Int, actual: Int)
    case invalidMaximumGenerationTokens
}

public struct GemmaIPCHandshakeRequest: Codable, Sendable, Equatable {
    public let model: GemmaModelSnapshotPin

    public init(model: GemmaModelSnapshotPin) {
        self.model = model
    }
}

public struct GemmaIPCTokenCountRequest: Codable, Sendable, Equatable {
    public let model: GemmaModelSnapshotPin
    public let text: String

    public init(model: GemmaModelSnapshotPin, text: String) throws {
        try Self.validateText(text)
        self.model = model
        self.text = text
    }

    fileprivate static func validateText(_ text: String) throws {
        let byteCount = text.utf8.count
        guard byteCount <= GemmaIPCProtocol.maximumTextBytes else {
            throw GemmaIPCValidationError.textTooLarge(
                limit: GemmaIPCProtocol.maximumTextBytes,
                actual: byteCount
            )
        }
    }
}

public struct GemmaIPCGenerateRequest: Codable, Sendable, Equatable {
    public let model: GemmaModelSnapshotPin
    public let prompt: String
    public let maximumTokens: Int

    public init(
        model: GemmaModelSnapshotPin,
        prompt: String,
        maximumTokens: Int
    ) throws {
        try GemmaIPCTokenCountRequest.validateText(prompt)
        guard (1 ... GemmaIPCProtocol.maximumGenerationTokens).contains(maximumTokens) else {
            throw GemmaIPCValidationError.invalidMaximumGenerationTokens
        }
        self.model = model
        self.prompt = prompt
        self.maximumTokens = maximumTokens
    }
}

public struct GemmaIPCCancelRequest: Codable, Sendable, Equatable {
    public let targetRequestID: UUID

    public init(targetRequestID: UUID) {
        self.targetRequestID = targetRequestID
    }
}

/// The request body is intentionally closed. New operations require a protocol-version change.
public enum GemmaIPCRequestBody: Sendable, Equatable, Codable {
    case handshake(GemmaIPCHandshakeRequest)
    case countTokens(GemmaIPCTokenCountRequest)
    case generate(GemmaIPCGenerateRequest)
    case cancel(GemmaIPCCancelRequest)
    case shutdown

    public var operation: GemmaIPCOperation {
        switch self {
        case .handshake:
            .handshake
        case .countTokens:
            .countTokens
        case .generate:
            .generate
        case .cancel:
            .cancel
        case .shutdown:
            .shutdown
        }
    }

    /// Returns the exact snapshot pin carried by application work.
    ///
    /// Lifecycle operations are deliberately pin-free and remain owned by the request registry.
    public var modelPin: GemmaModelSnapshotPin? {
        switch self {
        case .handshake(let request):
            request.model
        case .countTokens(let request):
            request.model
        case .generate(let request):
            request.model
        case .cancel, .shutdown:
            nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case operation
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try container.decode(GemmaIPCOperation.self, forKey: .operation)
        switch operation {
        case .handshake:
            self = .handshake(try container.decode(GemmaIPCHandshakeRequest.self, forKey: .payload))
        case .countTokens:
            self = .countTokens(try container.decode(GemmaIPCTokenCountRequest.self, forKey: .payload))
        case .generate:
            self = .generate(try container.decode(GemmaIPCGenerateRequest.self, forKey: .payload))
        case .cancel:
            self = .cancel(try container.decode(GemmaIPCCancelRequest.self, forKey: .payload))
        case .shutdown:
            _ = try container.decode(GemmaIPCEmptyPayload.self, forKey: .payload)
            self = .shutdown
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operation, forKey: .operation)
        switch self {
        case .handshake(let request):
            try container.encode(request, forKey: .payload)
        case .countTokens(let request):
            try container.encode(request, forKey: .payload)
        case .generate(let request):
            try container.encode(request, forKey: .payload)
        case .cancel(let request):
            try container.encode(request, forKey: .payload)
        case .shutdown:
            try container.encode(GemmaIPCEmptyPayload(), forKey: .payload)
        }
    }

    fileprivate func validate() throws {
        switch self {
        case .handshake:
            break
        case .countTokens(let request):
            try GemmaIPCTokenCountRequest.validateText(request.text)
        case .generate(let request):
            try GemmaIPCTokenCountRequest.validateText(request.prompt)
            guard (1 ... GemmaIPCProtocol.maximumGenerationTokens).contains(request.maximumTokens) else {
                throw GemmaIPCValidationError.invalidMaximumGenerationTokens
            }
        case .cancel, .shutdown:
            break
        }
    }
}

public struct GemmaIPCRequestEnvelope: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let body: GemmaIPCRequestBody

    public init(
        protocolVersion: Int = GemmaIPCProtocol.currentVersion,
        requestID: UUID = UUID(),
        body: GemmaIPCRequestBody
    ) throws {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.body = body
        try body.validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        body = try container.decode(GemmaIPCRequestBody.self, forKey: .body)
    }
}

public struct GemmaIPCHandshakeResponse: Codable, Sendable, Equatable {
    public let serviceIdentifier: String
    public let protocolVersion: Int
    public let adapterRevision: String
    public let supportedOperations: [GemmaIPCOperation]

    public init(
        serviceIdentifier: String,
        protocolVersion: Int = GemmaIPCProtocol.currentVersion,
        adapterRevision: String,
        supportedOperations: [GemmaIPCOperation]
    ) {
        self.serviceIdentifier = serviceIdentifier
        self.protocolVersion = protocolVersion
        self.adapterRevision = adapterRevision
        self.supportedOperations = supportedOperations
    }
}

public struct GemmaIPCTokenCountResponse: Codable, Sendable, Equatable {
    public let tokenCount: Int

    public init(tokenCount: Int) {
        self.tokenCount = tokenCount
    }
}

public struct GemmaIPCGenerateResponse: Codable, Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum GemmaIPCAcknowledgementKind: String, Codable, Sendable, Equatable {
    case cancelled
    case shutdown
}

public struct GemmaIPCAcknowledgement: Codable, Sendable, Equatable {
    public let kind: GemmaIPCAcknowledgementKind
    public let didChangeState: Bool

    public init(kind: GemmaIPCAcknowledgementKind, didChangeState: Bool) {
        self.kind = kind
        self.didChangeState = didChangeState
    }
}

public struct GemmaIPCFailure: Codable, Sendable, Equatable {
    public let code: GemmaIPCErrorCode

    public init(code: GemmaIPCErrorCode) {
        self.code = code
    }
}

public enum GemmaIPCResponseBody: Sendable, Equatable, Codable {
    case handshake(GemmaIPCHandshakeResponse)
    case tokenCount(GemmaIPCTokenCountResponse)
    case generate(GemmaIPCGenerateResponse)
    case acknowledgement(GemmaIPCAcknowledgement)
    case failure(GemmaIPCFailure)

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private enum Kind: String, Codable {
        case handshake
        case tokenCount
        case generate
        case acknowledgement
        case failure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .handshake:
            self = .handshake(try container.decode(GemmaIPCHandshakeResponse.self, forKey: .payload))
        case .tokenCount:
            self = .tokenCount(try container.decode(GemmaIPCTokenCountResponse.self, forKey: .payload))
        case .generate:
            self = .generate(try container.decode(GemmaIPCGenerateResponse.self, forKey: .payload))
        case .acknowledgement:
            self = .acknowledgement(try container.decode(GemmaIPCAcknowledgement.self, forKey: .payload))
        case .failure:
            self = .failure(try container.decode(GemmaIPCFailure.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .handshake(let response):
            try container.encode(Kind.handshake, forKey: .kind)
            try container.encode(response, forKey: .payload)
        case .tokenCount(let response):
            try container.encode(Kind.tokenCount, forKey: .kind)
            try container.encode(response, forKey: .payload)
        case .generate(let response):
            try container.encode(Kind.generate, forKey: .kind)
            try container.encode(response, forKey: .payload)
        case .acknowledgement(let response):
            try container.encode(Kind.acknowledgement, forKey: .kind)
            try container.encode(response, forKey: .payload)
        case .failure(let response):
            try container.encode(Kind.failure, forKey: .kind)
            try container.encode(response, forKey: .payload)
        }
    }
}

public struct GemmaIPCResponseEnvelope: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let body: GemmaIPCResponseBody

    public init(
        protocolVersion: Int = GemmaIPCProtocol.currentVersion,
        requestID: UUID,
        body: GemmaIPCResponseBody
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.body = body
    }
}

public enum GemmaIPCCodecError: Error, Equatable, Sendable {
    case oversizedMessage(limit: Int, actual: Int)
    case protocolMismatch
    case malformedMessage
}

/// Size-bounded, fail-closed JSON coding for IPC data frames.
public enum GemmaIPCCodec {
    public static func encode(_ request: GemmaIPCRequestEnvelope) throws -> Data {
        try encodeValue(request)
    }

    public static func encode(_ response: GemmaIPCResponseEnvelope) throws -> Data {
        try encodeValue(response)
    }

    public static func decodeRequest(_ data: Data) throws -> GemmaIPCRequestEnvelope {
        try checkSize(data)
        let request: GemmaIPCRequestEnvelope
        do {
            try GemmaJSONDuplicateKeyValidator.validate(data)
            try GemmaIPCJSONSchema.validateRequest(data)
            request = try JSONDecoder().decode(GemmaIPCRequestEnvelope.self, from: data)
        } catch {
            throw GemmaIPCCodecError.malformedMessage
        }
        guard request.protocolVersion == GemmaIPCProtocol.currentVersion else {
            throw GemmaIPCCodecError.protocolMismatch
        }
        return request
    }

    public static func decodeResponse(
        _ data: Data,
        expectedRequestID: UUID,
        expectedOperation: GemmaIPCOperation
    ) throws -> GemmaIPCResponseEnvelope {
        try checkSize(data)
        do {
            try GemmaJSONDuplicateKeyValidator.validate(data)
            try GemmaIPCJSONSchema.validateResponse(data)
            let response = try JSONDecoder().decode(GemmaIPCResponseEnvelope.self, from: data)
            guard response.protocolVersion == GemmaIPCProtocol.currentVersion,
                  response.requestID == expectedRequestID
            else {
                throw GemmaIPCCodecError.malformedMessage
            }
            try validateResponseSemantics(
                response.body,
                expectedOperation: expectedOperation
            )
            return response
        } catch {
            throw GemmaIPCCodecError.malformedMessage
        }
    }

    private static func encodeValue<Value: Encodable>(_ value: Value) throws -> Data {
        let data = try JSONEncoder().encode(value)
        try checkSize(data)
        return data
    }

    private static func checkSize(_ data: Data) throws {
        guard data.count <= GemmaIPCProtocol.maximumEncodedMessageBytes else {
            throw GemmaIPCCodecError.oversizedMessage(
                limit: GemmaIPCProtocol.maximumEncodedMessageBytes,
                actual: data.count
            )
        }
    }

    private static func validateResponseSemantics(
        _ body: GemmaIPCResponseBody,
        expectedOperation: GemmaIPCOperation
    ) throws {
        switch (expectedOperation, body) {
        case (_, .failure):
            break
        case (.handshake, .handshake(let response)):
            let operations = Set(response.supportedOperations)
            guard response.serviceIdentifier == GemmaIPCBuildInfo.serviceIdentifier,
                  response.protocolVersion == GemmaIPCProtocol.currentVersion,
                  response.adapterRevision == GemmaIPCBuildInfo.adapterRevision,
                  operations.count == response.supportedOperations.count,
                  operations.isSuperset(of: [.handshake, .cancel, .shutdown])
            else {
                throw GemmaIPCCodecError.malformedMessage
            }
        case (.countTokens, .tokenCount(let response)):
            guard response.tokenCount >= 0 else {
                throw GemmaIPCCodecError.malformedMessage
            }
        case (.generate, .generate(let response)):
            try GemmaIPCTokenCountRequest.validateText(response.text)
        case (.cancel, .acknowledgement(let response)):
            guard response.kind == .cancelled else {
                throw GemmaIPCCodecError.malformedMessage
            }
        case (.shutdown, .acknowledgement(let response)):
            guard response.kind == .shutdown else {
                throw GemmaIPCCodecError.malformedMessage
            }
        default:
            throw GemmaIPCCodecError.malformedMessage
        }
    }
}

/// Control requests travel inside the same bounded, strictly decoded Data frame as model work.
/// They are intercepted by the XPC shell and never reach `GemmaServiceCore`.
public enum GemmaXPCControlOperation: String, Codable, Sendable, Equatable {
    case bindSession
    case prepareForExit
    case armAndExit
}

/// The path-free identity returned after one helper process binds its execution gate.
public struct GemmaIPCBoundHelperIdentity: Codable, Sendable, Equatable {
    public let helperInstanceID: UUID
    public let processIdentifier: Int32

    public init(helperInstanceID: UUID, processIdentifier: Int32) {
        self.helperInstanceID = helperInstanceID
        self.processIdentifier = processIdentifier
    }
}

/// The expected filesystem identity of the local model root verified at bind time.
///
/// This is path-free so the control frame never reveals a model-store location.
/// The execution-gate and model-root descriptors travel separately over XPC.
public struct GemmaIPCModelRootIdentity: Codable, Sendable, Equatable {
    public let deviceID: UInt64
    public let fileID: UInt64

    public init(deviceID: UInt64, fileID: UInt64) throws {
        guard fileID != 0 else {
            throw GemmaIPCValidationError.invalidModelRootIdentity
        }
        self.deviceID = deviceID
        self.fileID = fileID
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case fileID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            deviceID: container.decode(UInt64.self, forKey: .deviceID),
            fileID: container.decode(UInt64.self, forKey: .fileID)
        )
    }
}

/// The path-free descriptor metadata that must agree with every file descriptor in a model bind.
///
/// The name is a canonical relative name inside the already verified model root. It is metadata,
/// not a path the helper is allowed to resolve. The actual bytes arrive only as XPC descriptors.
public struct GemmaIPCModelFileMetadata: Codable, Sendable, Equatable {
    public let relativePath: String
    public let size: Int64
    public let sha256: String

    public init(relativePath: String, size: Int64, sha256: String) throws {
        guard Self.isCanonicalRelativePath(relativePath) else {
            throw GemmaIPCValidationError.invalidModelFileMetadata("relativePath")
        }
        guard size >= 0 else {
            throw GemmaIPCValidationError.invalidModelFileMetadata("size")
        }
        guard GemmaModelSnapshotPin.isSHA256(sha256) else {
            throw GemmaIPCValidationError.invalidModelFileMetadata("sha256")
        }
        self.relativePath = relativePath
        self.size = size
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case relativePath
        case size
        case sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            relativePath: container.decode(String.self, forKey: .relativePath),
            size: container.decode(Int64.self, forKey: .size),
            sha256: container.decode(String.self, forKey: .sha256)
        )
    }

    private static func isCanonicalRelativePath(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty,
              bytes.count <= 1_024,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              bytes.allSatisfy({ (0x21 ... 0x7e).contains($0) && $0 != 0x5c && $0 != 0x3a })
        else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.count <= 8 && components.allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && $0.utf8.count <= 255
        }
    }
}

/// The path-free portion of an atomic model-session bind request.
///
/// The raw XPC frame carries the corresponding execution-gate, model-root, and model-file
/// descriptors, never JSON-encoded descriptor numbers.
public struct GemmaIPCBindSessionRequest: Codable, Sendable, Equatable {
    public let model: GemmaModelSnapshotPin
    public let expectedModelRootIdentity: GemmaIPCModelRootIdentity
    public let expectedModelFiles: [GemmaIPCModelFileMetadata]

    public init(
        model: GemmaModelSnapshotPin,
        expectedModelRootIdentity: GemmaIPCModelRootIdentity,
        expectedModelFiles: [GemmaIPCModelFileMetadata]
    ) throws {
        guard !expectedModelFiles.isEmpty,
              expectedModelFiles.count <= 4_097,
              expectedModelFiles.map(\.relativePath) == expectedModelFiles.map(\.relativePath).sorted(),
              Set(expectedModelFiles.map(\.relativePath)).count == expectedModelFiles.count,
              expectedModelFiles.contains(where: {
                  $0.relativePath == "gemma-model-manifest.json"
                      && $0.sha256 == model.manifestSHA256
              })
        else {
            throw GemmaIPCValidationError.invalidModelFileMetadataOrder
        }
        self.model = model
        self.expectedModelRootIdentity = expectedModelRootIdentity
        self.expectedModelFiles = expectedModelFiles
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case expectedModelRootIdentity
        case expectedModelFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            model: container.decode(GemmaModelSnapshotPin.self, forKey: .model),
            expectedModelRootIdentity: container.decode(
                GemmaIPCModelRootIdentity.self,
                forKey: .expectedModelRootIdentity
            ),
            expectedModelFiles: container.decode(
                [GemmaIPCModelFileMetadata].self,
                forKey: .expectedModelFiles
            )
        )
    }
}

/// The helper's atomic acknowledgement of an exact model-session bind.
///
/// `model` and `expectedModelRootIdentity` must be an exact echo of the request. The helper
/// adds only its process-lifetime identity after it has accepted both out-of-band descriptors.
public struct GemmaIPCBindSessionResponse: Codable, Sendable, Equatable {
    public let model: GemmaModelSnapshotPin
    public let expectedModelRootIdentity: GemmaIPCModelRootIdentity
    public let helperIdentity: GemmaIPCBoundHelperIdentity

    public init(
        binding: GemmaIPCBindSessionRequest,
        helperIdentity: GemmaIPCBoundHelperIdentity
    ) {
        model = binding.model
        expectedModelRootIdentity = binding.expectedModelRootIdentity
        self.helperIdentity = helperIdentity
    }
}

/// A helper-created identity, unique for exactly one helper process lifetime.
public struct GemmaIPCPreparedHelperExit: Codable, Sendable, Equatable {
    public let helperInstanceID: UUID
    public let processIdentifier: Int32

    public init(helperInstanceID: UUID, processIdentifier: Int32) {
        self.helperInstanceID = helperInstanceID
        self.processIdentifier = processIdentifier
    }
}

public struct GemmaIPCArmAndExitRequest: Codable, Sendable, Equatable {
    public let preparedHelper: GemmaIPCPreparedHelperExit

    public init(preparedHelper: GemmaIPCPreparedHelperExit) {
        self.preparedHelper = preparedHelper
    }
}

public enum GemmaXPCControlRequestBody: Sendable, Equatable, Codable {
    case bindSession(GemmaIPCBindSessionRequest)
    case prepareForExit
    case armAndExit(GemmaIPCArmAndExitRequest)

    public var operation: GemmaXPCControlOperation {
        switch self {
        case .bindSession:
            .bindSession
        case .prepareForExit:
            .prepareForExit
        case .armAndExit:
            .armAndExit
        }
    }

    private enum CodingKeys: String, CodingKey {
        case operation
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(GemmaXPCControlOperation.self, forKey: .operation) {
        case .bindSession:
            self = .bindSession(try container.decode(GemmaIPCBindSessionRequest.self, forKey: .payload))
        case .prepareForExit:
            _ = try container.decode(GemmaIPCEmptyPayload.self, forKey: .payload)
            self = .prepareForExit
        case .armAndExit:
            self = .armAndExit(try container.decode(GemmaIPCArmAndExitRequest.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operation, forKey: .operation)
        switch self {
        case .bindSession(let request):
            try container.encode(request, forKey: .payload)
        case .prepareForExit:
            try container.encode(GemmaIPCEmptyPayload(), forKey: .payload)
        case .armAndExit(let request):
            try container.encode(request, forKey: .payload)
        }
    }
}

public struct GemmaXPCControlRequestEnvelope: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let body: GemmaXPCControlRequestBody

    public init(
        protocolVersion: Int = GemmaIPCProtocol.currentVersion,
        requestID: UUID = UUID(),
        body: GemmaXPCControlRequestBody
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.body = body
    }
}

public enum GemmaXPCControlResponseBody: Sendable, Equatable, Codable {
    case sessionBound(GemmaIPCBindSessionResponse)
    case prepared(GemmaIPCPreparedHelperExit)
    case armed(GemmaIPCPreparedHelperExit)
    case failure(GemmaIPCFailure)

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private enum Kind: String, Codable {
        case sessionBound
        case prepared
        case armed
        case failure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .sessionBound:
            self = .sessionBound(try container.decode(GemmaIPCBindSessionResponse.self, forKey: .payload))
        case .prepared:
            self = .prepared(try container.decode(GemmaIPCPreparedHelperExit.self, forKey: .payload))
        case .armed:
            self = .armed(try container.decode(GemmaIPCPreparedHelperExit.self, forKey: .payload))
        case .failure:
            self = .failure(try container.decode(GemmaIPCFailure.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionBound(let response):
            try container.encode(Kind.sessionBound, forKey: .kind)
            try container.encode(response, forKey: .payload)
        case .prepared(let prepared):
            try container.encode(Kind.prepared, forKey: .kind)
            try container.encode(prepared, forKey: .payload)
        case .armed(let armed):
            try container.encode(Kind.armed, forKey: .kind)
            try container.encode(armed, forKey: .payload)
        case .failure(let failure):
            try container.encode(Kind.failure, forKey: .kind)
            try container.encode(failure, forKey: .payload)
        }
    }
}

public struct GemmaXPCControlResponseEnvelope: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let body: GemmaXPCControlResponseBody

    public init(
        protocolVersion: Int = GemmaIPCProtocol.currentVersion,
        requestID: UUID,
        body: GemmaXPCControlResponseBody
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.body = body
    }
}

public enum GemmaXPCControlCodec {
    public static func encode(_ request: GemmaXPCControlRequestEnvelope) throws -> Data {
        try encodeValue(request)
    }

    public static func encode(_ response: GemmaXPCControlResponseEnvelope) throws -> Data {
        try encodeValue(response)
    }

    public static func decodeRequest(_ data: Data) throws -> GemmaXPCControlRequestEnvelope {
        try checkSize(data)
        let request: GemmaXPCControlRequestEnvelope
        do {
            try GemmaJSONDuplicateKeyValidator.validate(data)
            try GemmaXPCControlJSONSchema.validateRequest(data)
            request = try JSONDecoder().decode(GemmaXPCControlRequestEnvelope.self, from: data)
        } catch {
            throw GemmaIPCCodecError.malformedMessage
        }
        guard request.protocolVersion == GemmaIPCProtocol.currentVersion else {
            throw GemmaIPCCodecError.protocolMismatch
        }
        return request
    }

    public static func decodeResponse(
        _ data: Data,
        expectedRequestID: UUID,
        expectedOperation: GemmaXPCControlOperation
    ) throws -> GemmaXPCControlResponseEnvelope {
        try checkSize(data)
        do {
            try GemmaJSONDuplicateKeyValidator.validate(data)
            try GemmaXPCControlJSONSchema.validateResponse(data)
            let response = try JSONDecoder().decode(GemmaXPCControlResponseEnvelope.self, from: data)
            guard response.protocolVersion == GemmaIPCProtocol.currentVersion,
                  response.requestID == expectedRequestID
            else {
                throw GemmaIPCCodecError.malformedMessage
            }
            switch (expectedOperation, response.body) {
            case (.bindSession, .sessionBound),
                 (.prepareForExit, .prepared),
                 (.armAndExit, .armed),
                 (_, .failure):
                return response
            default:
                throw GemmaIPCCodecError.malformedMessage
            }
        } catch {
            throw GemmaIPCCodecError.malformedMessage
        }
    }

    /// Decodes a bind acknowledgement and rejects a helper that did not exactly echo the
    /// snapshot pin and expected model-root identity supplied by the caller.
    public static func decodeBindSessionResponse(
        _ data: Data,
        expectedRequestID: UUID,
        expectedBinding: GemmaIPCBindSessionRequest
    ) throws -> GemmaIPCBindSessionResponse {
        let response = try decodeResponse(
            data,
            expectedRequestID: expectedRequestID,
            expectedOperation: .bindSession
        )
        guard case .sessionBound(let bound) = response.body,
              bound.model == expectedBinding.model,
              bound.expectedModelRootIdentity == expectedBinding.expectedModelRootIdentity
        else {
            throw GemmaIPCCodecError.malformedMessage
        }
        return bound
    }

    private static func encodeValue<Value: Encodable>(_ value: Value) throws -> Data {
        let data = try JSONEncoder().encode(value)
        try checkSize(data)
        return data
    }

    private static func checkSize(_ data: Data) throws {
        guard data.count <= GemmaIPCProtocol.maximumEncodedMessageBytes else {
            throw GemmaIPCCodecError.oversizedMessage(
                limit: GemmaIPCProtocol.maximumEncodedMessageBytes,
                actual: data.count
            )
        }
    }
}

/// Foundation's JSON decoders keep one value when an object repeats a key.
/// IPC treats duplicate keys as malformed because their meaning is ambiguous.
@_spi(StenoGemmaRuntime)
public enum GemmaStrictJSONValidation {
    public static func validateNoDuplicateObjectKeys(_ data: Data) throws {
        try GemmaJSONDuplicateKeyValidator.validate(data)
    }
}

private struct GemmaJSONDuplicateKeyValidator {
    private static let maximumNestingDepth = 64

    private let data: Data
    private var index: Data.Index

    private init(data: Data) {
        self.data = data
        index = data.startIndex
    }

    static func validate(_ data: Data) throws {
        var parser = GemmaJSONDuplicateKeyValidator(data: data)
        try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == data.endIndex else {
            throw GemmaIPCCodecError.malformedMessage
        }
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw GemmaIPCCodecError.malformedMessage
        }
        skipWhitespace()
        guard let byte = currentByte else {
            throw GemmaIPCCodecError.malformedMessage
        }

        switch byte {
        case 0x7B:
            try parseObject(depth: depth)
        case 0x5B:
            try parseArray(depth: depth)
        case 0x22:
            _ = try parseString()
        default:
            try parsePrimitive()
        }
    }

    private mutating func parseObject(depth: Int) throws {
        advance()
        skipWhitespace()
        if consume(0x7D) { return }

        // JSON object names are equal by their decoded Unicode scalar sequence, not by
        // Swift's canonical-equivalence String comparison. Tokenizer vocabularies may
        // intentionally contain canonically equivalent but byte-distinct tokens.
        var keys = Set<[UInt8]>()
        while true {
            skipWhitespace()
            guard currentByte == 0x22 else {
                throw GemmaIPCCodecError.malformedMessage
            }
            let keyRange = try parseString()
            let key = try JSONDecoder().decode(String.self, from: data.subdata(in: keyRange))
            guard keys.insert(Array(key.utf8)).inserted else {
                throw GemmaIPCCodecError.malformedMessage
            }

            skipWhitespace()
            guard consume(0x3A) else {
                throw GemmaIPCCodecError.malformedMessage
            }
            try parseValue(depth: depth + 1)
            skipWhitespace()

            if consume(0x7D) { return }
            guard consume(0x2C) else {
                throw GemmaIPCCodecError.malformedMessage
            }
        }
    }

    private mutating func parseArray(depth: Int) throws {
        advance()
        skipWhitespace()
        if consume(0x5D) { return }

        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else {
                throw GemmaIPCCodecError.malformedMessage
            }
        }
    }

    private mutating func parseString() throws -> Range<Data.Index> {
        let start = index
        guard consume(0x22) else {
            throw GemmaIPCCodecError.malformedMessage
        }

        while let byte = currentByte {
            switch byte {
            case 0x22:
                advance()
                return start ..< index
            case 0x5C:
                advance()
                guard currentByte != nil else {
                    throw GemmaIPCCodecError.malformedMessage
                }
                advance()
            case 0x00 ... 0x1F:
                throw GemmaIPCCodecError.malformedMessage
            default:
                advance()
            }
        }
        throw GemmaIPCCodecError.malformedMessage
    }

    private mutating func parsePrimitive() throws {
        let start = index
        while let byte = currentByte, !Self.isValueDelimiter(byte) {
            advance()
        }
        guard index != start else {
            throw GemmaIPCCodecError.malformedMessage
        }
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte, Self.isWhitespace(byte) {
            advance()
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard currentByte == byte else { return false }
        advance()
        return true
    }

    private mutating func advance() {
        index = data.index(after: index)
    }

    private var currentByte: UInt8? {
        guard index < data.endIndex else { return nil }
        return data[index]
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        [0x20, 0x09, 0x0A, 0x0D].contains(byte)
    }

    private static func isValueDelimiter(_ byte: UInt8) -> Bool {
        Self.isWhitespace(byte) || [0x2C, 0x5D, 0x7D].contains(byte)
    }
}

/// JSONDecoder intentionally ignores unknown keys. IPC frames do not: every protocol
/// version has one closed schema so a misspelled or injected field cannot be accepted.
private enum GemmaIPCJSONSchema {
    private static let envelopeKeys: Set<String> = ["protocolVersion", "requestID", "body"]
    private static let requestBodyKeys: Set<String> = ["operation", "payload"]
    private static let responseBodyKeys: Set<String> = ["kind", "payload"]
    private static let modelKeys: Set<String> = [
        "modelIdentifier",
        "checkpointRevision",
        "adapterRevision",
        "licenseIdentifier",
        "manifestSHA256",
    ]

    static func validateRequest(_ data: Data) throws {
        let envelope = try rootObject(data, keys: envelopeKeys)
        let body = try object(envelope["body"], keys: requestBodyKeys)
        guard let operation = body["operation"] as? String else {
            throw GemmaIPCCodecError.malformedMessage
        }

        switch operation {
        case GemmaIPCOperation.handshake.rawValue:
            let payload = try object(body["payload"], keys: ["model"])
            _ = try object(payload["model"], keys: modelKeys)
        case GemmaIPCOperation.countTokens.rawValue:
            let payload = try object(body["payload"], keys: ["model", "text"])
            _ = try object(payload["model"], keys: modelKeys)
        case GemmaIPCOperation.generate.rawValue:
            let payload = try object(
                body["payload"],
                keys: ["model", "prompt", "maximumTokens"]
            )
            _ = try object(payload["model"], keys: modelKeys)
        case GemmaIPCOperation.cancel.rawValue:
            _ = try object(body["payload"], keys: ["targetRequestID"])
        case GemmaIPCOperation.shutdown.rawValue:
            _ = try object(body["payload"], keys: [])
        default:
            throw GemmaIPCCodecError.malformedMessage
        }
    }

    static func validateResponse(_ data: Data) throws {
        let envelope = try rootObject(data, keys: envelopeKeys)
        let body = try object(envelope["body"], keys: responseBodyKeys)
        guard let kind = body["kind"] as? String else {
            throw GemmaIPCCodecError.malformedMessage
        }

        switch kind {
        case "handshake":
            _ = try object(
                body["payload"],
                keys: [
                    "serviceIdentifier",
                    "protocolVersion",
                    "adapterRevision",
                    "supportedOperations",
                ]
            )
        case "tokenCount":
            _ = try object(body["payload"], keys: ["tokenCount"])
        case "generate":
            _ = try object(body["payload"], keys: ["text"])
        case "acknowledgement":
            _ = try object(body["payload"], keys: ["kind", "didChangeState"])
        case "failure":
            _ = try object(body["payload"], keys: ["code"])
        default:
            throw GemmaIPCCodecError.malformedMessage
        }
    }

    private static func rootObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        return try object(value, keys: keys)
    }

    private static func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == keys else {
            throw GemmaIPCCodecError.malformedMessage
        }
        return object
    }
}

private enum GemmaXPCControlJSONSchema {
    private static let envelopeKeys: Set<String> = ["protocolVersion", "requestID", "body"]
    private static let requestBodyKeys: Set<String> = ["operation", "payload"]
    private static let responseBodyKeys: Set<String> = ["kind", "payload"]
    private static let helperIdentityKeys: Set<String> = ["helperInstanceID", "processIdentifier"]
    private static let modelPinKeys: Set<String> = [
        "modelIdentifier", "checkpointRevision", "adapterRevision", "licenseIdentifier", "manifestSHA256",
    ]
    private static let modelRootIdentityKeys: Set<String> = ["deviceID", "fileID"]
    private static let bindSessionRequestKeys: Set<String> = [
        "model", "expectedModelRootIdentity", "expectedModelFiles",
    ]
    private static let bindSessionResponseKeys: Set<String> = [
        "model", "expectedModelRootIdentity", "helperIdentity",
    ]

    static func validateRequest(_ data: Data) throws {
        let envelope = try rootObject(data, keys: envelopeKeys)
        let body = try object(envelope["body"], keys: requestBodyKeys)
        guard let operation = body["operation"] as? String else {
            throw GemmaIPCCodecError.malformedMessage
        }
        switch operation {
        case GemmaXPCControlOperation.bindSession.rawValue:
            let payload = try object(body["payload"], keys: bindSessionRequestKeys)
            _ = try object(payload["model"], keys: modelPinKeys)
            _ = try object(payload["expectedModelRootIdentity"], keys: modelRootIdentityKeys)
            let files = try array(payload["expectedModelFiles"])
            guard !files.isEmpty else {
                throw GemmaIPCCodecError.malformedMessage
            }
            for file in files {
                _ = try object(file, keys: ["relativePath", "size", "sha256"])
            }
        case GemmaXPCControlOperation.prepareForExit.rawValue:
            _ = try object(body["payload"], keys: [])
        case GemmaXPCControlOperation.armAndExit.rawValue:
            let payload = try object(body["payload"], keys: ["preparedHelper"])
            _ = try object(payload["preparedHelper"], keys: helperIdentityKeys)
        default:
            throw GemmaIPCCodecError.malformedMessage
        }
    }

    static func validateResponse(_ data: Data) throws {
        let envelope = try rootObject(data, keys: envelopeKeys)
        let body = try object(envelope["body"], keys: responseBodyKeys)
        guard let kind = body["kind"] as? String else {
            throw GemmaIPCCodecError.malformedMessage
        }
        switch kind {
        case "sessionBound":
            let payload = try object(body["payload"], keys: bindSessionResponseKeys)
            _ = try object(payload["model"], keys: modelPinKeys)
            _ = try object(payload["expectedModelRootIdentity"], keys: modelRootIdentityKeys)
            _ = try object(payload["helperIdentity"], keys: helperIdentityKeys)
        case "prepared", "armed":
            _ = try object(body["payload"], keys: helperIdentityKeys)
        case "failure":
            _ = try object(body["payload"], keys: ["code"])
        default:
            throw GemmaIPCCodecError.malformedMessage
        }
    }

    private static func rootObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        try object(try JSONSerialization.jsonObject(with: data), keys: keys)
    }

    private static func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == keys else {
            throw GemmaIPCCodecError.malformedMessage
        }
        return object
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let array = value as? [Any] else {
            throw GemmaIPCCodecError.malformedMessage
        }
        return array
    }
}

private struct GemmaIPCEmptyPayload: Codable, Sendable, Equatable {}
