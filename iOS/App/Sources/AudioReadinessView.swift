import Speech
import StenoDomain
import StenoiOSAudio
import SwiftUI

/// First screen of the iOS app: it proves the audio path works on a real
/// device before any recording exists.
///
/// This is a readiness and diagnostics screen, not the recording screen. It
/// stays useful afterwards, because interruptions and route changes are the
/// hardest part of iOS capture to observe, and milestone i1 needs them visible
/// rather than inferred from a log file.
struct AudioReadinessView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AudioReadinessModel

    init(session: AudioSessionController) {
        _model = State(wrappedValue: AudioReadinessModel(session: session))
    }

    /// Whether the device language and the transcription language disagree.
    /// An English phone in Germany reports `en_DE`, so this is the normal case
    /// here rather than an exotic one.
    private var divergesFromSystem: Bool {
        guard !app.language.available.isEmpty else { return false }
        return Locale.current.language.languageCode
            != app.language.locale.language.languageCode
    }

    private var systemLanguageName: String {
        Locale.current.localizedString(forIdentifier: Locale.current.identifier)
            ?? Locale.current.identifier
    }

    var body: some View {
        // No NavigationStack of its own: this view is the detail column of the
        // split view, which already provides one. Nesting a second stack gives
        // the iPad two navigation bars stacked inside one column.
        List {
            Section("Microphone") {
                LabeledContent("Permission", value: model.permissionText)
                switch MicrophonePermissionPresentation.action(for: model.permission) {
                case .request:
                    Button {
                        Task { await model.requestPermission() }
                    } label: {
                        Text(MicrophonePermissionPresentation.requestTitle)
                    }
                case .openSettings:
                    Text(MicrophonePermissionPresentation.deniedExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        openURL(MicrophonePermissionPresentation.settingsURL)
                    } label: {
                        Text(MicrophonePermissionPresentation.openSettingsTitle)
                    }
                    .accessibilityHint(
                        Text(MicrophonePermissionPresentation.openSettingsHint)
                    )
                    .accessibilityIdentifier("readiness-open-microphone-settings")
                case nil:
                    EmptyView()
                }
            }

            Section("Input") {
                LabeledContent("Route", value: model.inputName ?? "none")
                LabeledContent("Sample rate", value: model.sampleRateText)

                if app.recording.isActive {
                    // Metering here would open a second capture on the shared
                    // audio session, and stopping it would deactivate the
                    // session out from under the recording. The recording
                    // screen shows the same level anyway.
                    Text("A recording is running; its screen shows the level.")
                        .foregroundStyle(.secondary)
                } else {
                    LevelMeter(level: model.level, isActive: model.isMetering)
                        .padding(.vertical, 4)
                    Button(model.isMetering ? "Stop metering" : "Start metering") {
                        Task {
                            await model.toggleMetering(
                                recordingIsActive: app.recording.isActive
                            )
                        }
                    }
                    .disabled(model.permission != .authorized)
                }
            }

            // Whether on-device speech recognition exists here at all.
            // Shown rather than inferred: the same "unavailable" error
            // could mean unsupported hardware, a missing model, or an
            // unsupported language, and those need different answers.
            Section("Speech recognition") {
                LabeledContent(
                    "SpeechTranscriber",
                    value: model.speechAvailable == true ? "available" : "unavailable"
                )

                // Explicit language choice, not the system locale. An
                // English phone in Germany reports en_DE and would happily
                // transcribe German speech as English.
                if app.language.available.isEmpty {
                    LabeledContent(
                        "Transcription language",
                        value: "none offered here"
                    )
                } else {
                    Picker(
                        "Transcription language",
                        selection: Binding(
                            get: { app.language.locale.identifier },
                            // Ueber das Modell, nicht direkt: der Wechsel
                            // muss die Pipeline erneuern, sonst laeuft der
                            // finale Lauf weiter in der alten Sprache.
                            set: { identifier in
                                Task { await app.setLanguage(identifier) }
                            }
                        )
                    ) {
                        ForEach(app.language.available, id: \.identifier) { locale in
                            Text(app.language.displayName(locale))
                                .tag(locale.identifier)
                        }
                    }
                    .disabled(!app.canChangeLanguage)

                    if let title = AudioReadinessPresentation.confirmationTitle(
                        languageName: app.language.selectedDisplayName,
                        wasChosenExplicitly: app.language.wasChosenExplicitly,
                        canChangeLanguage: app.canChangeLanguage
                    ) {
                        Button(title) {
                            Task {
                                await app.setLanguage(app.language.locale.identifier)
                            }
                        }
                    }

                    if !app.canChangeLanguage {
                        Label(languageLockMessage, systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if !app.language.wasChosenExplicitly {
                        // Der Unterschied zwischen abgeleitet und gewaehlt ist
                        // der ganze Zweck dieses Bildschirms.
                        Label(
                            "Steno guessed this from your device. Pick the language people actually speak in the room, or a recording will be transcribed into the wrong language and still look plausible.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                ForEach(app.models.bundleDescriptions, id: \.title) { bundle in
                    LabeledContent("Speech model") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(bundle.title)
                            Text(
                                "\(bundle.source.displayHost), "
                                    + Self.sizeText(bundle.approximateBytes)
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("Model status") {
                    modelStatusText
                }

                if let presentation = app.models.installProgressPresentation {
                    IOSModelInstallationProgressView(
                        presentation: presentation,
                        isCancelling: app.models.isCancelling
                    ) {
                        Task {
                            await app.models.cancelInstall()
                            await model.refreshSpeechAvailability()
                        }
                    }
                } else if app.models.isReady(for: app.language.locale) == false {
                    Button("Allow and install") {
                        Task {
                            await app.allowAndInstallSpeechModel()
                            await model.refreshSpeechAvailability()
                        }
                    }
                    .disabled(
                        !app.canInstallSpeechModel
                            || !app.language.wasChosenExplicitly
                            || app.models.bundleDescriptions.isEmpty
                    )
                }

                if app.models.isReady(for: app.language.locale) != true,
                   app.recording.isActive {
                    Text("Stop the recording before installing a model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = app.models.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                if let record = app.models.consent.record {
                    LabeledContent("Allowed") {
                        Text(record.grantedAt, format: .dateTime)
                    }
                    LabeledContent("Sources", value: record.sources.joined(separator: ", "))
                    Text(
                        "Revoking stops future downloads. Models already installed keep working."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Revoke", role: .destructive) {
                        Task { await app.revokeSpeechModelConsent() }
                    }
                }

                // Spelled out rather than left as two labels side by side.
                // "System locale: en_DE" next to a language picker reads like
                // a second setting, and the whole point of this screen is that
                // the system locale is exactly what Steno does not follow.
                if divergesFromSystem {
                    Label(
                        "Your device is set to \(systemLanguageName). Steno transcribes in \(app.language.selectedDisplayName) regardless, because the device setting says nothing about the language people speak in the room.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                LabeledContent(
                    "Installed languages",
                    value: model.installedLocales.isEmpty
                        ? "none"
                        : model.installedLocales.joined(separator: ", ")
                )
                LabeledContent(
                    "Device language (not used)",
                    value: Locale.current.identifier
                )
            }

            Section("Speaker separation") {
                Text(DiarizationModelPresentation.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(app.diarizationModels.bundleDescriptions, id: \.title) { bundle in
                    LabeledContent("Model bundle") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(bundle.title)
                            Text(DiarizationModelPresentation.downloadDisclosure(bundle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("Model status") {
                    diarizationModelStatusText
                }

                if app.diarizationModels.isReady(for: app.language.locale) != true {
                    if let presentation = app.diarizationModels.installProgressPresentation {
                        IOSModelInstallationProgressView(
                            presentation: presentation,
                            isCancelling: app.diarizationModels.isCancelling
                        ) {
                            Task { await app.diarizationModels.cancelInstall() }
                        }
                    } else {
                        Button("Allow and install speaker separation") {
                            Task { await app.allowAndInstallDiarizationModels() }
                        }
                        .disabled(
                            !app.canInstallDiarizationModels
                                || app.diarizationModels.bundleDescriptions.isEmpty
                        )
                    }
                }

                if let lockMessage = DiarizationModelPresentation.installLockMessage(
                    recordingIsActive: app.recording.isActive
                ) {
                    Text(lockMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = app.diarizationModels.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                if let record = app.diarizationModels.consent.record {
                    LabeledContent("Allowed") {
                        Text(record.grantedAt, format: .dateTime)
                    }
                    LabeledContent("Sources", value: record.sources.joined(separator: ", "))
                    Text(
                        "Revoking stops future downloads. Models already installed keep separating speakers."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Revoke speaker separation download consent", role: .destructive) {
                        Task { await app.revokeDiarizationModelConsent() }
                    }
                }
            }

            Section("Session events") {
                if model.events.isEmpty {
                    Text("No interruptions or route changes yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.events) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                            Text(event.timestamp, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let failure = model.failure {
                Section("Last failure") {
                    Text(failure).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Audio readiness")
        .onChange(of: app.language.selectedID) {
            // The installed list changes when a model finishes downloading,
            // and a stale "none" here is the difference between "still
            // loading" and "something is broken".
            Task { await model.refreshSpeechAvailability() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.start(recordingIsActive: app.recording.isActive)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            model.refreshMicrophonePermission()
        }
        .onChange(of: app.recording.isActive) {
            Task {
                await model.recordingStateDidChange(
                    isActive: app.recording.isActive
                )
            }
        }
        .onDisappear {
            Task {
                await model.stopMetering()
            }
        }
    }

    private var languageLockMessage: String {
        if app.recording.isActive {
            return String(localized: "The language cannot change while a recording runs.")
        }
        if app.models.isInstalling {
            return String(localized: "The language cannot change while the model is installing.")
        }
        if app.diarizationModels.isInstalling {
            return String(localized: "The language cannot change while speaker separation installs.")
        }
        return String(localized: "The language cannot change while speech recognition restarts.")
    }

    private var modelStatusText: Text {
        if let presentation = app.models.installProgressPresentation {
            return installationStatusText(presentation)
        }
        switch app.models.isReady(for: app.language.locale) {
        case true:
            return Text("Ready for \(app.language.selectedDisplayName).")
        case false:
            return Text("Not installed for \(app.language.selectedDisplayName).")
        case nil:
            return Text("Checking…")
        }
    }

    private var diarizationModelStatusText: Text {
        if let presentation = app.diarizationModels.installProgressPresentation {
            return installationStatusText(presentation)
        }
        switch app.diarizationModels.isReady(for: app.language.locale) {
        case true:
            return Text("Ready. Future transcripts can be separated into speaker labels.")
        case false:
            return Text("Not installed. Recording and transcription still work.")
        case nil:
            return Text("Checking…")
        }
    }

    private static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func installationStatusText(
        _ presentation: IOSModelInstallProgressPresentation
    ) -> Text {
        switch presentation {
        case .indeterminate(let title):
            return Text(title)
        case .determinate(let title, let fraction):
            let titleText = Text(LocalizedStringKey(title))
            return Text(
                "Installing \(titleText), \(Int((fraction * 100).rounded())) %"
            )
        }
    }
}

enum AudioReadinessPresentation {
    static func confirmationTitle(
        languageName: String,
        wasChosenExplicitly: Bool,
        canChangeLanguage: Bool
    ) -> LocalizedStringResource? {
        guard canChangeLanguage, !wasChosenExplicitly else { return nil }
        return "Use \(languageName)"
    }
}

enum AudioReadinessLifecycle {
    enum StartAction: Equatable {
        case configureAndObserve
        case observeWithoutConfiguration
    }

    static func startAction(recordingIsActive: Bool) -> StartAction {
        recordingIsActive ? .observeWithoutConfiguration : .configureAndObserve
    }
}

enum DiarizationModelPresentation {
    static let explanation: LocalizedStringResource = "Separates voices into speaker labels on this device. It does not recognize people or assign names. Installation runs only while Steno is open."

    static func downloadDisclosure(
        _ description: ModelBundleDescription
    ) -> LocalizedStringResource {
        let exact = NumberFormatter()
        exact.locale = Locale(identifier: "en_US_POSIX")
        exact.numberStyle = .decimal
        exact.usesGroupingSeparator = true
        exact.groupingSize = 3
        exact.maximumFractionDigits = 0
        exact.groupingSeparator = ","
        let exactBytes = exact.string(from: NSNumber(value: description.approximateBytes))
            ?? String(description.approximateBytes)
        let megabytes = Double(description.approximateBytes) / 1_000_000
        let roundedMegabytes = String(
            format: "%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            megabytes
        )
        return "\(description.source.displayHost), \(exactBytes) bytes (about \(roundedMegabytes) MB)"
    }

    static func installLockMessage(
        recordingIsActive: Bool
    ) -> LocalizedStringResource? {
        guard recordingIsActive else { return nil }
        return "Stop the recording before installing speaker separation models. Recording and transcription work without them."
    }
}

@MainActor
@Observable
final class AudioReadinessModel {
    struct Event: Identifiable {
        let id = UUID()
        let title: String
        let timestamp: Date
    }

    private(set) var permission: RecordPermissionStatus
    private(set) var inputName: String?
    private(set) var sampleRate: Double = 0
    private(set) var isMetering = false
    private(set) var level: AudioLevel = .silence
    private(set) var events: [Event] = []
    private(set) var failure: String?

    private(set) var speechAvailable: Bool?
    private(set) var supportedLocaleCount = 0
    private(set) var installedLocales: [String] = []

    private let controller: AudioSessionController
    private let microphonePermissionStatus: @MainActor () -> RecordPermissionStatus
    private let microphonePermissionRequest: @MainActor () async -> RecordPermissionStatus
    private let capture = MicrophoneCapture()
    private var levelTask: Task<Void, Never>?
    private var meteringGeneration: UInt64 = 0
    private var meteringLease: AudioSessionController.MeteringLease?

    init(
        session: AudioSessionController,
        microphonePermissionStatus: @escaping @MainActor () -> RecordPermissionStatus = {
            RecordPermission.status()
        },
        microphonePermissionRequest: @escaping @MainActor () async -> RecordPermissionStatus = {
            await RecordPermission.request()
        }
    ) {
        controller = session
        self.microphonePermissionStatus = microphonePermissionStatus
        self.microphonePermissionRequest = microphonePermissionRequest
        permission = microphonePermissionStatus()
    }

    var permissionText: String {
        switch permission {
        case .notDetermined: "not asked yet"
        case .denied: "denied in Settings"
        case .authorized: "granted"
        }
    }

    var sampleRateText: String {
        sampleRate > 0 ? "\(Int(sampleRate)) Hz" : "unknown"
    }

    func start(recordingIsActive: Bool) async {
        refreshMicrophonePermission()
        if AudioReadinessLifecycle.startAction(
            recordingIsActive: recordingIsActive
        ) == .configureAndObserve {
            do {
                _ = try await controller.configureForReadiness()
            } catch {
                failure = error.localizedDescription
            }
        }
        await refreshRoute()
        await refreshSpeechAvailability()
        await observeEvents()
    }

    func refreshSpeechAvailability() async {
        speechAvailable = SpeechTranscriber.isAvailable
        supportedLocaleCount = await SpeechTranscriber.supportedLocales.count
        installedLocales = await SpeechTranscriber.installedLocales
            .map(\.identifier)
            .sorted()
    }

    func requestPermission() async {
        permission = await microphonePermissionRequest()
    }

    /// Reads only the current authorization. In particular this never
    /// configures the shared audio session when a recording is active.
    func refreshMicrophonePermission() {
        permission = microphonePermissionStatus()
    }

    func toggleMetering(recordingIsActive: Bool) async {
        guard !recordingIsActive else {
            await stopMetering()
            return
        }
        if isMetering {
            await stopMetering()
        } else {
            await startMetering()
        }
        await refreshRoute()
    }

    func recordingStateDidChange(isActive: Bool) async {
        if isActive {
            await stopMetering()
        }
    }

    private func startMetering() async {
        meteringGeneration &+= 1
        let generation = meteringGeneration
        do {
            guard let lease = try await controller.beginMetering(
                stopBeforeRecording: {
                    await self.recordingWillStart()
                }
            ) else { return }
            guard generation == meteringGeneration else {
                try? await controller.endMetering(lease)
                return
            }
            meteringLease = lease

            let (stream, continuation) = AsyncStream<AudioLevel>.makeStream(
                // Only the newest level matters; an old one is never worth
                // showing and buffering them would grow without bound.
                bufferingPolicy: .bufferingNewest(1)
            )
            try await capture.start { buffer in
                continuation.yield(AudioLevelCalculator.level(of: buffer))
            }
            guard generation == meteringGeneration else {
                await capture.stop()
                return
            }

            levelTask = Task { [weak self] in
                for await level in stream {
                    self?.level = level
                }
            }
            isMetering = true
            failure = nil
        } catch {
            guard generation == meteringGeneration else { return }
            failure = error.localizedDescription
            await stopMetering()
        }
    }

    func stopMetering() async {
        meteringGeneration &+= 1
        let lease = meteringLease
        meteringLease = nil
        guard lease != nil || isMetering else { return }
        levelTask?.cancel()
        levelTask = nil
        await capture.stop()
        if let lease {
            try? await controller.endMetering(lease)
        }
        isMetering = false
        level = .silence
    }

    private func recordingWillStart() async {
        await stopMetering()
    }

    private func refreshRoute() async {
        inputName = await controller.currentInputDescription
        sampleRate = await controller.currentSampleRate
    }

    private func observeEvents() async {
        let stream = await controller.events()
        for await event in stream {
            append(event)
            await refreshRoute()

            // A route change that invalidates the capture format must end the
            // run instead of quietly continuing on another microphone.
            if case .routeChanged(let reason) = event, reason.endsCurrentCapture,
               isMetering {
                await stopMetering()
            }
            if case .interruptionBegan = event, isMetering {
                await stopMetering()
            }
        }
    }

    private func append(_ event: AudioSessionEvent) {
        let title = switch event {
        case .interruptionBegan(let reason):
            "Interrupted (\(reason))"
        case .interruptionEnded(let shouldResume):
            shouldResume
                ? "Interruption ended, may resume"
                : "Interruption ended, must not resume"
        case .routeChanged(let reason):
            reason.endsCurrentCapture
                ? "Route changed (\(reason)) - ends a capture"
                : "Route changed (\(reason))"
        case .mediaServicesWereReset:
            "Media services were reset"
        }
        events.insert(Event(title: title, timestamp: Date()), at: 0)
    }
}
