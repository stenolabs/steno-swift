import AVFAudio
import AVFoundation
import Foundation
import Observation
import Speech
import StenoDomain
import StenoExchange
import StenoLibrary
import StenoAudioCore
import StenoMacAudio
import StenoPipeline
import StenoTranscription

/// Zustand einer laufenden Aufnahme für die Oberfläche.
struct LiveTranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let speaker: String
    let text: String
}

private struct MicrophoneDiscoveryLoad: Sendable {
    let snapshot: MicrophoneDiscoverySnapshot
    let errorDescription: String?
}

enum AudioExportProgressStream {
    static func make() -> (
        updates: AsyncStream<StereoM4AExportProgress>,
        continuation: AsyncStream<StereoM4AExportProgress>.Continuation
    ) {
        let pair = AsyncStream.makeStream(
            of: StereoM4AExportProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        return (updates: pair.stream, continuation: pair.continuation)
    }
}

@MainActor
@Observable
final class AppModel {
    typealias StereoAudioExportPerformer = @MainActor (
        URL,
        URL,
        URL,
        @escaping @MainActor @Sendable (StereoM4AExportProgress) -> Void
    ) async throws -> Void

    private(set) var runtime: PipelineRuntime?
    private(set) var folderStore: FolderStore?
    private(set) var bootstrapError: String?
    private(set) var recoveredMeetingIDs: [MeetingID] = []

    // Der Dialog besitzt niemals die externe Dokument-URL. Sie lebt nur auf
    // dem Stack des vorbereitenden Tasks, bis StenoKit den privaten Snapshot
    // erzeugt hat. Danach bleiben hier ausschließlich Preview und Session-ID.
    var meetingTransferImportState: MeetingTransferImportFlowState?
    var wantsMeetingTransferImport = false
    @ObservationIgnored
    var meetingTransferClient: MeetingTransferImportClient? {
        didSet {
            if meetingTransferClient != nil {
                meetingTransferClientDidBecomeReady()
            }
        }
    }
    @ObservationIgnored
    var meetingTransferDetailClient: MeetingTransferDetailClient?
    @ObservationIgnored
    private let meetingTransferImportClientWasInjected: Bool
    @ObservationIgnored
    private let meetingTransferDetailClientWasInjected: Bool
    @ObservationIgnored
    var meetingTransferSecurityScope: MeetingTransferSecurityScopedResource
    @ObservationIgnored
    var meetingTransferOperation: Task<Void, Never>?
    @ObservationIgnored
    var meetingTransferOperationID = UUID()
    @ObservationIgnored
    var pendingMeetingTransferURL: URL?
    @ObservationIgnored
    var meetingTransferCancellationRequested = false
    @ObservationIgnored
    var ownedMeetingTransferSessionID: UUID?
    @ObservationIgnored
    var committedMeetingTransferResultAwaitingCleanup: MeetingTransferImportResult?
    @ObservationIgnored
    let meetingTransferSharing: MeetingTransferSharing
    @ObservationIgnored
    let meetingTransferTemporaryDirectory: @Sendable () -> URL
    @ObservationIgnored
    let stereoAudioExportPerformer: StereoAudioExportPerformer

