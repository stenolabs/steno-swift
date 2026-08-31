import Foundation
@_spi(StenoGemmaRuntime) import StenoGemmaIPC
@_spi(StenoGemmaRuntime) import StenoGemmaModelStore

@_spi(StenoGemmaRuntime)
public enum NativeGemmaActivationProfileError: Error, Equatable, Sendable {
    case adapterRevisionMismatch(expected: String, actual: String)
    case invalidMaximumPromptTokens
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

    public init(
        pin: GemmaModelSnapshotPin,
        activationLimits: VerifiedGemmaModelActivationLimits,
        maximumPromptTokens: Int
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

    /// Deliberately empty until checkpoint identity, license, memory use, and activation timing
    /// have been reviewed and accepted.
    public static let production = NativeGemmaActivationCatalog(profiles: [])
}
