import Foundation

/// The complete, immutable identity the user approves before Steno imports a
/// native Gemma checkpoint.
///
/// This is intentionally a value rather than a model URL. A later importer
/// receives only pins that have survived this validation and a catalogue
/// membership check.
public struct ApprovedNativeGemmaModelPin: Equatable, Hashable, Sendable {
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
        let snapshot = NativeGemmaModelSnapshot(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            manifestSHA256: manifestSHA256
        )
        guard snapshot.isWellFormed else {
            throw ApprovedNativeGemmaModelPinError.invalidPin
        }
        self.modelIdentifier = modelIdentifier
        self.checkpointRevision = checkpointRevision
        self.adapterRevision = adapterRevision
        self.licenseIdentifier = licenseIdentifier
        self.manifestSHA256 = manifestSHA256
    }

    /// The only result that may become provenance for this pin.
    public var snapshot: NativeGemmaModelSnapshot {
        NativeGemmaModelSnapshot(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            manifestSHA256: manifestSHA256
        )
    }
}

/// Stable identity of the exact directory that was displayed for approval.
///
/// This deliberately is not Codable. A device and inode pair is meaningful
/// only while the source is still present on this machine, never as persisted
/// provenance.
public struct NativeGemmaSourceIdentity: Equatable, Hashable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64

    public init(deviceID: UInt64, inode: UInt64) {
        self.deviceID = deviceID
        self.inode = inode
    }
}

/// The allowlist for native Gemma imports.
///
/// Production contains only the reviewed Gemma 4 E2B checkpoint. Adding a
/// checkpoint is a deliberate release and legal decision, not runtime discovery.
public struct ApprovedNativeGemmaModelCatalog: Sendable {
    private let pins: Set<ApprovedNativeGemmaModelPin>

    package init(pins: Set<ApprovedNativeGemmaModelPin>) {
        self.pins = pins
    }

    public func contains(_ pin: ApprovedNativeGemmaModelPin) -> Bool {
        pins.contains(pin)
    }

    public static let productionPin: ApprovedNativeGemmaModelPin? = try? ApprovedNativeGemmaModelPin(
        modelIdentifier: "mlx-community/gemma-4-e2b-it-4bit",
        checkpointRevision: "238767527555cb75a05732a84dff5d6ba0dd6809",
        adapterRevision: "37688d2cf7d3906e08c74479c9d9949ce6b81136",
        licenseIdentifier: "gemma",
        manifestSHA256: "dab4d380ff03b1e6ac34fa47a0db672e540ee399b9d04dc765ba832a6f59cca5"
    )

    public static let production = Self(pins: Set([productionPin].compactMap { $0 }))
}

/// A store that can copy an already-approved local source into Steno's
/// immutable model store. It has no authority to choose a model or source.
public protocol NativeGemmaModelImporting: Sendable {
    func importApprovedNativeGemmaModel(
        pin: ApprovedNativeGemmaModelPin,
        sourceRoot: URL,
        sourceIdentity: NativeGemmaSourceIdentity
    ) async throws -> NativeGemmaModelSnapshot
}

public enum ApprovedNativeGemmaModelPinError: Error, Equatable, Sendable {
    case invalidPin
}