    init(
        meetingTransferClient: MeetingTransferImportClient? = nil,
        meetingTransferDetailClient: MeetingTransferDetailClient? = nil,
        meetingTransferSecurityScope: MeetingTransferSecurityScopedResource = .live,
        meetingTransferSharing: MeetingTransferSharing = .shared,
        meetingTransferTemporaryDirectory: @escaping @Sendable () -> URL = {
            FileManager.default.temporaryDirectory
        },
        stereoAudioExportPerformer: StereoAudioExportPerformer? = nil
    ) {
        self.meetingTransferClient = meetingTransferClient
        self.meetingTransferDetailClient = meetingTransferDetailClient
        meetingTransferImportClientWasInjected = meetingTransferClient != nil
        meetingTransferDetailClientWasInjected = meetingTransferDetailClient != nil
        self.meetingTransferSecurityScope = meetingTransferSecurityScope
        self.meetingTransferSharing = meetingTransferSharing
        self.meetingTransferTemporaryDirectory = meetingTransferTemporaryDirectory
        self.stereoAudioExportPerformer = stereoAudioExportPerformer ?? {
            microphoneURL, systemURL, destinationURL, progress in
            let (updates, continuation) = AudioExportProgressStream.make()
            let worker = Task.detached {
                defer { continuation.finish() }
                try StereoM4AExporter().export(
                    microphoneURL: microphoneURL,
                    systemURL: systemURL,
                    destinationURL: destinationURL
                ) { continuation.yield($0) }
            }
            try await withTaskCancellationHandler {
                for await update in updates {
                    progress(update)
                }
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
        recoverMeetingTransferExportsAtStartup()
    }

    private(set) var meetings: [Meeting] = []
    private(set) var folders: [Folder] = []
    private(set) var meetingsWithAudio: Set<MeetingID> = []
    private static let meetingSelectionDefaultsKey = "steno.selection.meeting"
    // Die Liste besitzt genau einen Auswahlzustand. Ein berechneter
    // Einzelelementzugriff haelt bestehende Detail- und Aufnahmewege kompatibel.
    var selectedMeetingIDs: Set<MeetingID> = [] {
        didSet { persistSingleMeetingSelection() }
    }
    var selectedMeetingID: MeetingID? {
        get {
            MeetingSidebarSelectionPolicy.singleID(in: selectedMeetingIDs)
        }
        set {
            selectedMeetingIDs = newValue.map { Set([$0]) } ?? []
        }
    }

    /// Prüft, ob mindestens eine Originalspur des Meetings tatsächlich
    /// abspielbar ist. Die blosse Existenz der Datei genügt nicht: Alt-Importe
    /// bringen WebM/Opus mit, das macOS nicht öffnen kann - Hörproben und
    /// Diarisierung wären dann tote Knöpfe.
    func hasPlayableAudio(_ meetingID: MeetingID) async -> Bool {
        guard let runtime else { return false }
        let layout = await runtime.library.layout
        let assets = (try? await runtime.library.listMediaAssets(
            meetingID: meetingID
        )) ?? []
        for asset in assets {
            let url = layout.mediaFile(meetingID, fileName: asset.fileName)
            if await AudioAssetReadability.isReadable(url) {
                return true
            }
        }
        return false
    }

    /// Aktualisiert die Audio-Verfügbarkeit eines einzelnen Meetings, damit
    /// die Detailansicht nach Jobs oder Löschungen nicht auf einem veralteten
    /// Ja sitzenbleibt und tote Knöpfe anbietet.
    func refreshAudioAvailability(_ meetingID: MeetingID) async {
        if await hasPlayableAudio(meetingID) {
            meetingsWithAudio.insert(meetingID)
        } else {
            meetingsWithAudio.remove(meetingID)
        }
    }

    func restoreSelection(from meetings: [Meeting]) {
        guard selectedMeetingIDs.isEmpty,
              let raw = UserDefaults.standard.string(
                  forKey: Self.meetingSelectionDefaultsKey
              ),
              let uuid = UUID(uuidString: raw)
        else { return }
        let restored = MeetingID(rawValue: uuid)
        if meetings.contains(where: { $0.id == restored }) {
            selectedMeetingIDs = Set([restored])
        }
    }

    private func persistSingleMeetingSelection() {
        if let meetingID = MeetingSidebarSelectionPolicy.singleID(
            in: selectedMeetingIDs
        ) {
            UserDefaults.standard.set(
                meetingID.description,
                forKey: Self.meetingSelectionDefaultsKey
            )
        } else if selectedMeetingIDs.isEmpty {
            UserDefaults.standard.removeObject(
                forKey: Self.meetingSelectionDefaultsKey
            )
        }
    }

    // Aufnahmezustand
    private(set) var isRecording = false
    private(set) var recordingMeetingID: MeetingID?
    private(set) var recordingStartedAt: Date?
    private(set) var liveFinalLines: [LiveTranscriptLine] = []
    private(set) var liveVolatileText: [AudioTrack: String] = [:]
    private(set) var levels: [AudioTrack: AudioLevels] = [:]
    private(set) var microphoneStatus: RecordingTrackStatus?
    private(set) var recordingPermissions = RecordingAudioPermissionState()
    private(set) var isResolvingRecordingPermissions = false
    private var hasResolvedRecordingPermissions = false
    private static let systemAudioPermissionDefaultsKey =
        "steno.permissions.systemAudio.lastStatus"
    private static let systemAudioPermissionIdentityDefaultsKey =
        "steno.permissions.systemAudio.codeIdentity"
    private static let legacyProtectedMicrophoneUIDDefaultsKey =
        "steno.permissions.microphone.beforeSystemAudioProbe"
    @ObservationIgnored
    var notesSessions: [MeetingID: MeetingNotesEditingSession] = [:]
    /// Eine Meldung, die den Benutzer sicher erreicht, egal welche Ansicht
    /// gerade offen ist. Vorher hingen Aufnahme- und Importfehler an einer
    /// Eigenschaft, die nur die Aufnahmeansicht rendert - und die existiert
    /// genau dann nicht, wenn eine Aufnahme gar nicht erst startet.
    private(set) var notice: Notice?
    var audioExportActivity: AudioExportActivity?
    private var noticeDismissTask: Task<Void, Never>?
    var reviewError: String?
    /// Eigene Meldung fuer die Einstellungen: `notice` haengt am Hauptfenster
    /// und waere im Einstellungsfenster unsichtbar.
    var peopleError: String?

    struct Notice: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    /// Fehler bleiben stehen, bis der Benutzer sie bestaetigt - eine
    /// Bestaetigung nicht: Sie hat ihre Arbeit getan, sobald sie gelesen ist,
    /// und stuende sonst noch da, wenn man laengst woanders arbeitet.
    func report(_ text: String, isError: Bool = true) {
        let notice = Notice(text: text, isError: isError)
        self.notice = notice
        noticeDismissTask?.cancel()
        guard !isError else { return }
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            // Nur wegraeumen, wenn inzwischen keine neue Meldung kam.
            if self?.notice == notice { self?.notice = nil }
        }
    }


    func dismissNotice() {
        noticeDismissTask?.cancel()
        notice = nil
    }

    func dismissBootstrapError() {
        bootstrapError = nil
    }

    /// Der Dateiwaehler haengt am Fenster, das Menue liegt darueber. Das Flag
    /// ist die Bruecke; ContentView bindet den fileImporter daran.
    var wantsAudioImport = false

    func requestAudioImport() {
        guard !isRecording else { return }
        wantsAudioImport = true
    }

    /// Rohe Swift-Fehlerbeschreibungen gehören nicht in die Oberfläche.
    /// Der Klartext sagt, was nicht ging; das technische Detail hängt hinten
    /// dran, damit ein Fehlerbericht noch etwas hergibt.
    static func message(_ summary: String, _ error: Error) -> String {
        "\(summary) (\(error.localizedDescription))"
    }

    nonisolated static func pipelineStartupWarningMessage(
        for warnings: [PipelineStartupWarning]
    ) -> String? {
        guard !warnings.isEmpty else { return nil }
        if warnings.count == 1 {
            return "One imported meeting needs attention because its processing could not be resumed. Other meetings and recording remain available."
        }
        return "\(warnings.count) imported meetings need attention because their processing could not be resumed. Other meetings and recording remain available."
    }

    // Hörproben-Wiedergabe im Sprecher-Review
    private(set) var playingSampleID: Double?
    /// Dieselbe Wiedergabe, angestossen aus der Personenverwaltung. Zwei
    /// Kennungen, aber nur ein Abspieler: was hier laeuft, stoppt dort.
    private(set) var playingPersonSampleID: SpeakerEvidenceID?
    // Hoerproben werden als herausgeschnittene Kopie abgespielt: AVAudioPlayer
    // kann in Opus-in-CAF nicht springen (gemessen: stille Passage klang wie
    // eine laute), und AVAudioEngine fasst auf macOS die Eingangsseite an und
    // loest eine Mikrofon-Abfrage aus. Der Ausschnitt wird deshalb ueber
    // AVAudioFile framegenau gelesen und als Temp-Datei ab Position 0 gespielt.
    var samplePlayer: AVAudioPlayer?
    var samplePlaybackTask: Task<Void, Never>?
    var sampleClipURL: URL?

    func setPlayingSample(_ id: Double?) { playingSampleID = id }
    func setPlayingPersonSample(_ id: SpeakerEvidenceID?) {
        playingPersonSampleID = id
    }

    private var session: RecordingSession?
    private var liveTasks: [Task<TranscriptOutput?, Never>] = []
    private var levelTask: Task<Void, Never>?
    private var recordingStopTask: Task<Void, Never>?
    private var meetingChangesTask: Task<Void, Never>?
    private var recordingStartState = RecordingStartState()

    var isStartingRecording: Bool { recordingStartState.isStarting }

    private(set) var microphoneDiscovery = MicrophoneDiscoverySnapshot.empty
    private(set) var microphoneDiscoveryError: String?
    private(set) var recordingMicrophoneMode = MicrophoneSelectionStore().load()
    private var microphoneDiscoveryRequestID: UInt64 = 0

    var resolvedRecordingMicrophone: MicrophoneDevice? {
        try? RecordingMicrophoneSelection.resolve(
            mode: recordingMicrophoneMode,
            discovery: microphoneDiscovery
        )
    }

    @discardableResult
    func refreshMicrophoneDiscovery() async -> MicrophoneDiscoverySnapshot {
        microphoneDiscoveryRequestID &+= 1
        let requestID = microphoneDiscoveryRequestID
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let load = await Task.detached(priority: .userInitiated) {
            do {
                return MicrophoneDiscoveryLoad(
                    snapshot: try .current(
                        excludingBundleIdentifier: ownBundleIdentifier
                    ),
                    errorDescription: nil
                )
            } catch {
                return MicrophoneDiscoveryLoad(
                    snapshot: .empty,
                    errorDescription: error.localizedDescription
                )
            }
        }.value
        guard requestID == microphoneDiscoveryRequestID else {
            return load.snapshot
        }
        microphoneDiscovery = load.snapshot
        if let errorDescription = load.errorDescription {
            microphoneDiscoveryError = "Steno could not read the available microphones. (\(errorDescription))"
        } else {
            microphoneDiscoveryError = nil
        }
        return load.snapshot
    }

    func selectAutomaticMicrophone() {
        guard !isRecording, !isStartingRecording else { return }
        recordingMicrophoneMode = .automatic
        MicrophoneSelectionStore().save(recordingMicrophoneMode)
    }

    func selectMicrophone(_ device: MicrophoneDevice) {
        guard !isRecording, !isStartingRecording else { return }
        recordingMicrophoneMode = .manual(device)
        MicrophoneSelectionStore().save(recordingMicrophoneMode)
    }

    private let micProvider = SpeechAnalyzerProvider(channel: .microphone)
    private let systemProvider = SpeechAnalyzerProvider(channel: .system)

    // Transkriptionssprache: explizit wählbar und persistiert. Der System-
    // Locale-Default hat sich als Falle erwiesen (englisches macOS ->
    // deutsche Sprache englisch transkribiert).
    private static let languageDefaultsKey = "steno.transcription.language"
    private(set) var availableLocales: [Locale] = []
    /// Eine leere Liste heisst zweierlei: noch nicht gefragt, oder gefragt und
    /// nichts bekommen. Ohne diese Unterscheidung muesste die Oberflaeche
    /// raten, und der Wizard oeffnet bewusst vor `bootstrap`.
    private(set) var hasLoadedLocales = false
    private(set) var selectedLanguageID: String = UserDefaults.standard
        .string(forKey: AppModel.languageDefaultsKey)
        ?? Locale.current.identifier
    private var locale: Locale { Locale(identifier: selectedLanguageID) }

    private func provider(for track: AudioTrack) -> SpeechAnalyzerProvider {
        track == .microphone ? micProvider : systemProvider
    }

    // MARK: - Modelle

    /// Die Zustimmung lebt in der App, nicht in StenoKit: die Bibliothek
    /// kennt UserDefaults nicht und soll es nicht.
    let modelConsent = ModelConsent()
    private var modelCoordinator: ModelInstallationCoordinator?
    /// Arbeitsfaehigkeit je Sprache, nicht als einzelnes Ja: die
    /// Sprachassets haengen an der Locale, die Antwort kippt beim Wechsel.
    private(set) var modelReadiness: ModelReadiness?
    private(set) var modelInstallProgress: ModelInstallProgress?
    private(set) var isInstallingModels = false
    private(set) var modelError: String?
    /// Die zuletzt geprueften Modellbytes stimmten nicht mit den
    /// freigegebenen ueberein.
    ///
    /// Das braucht die Statuszeile, weil `readiness` nur prueft, ob Dateien
    /// **da** sind, nicht ob sie stimmen. Eine beschaedigte Datei liest sich
    /// dort als bereit, und dann stuende ein gruener Haken neben einer roten
    /// Fehlermeldung - genau so am 07.08.2026 auf dem Schirm gesehen.
    ///
    /// Ausschliesslich `ModelIntegrityError` setzt das Flag. Ein Netzfehler
    /// darf es nicht: `DownloadUtils.downloadRepo` fragt zuerst die
    /// Dateiliste ab, also scheitert ein Klick ohne Netz auch dann, wenn
    /// alles vollstaendig und in Ordnung ist.
    ///
    /// **Grenze:** der Wert liegt im Speicher. Nach einem Neustart steht die
    /// Zeile wieder auf "bereit", obwohl die Dateien noch beschaedigt sind.
    /// Die Alternative waere, bei jedem Start ein halbes Gigabyte zu hashen.
    private(set) var lastCheckFoundWrongBytes = false

    /// Ein Wortlaut fuer beide Stellen: die Ansicht zeigt ihn, solange der
    /// Knopf gesperrt ist, der Waechter setzt ihn, falls jemand die
    /// Installation an der Ansicht vorbei anstoesst.
    static let waitingForLocalesMessage = """
        Steno is still checking which languages this Mac can transcribe. \
        The models are downloaded for the language you pick, so installing \
        waits until that is known.
        """

    var modelBundles: [ModelBundleDescription] {
        modelCoordinator?.bundleDescriptions ?? []
    }

    var transcriptionLocale: Locale { locale }

    /// Wird beim Start und beim Oeffnen des Registers gerufen. Baut den
    /// Koordinator beim ersten Mal auf; das Pruefsummenmanifest kann fehlen,
    /// deshalb kann das scheitern.
    func refreshModelReadiness() async {
        if modelCoordinator == nil {
            do {
                modelCoordinator = try ModelInstallationCoordinator.standard(
                    modelCacheDirectory: Self.modelCacheURL()
                )
            } catch {
                modelError = Self.message("The model list could not be read.", error)
                return
            }
        }
        guard let modelCoordinator else { return }
        modelReadiness = await modelCoordinator.readiness(for: [locale])
    }

    /// Zustimmen und sofort installieren. Der Nutzer soll nach dem Klick
    /// nicht raten muessen, ob noch etwas passieren wird.
    func allowAndInstallModels() async {
        _ = await installModels(for: locale)
    }

    /// Prüft ausschließlich die lokal ausgewählte Importsprache. Ein Paket
    /// kann eine andere Sprache als die globale App-Einstellung tragen; diese
    /// darf den gepinnten Importjob weder überschreiben noch ersetzen.
    func meetingTransferModelsReady(for localeIdentifier: String) async -> Bool {
        guard let locale = meetingTransferLocale(identifier: localeIdentifier) else {
            return false
        }
        if modelCoordinator == nil {
            await refreshModelReadiness()
        }
        guard let modelCoordinator else { return false }
        let readiness = await modelCoordinator.readiness(for: [locale])
        return readiness.isReady(for: locale) && !lastCheckFoundWrongBytes
    }

    /// Der Klick im importierten Meeting ist die ausdrückliche Zustimmung zu
    /// den benannten Modellquellen. Erst danach darf ein Download beginnen.
    @discardableResult
    func installMeetingTransferModels(for localeIdentifier: String) async -> Bool {
        guard let locale = meetingTransferLocale(identifier: localeIdentifier) else {
            modelError = "This Mac cannot transcribe the selected language."
            return false
        }
        if await meetingTransferModelsReady(for: localeIdentifier) { return true }
        return await installModels(for: locale)
    }

    func meetingTransferLocale(identifier: String) -> Locale? {
        availableLocales.first {
            $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame
        }
    }

    private func installModels(for locale: Locale) async -> Bool {
        // Der Waechter steht vor dem ersten `await`: der Hauptaktor gibt an
        // jedem Suspendierungspunkt ab, zwei schnelle Klicks kaemen sonst
        // beide durch, und der erste Abschluss meldete Ruhe, waehrend der
        // zweite Lauf noch laedt.
        guard !isInstallingModels else { return false }
        // Zweiter Waechter, aus demselben Grund an derselben Stelle: die
        // Installation reserviert die Sprachassets fuer `locale`, und `locale`
        // steht erst fest, wenn `loadAvailableLocales` durch ist. Vorher zu
        // laden hiesse, ein halbes Gigabyte fuer die zufaellig voreingestellte
        // Sprache zu reservieren. Er steht hier und nicht nur am Knopf, weil
        // der Knopf nicht der einzige Weg bleiben muss.
        guard hasLoadedLocales else {
            modelError = Self.waitingForLocalesMessage
            return false
        }
        isInstallingModels = true
        defer {
            isInstallingModels = false
            modelInstallProgress = nil
        }
        modelError = nil
        // `lastCheckFoundWrongBytes` wird hier bewusst **nicht** geloescht.
        // Es wird nur von einer bestandenen Pruefung widerlegt, nicht von
        // einem neuen Versuch: scheitert der naechste Lauf schon vorher,
        // etwa ohne Netz am Dateilisting, wissen wir nichts Neues - die
        // beschaedigten Dateien liegen unveraendert da, und "Ready" waere
        // wieder die Luege, die dieser Zustand verhindern soll.
        modelInstallProgress = ModelInstallProgress(fraction: 0, title: "Preparing")
        await refreshModelReadiness()
        guard let modelCoordinator else { return false }
        modelConsent.grant(sources: modelSources())
        var installationCompleted = false
        do {
            try await modelCoordinator.installAll(
                for: locale,
                consentGranted: modelConsent.isGranted
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.applyInstallProgress(progress)
                }
            }
            installationCompleted = true
        } catch is CancellationError {
            // Widerruf: kein Fehlschlag, ueber den der Nutzer etwas lesen
            // muss - er hat ihn selbst ausgeloest.
        } catch let integrity as ModelIntegrityError {
            // Der einzige Fall, in dem alle Dateien da sind und trotzdem
            // nichts stimmt. Nur hier darf die Statuszeile ihre Bereitschaft
            // zuruecknehmen; ein Netzfehler sagt darueber nichts.
            if modelConsent.isGranted {
                modelError = Self.message("The models could not be installed.", integrity)
                lastCheckFoundWrongBytes = true
            }
        } catch {
            // Zweiter Filter fuer denselben Fall: ein Widerruf mitten im Lauf
            // laesst die Installer auch mit einem anderen Fehler
            // zurueckkommen, weil Apple und URLSession einen abgebrochenen
            // Transfer als Fehlschlag melden. Ist die Zustimmung weg, war es
            // der Nutzer selbst, und dann steht hier nichts Rotes.
            if modelConsent.isGranted {
                modelError = Self.message("The models could not be installed.", error)
            }
        }
        if installationCompleted {
            // Nur eine durchgelaufene Pruefung widerlegt den Befund. Nicht
            // an `modelError == nil` haengen: ein Widerruf laesst die
            // Meldung bewusst leer, obwohl `verify` nie durchkam.
            lastCheckFoundWrongBytes = false
        }
        await refreshModelReadiness()
        guard installationCompleted else { return false }
        let readiness = await modelCoordinator.readiness(for: [locale])
        return readiness.isReady(for: locale) && !lastCheckFoundWrongBytes
    }

