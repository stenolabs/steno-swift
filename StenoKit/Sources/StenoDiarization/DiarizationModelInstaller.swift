import FluidAudio
import Foundation
import StenoDomain

public extension ModelChecksumManifest {
    static func bundled(name: String = "model-checksums") throws -> ModelChecksumManifest {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw ModelManifestError.missingFile("\(name).json")
        }
        return try ModelChecksumManifest.load(from: url)
    }
}

/// Der einzige Ort, an dem Diarisierungsmodelle geladen werden.
///
/// Frueher lud der Provider mitten in `diarize()` nach. Das konnte keinen
/// Fortschritt melden, und ein Fehlschlag verbrannte den laufenden Job. Der
/// Provider sagte es selbst: "Installation is an explicit caller-owned action".
public actor DiarizationModelInstaller: ModelInstalling {
    /// Der zweite Parameter meldet den Anteil des gesamten Downloads, nicht
    /// den einer einzelnen Datei. Ohne ihn saehe der Nutzer waehrend eines
    /// halben Gigabytes nichts.
    public typealias Download = @Sendable (
        URL,
        @Sendable @escaping (Double) -> Void
    ) async throws -> Void

    static let progressTitle = "Speaker separation"

    public static let expectedBundleDescription = ModelBundleDescription(
        id: .speakerSeparation,
        title: progressTitle,
        source: .huggingFace,
        approximateBytes: DiarizationModelBytes.total
    )

    /// Die Pruefsummenpruefung liest am Ende noch einmal alles von der
    /// Platte. Sie bekommt einen eigenen Anteil, damit der Balken nicht bei
    /// 100 Prozent steht, waehrend noch gearbeitet wird.
    private static let downloadShare = 0.95

    private let modelCacheDirectory: URL?
    private let manifest: ModelChecksumManifest
    private let download: Download
    private let relay = InstallProgressRelay(title: progressTitle)
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

    public static let defaultDownload: Download = { baseDirectory, progress in
        // Nur die zwei Varianten, die der Provider wirklich waehlt. Ohne
        // `variant:` holt FluidAudio `Sortformer.requiredModels`, also alle
        // sechs Bundles und damit gut das Doppelte an Daten.
        var steps: [(repo: Repo, variant: String?, bytes: Int)] =
            zip(try sortformerBundleNames(), DiarizationModelBytes.sortformerVariants)
                .map { (.sortformer, $0, $1) }
        steps.append((.diarizer, nil, DiarizationModelBytes.diarizer))

        // Gewichtung nach gemessener Groesse: gleich gewichtete Schritte
        // liessen den Balken bei den grossen Sortformer-Bundles haengen und
        // beim kleinen Diarizer springen.
        let total = Double(steps.reduce(0) { $0 + $1.bytes })
        var completedBytes = 0.0
        for step in steps {
            let stepBytes = Double(step.bytes)
            let alreadyDone = completedBytes
            do {
                try await ModelHub.download(
                    step.repo,
                    to: baseDirectory,
                    variant: step.variant
                ) { update in
                    progress((alreadyDone + update.fractionCompleted * stepBytes) / total)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // FluidAudios `DownloadUtils` prueft den Abbruch nirgends, und
                // URLSession meldet einen abgebrochenen Transfer als
                // `URLError.cancelled`. Ohne diese Pruefung saehe der Nutzer
                // nach einem selbst ausgeloesten Widerruf eine rote
                // Fehlermeldung. Nur wenn wirklich abgebrochen wurde - echte
                // Netzfehler muessen sichtbar bleiben.
                try Task.checkCancellation()
                throw DiarizationError.modelInstallationFailed(error.localizedDescription)
            }
            completedBytes += stepBytes
            progress(completedBytes / total)
        }
    }

    private var baseDirectory: URL {
        modelCacheDirectory ?? MLModelConfigurationUtils.defaultModelsDirectory()
    }

    public nonisolated var bundleDescription: ModelBundleDescription {
        Self.expectedBundleDescription
    }

    /// Nur fuer Tests: macht sichtbar, wann ein wartender Zweitaufrufer
    /// angemeldet ist, ohne auf eine Wartezeit zu wetten.
    var observerCount: Int { relay.observerCount }

    /// Diarisierungsmodelle sind sprachunabhaengig: dieselbe Antwort fuer
    /// jede angefragte Sprache.
    public func readiness(for locales: [Locale]) -> ModelReadiness {
        // Nach aussen geht der Bundletitel, nicht die Dateinamen: die Liste
        // steht in der Oberflaeche, und "Sortformer_v2.1.mlmodelc" sagt dort
        // niemandem etwas. Welche Datei fehlt, entscheidet weiter
        // `missingBundleNames()`.
        let missing: [String]
        do {
            missing = try missingBundleNames().isEmpty ? [] : [Self.progressTitle]
        } catch {
            // Ohne aufloesbare Bundlenamen kann nichts vollstaendig sein.
            // Fehlend melden statt Bereitschaft vorzutaeuschen.
            missing = [Self.progressTitle]
        }
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
        let token = relay.add(progress)
        defer { relay.remove(token) }

        // Serialisierung: Wizard und ein anlaufender Job duerfen den
        // Downloader nicht gleichzeitig treffen. Der Zweite haengt sich an
        // den laufenden Lauf und sieht dessen Fortschritt mit, statt stumm
        // zu warten.
        if let activeInstall {
            relay.deliverCurrent(to: token)
            try await activeInstall.value
            return
        }

        if diarizationModelInstallationIsVerified(
            in: baseDirectory,
            manifest: manifest,
            ignoringIncompleteMarker: false
        ) {
            progress(ModelInstallProgress(fraction: 1, title: Self.progressTitle))
            return
        }

        relay.reset()
        let task = Task<Void, Error> { [baseDirectory, download, manifest, relay] in
            do {
                // The provider stays available for final ASR while this download
                // runs. Hide partially moved FluidAudio bundles from diarization
                // until the complete manifest has passed verification.
                try markDiarizationModelInstallationIncomplete(in: baseDirectory)
                try await download(baseDirectory) { fraction in
                    relay.report(fraction * Self.downloadShare)
                }
                try Task.checkCancellation()
                do {
                    try manifest.verify(directory: baseDirectory)
                } catch let integrity as ModelIntegrityError {
                    // Genau ein Reparaturversuch. FluidAudios Downloader
                    // ueberspringt jeden vorhandenen Zielpfad, deshalb pruefte
                    // ohne das Loeschen jeder weitere Klick dieselben falschen
                    // Bytes: der Nutzer saesse in einer Schleife aus roter
                    // Meldung ohne Ausweg. Nur Dateien, die nachweislich von den
                    // freigegebenen abweichen, und nur im Modellzwischenspeicher.
                    let broken = manifest.mismatchingFiles(directory: baseDirectory)
                    // Leer waere ein Widerspruch zum eben geworfenen Fehler und
                    // hiesse, die Datei hat sich zwischen beiden Lesungen
                    // geaendert. Dann nichts loeschen, sondern melden.
                    guard !broken.isEmpty else { throw integrity }
                    for relativePath in broken {
                        try? FileManager.default.removeItem(
                            at: baseDirectory.appendingPathComponent(relativePath)
                        )
                    }
                    // Der Balken faengt sichtbar von vorn an: er ist monoton, und
                    // ohne das Zuruecksetzen stuende er waehrend des erneuten
                    // Ladens bei 95 Prozent.
                    relay.reset()
                    try await download(baseDirectory) { fraction in
                        relay.report(fraction * Self.downloadShare)
                    }
                    try Task.checkCancellation()
                    // Zweiter Fehlschlag geht durch. Ein weiterer Versuch braechte
                    // dieselben Bytes und der Nutzer saehe nie einen Fehler.
                    try manifest.verify(directory: baseDirectory)
                }
                try clearDiarizationModelInstallationMarker(in: baseDirectory)
                // Der Abschluss gehoert in den Task, nicht hinter das `await`
                // des Erstaufrufers: sonst kann sich ein wartender Zweiter
                // abmelden, bevor er die 100 Prozent gesehen hat.
                relay.report(1)
            } catch {
                if diarizationModelInstallationIsVerified(
                    in: baseDirectory,
                    manifest: manifest,
                    ignoringIncompleteMarker: true
                ) {
                    try? clearDiarizationModelInstallationMarker(in: baseDirectory)
                }
                throw error
            }
        }
        activeInstall = task
        defer { activeInstall = nil }
        try await task.value
    }

    /// Bricht eine laufende Installation bei Widerruf oder beim Wechsel der
    /// iOS-App in den Hintergrund ab. Ein bloss geschlossenes Einstellungs-
    /// sheet ist kein Widerruf und bricht nichts ab.
    public func cancelInstall() {
        activeInstall?.cancel()
    }

    private func missingBundleNames() throws -> [String] {
        guard !diarizationModelInstallationIsIncomplete(in: baseDirectory) else {
            return [Self.progressTitle]
        }
        let fileManager = FileManager.default
        return try requiredBundleURLs(baseDirectory: baseDirectory)
            .filter {
                !modelBundleIsComplete(
                    $0,
                    fileManager: fileManager,
                    installationRoot: baseDirectory
                )
            }
            .map(\.lastPathComponent)
    }
}

/// Verteilt Fortschritt an alle, die auf dieselbe Installation warten.
///
/// Bewusst kein Aktor: `downloadRepo` ruft aus einem fremden Kontext
/// zurueck, und ein Umweg ueber den Aktor koennte einen Zwischenwert hinter
/// die Fertigmeldung schieben, wo ihn niemand mehr sieht.
final class InstallProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let title: String
    private var observers: [UUID: @Sendable (ModelInstallProgress) -> Void] = [:]
    private var fraction: Double = 0
    /// Zaehlt jeden Neuanfang desselben Bundles, siehe `ModelInstallProgress.attempt`.
    private var attempt = 0

    init(title: String) {
        self.title = title
    }

    var observerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observers.count
    }

    func add(_ observer: @Sendable @escaping (ModelInstallProgress) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        defer { lock.unlock() }
        observers[token] = observer
        return token
    }

    func remove(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        observers[token] = nil
    }

    /// Ein Nachzuegler soll nicht auf den naechsten Rueckruf warten muessen,
    /// um ueberhaupt etwas zu sehen.
    func deliverCurrent(to token: UUID) {
        lock.lock()
        let observer = observers[token]
        let snapshot = ModelInstallProgress(fraction: fraction, title: title, attempt: attempt)
        lock.unlock()
        observer?(snapshot)
    }

    func reset() {
        lock.lock()
        fraction = 0
        attempt += 1
        let current = Array(observers.values)
        lock.unlock()
        let snapshot = ModelInstallProgress(fraction: 0, title: title, attempt: attempt)
        for observer in current {
            observer(snapshot)
        }
    }

    /// Fortschritt geht nur vorwaerts: die Rueckrufe koennen sich ueberholen.
    /// Die Rueckrufe laufen ausserhalb des Schlosses, damit ein Beobachter,
    /// der zurueckruft, nicht blockiert.
    func report(_ newFraction: Double) {
        lock.lock()
        guard newFraction >= fraction else {
            lock.unlock()
            return
        }
        fraction = newFraction
        let current = Array(observers.values)
        let attempt = attempt
        lock.unlock()
        let snapshot = ModelInstallProgress(fraction: newFraction, title: title, attempt: attempt)
        for observer in current {
            observer(snapshot)
        }
    }
}

