# Onboarding und Modellzustimmung - Umsetzungsplan

> **Für arbeitende Agenten:** ERFORDERLICHE UNTER-SKILL: Nutze `superpowers:subagent-driven-development` (empfohlen) oder `superpowers:executing-plans`, um diesen Plan Aufgabe für Aufgabe umzusetzen. Die Schritte nutzen Kästchen (`- [ ]`) zur Nachverfolgung.

**Ziel:** Steno kann seine Modelle nach ausdrücklicher, nachvollziehbarer Zustimmung selbst installieren, und ein Erstlauf-Wizard führt einmalig durch Rechtshinweis, Betreiberprofil, Sprache, Modelle und Berechtigungen.

**Architektur:** Der Modell-Download verlässt die Provider und zieht in zwei Installer, die ein Koordinator serialisiert und je Sprache nach Arbeitsfähigkeit befragt. Die Zustimmung lebt in der App-Schicht und wird in den Koordinator hineingereicht, StenoKit liest nie `UserDefaults`. Der Wizard ist reine SwiftUI-App-Schicht und ruft dieselben Bauteile wie der laufende Betrieb.

**Technik:** Swift 6.3, strikte Nebenläufigkeit, Swift Testing (`@Test`, `#expect`), SwiftUI, SwiftPM-Paket `StenoKit`, XcodeGen für das App-Ziel.

**Grundlage:** `docs/superpowers/specs/2026-08-07-onboarding-und-modellzustimmung-design.md`

## Globale Randbedingungen

- Mindestziel macOS 26, Swift-Sprachmodus 6, `SWIFT_STRICT_CONCURRENCY: complete`.
- Alle neuen Typen sind `Sendable`; Zustand hinter Aktoren.
- StenoKit darf `UserDefaults` nicht lesen und die App-Schicht nicht kennen.
- Keine neuen Paketabhängigkeiten. FluidAudio bleibt exakt auf 0.15.2.
- Kein Gedankenstrich in Text, Kommentaren und Bedienoberfläche; einfacher Bindestrich.
- Bedienoberfläche und Nutzertexte sind englisch, wie der Bestand (`SettingsView.swift`). Kommentare im Code sind deutsch, wie der Bestand.
- Transkript-Revisionen werden nicht verändert. Das Label "Ich" wird nur in der Anzeige aufgelöst.
- Tests laufen mit `cd StenoKit && swift test`. Die App wird mit `scripts/build-app.sh` gebaut.
- Der Arbeitsbaum enthält fremde uncommittete Änderungen (`App/Info.plist`, `StenoKit/Package.swift`, `UEBERGABE-sprecher-erkenntnisse.md`). Sie werden nie mit eingecheckt. Jeder Commit listet seine Dateien einzeln, niemals `git add -A`.

## Dateiplan

**Phase A, der Blocker.** Nach Aufgabe 6 funktioniert die Diarisierung auf einem frischen Rechner.

| Datei | Verantwortung |
|---|---|
| `StenoKit/Sources/StenoDomain/ModelInstalling.swift` (neu) | Vertrag, Quellenbeschreibung, Zustand je Sprache |
| `StenoKit/Sources/StenoDiarization/DiarizationModelInstaller.swift` (neu) | Lädt Diarisierungsmodelle, prüft Prüfsummen |
| `StenoKit/Sources/StenoDiarization/ModelChecksumManifest.swift` (neu) | Liest und prüft das eingecheckte Manifest |
| `StenoKit/Resources/model-checksums.json` (neu) | Das Manifest selbst |
| `StenoKit/Sources/StenoDiarization/FluidSortformerProvider.swift` (ändern) | Verliert `allowModelDownload` und den Download |
| `StenoKit/Sources/StenoDiarization/ModelAccess.swift` (ändern) | Verliert den Zustimmungsparameter |
| `StenoKit/Sources/StenoTranscription/SpeechAssetInstaller.swift` (neu) | Kapselt `AssetInventory` als Installer |
| `StenoKit/Sources/StenoTranscription/SpeechAnalyzerProvider.swift` (ändern) | Ruft `ensureAssets` nicht mehr selbst |
| `StenoKit/Sources/StenoPipeline/ModelInstallationCoordinator.swift` (neu) | Fasst zusammen, serialisiert, Arbeitsfähigkeit je Sprache |
| `StenoKit/Sources/StenoPipeline/PipelineStartup.swift` (ändern) | Reicht den Koordinator durch |
| `App/Sources/ModelConsent.swift` (neu) | Zustimmung mit Zeitpunkt und Quellen in `UserDefaults` |
| `App/Sources/ModelStatusView.swift` (neu) | Zustimmung erteilen, Fortschritt, Widerruf |

**Phase B, Wizard und Profil.**

| Datei | Verantwortung |
|---|---|
| `App/Sources/OperatorProfile.swift` (neu) | Name und Organisation in `UserDefaults` |
| `StenoKit/Sources/StenoIntelligence/TextModelProvider.swift` (ändern) | `RenderContext` bekommt `author` |
| `StenoKit/Sources/StenoDomain/Job.swift` (ändern) | Job pinnt den Verfasser beim Einreihen |
| `StenoKit/Sources/StenoPipeline/TemplateRenderRequest.swift` (ändern) | Nimmt den Verfasser entgegen |
| `StenoKit/Sources/StenoPipeline/MeetingMarkdown.swift` (ändern) | Verfasserzeile im Kopf |
| `App/Sources/OnboardingModel.swift` (neu) | Zustand und Seitenfolge |
| `App/Sources/OnboardingView.swift` (neu) | Die fünf Seiten |
| `App/Sources/StenoApp.swift` (ändern) | Fensterszene und Menüeintrag |
| `App/Sources/SettingsView.swift` (ändern) | Profilfelder und Modellzustand |
| `App/Sources/SpeakerDisplay` in `AppModel+Review.swift` (ändern) | Trennt Sprecherlabel von Spurnamen |

---

## Phase A: der Blocker

### Aufgabe 1: Vertrag und Zustandsmodell

**Dateien:**
- Anlegen: `StenoKit/Sources/StenoDomain/ModelInstalling.swift`
- Test: `StenoKit/Tests/StenoDomainTests/ModelInstallingTests.swift`

**Schnittstellen:**
- Liefert: `ModelSource`, `ModelBundleDescription`, `ModelReadiness`, `ModelInstalling`, `ModelInstallProgress`. Aufgaben 3, 5 und 6 bauen darauf.

**Warum StenoDomain und nicht StenoPipeline:** Die Installer entstehen in StenoTranscription und StenoDiarization, und beide dürfen StenoPipeline nicht kennen; die Abhängigkeit läuft andersherum. StenoDomain ist das einzige Ziel, das alle drei sehen.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

```swift
import Testing
import Foundation
@testable import StenoDomain

@Suite("Model readiness")
struct ModelInstallingTests {
    @Test("readiness is answered per locale, not globally")
    func readinessIsPerLocale() {
        let readiness = ModelReadiness(
            installed: [Locale(identifier: "de-DE")],
            missing: [Locale(identifier: "en-US"): ["Parakeet_de"]]
        )
        #expect(readiness.isReady(for: Locale(identifier: "de-DE")))
        #expect(!readiness.isReady(for: Locale(identifier: "en-US")))
    }

    @Test("a bundle description names its source and stays free of technical jargon")
    func descriptionNamesSource() {
        let description = ModelBundleDescription(
            title: "Speaker separation",
            source: .huggingFace,
            approximateBytes: 92_000_000
        )
        #expect(description.source.displayHost == "huggingface.co")
    }
}
```

- [ ] **Schritt 2: Test laufen lassen und Fehlschlag prüfen**

Ausführen: `cd StenoKit && swift test --filter ModelInstallingTests`
Erwartet: FEHLER, "cannot find 'ModelReadiness' in scope".

- [ ] **Schritt 3: Die kleinste Implementierung schreiben**