    /// Widerruf stoppt kuenftige Downloads und fordert den Abbruch eines
    /// laufenden an: die Diarisierung bricht ueber URLSession wirklich ab,
    /// bei Apples Assetanfrage wird zusaetzlich deren `Progress` abgebrochen.
    /// Geloescht wird nichts: Apple-Assets liegen systemweit, und was schon
    /// da ist, soll weiter benutzbar bleiben.
    func revokeModelConsent() async {
        modelConsent.revoke()
        await modelCoordinator?.cancelAll()
        // `isInstallingModels` wird hier bewusst nicht zurueckgesetzt: der
        // laufende Lauf raeumt selbst auf, wenn er wirklich beendet ist. Ein
        // sofort wieder erscheinender Knopf waere die Behauptung, es laufe
        // nichts mehr, waehrend der Abbruch noch durchgereicht wird.
        await refreshModelReadiness()
    }

    /// Die Quellen in der Reihenfolge der Bundles, jede genau einmal. Sie
    /// werden mit der Zustimmung protokolliert, ein blosses Ja waere zu wenig.
    private func modelSources() -> [ModelSource] {
        var seen: Set<ModelSource> = []
        return modelBundles.map(\.source).filter { seen.insert($0).inserted }
    }

    /// Die Rueckrufe kommen aus fremden Kontexten und koennen sich beim
    /// Sprung auf den Hauptaktor ueberholen. Innerhalb eines Bundles laeuft
    /// der Balken deshalb nur vorwaerts.
    private func applyInstallProgress(_ progress: ModelInstallProgress) {
        guard progress.supersedes(modelInstallProgress) else { return }
        modelInstallProgress = progress
    }

