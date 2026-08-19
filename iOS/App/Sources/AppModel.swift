import Foundation
import Observation
import StenoAudioCore
import StenoDiarization
import StenoDomain
import StenoIntelligence
import StenoLibrary
import StenoPipeline
import StenoTranscription
import StenoiOSAudio

/// Owns the library and the pipeline for the whole process.
///
/// Process-wide rather than per scene: on iPad two windows of the app must
/// show the same library and the same running jobs, and closing one window
/// must not tear the pipeline down.
@MainActor
@Observable
final class AppModel {
    private(set) var meetings: [Meeting] = []
    private(set) var folders: [Folder] = []
    private(set) var startupFailure: String?
    private(set) var startupWarning: String?
    private(set) var isReady = false

    // Die externe Dokument-URL lebt nur im vorbereitenden Task, bis StenoKit
    // den privaten Snapshot angelegt hat. Danach speichert die App nur noch
    // Vorschau und Session-ID.
    var meetingTransferImportState: MeetingTransferImportFlowState?
    var meetingTransferSceneID: MeetingTransferSceneID?
    var selectedMeetingID: MeetingID?
    var selectedMeetingSceneID: MeetingTransferSceneID?
    @ObservationIgnored var meetingTransferClient: MeetingTransferImportClient?
    @ObservationIgnored var meetingTransferOperation: Task<Void, Never>?
    @ObservationIgnored var meetingTransferOperationID = UUID()
    @ObservationIgnored var pendingMeetingTransferURL: URL?
    @ObservationIgnored var pendingMeetingTransferSceneID: MeetingTransferSceneID?
    @ObservationIgnored var livingMeetingTransferSceneIDs: [
        MeetingTransferSceneID
    ] = []
    @ObservationIgnored var hasRegisteredMeetingTransferScene = false
    @ObservationIgnored var meetingTransferCancellationRequested = false
    @ObservationIgnored var ownedMeetingTransferSession: MeetingTransferOwnedSession?
    @ObservationIgnored var committedMeetingTransferResultAwaitingCleanup: MeetingTransferImportResult?
    @ObservationIgnored let meetingTransferSecurityScope: MeetingTransferSecurityScopedResource
    @ObservationIgnored private let meetingTransferClientWasInjected: Bool
    @ObservationIgnored private let meetingListLoader: (@MainActor @Sendable () async throws -> [Meeting])?

    /// One session controller for the process.
    ///
    /// `AVAudioSession` is shared state; two controllers would both observe
    /// and both activate it, and whichever deactivated last would silently win.
    let audioSession: AudioSessionController

    /// The running recording, owned by the process rather than by a view.
    ///
    /// Recording is a state, not a place. While the view owned it, navigating
    /// to a meeting tore the view down and with it the recording, which is the
    /// one thing this app must never do quietly. It also makes the iPad case
    /// work at all: two windows must show the same run, and closing one must
    /// not end it.
    let recording: RecordingModel

    /// Explicit, persisted transcription language. Never `Locale.current`.
    let language = TranscriptionLanguage()

    /// Apple speech assets for the explicitly selected language.
    let models: IOSModelInstallationState

    /// Optional local speaker separation bundle. Its consent and readiness
    /// are intentionally independent from Apple's speech assets.
    let diarizationModels: IOSModelInstallationState

    private(set) var runtime: PipelineRuntime?
    private var folderStore: FolderStore?
    /// Monotonically identifies the paired runtime and folder index.
    ///
    /// Folder work crosses actor boundaries. A task therefore must not publish
    /// data it read from a runtime that has since been detached or replaced.
    private var runtimeGeneration: UInt64 = 0
    private var storeGeneration: UInt64 = 0
    private var folderMutationGeneration: UInt64 = 0
    private var folderStateFailure: String?
    private var runtimeTransitionBarrierIsActive = false
    private var activeFolderOperationID: UInt64?
    private var nextFolderOperationID: UInt64 = 0
    private var folderOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingFolderReload = false
    private var coalescedFolderReloadTask: Task<Void, Never>?
    private var pendingRuntimeRestartAfterRecording = false
    private var bootstrapTask: Task<Void, Never>?
    private var notesSessions: MeetingNotesSessionPool?
    var meetingTransferExportRoots: Set<URL> = []
    private let runtimeChanges = RuntimeChangeSerializer()
    private let prepareLibraryBackup: @Sendable (URL, URL) throws -> Void
    private let refreshLanguage: @MainActor @Sendable (
        TranscriptionLanguage
    ) async -> Void
    private let textModelProviderResolver: TextModelProviderResolver
    private let pipelineStarter: @MainActor @Sendable (
        URL,
        Locale,
        @escaping TextModelProviderResolver
    ) async throws -> PipelineRuntime
    private let folderStoreOpener: @Sendable (LibraryLayout) throws -> FolderStore
    private let folderStoreDeletion: @Sendable (
        FolderStore,
        FolderID
    ) async throws -> FolderDeletionResult?
    private let meetingFolderSetter: @Sendable (
        Library,
        Set<MeetingID>,
        FolderID?
    ) async throws -> [Meeting]
    private let beforeMeetingFolderSet: @Sendable () async -> Void
    private let beforeRuntimeTransitionDetach: @Sendable () async -> Void
    private let afterRuntimeTransitionBarrierStarts: @Sendable () async -> Void
    private let afterCoalescedFolderReload: @Sendable () async -> Void
    private let beforeRecordingStart: @Sendable () async -> Void
    private let recordingStarter: @MainActor @Sendable (
        RecordingModel,
        Locale,
        Bool
    ) async -> Void
    private let didScheduleCoalescedFolderReload: @Sendable () -> Void
    let runtimeMeetingLoader: @Sendable (Library) async throws -> [Meeting]
    let folderListLoader: @Sendable (FolderStore) async throws -> [Folder]
    private let libraryURL: URL
    let meetingTransferTemporaryDirectory: @Sendable () -> URL