```swift
import Foundation

/// Woher ein Modell kommt. Der Unterschied ist nicht kosmetisch: Apple
/// liefert ueber die Systemschnittstelle, FluidAudio ueber einen fremden
/// Host, den ein Behoerdennetz sperren oder protokollieren kann.
public enum ModelSource: String, Sendable, Equatable, CaseIterable {
    case appleSystemAssets
    case huggingFace

    public var displayHost: String {
        switch self {
        case .appleSystemAssets: "Apple"
        case .huggingFace: "huggingface.co"
        }
    }
}

public struct ModelBundleDescription: Sendable, Equatable {
    public let title: String
    public let source: ModelSource
    public let approximateBytes: Int

    public init(title: String, source: ModelSource, approximateBytes: Int) {
        self.title = title
        self.source = source
        self.approximateBytes = approximateBytes
    }
}

/// Arbeitsfaehigkeit ist keine einzelne Ja-Nein-Antwort: ASR-Assets sind an
/// die Sprache gebunden, die Antwort kippt also beim Sprachwechsel.
public struct ModelReadiness: Sendable, Equatable {
    public let installed: Set<Locale>
    public let missing: [Locale: [String]]

    public init(installed: Set<Locale>, missing: [Locale: [String]]) {
        self.installed = installed
        self.missing = missing
    }

    public func isReady(for locale: Locale) -> Bool {
        installed.contains(locale)
    }

    public func missingNames(for locale: Locale) -> [String] {
        missing[locale] ?? []
    }
}

public struct ModelInstallProgress: Sendable, Equatable {
    public let fraction: Double
    public let title: String

    public init(fraction: Double, title: String) {
        self.fraction = fraction
        self.title = title
    }
}

public protocol ModelInstalling: Sendable {
    /// Bewusst nicht `description`: dieser Name kollidiert mit
    /// `CustomStringConvertible` und liefert bei jedem versehentlichen
    /// String-Interpolieren stillschweigend etwas anderes.
    var bundleDescription: ModelBundleDescription { get }
    func readiness(for locales: [Locale]) async -> ModelReadiness
    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws
}
```

- [ ] **Schritt 4: Test laufen lassen und Erfolg prüfen**

Ausführen: `cd StenoKit && swift test --filter ModelInstallingTests`
Erwartet: BESTANDEN, zwei Tests.

- [ ] **Schritt 5: Committen**

```bash
git add StenoKit/Sources/StenoDomain/ModelInstalling.swift StenoKit/Tests/StenoDomainTests/ModelInstallingTests.swift
git commit -m "feat(models): Vertrag fuer Modellinstallation mit Quelle und Sprachbezug"
```

---

### Aufgabe 2: Prüfsummen-Manifest

**Dateien:**
- Anlegen: `StenoKit/Sources/StenoDiarization/ModelChecksumManifest.swift`
- Anlegen: `StenoKit/Sources/StenoDiarization/Resources/model-checksums.json`
- Ändern: `StenoKit/Package.swift`, Ziel `StenoDiarization` bekommt `resources: [.process("Resources")]`
- Test: `StenoKit/Tests/StenoDiarizationTests/ModelChecksumManifestTests.swift`

**Schnittstellen:**
- Nutzt: nichts aus Aufgabe 1.
- Liefert: `ModelChecksumManifest.verify(directory:)` und `ModelChecksumManifest.bundled(name:)`, wirft `DiarizationError.modelInstallationFailed`. Aufgabe 3 ruft `verify(directory:)` auf und bekommt das Manifest über den Konstruktor hineingereicht.

**Hinweis zur Ehrlichkeit:** Das Manifest sichert Reproduzierbarkeit, nicht Echtheit. Es friert die Bytes ein, die bei seiner Erzeugung vorlagen. Dieser Satz gehört als Kommentar in die Datei.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

```swift
import Testing
import Foundation
import CryptoKit
@testable import StenoDiarization

@Suite("Model checksum manifest")
struct ModelChecksumManifestTests {
    private func makeFile(_ directory: URL, _ name: String, _ content: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try content.data(using: .utf8)!.write(to: url)
        let digest = SHA256.hash(data: content.data(using: .utf8)!)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @Test("matching bytes pass")
    func matchingBytesPass() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = try makeFile(directory, "weights.bin", "hello")
        let manifest = ModelChecksumManifest(entries: ["weights.bin": hash])
        try manifest.verify(directory: directory)
    }

    @Test("a single changed byte throws and names the file")
    func changedByteThrows() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try makeFile(directory, "weights.bin", "hello")
        let manifest = ModelChecksumManifest(entries: ["weights.bin": String(repeating: "0", count: 64)])
        #expect(throws: DiarizationError.self) {
            try manifest.verify(directory: directory)
        }
    }

    @Test("a missing file throws")
    func missingFileThrows() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = ModelChecksumManifest(entries: ["absent.bin": String(repeating: "0", count: 64)])
        #expect(throws: DiarizationError.self) {
            try manifest.verify(directory: directory)
        }
    }
}
```

- [ ] **Schritt 2: Test laufen lassen und Fehlschlag prüfen**

Ausführen: `cd StenoKit && swift test --filter ModelChecksumManifestTests`
Erwartet: FEHLER, "cannot find 'ModelChecksumManifest' in scope".

- [ ] **Schritt 3: Die kleinste Implementierung schreiben**

```swift
import CryptoKit
import Foundation

/// Prueft heruntergeladene Modelldateien gegen eingecheckte Pruefsummen.
///
/// FluidAudio prueft nichts: der Download laeuft gegen den beweglichen
/// Branch (`resolve/main`), und die eingebaute Verifikation prueft nur, ob
/// die Datei existiert. Ohne diese Stelle koennte ein spaeterer Lauf andere
/// Bytes holen als die, denen zugestimmt wurde.
///
/// Grenze: Das sichert Reproduzierbarkeit, nicht Echtheit. Es friert die
/// Bytes ein, die bei der Erzeugung des Manifests vorlagen.
public struct ModelChecksumManifest: Sendable, Equatable, Codable {
    /// Relativer Pfad zur Kleinbuchstaben-SHA-256 in Hex.
    public let entries: [String: String]

    public init(entries: [String: String]) {
        self.entries = entries
    }

    public func verify(directory: URL) throws {
        for (relativePath, expected) in entries.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(relativePath)
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw DiarizationError.modelInstallationFailed(
                    "Model file is missing after download: \(relativePath)"
                )
            }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw DiarizationError.modelInstallationFailed(
                    "Checksum mismatch for \(relativePath). Expected \(expected), got \(actual)."
                )
            }
        }
    }

    public static func bundled(name: String = "model-checksums") throws -> ModelChecksumManifest {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw DiarizationError.modelInstallationFailed("Checksum manifest is missing from the bundle")
        }
        return try JSONDecoder().decode(ModelChecksumManifest.self, from: Data(contentsOf: url))
    }
}
```

Und `StenoKit/Sources/StenoDiarization/Resources/model-checksums.json` zunächst als leeres Manifest, das Aufgabe 3 füllt:

```json
{ "entries": {} }
```

In `StenoKit/Package.swift` beim Ziel `StenoDiarization` ergänzen:

```swift
            resources: [.process("Resources")],
```

- [ ] **Schritt 4: Test laufen lassen und Erfolg prüfen**

Ausführen: `cd StenoKit && swift test --filter ModelChecksumManifestTests`
Erwartet: BESTANDEN, drei Tests.

- [ ] **Schritt 5: Committen**

```bash
git add StenoKit/Sources/StenoDiarization/ModelChecksumManifest.swift StenoKit/Sources/StenoDiarization/Resources/model-checksums.json StenoKit/Tests/StenoDiarizationTests/ModelChecksumManifestTests.swift StenoKit/Package.swift
git commit -m "feat(models): Pruefsummen-Manifest fuer heruntergeladene Modelle"
```

> **Zu `Package.swift`:** In diesem Arbeitsbaum ist die Datei unverändert; die fremde `.iOS(.v26)`-Zeile liegt nur uncommittet im Eltern-Arbeitsbaum und ist hier nicht vorhanden (nachgeprüft). Ein einfaches `git add StenoKit/Package.swift` genügt also. Trotzdem vor dem Commit einmal `git diff --cached StenoKit/Package.swift` ansehen und bestätigen, dass nur die `resources:`-Zeile hinzugekommen ist.

---

### Aufgabe 3: Der Diarisierungs-Installer, und der Provider verliert den Download

**Dateien:**
- Anlegen: `StenoKit/Sources/StenoDiarization/DiarizationModelInstaller.swift`
- Ändern: `StenoKit/Sources/StenoDiarization/FluidSortformerProvider.swift:7,14,21,104,125`
- Ändern: `StenoKit/Sources/StenoDiarization/ModelAccess.swift`
- Ändern: `StenoKit/Sources/StenoDiarization/DiarizationModels.swift:70-71` (Fehlertext ohne Entwicklervokabular)
- Ändern: `StenoKit/Sources/steno-diarize-bench/main.swift:4,17,22,28-31`
- Ändern: `StenoKit/Tests/StenoDiarizationTests/DiarizationInfrastructureTests.swift:49,59,68,79`

**Achtung, sonst bricht der Bau:** `steno-diarize-bench` ruft `FluidSortformerProvider(allowModelDownload: allowDownload, computeUnits:)` und wertet ein Flag `--allow-download` aus. Beides verschwindet mit dieser Aufgabe. Das Kommando verliert das Flag, die Nutzungszeile in Zeile 4 und 17 verliert `[--allow-download]`, und der Aufruf wird zu `FluidSortformerProvider(computeUnits: computeUnits)`. Ohne diese Änderung schlägt schon `swift build` fehl, nicht erst ein Test.
- Test: `StenoKit/Tests/StenoDiarizationTests/DiarizationModelInstallerTests.swift`

