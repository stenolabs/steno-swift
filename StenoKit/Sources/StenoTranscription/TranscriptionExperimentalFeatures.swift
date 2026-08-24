public struct TranscriptionExperimentalFeatures: Sendable, Equatable {
    public var parakeetLiveEnabled: Bool

    public init(parakeetLiveEnabled: Bool = false) {
        self.parakeetLiveEnabled = parakeetLiveEnabled
    }

    public static let production = Self()
}