    init(
        prepareLibraryBackup: @escaping @Sendable (URL, URL) throws -> Void
            = LibraryBackupPolicy.prepareAndVerify,
        refreshLanguage: @escaping @MainActor @Sendable (
            TranscriptionLanguage
        ) async -> Void = { language in
            await language.refresh()
        },
        textModelProviderResolver: @escaping TextModelProviderResolver =
            TextModelSettings.resolveProvider,
        startPipeline: @escaping @MainActor @Sendable (
            URL,
            Locale,
            @escaping TextModelProviderResolver
        ) async throws -> PipelineRuntime = AppModel.startLivePipeline,
        folderStoreOpener: @escaping @Sendable (LibraryLayout) throws -> FolderStore
            = FolderStore.open,
        deleteFolder: @escaping @Sendable (
            FolderStore,
            FolderID
        ) async throws -> FolderDeletionResult? = { store, folderID in
            try store.deleteFolder(folderID)
        },
        setMeetingFolders: @escaping @Sendable (
            Library,
            Set<MeetingID>,
            FolderID?
        ) async throws -> [Meeting] = { library, meetingIDs, folderID in
            try library.setMeetingFolders(meetingIDs, folderID: folderID)
        },
        beforeMeetingFolderSet: @escaping @Sendable () async -> Void = {},
        beforeRuntimeTransitionDetach: @escaping @Sendable () async -> Void = {},
        afterRuntimeTransitionBarrierStarts: @escaping @Sendable () async -> Void = {},
        afterCoalescedFolderReload: @escaping @Sendable () async -> Void = {},
        beforeRecordingStart: @escaping @Sendable () async -> Void = {},
        recordingStarter: @escaping @MainActor @Sendable (
            RecordingModel,
            Locale,
            Bool
        ) async -> Void = { recording, locale, wasChosenExplicitly in
            await recording.start(
                locale: locale,
                languageWasChosenExplicitly: wasChosenExplicitly
            )
        },
        didScheduleCoalescedFolderReload: @escaping @Sendable () -> Void = {},
        loadMeetings: @escaping @Sendable (Library) async throws -> [Meeting] = {
            library in
            try library.listMeetings()
        },
        loadFolders: @escaping @Sendable (FolderStore) async throws -> [Folder] = {
            store in
            try store.listFolders()
        },
        meetingTransferTemporaryDirectory: @escaping @Sendable () -> URL = {
            FileManager.default.temporaryDirectory
        },
        meetingTransferClient: MeetingTransferImportClient? = nil,
        meetingTransferSecurityScope: MeetingTransferSecurityScopedResource = .live,
        meetingListLoader: (@MainActor @Sendable () async throws -> [Meeting])? = nil,
        speechModels: IOSModelInstallationState? = nil,
        diarizationModels: IOSModelInstallationState? = nil,
        libraryURL: URL = LibraryLocation.libraryURL()
    ) {
        let session = AudioSessionController()
        audioSession = session
        recording = RecordingModel(session: session)
        models = speechModels ?? IOSModelInstallationState(
            coordinator: ModelInstallationCoordinator(installers: [
                SpeechAssetInstaller(assets: SystemSpeechAssets()),
            ]),
            consent: .speech()
        )
        self.diarizationModels = diarizationModels ?? Self.makeDiarizationModelState()
        self.libraryURL = libraryURL
        self.prepareLibraryBackup = prepareLibraryBackup
        self.refreshLanguage = refreshLanguage
        self.textModelProviderResolver = textModelProviderResolver
        pipelineStarter = startPipeline
        self.folderStoreOpener = folderStoreOpener
        folderStoreDeletion = deleteFolder
        meetingFolderSetter = setMeetingFolders
        self.beforeMeetingFolderSet = beforeMeetingFolderSet
        self.beforeRuntimeTransitionDetach = beforeRuntimeTransitionDetach
        self.afterRuntimeTransitionBarrierStarts = afterRuntimeTransitionBarrierStarts
        self.afterCoalescedFolderReload = afterCoalescedFolderReload
        self.beforeRecordingStart = beforeRecordingStart
        self.recordingStarter = recordingStarter
        self.didScheduleCoalescedFolderReload = didScheduleCoalescedFolderReload
        runtimeMeetingLoader = loadMeetings
        folderListLoader = loadFolders
        self.meetingTransferTemporaryDirectory = meetingTransferTemporaryDirectory
        self.meetingTransferClient = meetingTransferClient
        meetingTransferClientWasInjected = meetingTransferClient != nil
        self.meetingTransferSecurityScope = meetingTransferSecurityScope
        self.meetingListLoader = meetingListLoader
        recording.didBecomeIdle = { [weak self] in
            Task { @MainActor in
                await self?.recordingDidBecomeIdle()
            }
        }
    }