**Schnittstellen:**
- Nutzt: `ModelChecksumManifest.verify(directory:)` aus Aufgabe 2, `ModelInstalling` aus Aufgabe 1.
- Liefert: `DiarizationModelInstaller(modelCacheDirectory:manifest:download:)`, wobei `download` eine einsetzbare Attrappe ist. `FluidSortformerProvider.init` ohne `allowModelDownload`.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

```swift
import Testing
import Foundation
@testable import StenoDiarization

@Suite("Diarization model installer")
struct DiarizationModelInstallerTests {
    private func emptyDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the provider builds without a download switch and reports what is missing")
    func providerReportsMissing() throws {
        let directory = try emptyDirectory()
        // Kein Audio noetig: geprueft wird die Modellabfrage, nicht die
        // Inferenz. StenoDiarizationTests fuehrt keine Fixtures.
        let missing = missingModelURLs(
            required: [directory.appendingPathComponent("sortformer.mlmodelc")],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(missing.count == 1)
    }

    @Test("install runs exactly one download and then verifies checksums")
    func installDownloadsOnce() async throws {
        let directory = try emptyDirectory()
        let counter = DownloadCounter()
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [:]),
            download: { _ in await counter.increment() }
        )
        try await installer.install(for: Locale(identifier: "de-DE")) { _ in }
        #expect(await counter.value == 1)
    }

    @Test("a failing download does not leave the installer claiming readiness")
    func failedDownloadKeepsMissing() async throws {
        let directory = try emptyDirectory()
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [:]),
            download: { _ in throw DiarizationError.modelInstallationFailed("no network") }
        )
        await #expect(throws: DiarizationError.self) {
            try await installer.install(for: Locale(identifier: "de-DE")) { _ in }
        }
        let readiness = await installer.readiness(for: [Locale(identifier: "de-DE")])
        #expect(!readiness.isReady(for: Locale(identifier: "de-DE")))
    }
}

actor DownloadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
```

- [ ] **Schritt 2: Test laufen lassen und Fehlschlag prüfen**

Ausführen: `cd StenoKit && swift test --filter DiarizationModelInstallerTests`
Erwartet: FEHLER, "cannot find 'DiarizationModelInstaller' in scope" und "extra argument 'modelCacheDirectory'" beim Provider, weil `allowModelDownload` noch als erster Parameter steht.

- [ ] **Schritt 3: Den Installer anlegen und den Provider entkernen**

Neu, `DiarizationModelInstaller.swift`:

```swift
import FluidAudio
import Foundation
import StenoDomain

/// Der einzige Ort, an dem Diarisierungsmodelle geladen werden.
///
/// Frueher lud der Provider mitten in `diarize()` nach. Das konnte keinen
/// Fortschritt melden, und ein Fehlschlag verbrannte den laufenden Job. Der
/// Provider sagte es selbst: "Installation is an explicit caller-owned action".
public actor DiarizationModelInstaller {
    public typealias Download = @Sendable (URL) async throws -> Void

    private let modelCacheDirectory: URL?
    private let manifest: ModelChecksumManifest
    private let download: Download
    private var activeInstall: Task<Void, Error>?

    public init(
        modelCacheDirectory: URL? = nil,
        manifest: ModelChecksumManifest,
        download: @escaping Download = DiarizationModelInstaller.defaultDownload
    ) {
        self.modelCacheDirectory = modelCacheDirectory
        self.manifest = manifest
        self.download = download
    }

    public static let defaultDownload: Download = { baseDirectory in
        do {
            try await DownloadUtils.downloadRepo(.sortformer, to: baseDirectory)
            try await DownloadUtils.downloadRepo(.diarizer, to: baseDirectory)
        } catch {
            throw DiarizationError.modelInstallationFailed(error.localizedDescription)
        }
    }

    private var baseDirectory: URL {
        modelCacheDirectory ?? MLModelConfigurationUtils.defaultModelsDirectory()
    }

    public nonisolated var bundleDescription: ModelBundleDescription {
        ModelBundleDescription(
            title: "Speaker separation",
            source: .huggingFace,
            approximateBytes: 92_000_000
        )
    }

    /// Diarisierungsmodelle sind sprachunabhaengig: dieselbe Antwort fuer
    /// jede angefragte Sprache.
    public func readiness(for locales: [Locale]) -> ModelReadiness {
        let missing = missingBundleNames()
        if missing.isEmpty {
            return ModelReadiness(installed: Set(locales), missing: [:])
        }
        return ModelReadiness(
            installed: [],
            missing: Dictionary(uniqueKeysWithValues: locales.map { ($0, missing) })
        )
    }

    public func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        // Serialisierung: Wizard und ein anlaufender Job duerfen den
        // Downloader nicht gleichzeitig treffen.
        if let activeInstall {
            try await activeInstall.value
            return
        }
        let task = Task<Void, Error> { [baseDirectory, download, manifest] in
            progress(ModelInstallProgress(fraction: 0, title: "Speaker separation"))
            try await download(baseDirectory)
            try manifest.verify(directory: baseDirectory)
            progress(ModelInstallProgress(fraction: 1, title: "Speaker separation"))
        }
        activeInstall = task
        defer { activeInstall = nil }
        try await task.value
    }

    private func missingBundleNames() -> [String] {
        let fileManager = FileManager.default
        return requiredBundleURLs(baseDirectory: baseDirectory)
            .filter { !modelBundleIsComplete($0, fileManager: fileManager) }
            .map(\.lastPathComponent)
    }
}
```

In `FluidSortformerProvider.swift`: `allowModelDownload` in Zeile 7 und 14 und 21 streichen, den gesamten `if !missing.isEmpty { ... }`-Block (Zeilen 104-127) durch den reinen Fehlerwurf ersetzen:

```swift
        let missing = requiredURLs
            .filter { !modelBundleIsComplete($0, fileManager: fileManager) }
        guard missing.isEmpty else {
            throw DiarizationError.modelsNotInstalled(
                missing: missing.map(\.lastPathComponent)
            )
        }
```

`ModelAccess.swift` wird zu einer reinen Abfrage ohne Zustimmungsparameter:

```swift
import Foundation

func missingModelURLs(
    required: [URL],
    fileExists: (URL) -> Bool
) -> [URL] {
    required.filter { !fileExists($0) }
}
```

`DiarizationModels.swift:70-71`, Fehlertext ohne Entwicklervokabular:

```swift
        case .modelsNotInstalled(let missing):
            return "The speaker separation models are not installed yet (missing: \(missing.joined(separator: ", "))). Install them in Steno's settings."
```

Bestehende Tests in `DiarizationInfrastructureTests.swift` anpassen: die Zeilen 49, 59, 68 und 79 prüfen `allowModelDownload`, das es nicht mehr gibt. Zeile 68 prüft auf den Text "allowModelDownload: true", der durch "Install them in Steno's settings." ersetzt wird.

- [ ] **Schritt 4: Tests laufen lassen und Erfolg prüfen**

Ausführen: `cd StenoKit && swift test --filter DiarizationModelInstallerTests`
Erwartet: BESTANDEN, drei Tests.
Danach die ganze Suite: `cd StenoKit && swift test`
Erwartet: BESTANDEN. Schlägt `DiarizationInfrastructureTests` fehl, sind die vier Zeilen oben nicht angepasst.

- [ ] **Schritt 5: Committen**

```bash
git add StenoKit/Sources/StenoDiarization/ StenoKit/Tests/StenoDiarizationTests/
git commit -m "refactor(diarization): Download verlaesst den Provider und zieht in den Installer"
```

---

### Aufgabe 4: Das Manifest mit echten Prüfsummen füllen

**Dateien:**
- Anlegen: `scripts/generate-model-checksums.sh`
- Ändern: `StenoKit/Sources/StenoDiarization/Resources/model-checksums.json`
- Ändern: `docs/superpowers/specs/2026-08-07-onboarding-und-modellzustimmung-design.md` (Auflage abhaken)

**Schnittstellen:** keine neuen Typen.

Diese Aufgabe schließt die Auflage aus der Spezifikation: ohne dokumentierten Erzeugungsweg wird der erste Prüfsummenfehler mit einem blinden Update beantwortet, und der Schutz ist weg.

- [ ] **Schritt 1: Das Erzeugungsskript schreiben**

