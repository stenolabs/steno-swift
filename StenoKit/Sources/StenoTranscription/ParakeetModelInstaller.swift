import FluidAudio
import Foundation
import StenoDomain

public actor ParakeetModelInstaller: ModelInstalling {
    public typealias Download = @Sendable (
        URL,
        @Sendable @escaping (Double) -> Void
    ) async throws -> Void

    public static let directoryName = "parakeet-tdt-0.6b-v3"
    private static let title = "FluidAudio Parakeet TDT"
    private static let downloadShare = 0.98

    private let modelCacheDirectory: URL
    private let manifest: ModelChecksumManifest
    private let download: Download
    private var activeInstall: Task<Void, Error>?

    public init(
        modelCacheDirectory: URL? = nil,
        manifest: ModelChecksumManifest,
        download: @escaping Download = ParakeetModelInstaller.defaultDownload
    ) {
        self.modelCacheDirectory = modelCacheDirectory
            ?? MLModelConfigurationUtils.defaultModelsDirectory()
        self.manifest = manifest
        self.download = download
    }

    public nonisolated var bundleDescription: ModelBundleDescription {
        ModelBundleDescription(
            id: .parakeetTDTv3,
            title: Self.title,
            source: .huggingFace,
            approximateBytes: 483_307_520
        )
    }

    public static func bundledManifest() throws -> ModelChecksumManifest {
        guard let url = Bundle.module.url(
            forResource: "parakeet-model-checksums",
            withExtension: "json"
        ) else {
            throw ModelManifestError.missingFile("parakeet-model-checksums.json")
        }
        return try ModelChecksumManifest.load(from: url)
    }

    public static let defaultDownload: Download = { directory, progress in
        try await AsrModels.download(
            to: directory,
            version: .v3,
            encoderPrecision: .int8,
            progressHandler: { update in progress(update.fractionCompleted) }
        )
    }

    public func readiness(for locales: [Locale]) -> ModelReadiness {
        do {
            try manifest.verify(directory: modelDirectory)
            return ModelReadiness(installed: Set(locales), missing: [:])
        } catch {
            return ModelReadiness(
                installed: [],
                missing: Dictionary(
                    uniqueKeysWithValues: locales.map { ($0, [Self.title]) }
                )
            )
        }
    }

    public func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        if let activeInstall {
            try await activeInstall.value
            return
        }

        let modelDirectory = self.modelDirectory
        let manifest = self.manifest
        let download = self.download
        let task = Task<Void, Error> {
            var completionAttempt = 1
            progress(ModelInstallProgress(fraction: 0, title: Self.title, attempt: 1))
            try await download(modelDirectory) { fraction in
                progress(ModelInstallProgress(
                    fraction: max(0, min(1, fraction * Self.downloadShare)),
                    title: Self.title,
                    attempt: 1
                ))
            }
            try Task.checkCancellation()
            do {
                try manifest.verify(directory: modelDirectory)
            } catch let integrity as ModelIntegrityError {
                let broken = manifest.mismatchingFiles(directory: modelDirectory)
                guard !broken.isEmpty else { throw integrity }
                for relativePath in broken {
                    try? FileManager.default.removeItem(
                        at: modelDirectory.appendingPathComponent(relativePath)
                    )
                }
                progress(ModelInstallProgress(fraction: 0, title: Self.title, attempt: 2))
                completionAttempt = 2
                try await download(modelDirectory) { fraction in
                    progress(ModelInstallProgress(
                        fraction: max(0, min(1, fraction * Self.downloadShare)),
                        title: Self.title,
                        attempt: 2
                    ))
                }
                try Task.checkCancellation()
                try manifest.verify(directory: modelDirectory)
            }
            progress(ModelInstallProgress(
                fraction: 1,
                title: Self.title,
                attempt: completionAttempt
            ))
        }
        activeInstall = task
        defer { activeInstall = nil }
        try await task.value
    }

    public func cancelInstall() {
        activeInstall?.cancel()
    }

    public var installedModelDirectory: URL { modelDirectory }

    private var modelDirectory: URL {
        modelCacheDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }
}