    /// Verifies the local backup boundary, then opens the library and starts
    /// the pipeline.
    ///
    /// Same `startPipeline` as the Mac, including the recovery sweep and the
    /// job recovery, gefolgt von `CaptureRecovery.run`. Beides ist noetig:
    /// der Sweep markiert ein Meeting nur als unterbrochen, erst
    /// `CaptureRecovery` adoptiert die unregistrierten CAF-Dateien als
    /// Originalspuren und reiht den Final-ASR-Lauf ein. Ohne den zweiten
    /// Schritt ueberlebte die Aufnahme den Absturz auf der Platte, blieb
    /// aber unsichtbar - und genau das behauptete dieser Kommentar vorher
    /// bereits, ohne dass der Aufruf existierte.
    ///
    /// Models are no longer downloaded by the providers themselves. iOS uses
    /// separate `ModelInstallationCoordinator` instances and consent records
    /// for Apple speech assets and optional speaker separation. A missing
    /// model never blocks library startup or recording.
    func bootstrap() async {
        // Scene lifecycle calls must not enter between a configuration change
        // and its ordered restart. Model installation likewise owns this gap
        // until it can requeue failed work against a stopped coordinator.
        guard !models.isInstalling,
              !diarizationModels.isInstalling,
              !runtimeChanges.isRunning else { return }
        await startOrJoinBootstrap()
    }

    private func startOrJoinBootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard runtime == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        defer { bootstrapTask = nil }
        startupWarning = nil
        await refreshLanguage(language)
        do {
            let validationRoot = LibraryLayout(root: libraryURL).transferValidationRoot
            try prepareLibraryBackup(libraryURL, validationRoot)
            let runtime = try await pipelineStarter(
                libraryURL,
                language.locale,
                textModelProviderResolver
            )
            self.runtime = runtime
            let folderStoreFailure: String?
            do {
                folderStore = try folderStoreOpener(runtime.library.layout)
                folders = []
                folderStoreFailure = nil
            } catch {
                folderStore = nil
                folders = []
                folderStoreFailure = "The folders could not be loaded. (\(error.localizedDescription))"
            }
            advanceRuntimeGeneration()
            advanceStoreGeneration()
            folderStateFailure = folderStoreFailure
            if !meetingTransferClientWasInjected {
                meetingTransferClient = MeetingTransferImportClient(
                    service: MeetingTransferImportService(
                        library: runtime.library,
                        jobStore: runtime.jobStore
                    )
                )
            }
            meetingTransferClientDidBecomeReady()
            let notesSessions = self.notesSessions ?? MeetingNotesSessionPool(
                store: MeetingNotesStore(layout: runtime.library.layout)
            )
            self.notesSessions = notesSessions
            // Gestrandete Capture-Dateien eines harten Abbruchs als
            // Originalspuren adoptieren, wie auf dem Mac
            // (`App/Sources/AppModel.swift`). Scheitert es, fehlen die
            // geretteten Spuren - die Bibliothek selbst ist unberuehrt,
            // deshalb bricht es den Start nicht ab.
            _ = try? await CaptureRecovery.run(
                library: runtime.library,
                jobStore: runtime.jobStore
            )
            // Without this the record button has nowhere to write, so it stays
            // disabled rather than producing an audio file nobody can find.
            recording.attach(runtime: runtime, notesSessions: notesSessions)
            if let snapshot = runtimeSnapshot() {
                _ = await reloadMeetings(for: snapshot, operation: nil)
            }
            isReady = true
            if let folderStoreFailure { startupFailure = folderStoreFailure }
            startupWarning = Self.pipelineStartupWarningMessage(
                for: runtime.startupWarnings
            )
            await models.refresh(for: language.locale)
            await diarizationModels.refresh(for: language.locale)
            scheduleCoalescedFolderReloadIfPossible()
        } catch {
            startupFailure = error.localizedDescription
        }
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