```bash
#!/bin/bash
# Erzeugt das Pruefsummen-Manifest aus einer lokal vorhandenen, geprueften
# Modellinstallation.
#
# Grenze: Das friert die Bytes ein, die JETZT auf dieser Platte liegen. Es
# beweist nicht ihre Echtheit. Vor dem Ausfuehren pruefen, woher sie stammen.
#
# Nutzung: scripts/generate-model-checksums.sh <modellverzeichnis>
set -euo pipefail

DIR="${1:?Modellverzeichnis angeben}"
OUT="StenoKit/Sources/StenoDiarization/Resources/model-checksums.json"

cd "$DIR"
{
    echo '{'
    echo '  "entries": {'
    find . -type f ! -name '.DS_Store' | sort | while read -r f; do
        rel="${f#./}"
        hash=$(shasum -a 256 "$f" | cut -d' ' -f1)
        echo "    \"$rel\": \"$hash\","
    done | sed '$ s/,$//'
    echo '  }'
    echo '}'
} > "$OLDPWD/$OUT"

echo "Geschrieben: $OUT"
```

- [ ] **Schritt 2: Modelle einmal beziehen und das Manifest erzeugen**

> **Reihenfolge:** Dieser Schritt läuft **nach Aufgabe 6**, nicht vorher. Vor Aufgabe 6 gibt es keinen Weg mehr, Modelle zu beziehen: Aufgabe 3 nimmt den Download aus dem Provider und aus `steno-diarize-bench`, und der Installer wird erst in Aufgabe 6 an eine Bedienoberfläche angeschlossen. Aufgabe 4 wird deshalb als vorletzte Aufgabe der Phase A ausgeführt. Bis dahin bleibt das Manifest leer, was gültig ist: ein leeres Manifest prüft nichts und blockiert nichts.

Modelle über die App beziehen: `scripts/build-app.sh --run`, Einstellungen, Register "Models", "Allow and install". Danach:

```bash
chmod +x scripts/generate-model-checksums.sh
```

Erwartet: die Modelle liegen unter dem von `MLModelConfigurationUtils.defaultModelsDirectory()` gemeldeten Pfad. Den Pfad aus der Fortschrittsanzeige oder per `find ~/Library -maxdepth 6 -name "*.mlmodelc" -path "*luid*"` bestimmen und einsetzen:

```bash
scripts/generate-model-checksums.sh "$HOME/Library/Application Support/FluidAudio/Models"
```

Ist der Pfad ein anderer, den ausgegebenen verwenden. Erwartet: `model-checksums.json` enthält je Modelldatei eine Zeile.

- [ ] **Schritt 3: Gegenprobe, dass die Prüfung greift**

Ausführen:

```bash
cd StenoKit && swift test --filter ModelChecksumManifestTests
```

Erwartet: BESTANDEN. Danach von Hand ein Byte in einer Modelldatei ändern und `swift test --filter DiarizationModelInstallerTests` laufen lassen: die Installation muss werfen. Anschließend die Datei aus dem Backup zurückholen oder neu laden.

- [ ] **Schritt 3b: Wiederaufsetzen nach Abbruch prüfen**

Das ist das in der Spezifikation benannte ungemessene Risiko. Modellverzeichnis leeren, Installation über die App starten, nach wenigen Sekunden das Netz trennen, dann wieder verbinden und erneut installieren.
Erwartet: der zweite Lauf kommt durch. Scheitert er an Teilresten, ist das ein Befund für den Nutzer und wird im Bericht festgehalten, nicht stillschweigend umgangen.

- [ ] **Schritt 4: Committen**

```bash
git add scripts/generate-model-checksums.sh StenoKit/Sources/StenoDiarization/Resources/model-checksums.json
git commit -m "feat(models): Pruefsummen der ausgelieferten Modellstaende festschreiben"
```

---

### Aufgabe 5: Der Sprach-Asset-Installer

**Dateien:**
- Anlegen: `StenoKit/Sources/StenoTranscription/SpeechAssetInstaller.swift`
- Ändern: `StenoKit/Sources/StenoTranscription/SpeechAnalyzerProvider.swift:193`
- Test: `StenoKit/Tests/StenoTranscriptionTests/SpeechAssetInstallerTests.swift`

**Schnittstellen:**
- Nutzt: `ModelInstalling`, `ModelReadiness`, `ModelInstallProgress` aus Aufgabe 1.
- Liefert: `SpeechAssetInstaller(assets:)` mit einsetzbarer Attrappe `SpeechAssetGateway`.

Der entscheidende Punkt: `prepareTranscriber` ruft heute in Zeile 193 `ensureAssets` und installiert damit ungefragt. Dieser Aufruf entfällt; der Provider wirft stattdessen, wenn Assets fehlen.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

```swift
import Testing
import Foundation
@testable import StenoTranscription

@Suite("Speech asset installer")
struct SpeechAssetInstallerTests {
    @Test("installing is never attempted without being asked")
    func neverInstallsByItself() async {
        let gateway = RecordingGateway(installedLocales: [])
        let installer = SpeechAssetInstaller(assets: gateway)
        let readiness = await installer.readiness(for: [Locale(identifier: "de-DE")])
        #expect(!readiness.isReady(for: Locale(identifier: "de-DE")))
        #expect(await gateway.installCount == 0)
    }

    @Test("readiness distinguishes languages")
    func readinessPerLanguage() async {
        let gateway = RecordingGateway(installedLocales: [Locale(identifier: "de-DE")])
        let installer = SpeechAssetInstaller(assets: gateway)
        let readiness = await installer.readiness(
            for: [Locale(identifier: "de-DE"), Locale(identifier: "en-US")]
        )
        #expect(readiness.isReady(for: Locale(identifier: "de-DE")))
        #expect(!readiness.isReady(for: Locale(identifier: "en-US")))
    }

    @Test("two concurrent requests lead to exactly one installation")
    func concurrentRequestsCollapse() async throws {
        let gateway = RecordingGateway(installedLocales: [])
        let installer = SpeechAssetInstaller(assets: gateway)
        async let first: Void = installer.install(for: Locale(identifier: "de-DE")) { _ in }
        async let second: Void = installer.install(for: Locale(identifier: "de-DE")) { _ in }
        _ = try await (first, second)
        #expect(await gateway.installCount == 1)
    }
}

actor RecordingGateway: SpeechAssetGateway {
    private var installed: Set<String>
    private(set) var installCount = 0

    init(installedLocales: [Locale]) {
        installed = Set(installedLocales.map(\.identifier))
    }

    func isInstalled(locale: Locale) async -> Bool {
        installed.contains(locale.identifier)
    }

    func install(locale: Locale, progress: @Sendable @escaping (Double) -> Void) async throws {
        installCount += 1
        try await Task.sleep(for: .milliseconds(20))
        installed.insert(locale.identifier)
        progress(1)
    }
}
```

- [ ] **Schritt 2: Test laufen lassen und Fehlschlag prüfen**

Ausführen: `cd StenoKit && swift test --filter SpeechAssetInstallerTests`
Erwartet: FEHLER, "cannot find type 'SpeechAssetGateway' in scope".

- [ ] **Schritt 3: Die kleinste Implementierung schreiben**

```swift
import Foundation

/// Trennt die Asset-Installation vom Transkriptionslauf.
///
/// Vorher rief `prepareTranscriber` bei jeder Live-Session und jedem
/// Finallauf `ensureAssets` und installierte ungefragt. Damit waere jede
/// Zustimmung, die der Nutzer verweigert, wirkungslos gewesen.
public protocol SpeechAssetGateway: Sendable {
    func isInstalled(locale: Locale) async -> Bool
    func install(locale: Locale, progress: @Sendable @escaping (Double) -> Void) async throws
}

public actor SpeechAssetInstaller {
    private let assets: any SpeechAssetGateway
    private var activeInstalls: [String: Task<Void, Error>] = [:]

    public init(assets: any SpeechAssetGateway) {
        self.assets = assets
    }

    public nonisolated var bundleDescription: ModelBundleDescription {
        ModelBundleDescription(
            title: "Transcription language",
            source: .appleSystemAssets,
            approximateBytes: 250_000_000
        )
    }

    public func readiness(for locales: [Locale]) async -> ModelReadiness {
        var installed: Set<Locale> = []
        var missing: [Locale: [String]] = [:]
        for locale in locales {
            if await assets.isInstalled(locale: locale) {
                installed.insert(locale)
            } else {
                missing[locale] = ["Speech model \(locale.identifier)"]
            }
        }
        return ModelReadiness(installed: installed, missing: missing)
    }

    public func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        let key = locale.identifier
        if let running = activeInstalls[key] {
            try await running.value
            return
        }
        let task = Task<Void, Error> { [assets] in
            try await assets.install(locale: locale) { fraction in
                progress(ModelInstallProgress(fraction: fraction, title: "Transcription language"))
            }
        }
        activeInstalls[key] = task
        defer { activeInstalls[key] = nil }
        try await task.value
    }
}
```

In `SpeechAnalyzerProvider.swift` Zeile 193 den Aufruf ersetzen:

```swift
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw TranscriptionError.assetInstallationUnavailable(
                localeIdentifier: locale.identifier
            )
        }
```

- [ ] **Schritt 4: Tests laufen lassen und Erfolg prüfen**

Ausführen: `cd StenoKit && swift test`
Erwartet: BESTANDEN, alle Suiten.

- [ ] **Schritt 5: Committen**

```bash
git add StenoKit/Sources/StenoTranscription/ StenoKit/Tests/StenoTranscriptionTests/
git commit -m "refactor(transcription): Sprachassets installieren nur noch auf Anforderung"
```

---

### Aufgabe 6: Koordinator, Zustimmung und der sichtbare Weg in der App

**Dateien:**
- Anlegen: `StenoKit/Sources/StenoPipeline/ModelInstallationCoordinator.swift`
- Ändern: `StenoKit/Sources/StenoPipeline/PipelineStartup.swift:26-31`
- Ändern: `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift:49-51`
- Anlegen: `App/Sources/ModelConsent.swift`
- Anlegen: `App/Sources/ModelStatusView.swift`
- Ändern: `App/Sources/SettingsView.swift:9-15`
- Ändern: `App/Sources/AppModel.swift:205-220`
- Test: `StenoKit/Tests/StenoPipelineTests/ModelInstallationCoordinatorTests.swift`

**Schnittstellen:**
- Nutzt: `DiarizationModelInstaller` (Aufgabe 3), `SpeechAssetInstaller` (Aufgabe 5).
- Liefert: `ModelInstallationCoordinator(installers:)` mit `readiness(for:)`, `installAll(for:progress:)`. `ModelConsent` in der App mit `grantedAt`, `sources`, `isGranted`.

Nach dieser Aufgabe funktioniert die Diarisierung auf einem frischen Rechner. Das ist der Blocker aus dem Anlass.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

```swift
import Testing
import Foundation
import StenoDomain
@testable import StenoPipeline

@Suite("Model installation coordinator")
struct ModelInstallationCoordinatorTests {
    @Test("without consent nothing is requested")
    func withoutConsentNothingHappens() async throws {
        let installer = CountingInstaller(readyLocales: [])
        let coordinator = ModelInstallationCoordinator(installers: [installer])
        await #expect(throws: ModelInstallationError.self) {
            try await coordinator.installAll(
                for: Locale(identifier: "de-DE"),
                consentGranted: false
            ) { _ in }
        }
        #expect(await installer.installCount == 0)
    }

    @Test("with consent every installer runs exactly once")
    func withConsentEachRunsOnce() async throws {
        let first = CountingInstaller(readyLocales: [])
        let second = CountingInstaller(readyLocales: [])
        let coordinator = ModelInstallationCoordinator(installers: [first, second])
        try await coordinator.installAll(
            for: Locale(identifier: "de-DE"),
            consentGranted: true
        ) { _ in }
        #expect(await first.installCount == 1)
        #expect(await second.installCount == 1)
    }

    @Test("readiness is false as soon as one installer is missing something")
    func readinessNeedsEveryone() async {
        let ready = CountingInstaller(readyLocales: [Locale(identifier: "de-DE")])
        let notReady = CountingInstaller(readyLocales: [])
        let coordinator = ModelInstallationCoordinator(installers: [ready, notReady])
        let readiness = await coordinator.readiness(for: [Locale(identifier: "de-DE")])
        #expect(!readiness.isReady(for: Locale(identifier: "de-DE")))
    }
}

actor CountingInstaller: ModelInstalling {
    nonisolated let bundleDescription = ModelBundleDescription(
        title: "Test bundle",
        source: .huggingFace,
        approximateBytes: 1
    )
    private var ready: Set<String>
    private(set) var installCount = 0

    init(readyLocales: [Locale]) {
        ready = Set(readyLocales.map(\.identifier))
    }

    func readiness(for locales: [Locale]) async -> ModelReadiness {
        var installed: Set<Locale> = []
        var missing: [Locale: [String]] = [:]
        for locale in locales {
            if ready.contains(locale.identifier) { installed.insert(locale) }
            else { missing[locale] = ["test"] }
        }
        return ModelReadiness(installed: installed, missing: missing)
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        installCount += 1
        ready.insert(locale.identifier)
        progress(ModelInstallProgress(fraction: 1, title: "Test bundle"))
    }
}
```

- [ ] **Schritt 2: Test laufen lassen und Fehlschlag prüfen**

Ausführen: `cd StenoKit && swift test --filter ModelInstallationCoordinatorTests`
Erwartet: FEHLER, "cannot find 'ModelInstallationCoordinator' in scope".

- [ ] **Schritt 3: Koordinator und Zustimmung schreiben**

`ModelInstallationCoordinator.swift`:

```swift
import Foundation
import StenoDomain

public enum ModelInstallationError: Error, Equatable, LocalizedError, Sendable {
    case consentMissing

    public var errorDescription: String? {
        switch self {
        case .consentMissing:
            "Steno may not download its models yet. Allow it in Settings under Models."
        }
    }
}

/// Fasst die Installer zusammen und beantwortet, ob Steno fuer eine Sprache
/// arbeitsfaehig ist. Die Zustimmung wird hineingereicht, nicht gelesen:
/// StenoKit kennt UserDefaults nicht.
public actor ModelInstallationCoordinator {
    private let installers: [any ModelInstalling]

    public init(installers: [any ModelInstalling]) {
        self.installers = installers
    }

    public func readiness(for locales: [Locale]) async -> ModelReadiness {
        var installed = Set(locales)
        var missing: [Locale: [String]] = [:]
        for installer in installers {
            let readiness = await installer.readiness(for: locales)
            for locale in locales where !readiness.isReady(for: locale) {
                installed.remove(locale)
                missing[locale, default: []].append(contentsOf: readiness.missingNames(for: locale))
            }
        }
        return ModelReadiness(installed: installed, missing: missing)
    }

    public func installAll(
        for locale: Locale,
        consentGranted: Bool,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async throws {
        guard consentGranted else { throw ModelInstallationError.consentMissing }
        for installer in installers {
            try await installer.install(for: locale, progress: progress)
        }
    }
}
```

`App/Sources/ModelConsent.swift`:

```swift
import Foundation
import Observation
import StenoDomain

/// Die Zustimmung zum Nachladen der Modelle.
///
/// Sie liegt bewusst hier und nicht in der Bibliothek: Sie ist eine
/// Entscheidung ueber diesen Rechner und sein Netz, keine Eigenschaft der
/// Meetings, und darf nicht mitwandern, wenn die Bibliothek den Mac wechselt.
///
/// Gespeichert wird kein nacktes Ja, sondern Zeitpunkt und benannte Quellen:
/// im Behoerdenumfeld ist die Nachvollziehbarkeit der halbe Wert.
@Observable
final class ModelConsent {
    private static let key = "org.steno.modelConsent"

    struct Record: Codable, Equatable {
        let grantedAt: Date
        let sources: [String]
    }

    private(set) var record: Record?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            record = try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    var isGranted: Bool { record != nil }

    func grant(sources: [ModelSource]) {
        let value = Record(grantedAt: Date(), sources: sources.map(\.displayHost))
        record = value
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: Self.key)
    }

    /// Widerruf heisst: es wird nichts mehr geladen. Bereits installierte
    /// Modelle bleiben nutzbar, Apple-Assets sind ohnehin systemweit und von
    /// Steno nicht entfernbar. Der Text im Fenster muss das so sagen.
    func revoke() {
        record = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
```

`App/Sources/ModelStatusView.swift` als neues Register in den Einstellungen: zeigt je Quelle Titel, Host und ungefähre Größe, den Zustand für die aktuelle Sprache, einen Knopf "Allow and install" und, wenn zugestimmt wurde, Zeitpunkt und Quellen sowie "Revoke". Während der Installation ein `ProgressView` mit dem Titel aus `ModelInstallProgress`. Der Text unter dem Knopf lautet wörtlich:

> Without these models Steno cannot transcribe at all. Speech models come from Apple, speaker separation from huggingface.co. Revoking stops future downloads; models already installed keep working.

In `SettingsView.swift` das Register einhängen:

```swift
            ModelStatusView()
                .tabItem { Label("Models", systemImage: "arrow.down.circle") }
```

In `AppModel.swift` den Koordinator aufbauen und in `startPipeline` durchreichen; `PipelineStartup.swift` und `PipelineCoordinator.swift` verlieren den Vorgabewert `FluidSortformerProvider(allowModelDownload: false)` und bekommen den Provider ohne Parameter.

- [ ] **Schritt 4: Tests laufen lassen und Erfolg prüfen**

Ausführen: `cd StenoKit && swift test`
Erwartet: BESTANDEN.
Dann bauen: `scripts/build-app.sh`
Erwartet: `** BUILD SUCCEEDED **`.

