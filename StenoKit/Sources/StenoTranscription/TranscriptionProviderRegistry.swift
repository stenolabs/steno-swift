import FluidAudio
import Foundation
import StenoDomain

public typealias TranscriptionProviderFactory = @Sendable (MediaAsset.Kind) throws
    -> any TranscriptionProvider

public enum TranscriptionRegistryError: Error, Equatable, Sendable {
    case unknownProvider(TranscriptionProviderID)
}

extension TranscriptionRegistryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let id):
            "The transcription provider \(id.rawValue) is not registered."
        }
    }
}

public struct TranscriptionProviderRegistry: Sendable {
    private let factories: [TranscriptionProviderID: TranscriptionProviderFactory]
    public let registeredProviderIDs: Set<TranscriptionProviderID>

    public init(factories: [TranscriptionProviderID: TranscriptionProviderFactory]) {
        self.factories = factories
        registeredProviderIDs = Set(factories.keys)
    }

    public func resolve(
        _ id: TranscriptionProviderID,
        for assetKind: MediaAsset.Kind
    ) throws -> any TranscriptionProvider {
        guard let factory = factories[id] else {
            throw TranscriptionRegistryError.unknownProvider(id)
        }
        return try factory(assetKind)
    }

    public static let appleOnly = Self(factories: [
        .apple: { assetKind in
            let channel: TranscriptionChannel = assetKind == .micTrack
                ? .microphone
                : .system
            return SpeechAnalyzerProvider(channel: channel)
        },
    ])

    /// `modelDirectory` ist die Basis-Cacheablage, dasselbe Verzeichnis, das
    /// `ModelInstallationCoordinator.standard(modelCacheDirectory:)` erhaelt.
    /// `nil` loest wie dort auf FluidAudios Standardablage auf - der Installer
    /// laedt sonst an eine Stelle, an der dieser Provider nie nachsieht.
    public static func standard(
        modelDirectory: URL? = nil,
        experimentalFeatures: TranscriptionExperimentalFeatures = .production
    ) -> Self {
        let baseDirectory = modelDirectory
            ?? MLModelConfigurationUtils.defaultModelsDirectory()
        return Self(factories: [
            .apple: { assetKind in
                SpeechAnalyzerProvider(channel: Self.channel(for: assetKind))
            },
            .parakeetTDTv3: { assetKind in
                ParakeetTranscriptionProvider(
                    channel: Self.channel(for: assetKind),
                    modelDirectory: baseDirectory.appendingPathComponent(
                        ParakeetModelInstaller.directoryName,
                        isDirectory: true
                    ),
                    experimentalFeatures: experimentalFeatures
                )
            },
        ])
    }

    private static func channel(for assetKind: MediaAsset.Kind) -> TranscriptionChannel {
        assetKind == .micTrack ? .microphone : .system
    }
}