    /// Replaces the process runtime after a language or model change.
    ///
    /// Detaching both owners is one synchronous main-actor operation and
    /// happens before stopping the old coordinator or starting the new
    /// bootstrap. If capture is active, the old runtime remains untouched so
    /// its normal stop/finalization path can preserve the recording.
    func restartPipelineAfterConfigurationChange() async {
        await invalidateAndWaitForFolderOperation()
        defer { endRuntimeTransitionBarrier() }
        guard let detached = detachRuntimeIfIdle() else {
            if recording.isActive {
                pendingRuntimeRestartAfterRecording = true
            }
            return
        }
        if let runtime = detached.runtime {
            await runtime.coordinator.stop()
        }
        await startOrJoinBootstrap()
    }

    /// Sprachwechsel, wie auf dem Mac (`App/Sources/AppModel.swift:465`).
    ///
    /// Der Koordinator haelt seine Locale unveraenderlich aus `bootstrap()`.
    /// Ohne den Neustart nutzte die naechste Live-Transkription die neue
    /// Sprache, der danach eingereihte Final-ASR-Lauf aber bis zum
    /// App-Neustart die alte - und der finale Lauf ist der, der zaehlt.
    ///
    /// Waehrend einer Aufnahme gesperrt: den Koordinator unter einer
    /// laufenden Aufnahme wegzuziehen, ist genau das, was diese App nie
    /// still tun darf.
    func setLanguage(_ identifier: String) async {
        guard canChangeLanguage else { return }
        // Derselbe Wert zaehlt, solange noch niemand bestaetigt hat: auf
        // bestehenden Installationen steht in `selectedID` bereits die
        // frueher abgeleitete Sprache, und der Picker zeigt genau sie an.
        // Wuerde die erneute Auswahl hier verworfen, liesse sie sich nie
        // bestaetigen, ohne vorher auf eine andere Sprache zu wechseln.
        let isConfirmation = !language.wasChosenExplicitly
        guard identifier != language.selectedID || isConfirmation else { return }
        await runtimeChanges.run { [weak self] in
            await self?.performLanguageSwitch(identifier)
        }
    }

    private func performLanguageSwitch(_ identifier: String) async {
        // The outer guard may wait behind another serialized mutation. Check
        // the bootstrap lock again before persisting the language choice.
        guard bootstrapTask == nil,
              !recording.isActive,
              !models.isInstalling,
              !diarizationModels.isInstalling else { return }
        // Nach dem Warten noch einmal pruefen, mit derselben Regel wie
        // draussen. Zwei gleiche Auswahlen koennen sich einreihen, bevor die
        // erste `selectedID` gesetzt hat; ohne diese Zeile stoppte und
        // startete die zweite den Koordinator ein zweites Mal, ohne dass
        // sich etwas geaendert haette.
        guard identifier != language.selectedID || !language.wasChosenExplicitly else {
            return
        }
        language.select(identifier)
        await restartPipelineAfterConfigurationChange()
        await models.refresh(for: language.locale)
    }

    /// Ob ein Sprachwechsel gerade moeglich ist. Die Oberflaeche soll den
    /// Grund zeigen koennen, statt einen wirkungslosen Regler anzubieten.
    var canChangeLanguage: Bool {
        bootstrapTask == nil
            && !recording.isActive
            && !models.isInstalling
            && !diarizationModels.isInstalling
            && !runtimeChanges.isRunning
            && meetingTransferImportState == nil
    }

    var canInstallSpeechModel: Bool {
        bootstrapTask == nil
            && !recording.isActive
            && !models.isInstalling
            && !diarizationModels.isInstalling
            && !runtimeChanges.isRunning
            && meetingTransferImportState == nil
    }

    func allowAndInstallSpeechModel() async {
        // Do not grant consent or start an installer while a pipeline with an
        // already captured configuration is still being constructed.
        guard canInstallSpeechModel else { return }
        let locale = language.locale
        let installed = await models.allowAndInstall(
            for: locale,
            recordingIsActive: recording.isActive
        )
        guard installed else { return }

        await runtimeChanges.run { [weak self] in
            guard let self else { return }
            // `isInstalling` becomes false immediately before the installer
            // returns. If a new scene entered that narrow gap, finish its
            // bootstrap and then perform this requested restart in order.
            if let bootstrapTask = self.bootstrapTask {
                await bootstrapTask.value
            }
            await self.invalidateAndWaitForFolderOperation()
            defer { self.endRuntimeTransitionBarrier() }
            guard let detached = self.detachRuntimeIfIdle() else { return }
            guard let runtime = detached.runtime else {
                await self.startOrJoinBootstrap()
                return
            }
            await runtime.coordinator.stop()
            let retryFailure: String?
            do {
                _ = try await MissingSpeechModelJobRetrier.requeue(
                    jobStore: runtime.jobStore,
                    locale: locale
                )
                retryFailure = nil
            } catch {
                retryFailure = error.localizedDescription
            }
            await self.startOrJoinBootstrap()
            if let retryFailure {
                self.startupFailure = retryFailure
            }
        }
    }