    static func libraryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["STENO_LIBRARY_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return base.appendingPathComponent("Steno/Library", isDirectory: true)
    }

    /// Nur fuer Tests des Erstlaufs: lenkt Download und Provider auf ein
    /// Wegwerfverzeichnis, damit ein Rechner mit vorhandenen Modellen den
    /// Zustand eines frischen Rechners zeigen kann. Ohne die Variable bleibt
    /// alles, wie FluidAudio es vorgibt.
    ///
    /// Wie `STENO_LIBRARY_DIR` wird die Umgebung hier gelesen und nicht in
    /// StenoKit: die Kenntnis der Ablage gehoert in die App-Schicht.
    static func modelCacheURL() -> URL? {
        guard let override = ProcessInfo.processInfo.environment["STENO_MODEL_DIR"] else {
            return nil
        }
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    // MARK: - Start

    func bootstrap() async {
        guard runtime == nil else { return }
        do {
            let runtime = try await startPipeline(
                at: Self.libraryURL(),
                providers: [
                    .micTrack: micProvider,
                    .systemTrack: systemProvider,
                    // Importe haben keine Kanalsemantik; das System-Label
                    // "Andere" ist die bewusste M1-Vereinfachung, bis die
                    // Diarisierung (Meilenstein 3) echte Sprecher liefert.
                    .imported: systemProvider,
                ],
                modelCacheDirectory: Self.modelCacheURL(),
                textModelProviderResolver: { selection in
                    try TextModelSettings.resolveProvider(selection: selection)
                },
                locale: locale
            )
            self.runtime = runtime
            if !meetingTransferImportClientWasInjected {
                meetingTransferClient = MeetingTransferImportClient(
                    service: MeetingTransferImportService(
                        library: runtime.library,
                        jobStore: runtime.jobStore
                    )
                )
            }
            if !meetingTransferDetailClientWasInjected {
                meetingTransferDetailClient = MeetingTransferDetailClient(
                    library: runtime.library,
                    jobStore: runtime.jobStore
                )
            }
            do {
                folderStore = try FolderStore.open(layout: runtime.library.layout)
            } catch {
                folderStore = nil
                report(Self.message("The folders could not be loaded.", error))
            }
            let meetingChanges = await runtime.library.meetingChanges()
            meetingChangesTask?.cancel()
            meetingChangesTask = Task { [weak self] in
                for await meetingID in meetingChanges {
                    guard !Task.isCancelled else { return }
                    await self?.refreshMeeting(meetingID)
                }
            }
            // Nach dem Sweep: gestrandete Capture-Dateien harter Abstürze
            // als Originalspuren adoptieren und die Finalisierung einreihen.
            _ = try? await CaptureRecovery.run(
                library: runtime.library,
                jobStore: runtime.jobStore
            )
            // Einmalig: Ordnernamen aus dem Steno-Altimport in echte Ordner
            // überführen. Scheitert das, fehlen Ordner - die Meetings selbst
            // sind unberührt, deshalb bricht es den Start nicht ab.
            if let folderStore {
                _ = try? await LegacyFolderAdoption.run(
                    library: runtime.library,
                    folders: folderStore
                )
            }
            await refreshMeetings()
            if let warning = Self.pipelineStartupWarningMessage(
                for: runtime.startupWarnings
            ) {
                report(warning, isError: false)
            }
        } catch {
            bootstrapError = Self.message("The library could not be opened.", error)
        }
        await loadAvailableLocales()
        // Erst nach der Sprachwahl: die Arbeitsfaehigkeit haengt an der
        // Sprache, die dann wirklich eingestellt ist.
        await refreshModelReadiness()
    }

    private func loadAvailableLocales() async {
        let supported = await SpeechTranscriber.supportedLocales
        availableLocales = supported.sorted {
            localizedLanguageName($0) < localizedLanguageName($1)
        }
        // Erste Ausführung ohne gespeicherte Wahl: den System-Locale nur
        // übernehmen, wenn er wirklich unterstützt wird, sonst bewusst
        // nichts raten und den ersten unterstützten Eintrag zeigen.
        if !availableLocales.contains(where: {
            $0.identifier.caseInsensitiveCompare(selectedLanguageID) == .orderedSame
        }) {
            let fallback = LocaleResolver.select(
                requested: locale,
                supported: availableLocales
            )
            selectedLanguageID = fallback?.identifier
                ?? availableLocales.first?.identifier
                ?? selectedLanguageID
        }
        hasLoadedLocales = true
    }

    func localizedLanguageName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    /// Sprachwechsel startet die Pipeline neu, damit auch finale Läufe die
    /// neue Sprache nutzen. Während einer Aufnahme nicht erlaubt (die UI
    /// sperrt das zusätzlich).
    func setLanguage(_ identifier: String) async {
        guard !isRecording, identifier != selectedLanguageID else { return }
        guard meetingTransferImportState == nil else {
            report("Close the meeting import before changing the transcription language.")
            return
        }
        selectedLanguageID = identifier
        UserDefaults.standard.set(identifier, forKey: Self.languageDefaultsKey)
        if let runtime {
            meetingChangesTask?.cancel()
            meetingChangesTask = nil
            await runtime.coordinator.stop()
            self.runtime = nil
            folderStore = nil
            await bootstrap()
        }
    }

    func refreshMeetings() async {
        guard let runtime else { return }
        do {
            meetings = try await runtime.library.listMeetings()
                .sorted { $0.createdAt > $1.createdAt }
            if let folderStore {
                do {
                    folders = try await folderStore.listFolders()
                } catch {
                    report(Self.message("The folders could not be loaded.", error))
                }
            }
            var withAudio: Set<MeetingID> = []
            for meeting in meetings where await hasPlayableAudio(meeting.id) {
                withAudio.insert(meeting.id)
            }
            meetingsWithAudio = withAudio
            restoreSelection(from: meetings)
            selectedMeetingIDs = MeetingSidebarSelectionPolicy.pruned(
                selectedMeetingIDs,
                to: Set(meetings.map(\.id))
            )
        } catch {
            bootstrapError = Self.message("The meeting list could not be loaded.", error)
        }
    }

    private func refreshMeeting(_ meetingID: MeetingID) async {
        guard let runtime else { return }
        guard meetings.contains(where: { $0.id == meetingID }) else {
            await refreshMeetings()
            return
        }
        do {
            let latest = try await runtime.library.loadMeeting(meetingID)
            meetings = MeetingListSnapshot.replacing(latest, in: meetings)
        } catch {
            await refreshMeetings()
        }
    }

    // MARK: - Aufnahme

    func resolveRecordingPermissions(forceSystemAudioProbe: Bool = false) async {
        guard !isResolvingRecordingPermissions,
              !isRecording,
              !isStartingRecording,
              forceSystemAudioProbe || !hasResolvedRecordingPermissions else {
            return
        }
        isResolvingRecordingPermissions = true
        defer { isResolvingRecordingPermissions = false }
        let defaults = UserDefaults.standard
        let currentIdentity = CurrentCodeSigningIdentity.cacheKey()
        if !forceSystemAudioProbe,
           let cachedSystemStatus = RecordingPermissionCache.reusableStatus(
               rawStatus: defaults.string(
                   forKey: Self.systemAudioPermissionDefaultsKey
               ),
               cachedIdentity: defaults.string(
                   forKey: Self.systemAudioPermissionIdentityDefaultsKey
               ),
               currentIdentity: currentIdentity
           ) {
            recordingPermissions = RecordingAudioPermissionState(
                microphone: await AudioPermissions.requestMicrophone(),
                systemAudio: cachedSystemStatus
            )
        } else {
            recordingPermissions = await AudioPermissions.requestRecordingAccess()
            cacheSystemAudioPermission(recordingPermissions.systemAudio)
        }
        defaults.removeObject(
            forKey: Self.legacyProtectedMicrophoneUIDDefaultsKey
        )
        hasResolvedRecordingPermissions = true
        await refreshMicrophoneDiscovery()
    }

    private func cacheSystemAudioPermission(_ status: AudioPermissionStatus) {
        let defaults = UserDefaults.standard
        defaults.set(status.rawValue, forKey: Self.systemAudioPermissionDefaultsKey)
        if let identity = CurrentCodeSigningIdentity.cacheKey() {
            defaults.set(
                identity,
                forKey: Self.systemAudioPermissionIdentityDefaultsKey
            )
        } else {
            defaults.removeObject(
                forKey: Self.systemAudioPermissionIdentityDefaultsKey
            )
        }
    }

    func startRecording() async {
        guard let runtime,
              !isRecording,
              recordingStartState.begin() else { return }
        dismissNotice()

        let micStatus = await AudioPermissions.requestMicrophone()
        recordingPermissions = RecordingAudioPermissionState(
            microphone: micStatus,
            systemAudio: recordingPermissions.systemAudio,
            systemAudioError: recordingPermissions.systemAudioError
        )
        guard micStatus == .authorized else {
            _ = recordingStartState.fail()
            report("No microphone access. Allow it in System Settings under Privacy & Security.")
            return
        }

        do {
            let discovery = await refreshMicrophoneDiscovery()
            // Pin exactly the selected input when the user clicks Record.
            // The system-audio source starts first and may rebuild Core Audio's
            // graph, but it must not change which physical mic this recording
            // will accept. There is deliberately no default-device fallback.
            let recordingMicrophone = try RecordingMicrophoneSelection.resolve(
                mode: recordingMicrophoneMode,
                discovery: discovery
            )
            let title = Self.defaultMeetingTitle()
            let meeting = try await runtime.library.createMeeting(
                title: title,
                status: .recording
            )
            recordingStartState.didCreateMeeting(meeting.id)
            // Capture INNERHALB des Meeting-Ordners: nach kill -9 liegen die
            // Spuren in der Bibliothek und werden beim nächsten Start
            // adoptiert, statt in einem Temp-Verzeichnis zu stranden.
            let captureDirectory = await runtime.library.layout
                .captureDirectory(meeting.id)
            let session = RecordingSession(
                meetingID: meeting.id,
                library: runtime.library,
                outputDirectory: captureDirectory,
                microphoneSource: MicRecorder(
                    selectedDeviceUID: recordingMicrophone.uid
                ),
                systemAudioSource: SystemAudioRecorder()
            )
            try await session.start()

            recordingPermissions = RecordingAudioPermissionState(
                microphone: micStatus,
                systemAudio: .authorized
            )
            cacheSystemAudioPermission(.authorized)

            self.session = session
            microphoneStatus = await session.status(for: .microphone)
            recordingMeetingID = meeting.id
            // Die Auswahl folgt der Aufnahme: Sonst zeigt die Seitenleiste
            // ein anderes Meeting als das, in das gerade aufgenommen wird.
            selectedMeetingID = meeting.id
            recordingStartedAt = Date()
            isRecording = true
            liveFinalLines = []
            liveVolatileText = [:]

            for track in AudioTrack.allCases {
                let stream = try await session.liveAudioEvents(for: track)
                liveTasks.append(makeLiveTask(track: track, stream: stream))
            }
            startLevelPolling(session: session)
            await refreshMeetings()
            recordingStartState.succeed()
        } catch {
            if let audioError = error as? AudioRecordingError,
               audioError == .systemAudioPermissionDenied {
                recordingPermissions = RecordingAudioPermissionState(
                    microphone: micStatus,
                    systemAudio: .denied
                )
                cacheSystemAudioPermission(.denied)
            }
            let failedMeetingID = recordingStartState.fail()
            report(Self.message("The recording could not be started.", error))
            await abortRecordingCleanup()
            if let failedMeetingID {
                _ = try? await runtime.library.updateMeetingStatus(
                    failedMeetingID,
                    to: .interrupted
                )
            }
            await refreshMeetings()
        }
    }

    func stopRecording() async {
        if let recordingStopTask {
            await recordingStopTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStopRecording()
        }
        recordingStopTask = task
        await task.value
        recordingStopTask = nil
    }

    private func performStopRecording() async {
        guard let runtime, let session, let meetingID = recordingMeetingID else { return }
        do {
            levelTask?.cancel()
            levelTask = nil
            _ = try await session.stop()

            if let notesSession = notesSessions[meetingID] {
                await notesSession.flush()
                if let error = notesSession.errorMessage {
                    report("The notes could not be saved. (\(error))")
                }
            }

            // Live-Ergebnisse einsammeln und als vorläufige Revision sichern.
            var outputs: [TranscriptOutput] = []
            for task in liveTasks {
                if let output = await task.value {
                    outputs.append(output)
                }
            }
            liveTasks = []
            if outputs.contains(where: { !$0.blocks.isEmpty }) {
                let revision = TranscriptMapper.revision(
                    from: outputs,
                    meetingID: meetingID,
                    origin: .liveProvisional
                )
                _ = try await runtime.library.appendRevision(revision)
            }

            try await runtime.jobStore.enqueue(
                Job(kind: .finalASR, meetingID: meetingID)
            )
            selectedMeetingID = meetingID
        } catch {
            report(Self.message("The recording could not be stopped cleanly.", error))
        }
        self.session = nil
        isRecording = false
        recordingMeetingID = nil
        recordingStartedAt = nil
        microphoneStatus = nil
        liveVolatileText = [:]
        await refreshMeetings()
    }

    private func abortRecordingCleanup() async {
        levelTask?.cancel()
        levelTask = nil
        for task in liveTasks { task.cancel() }
        liveTasks = []
        if let session { _ = try? await session.stop() }
        session = nil
        isRecording = false
        recordingMeetingID = nil
        recordingStartedAt = nil
        microphoneStatus = nil
    }

    func setMicrophonePaused(_ paused: Bool) async {
        guard let session, isRecording else { return }
        await session.setPaused(paused, for: .microphone)
        microphoneStatus = await session.status(for: .microphone)
    }

    /// Verbindet den Live-Audiostrom einer Spur mit einer SpeechAnalyzer-
    /// Sitzung. Die Sitzung entsteht erst mit dem ersten Puffer, weil erst
    /// dieser das tatsächliche Format kennt.
    private func makeLiveTask(
        track: AudioTrack,
        stream: LiveAudioEventStream
    ) -> Task<TranscriptOutput?, Never> {
        let provider = provider(for: track)
        let locale = self.locale
        // Detached: der Puffer-Konsum darf nicht die MainActor-Isolation des
        // Aufrufers erben, sonst läuft die Audioverarbeitung über den Main
        // Thread.
        return Task.detached { [weak self] in
            var liveSession: (any LiveTranscriptionSession)?
            var eventTask: Task<Void, Never>?
            var segmentOffset: TimeInterval = 0
            var outputs: [TranscriptOutput] = []
            do {
                for await audioEvent in stream.stream {
                    switch audioEvent {
                    case let .buffer(owned):
                        let buffer = owned.buffer
                        if liveSession == nil {
                            let created = try await provider.liveSession(
                                format: AudioFormat(buffer.format),
                                locale: locale
                            )
                            let offset = segmentOffset
                            liveSession = created
                            eventTask = Task { [weak self] in
                                for await event in created.events {
                                    await self?.applyLiveEvent(
                                        event.shifted(by: offset),
                                        track: track
                                    )
                                }
                            }
                        }
                        await liveSession?.append(try AudioBuffer(copying: buffer))
                    case .gapStarted:
                        if let liveSession {
                            let output = try await liveSession.finish()
                            await eventTask?.value
                            outputs.append(output.shifted(by: segmentOffset))
                        }
                        liveSession = nil
                        eventTask = nil
                        await self?.clearLiveVolatileText(for: track)
                    case let .gapEnded(at):
                        segmentOffset = at
                    }
                }
                if let liveSession {
                    let output = try await liveSession.finish()
                    await eventTask?.value
                    outputs.append(output.shifted(by: segmentOffset))
                }
                guard !outputs.isEmpty else { return nil }
                return TranscriptOutput(
                    localeIdentifier: outputs[0].localeIdentifier,
                    blocks: outputs.flatMap(\.blocks).sorted { $0.start < $1.start }
                )
            } catch {
                await self?.reportLiveError(error, track: track)
                eventTask?.cancel()
                return nil
            }
        }
    }

    private func clearLiveVolatileText(for track: AudioTrack) {
        liveVolatileText[track] = ""
    }

    private func applyLiveEvent(_ event: TranscriptionEvent, track: AudioTrack) {
        switch event {
        case .volatile(let output):
            liveVolatileText[track] = output.blocks.map(\.text).joined(separator: " ")
        case .final(let output):
            liveVolatileText[track] = ""
            for block in output.blocks where !block.text.isEmpty {
                liveFinalLines.append(
                    LiveTranscriptLine(
                        // Ueber den einen Aufloeser, nicht roh: sonst stuende
                        // "Ich" aus den finalen Zeilen neben "Me" aus den
                        // volatilen, und das spaetere Bindungs-Paket haette
                        // eine Stelle, die es nicht erwischt.
                        speaker: ChannelLabel.speakerLabel(block.channel.speakerLabel),
                        text: block.text
                    )
                )
            }
        }
    }

    private func reportLiveError(_ error: any Error, track: AudioTrack) {
        // Live-Transkription ist ein Komfortpfad: ihr Ausfall beendet die
        // Aufnahme nicht, die Originalspuren laufen weiter.
        report("Live transcript (\(track.rawValue)) interrupted: \(error.localizedDescription)")
    }

    private func startLevelPolling(session: RecordingSession) {
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                if await session.state.isTerminal {
                    await self?.finishAfterSelfStop(session)
                    return
                }
                var updated: [AudioTrack: AudioLevels] = [:]
                for track in AudioTrack.allCases {
                    updated[track] = await session.levels(for: track)
                }
                let microphoneStatus = await session.status(for: .microphone)
                self?.levels = updated
                self?.applyMicrophoneStatus(microphoneStatus)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finishAfterSelfStop(_ observedSession: RecordingSession) async {
        guard session === observedSession, isRecording else { return }
        await stopRecording()
    }

    private func applyMicrophoneStatus(_ status: RecordingTrackStatus?) {
        let previous = microphoneStatus
        microphoneStatus = status
        guard let previous, let status else { return }
        let wasUnavailable = !previous.deviceAvailable || previous.sourceStalled
        let isUnavailable = !status.deviceAvailable || status.sourceStalled
        if !wasUnavailable, isUnavailable {
            let name = status.deviceName ?? "Microphone"
            let reason = status.deviceAvailable
                ? "stopped responding"
                : "disconnected"
            report(
                "\(name) \(reason). The microphone track is paused; system audio continues.",
                isError: false
            )
        } else if wasUnavailable,
                  !isUnavailable,
                  !status.userPaused {
            let name = status.deviceName ?? "Microphone"
            report(
                "\(name) reconnected. Microphone recording resumed.",
                isError: false
            )
        }
    }

    // MARK: - Import

    func importAudioFile(at url: URL) async {
        guard let runtime else { return }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            let duration = sampleRate > 0
                ? Double(file.length) / sampleRate
                : 0
            let meeting = try await runtime.library.createMeeting(
                title: url.deletingPathExtension().lastPathComponent,
                status: .processing
            )
            _ = try await runtime.library.registerMediaAsset(
                for: meeting.id,
                sourceURL: url,
                kind: .imported,
                sampleRate: sampleRate,
                duration: duration
            )
            try await runtime.jobStore.enqueue(
                Job(kind: .finalASR, meetingID: meeting.id)
            )
            selectedMeetingID = meeting.id
            await refreshMeetings()
        } catch let LibraryError.duplicateProvenance(_, existingMeetingID) {
            report("This file has already been imported.")
            selectedMeetingID = existingMeetingID
        } catch {
            report(Self.message("The import failed.", error))
        }
    }

    // MARK: - Detail

    func transcript(for meetingID: MeetingID) async -> TranscriptRevision? {
        guard let runtime else { return nil }
        return try? await runtime.library.loadCurrentRevision(meetingID: meetingID)
    }

    func speakerPresentationContext(
        for meetingID: MeetingID
    ) async -> SpeakerPresentationContext {
        guard let runtime else { return .empty }
        let assets = (try? await runtime.library.listMediaAssets(
            meetingID: meetingID
        )) ?? []
        return SpeakerPresentationContext(channelsByNamespace: Dictionary(
            uniqueKeysWithValues: assets.map {
                ($0.id.description, $0.kind.rawValue)
            }
        ))
    }

    /// Laengste Originalspur des Meetings. Mikro und System laufen parallel,
    /// deshalb das Maximum und nicht die Summe.
    func duration(for meetingID: MeetingID) async -> TimeInterval? {
        guard let runtime else { return nil }
        let assets = (try? await runtime.library.listMediaAssets(
            meetingID: meetingID
        )) ?? []
        return assets.map(\.duration).max()
    }

    func jobs(for meetingID: MeetingID) async -> [StenoDomain.Job] {
        guard let runtime else { return [] }
        let all = (try? await runtime.jobStore.list()) ?? []
        return all.filter { $0.meetingID == meetingID }
    }

    private static func defaultMeetingTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recording \(formatter.string(from: Date()))"
    }
}