/// Gemessene Groessen dessen, was `defaultDownload` wirklich **anfordert** -
/// nicht dessen, was der Provider spaeter oeffnet. Der Zustimmungsdialog
/// spricht vom Herunterladen, also ist die uebertragene Menge die richtige
/// Bezugsgroesse.
///
/// Konvention: `du -sk` auf den geladenen Pfaden, gegengeprueft gegen die
/// Dateigroessen der HuggingFace-Baumabfrage (Belege im Bericht zu Aufgabe 3
/// und in Korrekturrunde 2). `du` rundet auf Bloecke auf und liegt damit um
/// Bruchteile eines Prozents ueber der uebertragenen Menge - vor einer
/// Einwilligung die unbedenkliche Richtung.
///
/// Eine Quelle fuer zwei Dinge: die Groesse im Zustimmungsdialog und die
/// Gewichte des Fortschritts. Eine geschaetzte Zahl waere hier eine falsche
/// Zahl vor einer Einwilligung.
enum DiarizationModelBytes {
    /// Sortformer_v2.1.mlmodelc, die Wahl fuer kurze Aufnahmen.
    static let sortformerShort = 240_594_944
    /// SortformerNvidiaHigh_v2.mlmodelc, die Wahl fuer lange Aufnahmen.
    static let sortformerLong = 255_283_200
    /// Was `downloadRepo(.diarizer, variant: nil)` anfordert, und das ist
    /// mehr als die zwei Modelle, die der Provider oeffnet:
    /// `pyannote_segmentation.mlmodelc` und `wespeaker_v2.mlmodelc`, dazu
    /// **jede `.json`- und `.txt`-Datei in der Repositoriumswurzel**.
    /// `DownloadUtils` nimmt die ueber die Dateiendung mit, am Modellfilter
    /// vorbei - hier `xvector-transform.json` (177_499),
    /// `plda-parameters.json` (89_416) und `config.json` (2), zusammen
    /// 266_917 Byte, die vorher fehlten.
    ///
    /// Nicht das ganze Repositorium: dessen 81 Dateien waeren 129_243_647
    /// Byte. Die uebrigen Verzeichnisse (Embedding, Segmentation, FBank,
    /// PldaRho, PLDA, wespeaker, wespeaker_int8, mlpackages, plots) passen
    /// auf kein Muster und werden nicht angefasst. Liegen sie trotzdem im
    /// Modellordner, stammen sie aus einem anderen Pfad - etwa dem
    /// Offline-Diarizer oder einem Benchmarklauf - und gehoeren nicht in
    /// diese Zahl.
    static let diarizer = 14_024_704