    private struct DetachedRuntime {
        let runtime: PipelineRuntime?
    }

    private func detachRuntimeIfIdle() -> DetachedRuntime? {
        guard recording.detachRuntimeIfIdle() else { return nil }
        let detached = DetachedRuntime(runtime: runtime)
        runtime = nil
        folderStore = nil
        advanceRuntimeGeneration()
        advanceStoreGeneration()
        folderStateFailure = nil
        folders = []
        isReady = false
        return detached
    }

    func revokeSpeechModelConsent() async {
        await models.revoke()
    }

    var canInstallDiarizationModels: Bool {
        bootstrapTask == nil
            && !recording.isActive
            && !models.isInstalling
            && !diarizationModels.isInstalling
            && !runtimeChanges.isRunning
            && meetingTransferImportState == nil
    }

    var canStartRecording: Bool {
        recording.canRecord
            && !diarizationModels.isInstalling
            && !runtimeTransitionBarrierIsActive
            && !runtimeChanges.isRunning
            && bootstrapTask == nil
    }

    @discardableResult
    func startRecording() async -> Bool {
        guard canStartRecording else { return false }
        await beforeRecordingStart()
        guard canStartRecording else { return false }
        let selection = language.recordingSelection
        await recordingStarter(
            recording,
            selection.locale,
            selection.effectiveLocaleWasChosenExplicitly
        )
        return true
    }

    func recordingDidBecomeIdle() async {
        guard pendingRuntimeRestartAfterRecording, !recording.isActive else { return }
        pendingRuntimeRestartAfterRecording = false
        await restartPipelineAfterConfigurationChange()
    }

    func stopRecording() async {
        await recording.stop()
        await reloadMeetings()
        await recordingDidBecomeIdle()
    }

    func allowAndInstallDiarizationModels() async {
        guard canInstallDiarizationModels else { return }
        let installed = await diarizationModels.allowAndInstall(
            for: language.locale,
            recordingIsActive: recording.isActive
        )
        guard installed else { return }

        await runtimeChanges.run { [weak self] in
            guard let self else { return }
            if let bootstrapTask = self.bootstrapTask {
                await bootstrapTask.value
            }
            await self.invalidateAndWaitForFolderOperation()
            defer { self.endRuntimeTransitionBarrier() }
            guard let detached = self.detachRuntimeIfIdle() else { return }
            guard let runtime = detached.runtime else {
                await self.startOrJoinBootstrap()
                return
            }
            await runtime.coordinator.stop()
            let retryFailure: String?
            do {
                _ = try await MissingDiarizationModelJobRetrier.requeue(
                    jobStore: runtime.jobStore
                )
                retryFailure = nil
            } catch {
                retryFailure = error.localizedDescription
            }
            await self.startOrJoinBootstrap()
            if let retryFailure {
                self.startupFailure = retryFailure
            }
        }
    }

    func revokeDiarizationModelConsent() async {
        await diarizationModels.revoke()
    }

    func cancelDiarizationModelInstallForBackground() async {
        guard diarizationModels.isInstalling else { return }
        await diarizationModels.cancelInstall()
    }

    func reloadMeetings() async {
        guard activeFolderOperationID == nil, !runtimeTransitionBarrierIsActive else {
            requestCoalescedFolderReload()
            return
        }
        if let meetingListLoader {
            do {
                meetings = try await meetingListLoader()
                if folderStateFailure == nil { startupFailure = nil }
            } catch {
                if folderStateFailure == nil { startupFailure = error.localizedDescription }
            }
            return
        }
        guard let snapshot = runtimeSnapshot() else { return }
        _ = await reloadMeetings(for: snapshot, operation: nil)
    }

    struct RuntimeFolderSnapshot {
        let generation: UInt64
        let storeGeneration: UInt64
        let folderMutationGeneration: UInt64
        let runtime: PipelineRuntime
        let folderStore: FolderStore?
    }

    struct FolderOperationToken: Equatable {
        let id: UInt64
    }

    enum FolderReloadResult: Equatable {
        case published
        case foldersUnavailable(String)
        case meetingsUnavailable(String)
        case stale
    }