- [ ] **Schritt 5: Am Bildschirm prüfen, nicht nur in der Suite**

**Diesen Schritt führt der Koordinator aus, nicht der Umsetzer.** Er berührt eine laufende Anwendung auf dem Testrechner und braucht Vorsichtsmaßnahmen, die außerhalb einer Umsetzungsaufgabe liegen.

Sicherheitsregeln, bindend:

- **Niemals gegen die echte Bibliothek.** Der Debug-Build wird mit `STENO_LIBRARY_DIR` auf ein Wegwerfverzeichnis gestartet. Ohne diese Variable schreibt die App nach `~/Library/Application Support/Steno/Library`, und dort liegen nutzereigene Meetings.
- **Niemals die installierte Fassung** aus `/Applications` starten, nur den Build aus `.build/DerivedData`.
- **Keine Vollbildaufnahme.** Aufgenommen wird gezielt ein Fenster über `screencapture -x -o -l <windowID>`, die ID über eine CGWindowList-Abfrage, und **immer das Fenster mit Namen wählen**: die App hält mehrere namenlose 30-pt-Fenster für die Menüleiste, die sonst statt des Hauptfensters im Bild landen.
- Vor jedem Tastendruck die Ziel-App aktivieren **und prüfen**, dass sie vorne ist.

Ablauf: Einstellungen öffnen, Register "Models". Zustimmen. Der Fortschritt muss laufen und echte Zwischenwerte zeigen, nicht von 0 auf 1 springen. Danach eine Audiodatei importieren und verarbeiten. Die Verarbeitung muss durchlaufen.

Das ist zugleich der einzige Ort, an dem der **echte Download** stattfindet: bis hierher ist der `variant:`-Pfad nur gegen den Quelltext gelesen, nie gegen den Server gemessen. Stimmen die geladenen Bundles und die angezeigte Größe nicht mit der Erwartung überein, ist das ein Befund.

Das ist die Abnahme des ursprünglichen Fehlers. Ohne diesen Schritt gilt die Aufgabe nicht als erledigt.

- [ ] **Schritt 6: Committen**

```bash
git add StenoKit/Sources/StenoPipeline/ App/Sources/ModelConsent.swift App/Sources/ModelStatusView.swift App/Sources/SettingsView.swift App/Sources/AppModel.swift StenoKit/Tests/StenoPipelineTests/
git commit -m "feat(models): Zustimmung erteilen und Modelle aus den Einstellungen installieren"
```

---

## Phase B: Betreiberprofil und Wizard

### Aufgabe 7: Betreiberprofil

**Dateien:**
- Anlegen: `StenoKit/Sources/StenoDomain/OperatorIdentity.swift`
- Anlegen: `StenoKit/Tests/StenoDomainTests/OperatorIdentityTests.swift`
- Anlegen: `App/Sources/OperatorProfile.swift`
- Ändern: `App/Sources/SettingsView.swift` (Felder in `GeneralSettingsView`)

**Schnittstellen:**
- Liefert: `OperatorIdentity` (Werttyp in StenoKit, testbar) und `OperatorProfile` (Speicherung in `UserDefaults`, App-Schicht).

**Zuschnitt:** Die Bildung der Verfasserzeile hat echte Verzweigungen (leerer Name, leere Organisation, nur Leerraum) und gehört deshalb als Werttyp nach StenoKit, wo sie geprüft werden kann. Die Speicherung bleibt in der App, weil StenoKit `UserDefaults` nicht kennen darf. Die spätere iOS-App übernimmt den Werttyp samt Tests unverändert.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

```swift
import Testing
@testable import StenoDomain

@Suite("Operator identity")
struct OperatorIdentityTests {
    @Test("name and organisation are joined for the minutes header")
    func joinsNameAndOrganisation() {
        let identity = OperatorIdentity(name: "Ada Lovelace", organization: "Stadt Musterstadt")
        #expect(identity.authorLine == "Ada Lovelace, Stadt Musterstadt")
    }

    @Test("without an organisation the name stands alone")
    func nameAlone() {
        #expect(OperatorIdentity(name: "Ada Lovelace", organization: "").authorLine == "Ada Lovelace")
    }

    @Test("without a name there is no author line at all")
    func noNameNoLine() {
        #expect(OperatorIdentity(name: "", organization: "Stadt Musterstadt").authorLine == nil)
        #expect(OperatorIdentity(name: "   ", organization: "").authorLine == nil)
    }

    @Test("surrounding whitespace never reaches the document")
    func trimsWhitespace() {
        let identity = OperatorIdentity(name: "  Ada Lovelace  ", organization: "  Stadt  ")
        #expect(identity.authorLine == "Ada Lovelace, Stadt")
    }
}
```

- [ ] **Schritt 2: Test laufen lassen und Fehlschlag prüfen**

Ausführen: `cd StenoKit && swift test --filter OperatorIdentityTests`
Erwartet: FEHLER, "cannot find 'OperatorIdentity' in scope".

- [ ] **Schritt 3: Den Werttyp schreiben**

```swift
import Foundation

/// Wer dieses Steno bedient. Bewusst getrennt von der Frage, wer bei einem
/// Meeting ins Mikrofon gesprochen hat: beim Auftragstranskript und beim
/// geteilten Geraet fallen die beiden auseinander. Die Mikrofonbindung ist
/// ein eigenes Arbeitspaket.
public struct OperatorIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let organization: String

    public init(name: String, organization: String) {
        self.name = name
        self.organization = organization
    }

    /// Nil, wenn kein Name hinterlegt ist: ein Protokollkopf ohne Verfasser
    /// ist besser als einer mit leerem Feld.
    public var authorLine: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let trimmedOrganization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedOrganization.isEmpty ? trimmedName : "\(trimmedName), \(trimmedOrganization)"
    }
}
```

- [ ] **Schritt 4: Die Speicherung in der App schreiben**

```swift
import Foundation
import Observation
import StenoDomain

/// Nur die Speicherung. Die Regeln stehen in `OperatorIdentity`, damit sie
/// geprueft werden koennen und die spaetere iOS-App sie unveraendert erbt.
@Observable
final class OperatorProfile {
    private static let nameKey = "org.steno.operatorName"
    private static let organizationKey = "org.steno.operatorOrganization"

    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: Self.nameKey) }
    }

    var organization: String {
        didSet { UserDefaults.standard.set(organization, forKey: Self.organizationKey) }
    }

    init() {
        name = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
        organization = UserDefaults.standard.string(forKey: Self.organizationKey) ?? ""
    }

    var identity: OperatorIdentity {
        OperatorIdentity(name: name, organization: organization)
    }

    var authorLine: String? { identity.authorLine }
}
```

In `GeneralSettingsView` zwei Felder ergänzen, mit dem Hinweis darunter:

```swift
            TextField("Your name", text: $profile.name)
            TextField("Organisation (optional)", text: $profile.organization)
            Text("Appears in generated minutes. Sent to an external language model only when you pick one for a render.")
```

- [ ] **Schritt 5: Tests und Bau**

Ausführen: `cd StenoKit && swift test --filter OperatorIdentityTests` und danach `scripts/build-app.sh`
Erwartet: BESTANDEN, vier Tests, und `** BUILD SUCCEEDED **`.

- [ ] **Schritt 6: Committen**

```bash
git add StenoKit/Sources/StenoDomain/OperatorIdentity.swift StenoKit/Tests/StenoDomainTests/OperatorIdentityTests.swift App/Sources/OperatorProfile.swift App/Sources/SettingsView.swift App/Sources/StenoApp.swift
git commit -m "feat(profile): Name und Organisation des Betreibers in den Einstellungen"
```

---

### Aufgabe 8: Verfasser in Auftrag, Render-Kontext und Protokollkopf

**Dateien:**
- Ändern: `StenoKit/Sources/StenoIntelligence/TextModelProvider.swift:143-163`
- Ändern: `StenoKit/Sources/StenoDomain/Job.swift:18,32,45`
- Ändern: `StenoKit/Sources/StenoPipeline/TemplateRenderRequest.swift:6-27`
- Ändern: `StenoKit/Sources/StenoPipeline/MeetingMarkdown.swift:69`
- Ändern: `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift` (Render-Kontext bauen)
- Test: `StenoKit/Tests/StenoPipelineTests/TemplateAuthorTests.swift`

**Schnittstellen:**
- Nutzt: nichts aus Phase A.
- Liefert: `RenderContext.author: String?`, `Job.authorLine: String?`, `TemplateRenderRequest.enqueue(..., authorLine:)`.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