    /// Reihenfolge wie in `sortformerBundleNames()`.
    static let sortformerVariants = [sortformerShort, sortformerLong]
    static let total = sortformerShort + sortformerLong + diarizer
}

/// Die beiden Sortformer-Varianten, zwischen denen der Provider je nach
/// Aufnahmelaenge waehlt, in der Reihenfolge kurz vor lang.
func sortformerBundleNames() throws -> [String] {
    var names: [String] = []
    for config in [SortformerConfig.default, SortformerConfig.highContextV2] {
        guard let name = ModelNames.Sortformer.bundle(for: config) else {
            // Ein fehlender Bundlename heisst, dass FluidAudio die von uns
            // benutzte Konfiguration nicht mehr kennt. Das still zu
            // ueberspringen wuerde eine unvollstaendige Installation als
            // fertig ausweisen.
            throw DiarizationError.modelInstallationFailed(
                "FluidAudio has no Sortformer model bundle for a configuration Steno uses"
            )
        }
        guard !names.contains(name) else { continue }
        names.append(name)
    }
    return names
}

/// Alles, was ein Lauf braucht. Der Provider waehlt die Sortformer-Variante
/// erst zur Laufzeit nach Laenge der Aufnahme, deshalb muessen beide
/// Varianten vorliegen, bevor die Installation als vollstaendig gilt.
func requiredBundleURLs(baseDirectory: URL) throws -> [URL] {
    let sortformerDirectory = baseDirectory
        .appendingPathComponent(Repo.sortformer.folderName, isDirectory: true)
    let diarizerDirectory = baseDirectory
        .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    return try sortformerBundleNames().map {
        sortformerDirectory.appendingPathComponent($0, isDirectory: true)
    } + [
        diarizerDirectory.appendingPathComponent(
            ModelNames.Diarizer.segmentationFile,
            isDirectory: true
        ),
        diarizerDirectory.appendingPathComponent(
            ModelNames.Diarizer.embeddingFile,
            isDirectory: true
        ),
    ]
}

private func diarizationModelInstallationIsVerified(
    in baseDirectory: URL,
    manifest: ModelChecksumManifest,
    ignoringIncompleteMarker: Bool
) -> Bool {
    if !ignoringIncompleteMarker,
       diarizationModelInstallationIsIncomplete(in: baseDirectory)
    {
        return false
    }
    do {
        try manifest.verify(directory: baseDirectory)
        return try requiredBundleURLs(baseDirectory: baseDirectory).allSatisfy {
            modelBundleIsComplete($0, fileManager: .default)
        }
    } catch {
        return false
    }
}