    func runtimeSnapshot() -> RuntimeFolderSnapshot? {
        guard let runtime else { return nil }
        return RuntimeFolderSnapshot(
            generation: runtimeGeneration,
            storeGeneration: storeGeneration,
            folderMutationGeneration: folderMutationGeneration,
            runtime: runtime,
            folderStore: folderStore
        )
    }

    func folderOperationSnapshot() throws -> RuntimeFolderSnapshot {
        guard let snapshot = runtimeSnapshot() else {
            throw AppModelFolderError.runtimeUnavailable
        }
        guard snapshot.folderStore != nil else {
            throw AppModelFolderError.storeUnavailable
        }
        return snapshot
    }

    func isCurrent(
        _ snapshot: RuntimeFolderSnapshot,
        operation: FolderOperationToken? = nil
    ) -> Bool {
        guard runtimeGeneration == snapshot.generation,
              storeGeneration == snapshot.storeGeneration,
              folderMutationGeneration == snapshot.folderMutationGeneration else { return false }
        guard let operation else { return activeFolderOperationID == nil }
        return activeFolderOperationID == operation.id
    }

    private func advanceRuntimeGeneration() {
        runtimeGeneration &+= 1
    }

    private func advanceStoreGeneration() {
        storeGeneration &+= 1
    }

    private func advanceFolderMutationGeneration() {
        folderMutationGeneration &+= 1
    }

    /// Reads both indexes through one runtime snapshot and publishes them only
    /// if that exact snapshot still owns the screen after every await.
    @discardableResult
    func reloadMeetings(
        for snapshot: RuntimeFolderSnapshot,
        operation: FolderOperationToken?
    ) async -> FolderReloadResult {
        let loadedMeetings: [Meeting]
        do {
            loadedMeetings = try await runtimeMeetingLoader(snapshot.runtime.library)
        } catch {
            guard isCurrent(snapshot, operation: operation) else {
                return staleReloadResult(for: operation)
            }
            let message = error.localizedDescription
            if folderStateFailure == nil { startupFailure = message }
            return .meetingsUnavailable(message)
        }

        guard isCurrent(snapshot, operation: operation) else {
            return staleReloadResult(for: operation)
        }
        guard let store = snapshot.folderStore else {
            meetings = loadedMeetings
            folders = []
            let message = folderStateFailure
                ?? "The folders could not be loaded. (The folder index is not available.)"
            reportFolderAvailabilityFailure(message)
            return .foldersUnavailable(message)
        }

        do {
            let loadedFolders = try await folderListLoader(store)
            guard isCurrent(snapshot, operation: operation) else {
                return staleReloadResult(for: operation)
            }
            meetings = loadedMeetings
            folders = loadedFolders
            folderStateFailure = nil
            startupFailure = nil
            return .published
        } catch {
            guard isCurrent(snapshot, operation: operation) else {
                return staleReloadResult(for: operation)
            }
            meetings = loadedMeetings
            folders = []
            let message = "The folders could not be loaded. (\(error.localizedDescription))"
            reportFolderAvailabilityFailure(message)
            return .foldersUnavailable(message)
        }
    }

    /// Use this only after a failed folder recovery. The meeting index remains
    /// independently readable, whereas retaining a former folder tree would
    /// show IDs that may no longer exist on disk.
    @discardableResult
    func publishReadableMeetingsWithUnavailableFolders(
        for snapshot: RuntimeFolderSnapshot,
        failure: String,
        operation: FolderOperationToken
    ) async -> FolderReloadResult {
        do {
            let loadedMeetings = try await runtimeMeetingLoader(snapshot.runtime.library)
            guard isCurrent(snapshot, operation: operation) else { return .stale }
            meetings = loadedMeetings
            folders = []
            reportFolderAvailabilityFailure(failure)
            return .foldersUnavailable(failure)
        } catch {
            guard isCurrent(snapshot, operation: operation) else { return .stale }
            folders = []
            let message = "\(failure) The meetings could not be reloaded. (\(error.localizedDescription))"
            reportFolderAvailabilityFailure(message)
            return .meetingsUnavailable(message)
        }
    }

    func beginFolderOperation() -> FolderOperationToken? {
        guard !runtimeTransitionBarrierIsActive else {
            reportFolderFailure(
                "The folder action could not start.",
                AppModelFolderError.runtimeTransitionInProgress
            )
            return nil
        }
        guard activeFolderOperationID == nil else {
            reportFolderFailure(
                "The folder action could not start.",
                AppModelFolderError.operationInProgress
            )
            return nil
        }
        nextFolderOperationID &+= 1
        advanceFolderMutationGeneration()
        let token = FolderOperationToken(id: nextFolderOperationID)
        activeFolderOperationID = token.id
        return token
    }

