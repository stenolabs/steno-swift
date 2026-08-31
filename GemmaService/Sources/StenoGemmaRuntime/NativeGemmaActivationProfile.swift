import Foundation
@_spi(StenoGemmaRuntime) import StenoGemmaIPC
@_spi(StenoGemmaRuntime) import StenoGemmaModelStore

@_spi(StenoGemmaRuntime)
public enum NativeGemmaActivationProfileError: Error, Equatable, Sendable {
    case adapterRevisionMismatch(expected: String, actual: String)
    case invalidMaximumPromptTokens
}

/// Checkpoint-bound layout accepted for the verified model bytes.
///
/// The default accepts only a native text checkpoint. The E2B projection is reserved for the exact
/// reviewed `mlx-community/gemma-4-e2b-it-4bit` pin whose media tensors are verified but never
/// materialized or exposed to the text-only Steno runtime.
@_spi(StenoGemmaRuntime)
public enum NativeGemmaActivationModelLayout: Sendable, Equatable {
    case strictTextOnly
    case gemma4E2BConditionalTextProjection
}

/// Steno-controlled resource and prompt bounds for exactly one immutable checkpoint.
///
/// A profile grants no installation consent and contains no filesystem path. Production entries
/// must be reviewed together with the app-side import catalog for the same exact pin.
@_spi(StenoGemmaRuntime)
public struct NativeGemmaActivationProfile: Sendable, Equatable {
    public let pin: GemmaModelSnapshotPin
    public let activationLimits: VerifiedGemmaModelActivationLimits
    public let maximumPromptTokens: Int
    public let modelLayout: NativeGemmaActivationModelLayout

    public init(
        pin: GemmaModelSnapshotPin,
        activationLimits: VerifiedGemmaModelActivationLimits,
        maximumPromptTokens: Int,
        modelLayout: NativeGemmaActivationModelLayout = .strictTextOnly
    ) throws {
        guard pin.adapterRevision == GemmaIPCBuildInfo.adapterRevision else {
            throw NativeGemmaActivationProfileError.adapterRevisionMismatch(
                expected: GemmaIPCBuildInfo.adapterRevision,
                actual: pin.adapterRevision
            )
        }
        guard maximumPromptTokens > 0 else {
            throw NativeGemmaActivationProfileError.invalidMaximumPromptTokens
        }
        self.pin = pin
        self.activationLimits = activationLimits
        self.maximumPromptTokens = maximumPromptTokens
        self.modelLayout = modelLayout
    }
}

/// Exact helper-side allowlist for runtime activation.
///
/// Zero matches means unavailable. Multiple exact matches also mean unavailable so a duplicate
/// entry can never select an arbitrary resource policy.
@_spi(StenoGemmaRuntime)
public struct NativeGemmaActivationCatalog: Sendable {
    private let profiles: [NativeGemmaActivationProfile]

    public init(profiles: [NativeGemmaActivationProfile]) {
        self.profiles = profiles
    }

    public func profile(for pin: GemmaModelSnapshotPin) -> NativeGemmaActivationProfile? {
        var match: NativeGemmaActivationProfile?
        for profile in profiles where profile.pin == pin {
            guard match == nil else { return nil }
            match = profile
        }
        return match
    }

    /// The sole reviewed production activation profile.
    ///
    /// Construction is deliberately failable so a drifted adapter revision or invalid static
    /// resource bound leaves the production catalog empty instead of weakening activation.
    public static let production: NativeGemmaActivationCatalog = {
        guard let pin = try? GemmaModelSnapshotPin(
            modelIdentifier: "mlx-community/gemma-4-e2b-it-4bit",
            checkpointRevision: "238767527555cb75a05732a84dff5d6ba0dd6809",
            adapterRevision: "37688d2cf7d3906e08c74479c9d9949ce6b81136",
            licenseIdentifier: "gemma",
            manifestSHA256: "dab4d380ff03b1e6ac34fa47a0db672e540ee399b9d04dc765ba832a6f59cca5"
        ),
        let limits = try? VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: 32_169_626,
            // Exact non-weight payload total, including the pinned 1,403-byte manifest.
            maximumTotalSmallFileByteCount: 32_416_031,
            maximumSafetensorsFileCount: 1,
            maximumSafetensorsFileByteCount: 3_550_670_554,
            maximumTotalSafetensorsByteCount: 3_550_670_554
        ),
        let profile = try? NativeGemmaActivationProfile(
            pin: pin,
            activationLimits: limits,
            maximumPromptTokens: 4_096,
            modelLayout: .gemma4E2BConditionalTextProjection
        )
        else {
            return NativeGemmaActivationCatalog(profiles: [])
        }
        return NativeGemmaActivationCatalog(profiles: [profile])
    }()
}