```swift
import Testing
import Foundation
import StenoDomain
import StenoIntelligence
@testable import StenoPipeline

@Suite("Template author")
struct TemplateAuthorTests {
    @Test("the author is pinned when the job is queued, not when it renders")
    func authorIsPinnedAtEnqueue() async throws {
        let job = Job(
            kind: .templateRender,
            meetingID: MeetingID(),
            templateID: "meeting-minutes",
            authorLine: "Ada Lovelace, Stadt Musterstadt"
        )
        #expect(job.authorLine == "Ada Lovelace, Stadt Musterstadt")
    }

    @Test("an empty author leaves the render context free of an empty line")
    func emptyAuthorStaysNil() {
        let context = RenderContext(author: "   ")
        #expect(context.author == nil)
    }

    @Test("the markdown header carries the author when there is one")
    func markdownCarriesAuthor() {
        let markdown = MeetingMarkdown.header(title: "Weekly", authorLine: "Ada Lovelace")
        #expect(markdown.contains("Ada Lovelace"))
    }
}
```

- [ ] **Schritt 2: Test laufen lassen und Fehlschlag prüfen**

Ausführen: `cd StenoKit && swift test --filter TemplateAuthorTests`
Erwartet: FEHLER, "extra argument 'authorLine' in call".

- [ ] **Schritt 3: Implementieren**

`RenderContext` bekommt ein drittes Feld, mit derselben Leerraumbehandlung wie `userNotes`:

```swift
    /// Wer das Protokoll erstellt. Faellt in die bestehende Klasse
    /// "Teilnehmerliste, Namen und Firmen" aus PLAN-PRIVACY.md und geht
    /// deshalb genau dann mit, wenn fuer diesen Lauf ein externes Modell
    /// gewaehlt ist. Keine neue Datenklasse.
    public let author: String?

    public init(userNotes: String? = nil, participants: [String] = [], author: String? = nil) {
        let trimmedNotes = userNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userNotes = (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes
        self.participants = participants
        let trimmedAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.author = (trimmedAuthor?.isEmpty ?? true) ? nil : trimmedAuthor
    }
```

`isEmpty` entsprechend erweitern: `userNotes == nil && participants.isEmpty && author == nil`.

`Job` bekommt `public let authorLine: String?` mit Vorgabe `nil` im Initialisierer, direkt nach `textModelEndpointID`, mit Kommentar:

```swift
    /// Pinnt bei templateRender den Verfasser beim Einreihen, aus demselben
    /// Grund wie die Revision: das Protokoll gehoert zu dem Stand, den der
    /// Nutzer vor sich hatte, nicht zu einem, der waehrend des Wartens
    /// entstanden ist.
```

`Job.currentSchemaVersion` bleibt bei 1, weil ein optionales Feld mit Vorgabewert alte Dokumente weiterhin dekodiert. Das ist in einem Test festzuhalten: ein Job-JSON ohne `authorLine` muss weiterhin dekodieren.

`TemplateRenderRequest.enqueue` bekommt `authorLine: String? = nil` und reicht es an `Job` durch. Der `PipelineCoordinator` liest es beim Rendern aus dem Job und setzt es in den `RenderContext`.

`MeetingMarkdown` bekommt eine `header`-Funktion, die den Verfasser aufnimmt, wenn einer da ist.

- [ ] **Schritt 4: Tests laufen lassen und Erfolg prüfen**

Ausführen: `cd StenoKit && swift test`
Erwartet: BESTANDEN.

- [ ] **Schritt 5: Committen**

```bash
git add StenoKit/Sources/ StenoKit/Tests/StenoPipelineTests/TemplateAuthorTests.swift
git commit -m "feat(templates): Verfasser beim Einreihen pinnen und im Protokollkopf fuehren"
```

---

### Aufgabe 9: Die "Ich"-Auflösung auf eine Naht bringen

**Dateien:**
- Ändern: `App/Sources/AppModel+Review.swift:638-646`
- Ändern: `App/Sources/AppModel+Export.swift:80,97`
- Ändern: `App/Sources/RecordingView.swift:78`
- Test: `StenoKit/Tests/StenoDomainTests/ChannelLabelTests.swift`

**Schnittstellen:**
- Liefert: `SpeakerDisplay.speakerLabel(_:)` für Sprecher und `SpeakerDisplay.trackName(_:)` für Spurnamen. Zwei Funktionen statt einer.

Grund: heute macht `channelName` beides. Nur die erste Verwendung meint je einen Menschen; nur sie wird das spätere Bindungs-Paket auf `meeting.json` umstellen. Ohne die Trennung müssten dann vier Aufrufstellen umlernen.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

```swift
import Testing
@testable import StenoDomain

@Suite("Channel labels")
struct ChannelLabelTests {
    @Test("speaker labels and track names are resolved by different functions")
    func speakerAndTrackAreSeparate() {
        #expect(ChannelLabel.speakerLabel("Ich") == "Me")
        #expect(ChannelLabel.speakerLabel("Andere") == "Others")
        #expect(ChannelLabel.trackName("micTrack") == "Microphone")
        #expect(ChannelLabel.trackName("systemTrack") == "System audio")
    }

    @Test("a speaker label function does not answer for track kinds")
    func speakerLabelLeavesTrackKindsAlone() {
        #expect(ChannelLabel.speakerLabel("micTrack") == "micTrack")
    }
}
```

- [ ] **Schritt 2: Test laufen lassen und Fehlschlag prüfen**

Ausführen: `cd StenoKit && swift test --filter ChannelLabelTests`
Erwartet: FEHLER, "cannot find 'ChannelLabel' in scope".

- [ ] **Schritt 3: Implementieren**

`ChannelLabel` nach `StenoDomain`, weil beide Aufrufer es brauchen und es keine Anzeigelogik der App ist:

```swift
public enum ChannelLabel {
    /// Loest ein Sprecher-Kanallabel auf. Das ist die einzige Stelle, an der
    /// aus "Ich" ein Mensch wird; das spaetere Bindungs-Paket ersetzt hier
    /// die feste Uebersetzung durch die Abfrage von meeting.json.
    public static func speakerLabel(_ raw: String) -> String {
        switch raw {
        case "Ich": "Me"
        case "Andere": "Others"
        default: raw
        }
    }

    /// Benennt eine Spur. Meint nie einen Menschen.
    public static func trackName(_ raw: String) -> String {
        switch raw {
        case MediaAsset.Kind.micTrack.rawValue: "Microphone"
        case MediaAsset.Kind.systemTrack.rawValue: "System audio"
        case MediaAsset.Kind.imported.rawValue: "Imported track"
        default: raw
        }
    }
}
```

`SpeakerDisplay.channelName` entfällt. `AppModel+Review.swift:543` und `RecordingView.swift:78` rufen `ChannelLabel.speakerLabel`, `AppModel+Export.swift:80,97` und `PeopleSettingsView.swift:397` rufen `ChannelLabel.trackName`.

- [ ] **Schritt 4: Tests laufen lassen und bauen**

Ausführen: `cd StenoKit && swift test --filter ChannelLabelTests` und danach `scripts/build-app.sh`
Erwartet: BESTANDEN und `** BUILD SUCCEEDED **`.

- [ ] **Schritt 5: Committen**

```bash
git add StenoKit/Sources/StenoDomain/ChannelLabel.swift StenoKit/Tests/StenoDomainTests/ChannelLabelTests.swift App/Sources/
git commit -m "refactor(ui): Sprecherlabel und Spurname trennen"
```

---

### Aufgabe 10: Der Wizard

**Dateien:**
- Anlegen: `StenoKit/Sources/StenoPipeline/OnboardingFlow.swift`
- Anlegen: `StenoKit/Tests/StenoPipelineTests/OnboardingFlowTests.swift`
- Anlegen: `App/Sources/OnboardingModel.swift`
- Anlegen: `App/Sources/OnboardingView.swift`
- Ändern: `App/Sources/StenoApp.swift:8-20,74-79`

**Schnittstellen:**
- Nutzt: `ModelConsent` (Aufgabe 6), `OperatorProfile` (Aufgabe 7), `ModelInstallationCoordinator` (Aufgabe 6), `AppModel.setLanguage` (Bestand).
- Liefert: `OnboardingFlow` (Zustandsmaschine in StenoKit, testbar) und `OnboardingModel` (Speicherung und Anbindung, App-Schicht).

**Zuschnitt:** Die Seitenfolge hat echte Verzweigungen, die am Bildschirm niemand vollständig durchklickt: Abbruch mitten drin, Wiedereintritt, Überspringen einzelner Seiten. Sie liegt deshalb als Werttyp in StenoKit. Die Speicherung bleibt in der App. Die spätere iOS-App schreibt ihre Ansichten neu und übernimmt die Zustandsmaschine samt Tests unverändert.

**Das amendiert die Spezifikation:** Dort stand "StenoKit weiß nichts vom Wizard". Es gilt jetzt: StenoKit kennt den **Zustand** des Wizards, nicht sein **Fenster**. Der ursprüngliche Satz diente dem iOS-Ziel, und genau dem dient die Änderung.