    func endFolderOperation(_ operation: FolderOperationToken) {
        guard activeFolderOperationID == operation.id else { return }
        activeFolderOperationID = nil
        advanceFolderMutationGeneration()
        let waiters = folderOperationWaiters
        folderOperationWaiters = []
        for waiter in waiters { waiter.resume() }
        scheduleCoalescedFolderReloadIfPossible()
    }

    func setMeetingFolders(
        _ meetingIDs: Set<MeetingID>,
        to folderID: FolderID?,
        in snapshot: RuntimeFolderSnapshot,
        operation: FolderOperationToken
    ) async throws -> [Meeting] {
        await beforeMeetingFolderSet()
        guard isCurrent(snapshot, operation: operation) else {
            throw AppModelFolderError.operationInvalidated
        }
        return try await meetingFolderSetter(snapshot.runtime.library, meetingIDs, folderID)
    }

    func deleteFolderIndex(
        _ folderID: FolderID,
        from store: FolderStore
    ) async throws -> FolderDeletionResult? {
        try await folderStoreDeletion(store, folderID)
    }

    func freshFolderStore(for snapshot: RuntimeFolderSnapshot) throws -> FolderStore {
        try folderStoreOpener(snapshot.runtime.library.layout)
    }

    func adoptFolderStore(
        _ store: FolderStore,
        for snapshot: RuntimeFolderSnapshot,
        operation: FolderOperationToken
    ) -> RuntimeFolderSnapshot? {
        guard isCurrent(snapshot, operation: operation) else { return nil }
        folderStore = store
        advanceStoreGeneration()
        return RuntimeFolderSnapshot(
            generation: runtimeGeneration,
            storeGeneration: storeGeneration,
            folderMutationGeneration: folderMutationGeneration,
            runtime: snapshot.runtime,
            folderStore: store
        )
    }

    private func invalidateAndWaitForFolderOperation() async {
        runtimeTransitionBarrierIsActive = true
        await afterRuntimeTransitionBarrierStarts()
        if activeFolderOperationID != nil {
            await withCheckedContinuation { continuation in
                folderOperationWaiters.append(continuation)
            }
        }
        await beforeRuntimeTransitionDetach()
    }

    private func endRuntimeTransitionBarrier() {
        runtimeTransitionBarrierIsActive = false
        scheduleCoalescedFolderReloadIfPossible()
    }

    private func staleReloadResult(
        for operation: FolderOperationToken?
    ) -> FolderReloadResult {
        if operation == nil { requestCoalescedFolderReload() }
        return .stale
    }

    private func requestCoalescedFolderReload() {
        pendingFolderReload = true
        scheduleCoalescedFolderReloadIfPossible()
    }

    private func scheduleCoalescedFolderReloadIfPossible() {
        guard pendingFolderReload,
              activeFolderOperationID == nil,
              !runtimeTransitionBarrierIsActive,
              runtime != nil,
              coalescedFolderReloadTask == nil else { return }
        didScheduleCoalescedFolderReload()
        coalescedFolderReloadTask = Task { @MainActor [weak self] in
            await self?.performCoalescedFolderReload()
        }
    }

    private func performCoalescedFolderReload() async {
        defer {
            coalescedFolderReloadTask = nil
            scheduleCoalescedFolderReloadIfPossible()
        }
        guard pendingFolderReload,
              activeFolderOperationID == nil,
              !runtimeTransitionBarrierIsActive,
              runtime != nil else { return }
        pendingFolderReload = false
        await reloadMeetings()
        await afterCoalescedFolderReload()
    }

    func reportFolderFailure(_ summary: String, _ error: Error) {
        startupFailure = "\(summary) (\(error.localizedDescription))"
    }

    func reportFolderAvailabilityFailure(_ message: String) {
        folderStateFailure = message
        startupFailure = message
    }

    func reportFolderStateReloaded() {
        startupFailure = "The folder no longer exists and the current library state was reloaded."
    }

    func reportFolderPartialRecoveryFailure(
        _ restorationError: Error,
        reloadResult: FolderReloadResult
    ) {
        let context: String
        switch reloadResult {
        case let .foldersUnavailable(message), let .meetingsUnavailable(message):
            context = message
        case .published, .stale:
            context = "The current folder index was reloaded."
        }
        reportFolderAvailabilityFailure(
            "\(context) The folder could not be deleted and some meeting assignments could not be restored. \(restorationError.localizedDescription)"
        )
    }

    /// The request is retained until the normal split/compact route can find
    /// the meeting in the list it renders.
    func consumeSelectedMeetingIDIfAvailable(
        for sceneID: MeetingTransferSceneID
    ) -> MeetingID? {
        guard let selectedMeetingID,
              selectedMeetingSceneID == sceneID,
              isLivingMeetingTransferScene(sceneID),
              meetings.contains(where: { $0.id == selectedMeetingID }) else {
            return nil
        }
        self.selectedMeetingID = nil
        selectedMeetingSceneID = nil
        return selectedMeetingID
    }

