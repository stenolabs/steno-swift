import CryptoKit
import Foundation
import StenoDomain
import Testing
@testable import StenoTranscription

@Suite("Parakeet model installer")
struct ParakeetModelInstallerTests {
    @Test("Selection does not download and explicit installation verifies bytes")
    func explicitInstallOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakeetInstallerTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("model".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = ModelChecksumManifest(entries: ["model.bin": digest])
        let calls = Counter()
        let installer = ParakeetModelInstaller(
            modelCacheDirectory: root,
            manifest: manifest,
            download: { directory, progress in
                await calls.increment()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent("model.bin"))
                progress(1)
            }
        )

        let before = await installer.readiness(for: [Locale(identifier: "de-DE")])
        #expect(!before.isReady(for: Locale(identifier: "de-DE")))
        #expect(await calls.value == 0)

        try await installer.install(for: Locale(identifier: "de-DE")) { _ in }

        #expect(await calls.value == 1)
        let after = await installer.readiness(for: [Locale(identifier: "de-DE")])
        #expect(after.isReady(for: Locale(identifier: "de-DE")))
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Suite("Parakeet checksum manifest")
struct ParakeetChecksumManifestTests {
    /// Das Manifest darf nur Dateien fordern, die der Download wirklich
    /// liefert. Es entstand einmal aus einem gewachsenen Modellordner und
    /// verlangte danach `config.json` und `parakeet_vocab.json` - beides
    /// Altlasten, die FluidAudio fuer v3 nicht laedt. Folge: auf jedem
    /// frischen Geraet brach die Installation mit "model file is missing
    /// after download" ab, waehrend sie auf dem Rechner, der das Manifest
    /// erzeugt hatte, fehlerfrei durchlief.
    @Test("the manifest requires only what the download provides")
    func manifestMatchesTheDownloadedSet() throws {
        let manifest = try ParakeetModelInstaller.bundledManifest()
        let paths = Set(manifest.entries.keys)

        // FluidAudios `requiredModelsV3` liefert genau diese vier Bundles,
        // dazu zieht `ensureVocabularyDownloaded` das v3-Vokabular nach.
        let expectedBundles = [
            "Preprocessor.mlmodelc",
            "Encoder.mlmodelc",
            "Decoder.mlmodelc",
            "JointDecisionv3.mlmodelc",
        ]
        for path in paths where !path.hasSuffix("vocab.json") {
            #expect(
                expectedBundles.contains { path.hasPrefix($0 + "/") },
                "Unerwarteter Manifest-Eintrag: \(path)"
            )
        }
        #expect(paths.contains("parakeet_v3_vocab.json"))
        #expect(!paths.contains("config.json"))
        #expect(!paths.contains("parakeet_vocab.json"))
        for bundle in expectedBundles {
            #expect(
                paths.contains { $0.hasPrefix(bundle + "/") },
                "Manifest kennt \(bundle) nicht"
            )
        }
    }
}