- [ ] **Schritt 1: Den fehlschlagenden Test schreiben**

```swift
import Testing
@testable import StenoPipeline

@Suite("Onboarding flow")
struct OnboardingFlowTests {
    @Test("language comes before models because assets are locale-bound")
    func languagePrecedesModels() {
        let pages = OnboardingFlow.Page.allCases
        let language = pages.firstIndex(of: .language)!
        let models = pages.firstIndex(of: .models)!
        #expect(language < models)
    }

    @Test("advancing walks every page and then finishes")
    func advanceWalksEveryPage() {
        var flow = OnboardingFlow()
        var seen: [OnboardingFlow.Page] = [flow.page]
        while !flow.isFinished {
            flow.advance()
            if !flow.isFinished { seen.append(flow.page) }
        }
        #expect(seen == OnboardingFlow.Page.allCases)
        #expect(flow.isFinished)
    }

    @Test("skipping a page does not skip the rest")
    func skipAdvancesByOne() {
        var flow = OnboardingFlow()
        flow.skip()
        #expect(flow.page == .profile)
    }

    @Test("a deliberate abort counts as finished so it does not reappear")
    func abortFinishes() {
        var flow = OnboardingFlow()
        flow.advance()
        flow.abort()
        #expect(flow.isFinished)
    }

    @Test("reopening starts at the first page again")
    func reopenRestarts() {
        var flow = OnboardingFlow()
        flow.abort()
        flow.reopen()
        #expect(flow.page == .welcome)
        #expect(!flow.isFinished)
    }
}
```

- [ ] **Schritt 2: Test laufen lassen und Fehlschlag prüfen**

Ausführen: `cd StenoKit && swift test --filter OnboardingFlowTests`
Erwartet: FEHLER, "cannot find 'OnboardingFlow' in scope".

- [ ] **Schritt 3: Die Zustandsmaschine schreiben**

```swift
import Foundation

/// Zustand und Seitenfolge des Erstlauf-Wizards. Bewusst ohne Fenster und
/// ohne UserDefaults: die Speicherung liegt in der App, damit dieser Typ
/// auf jeder Plattform gilt.
public struct OnboardingFlow: Equatable, Sendable {
    /// Reihenfolge ist bindend: Sprache steht vor den Modellen, weil die
    /// Sprachassets an die Locale gebunden und reserviert werden. Ohne
    /// gewaehlte Sprache wuerde das Falsche geladen.
    public enum Page: Int, CaseIterable, Sendable {
        case welcome
        case profile
        case language
        case models
        case permissions
    }

    public private(set) var page: Page
    public private(set) var isFinished: Bool

    public init(page: Page = .welcome, isFinished: Bool = false) {
        self.page = page
        self.isFinished = isFinished
    }

    public var isLastPage: Bool { page == Page.allCases.last }

    public mutating func advance() {
        guard let next = Page(rawValue: page.rawValue + 1) else {
            isFinished = true
            return
        }
        page = next
    }

    /// Ueberspringen und Weitergehen sind derselbe Schritt: der Unterschied
    /// liegt darin, ob die Seite etwas gespeichert hat, nicht in der Folge.
    public mutating func skip() { advance() }

    /// Auch der bewusste Abbruch gilt als erledigt: wer den Wizard wegklickt,
    /// soll ihn nicht bei jedem Start wiedersehen. Erneut zu oeffnen ueber
    /// das Hilfe-Menue.
    public mutating func abort() { isFinished = true }

    public mutating func reopen() {
        page = .welcome
        isFinished = false
    }
}
```

- [ ] **Schritt 4: Speicherung und die fünf Seiten schreiben**

`App/Sources/OnboardingModel.swift` haelt einen `OnboardingFlow`, spiegelt `isFinished` nach `UserDefaults` unter `org.steno.onboardingFinished` und reicht `advance`, `skip`, `abort` und `reopen` durch. Keine Entscheidungslogik in dieser Datei.

`OnboardingView` mit einem `TabView(selection:)` ohne sichtbare Reiter, je Seite ein `Form`, unten "Skip" und "Continue". Die Texte wörtlich:

- **welcome:** "Steno records and transcribes conversations on this Mac. Nothing leaves the machine unless you pick an external language model for a render." und darunter, kleiner: "Recording someone without their consent is a criminal offence in Germany under section 201 of the criminal code, and the rules differ from country to country. Please make sure everyone in the room knows they are being recorded."
- **profile:** die beiden Felder aus Aufgabe 7, mit "You can skip this and add it later in Settings."
- **language:** der Picker aus `GeneralSettingsView`.
- **models:** die Ansicht aus Aufgabe 6, samt dem Satz, dass Steno ohne Modelle gar nicht transkribieren kann.
- **permissions:** zwei Knöpfe, die Mikrofon- und Systemaudio-Zugriff anfragen, mit dem jeweiligen Zustand daneben.

In `StenoApp.swift` die Szene und den Menüeintrag ergänzen:

```swift
        Window("Welcome to Steno", id: "onboarding") {
            OnboardingView()
                .environment(model)
                .environment(onboarding)
                .environment(profile)
                .environment(consent)
        }
        .defaultSize(width: 620, height: 480)
```

sowie in `.commands` unter `CommandGroup(replacing: .help)` einen Eintrag "Show Setup Assistant", der `onboarding.reopen()` ruft und das Fenster öffnet. Beim Start öffnet `ContentView.task`, wenn `!onboarding.isFinished`, dasselbe Fenster.

- [ ] **Schritt 5: Tests und Bau**

Ausführen: `cd StenoKit && swift test --filter OnboardingFlowTests` und danach `scripts/build-app.sh`
Erwartet: BESTANDEN, fünf Tests, und `** BUILD SUCCEEDED **`.

- [ ] **Schritt 6: Am Bildschirm prüfen**

Ausführen:

```bash
defaults delete org.steno.Steno 2>/dev/null || true
scripts/build-app.sh --run
```

Prüfen, jede Zeile einzeln:
1. Der Wizard erscheint beim Start.
2. Jede Seite lässt sich überspringen.
3. Nach dem Durchlauf erscheint er beim nächsten Start nicht mehr.
4. Über das Hilfe-Menü lässt er sich erneut öffnen.
5. Nach dem Modellschritt läuft ein Import ohne Fehlermeldung durch.
6. Der Name aus dem Profilschritt steht im erzeugten Protokoll.

`defaults delete` setzt Zustimmung, Profil und Wizard-Zustand zurück, weil alle drei unter derselben Bundle-ID liegen.

- [ ] **Schritt 7: Committen**

```bash
git add StenoKit/Sources/StenoPipeline/OnboardingFlow.swift StenoKit/Tests/StenoPipelineTests/OnboardingFlowTests.swift App/Sources/OnboardingModel.swift App/Sources/OnboardingView.swift App/Sources/StenoApp.swift
git commit -m "feat(onboarding): Erstlauf-Wizard mit Rechtshinweis, Profil, Sprache, Modellen und Rechten"
```

---

## Selbstprüfung des Plans

**Abdeckung der Spezifikation:**

| Anforderung aus der Spezifikation | Aufgabe |
|---|---|
| Download verlässt den Provider, `allowModelDownload` entfällt | 3 |
| `ModelInstalling`, zwei Installer, Koordinator | 1, 3, 5, 6 |
| ASR-Pfad hinter dieselbe Zustimmung | 5 |
| Zustimmung mit Zeitpunkt und Quellen, in der App-Schicht | 6 |
| Widerruf lädt nicht mehr, löscht nicht | 6, Text in `ModelStatusView` |
| Arbeitsfähigkeit je Sprache | 1, 6 |
| Prüfsummen-Manifest samt Erzeugungsweg | 2, 4 |
| Downloads bleiben sichtbar | 6, `ProgressView` |
| Betreiberprofil in den Einstellungen | 7, Verfasserzeile als geprüfter Werttyp in StenoKit |
| Profil beim Einreihen gepinnt, im Kopf und im Render-Kontext | 8 |
| Wizard, fünf Seiten, Sprache vor Modellen | 10, Seitenfolge als geprüfte Zustandsmaschine in StenoKit |
| Rechtshinweis ohne Häkchen | 10 |
| "Ich"-Auflösung über genau eine Funktion | 9 |
| Aufnahme hängt nie an Modellen | unverändert, weil der Aufnahmeweg keine Modelle berührt; in Aufgabe 6 Schritt 5 am Bildschirm zu prüfen |

**Offen gebliebenes Risiko aus der Spezifikation:** Ob FluidAudios Downloader nach einem Abbruch sauber wieder aufsetzt, klärt Aufgabe 4 Schritt 3b. Scheitert der zweite Lauf an Teilresten, ist das ein Befund für den Nutzer und kein stiller Umweg.