    func isLivingMeetingTransferScene(_ sceneID: MeetingTransferSceneID) -> Bool {
        livingMeetingTransferSceneIDs.contains(sceneID)
    }

    func consumeSelectedMeetingIDIfAvailable() -> MeetingID? {
        guard let selectedMeetingSceneID else { return nil }
        return consumeSelectedMeetingIDIfAvailable(for: selectedMeetingSceneID)
    }

    // MARK: - Reading a meeting
    //
    // Same calls as the Mac (`AppModel.swift:525-544`, `AppModel+Review.swift`).
    // Transcript and speaker review stay read-only here. Notes use the shared
    // editing session below, which owns their complete persistence path.

    func meeting(_ meetingID: MeetingID) async -> Meeting? {
        guard let runtime else { return nil }
        return try? await runtime.library.loadMeeting(meetingID)
    }

    func transcript(for meetingID: MeetingID) async -> TranscriptRevision? {
        guard let runtime else { return nil }
        return try? await runtime.library.loadCurrentRevision(meetingID: meetingID)
    }

    func reviewData(for meetingID: MeetingID) async -> MeetingReviewData? {
        guard let runtime else { return nil }
        return try? await MeetingReviewAssembler.load(
            library: runtime.library,
            meetingID: meetingID
        )
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

    func meetingDiarizationState(
        for meetingID: MeetingID
    ) async -> MeetingDiarizationJobState {
        guard let runtime else { return .unavailable }
        do {
            return try await MeetingDiarizationRequest.status(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID,
                modelsReady: diarizationModels.isReady(for: language.locale) == true
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func requestMeetingDiarization(
        for meetingID: MeetingID
    ) async -> MeetingDiarizationJobState {
        guard let runtime else { return .unavailable }
        do {
            return try await MeetingDiarizationRequest.request(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID,
                modelsReady: diarizationModels.isReady(for: language.locale) == true
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func adoptPendingMeetingDiarization(
        for meetingID: MeetingID,
        expectedCurrentRevisionID: RevisionID
    ) async -> MeetingDiarizationJobState {
        guard let runtime else { return .unavailable }
        do {
            return try await MeetingDiarizationRequest.adoptPendingResult(
                library: runtime.library,
                jobStore: runtime.jobStore,
                meetingID: meetingID,
                expectedCurrentRevisionID: expectedCurrentRevisionID,
                modelsReady: diarizationModels.isReady(for: language.locale) == true
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func notesSession(for meetingID: MeetingID) async -> MeetingNotesEditingSession? {
        guard let notesSessions else { return nil }
        return await notesSessions.session(for: meetingID)
    }

    /// Longest original track of the meeting. Microphone and system run in
    /// parallel, so the maximum rather than the sum.
    func duration(for meetingID: MeetingID) async -> TimeInterval? {
        guard let runtime else { return nil }
        let assets = (try? await runtime.library.listMediaAssets(
            meetingID: meetingID
        )) ?? []
        return assets.map(\.duration).max()
    }

    /// Where the library sits, for the diagnostics screen and for pointing the
    /// user at the Files app.
    var libraryPath: String {
        libraryURL.path(percentEncoded: false)
    }

    private static func startLivePipeline(
        at libraryURL: URL,
        locale: Locale,
        textModelProviderResolver: @escaping TextModelProviderResolver
    ) async throws -> PipelineRuntime {
        try await startPipeline(
            at: libraryURL,
            providers: [
                // iOS records one track. There is no system audio and
                // therefore no "the others" channel: every speaker in the
                // room lands on the microphone track, and telling them
                // apart is the diarisation's job, not the channel's.
                .micTrack: SpeechAnalyzerProvider(channel: .microphone),
                .imported: SpeechAnalyzerProvider(channel: .microphone),
            ],
            diarizationProvider: FluidSortformerProvider(
                modelCacheDirectory: try LibraryLocation.modelCacheURL()
            ),
            textModelProviderResolver: textModelProviderResolver,
            locale: locale
        )
    }

    private static func makeDiarizationModelState() -> IOSModelInstallationState {
        let consent = ModelConsent.diarization()
        do {
            let installer = DiarizationModelInstaller(
                modelCacheDirectory: try LibraryLocation.modelCacheURL(),
                manifest: try ModelChecksumManifest.bundled()
            )
            return IOSModelInstallationState(
                coordinator: ModelInstallationCoordinator(installers: [installer]),
                consent: consent
            )
        } catch {
            return IOSModelInstallationState(
                unavailableBundle: DiarizationModelInstaller.expectedBundleDescription,
                consent: consent,
                errorMessage: error.localizedDescription
            )
        }
    }
}
