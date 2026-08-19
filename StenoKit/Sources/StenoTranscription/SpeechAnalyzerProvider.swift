@preconcurrency import AVFAudio
import Foundation
import Speech
import StenoDomain

public struct SpeechAnalyzerProvider: TranscriptionProvider {
    public let channel: TranscriptionChannel

    /// Kein Fortschrittsrueckruf mehr: der Provider installiert nichts. Wer
    /// den Fortschritt einer Assetinstallation sehen will, bekommt ihn von
    /// `SpeechAssetInstaller`, der als einziger installiert.
    public init(channel: TranscriptionChannel) {
        self.channel = channel
    }

    public var descriptor: EngineDescriptor {
        let version = Bundle(identifier: "com.apple.Speech")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return EngineDescriptor(
            name: "SpeechAnalyzer",
            version: version ?? "system",
            modelVersion: nil
        )
    }

    public func liveSession(
        format: AudioFormat,
        locale: Locale
    ) async throws -> any LiveTranscriptionSession {
        let prepared = try await prepareTranscriber(requestedLocale: locale)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [prepared.transcriber],
            considering: format.avAudioFormat
        ) else {
            throw TranscriptionError.noCompatibleAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [prepared.transcriber])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        let session = SpeechLiveTranscriptionSession(
            analyzer: analyzer,
            analyzerFormat: analyzerFormat,
            locale: prepared.locale
        )
        await session.startResultConsumption(
            transcriber: prepared.transcriber,
            channel: channel
        )
        return session
    }

    public func transcribeFile(
        _ url: URL,
        locale: Locale
    ) async throws -> TranscriptOutput {
        let prepared = try await prepareTranscriber(requestedLocale: locale)
        // Mehrkanaldateien vor der Analyse auf Mono mischen: real beobachtet
        // (Stereo-Import mit stillem linkem Kanal) lieferte die Analyse sonst
        // ein leeres Transkript, weil nicht der Mixdown, sondern ein einzelner
        // Kanal ausgewertet wurde.
        let sourceFile = try AVAudioFile(forReading: url)
        var temporaryMonoURL: URL?
        defer {
            if let temporaryMonoURL {
                try? FileManager.default.removeItem(at: temporaryMonoURL)
            }
        }
        let audioFile: AVAudioFile
        if sourceFile.processingFormat.channelCount > 1 {
            let monoURL = try Self.downmixToMono(sourceFile)
            temporaryMonoURL = monoURL
            audioFile = try AVAudioFile(forReading: monoURL)
        } else {
            audioFile = sourceFile
        }
        let analyzer = SpeechAnalyzer(modules: [prepared.transcriber])
        var accumulator = TranscriptionAccumulator(
            localeIdentifier: prepared.locale.identifier
        )
        let resultTask = Task { () throws -> TranscriptOutput in
            for try await result in prepared.transcriber.results {
                let block = SpeechResultConverter.block(
                    text: result.text,
                    range: result.range,
                    channel: channel
                )
                _ = accumulator.record(block, isFinal: result.isFinal)
            }
            return accumulator.output
        }

        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await resultTask.value
        } catch {
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            throw error
        }
    }

    /// Mischt eine Mehrkanaldatei per AVAudioConverter (echter Mixdown, kein
    /// Kanal-Verwerfen) in eine temporäre Mono-CAF gleicher Sample-Rate.
    static func downmixToMono(_ source: AVAudioFile) throws -> URL {
        let sourceFormat = source.processingFormat
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: monoFormat) else {
            throw TranscriptionError.audioConversionFailed(
                "cannot build a mono downmix converter"
            )
        }
        converter.downmix = true

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-downmix-\(UUID().uuidString).caf")
        let destination = try AVAudioFile(
            forWriting: destinationURL,
            settings: monoFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let chunkFrames: AVAudioFrameCount = 65_536
        while source.framePosition < source.length {
            guard let input = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: chunkFrames
            ), let output = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: chunkFrames
            ) else {
                throw TranscriptionError.audioConversionFailed(
                    "cannot allocate downmix buffers"
                )
            }
            try source.read(into: input)
            guard input.frameLength > 0 else { break }
            // Der Input-Block läuft synchron innerhalb von convert(); die Box
            // hält nur die Sendable-Prüfung ehrlich.
            final class FeedState: @unchecked Sendable { var fed = false }
            let state = FeedState()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if state.fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                state.fed = true
                outStatus.pointee = .haveData
                return input
            }
            guard conversionError == nil, status != .error else {
                throw TranscriptionError.audioConversionFailed(
                    "downmix failed: \(conversionError?.localizedDescription ?? "unknown")"
                )
            }
            if output.frameLength > 0 {
                try destination.write(from: output)
            }
        }
        return destinationURL
    }

    private func prepareTranscriber(
        requestedLocale: Locale
    ) async throws -> (transcriber: SpeechTranscriber, locale: Locale) {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.speechTranscriberUnavailable
        }
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = LocaleResolver.select(
            requested: requestedLocale,
            supported: supported
        ) else {
            throw TranscriptionError.noSupportedLocale
        }
        let transcriber = Self.transcriber(for: locale)
        // Kein ungefragtes `ensureAssets` mehr: das war der Ort, an dem jede
        // Live-Session und jeder Finallauf Sprachassets installierte, ohne
        // dass eine verweigerte Zustimmung etwas bewirkt haette. Fehlende
        // Assets sind jetzt Sache von `SpeechAssetInstaller`, den ein
        // Aufrufer vorher explizit anstossen muss.
        guard await Self.assetsAreInstalled(for: transcriber, locale: locale) else {
            // Andere Lage als `assetInstallationUnavailable`: es wurde nichts
            // versucht und ist nichts gescheitert, es fehlt schlicht die
            // Installation. Der Text landet ueber `reportLiveError` im
            // Statusband und wird gelesen, er darf also keinen
            // Installationsfehlschlag behaupten, den es nicht gab.
            throw TranscriptionError.assetsNotInstalled(
                localeIdentifier: locale.identifier
            )
        }
        return (transcriber, locale)
    }

    /// Genau der Transcriber, mit dem auch transkribiert wird. Die Optionen
    /// bestimmen mit, welche Assets das System verlangt: wer den Zustand mit
    /// anderen Optionen abfragt, fragt nach anderen Assets.
    static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Zwei unabhaengige Belege statt einem, aus demselben Grund wie vorher
    /// in `ensureAssets`: `AssetInventory.status` meldet auch fuer bereits
    /// installierte Sprachen `.supported` statt `.installed` (gemessen an
    /// de_DE). Ohne den zweiten Beleg wuerde dieser Wurf faelschlich
    /// "fehlend" melden und laufende Live-Transkription fuer eine bereits
    /// installierte Sprache blockieren.
    static func assetsAreInstalled(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async -> Bool {
        if await AssetInventory.status(forModules: [transcriber]) == .installed {
            return true
        }
        return await SpeechTranscriber.installedLocales.contains {
            normalizedLocaleKey($0) == normalizedLocaleKey(locale)
        }
    }

    static func installAssets(
        modules: [any SpeechModule],
        locale: Locale,
        progress: @escaping AssetProgressHandler
    ) async throws {
        let localeIdentifier = locale.identifier
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .unsupported:
            throw TranscriptionError.assetsUnsupported(
                localeIdentifier: localeIdentifier
            )
        case .supported, .downloading:
            break
        @unknown default:
            throw TranscriptionError.assetInstallationUnavailable(
                localeIdentifier: localeIdentifier
            )
        }

        try await ensureReservedLocale(locale)

        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: modules
        ) else {
            try await waitForExistingInstallation(
                modules: modules,
                localeIdentifier: localeIdentifier,
                progress: progress
            )
            return
        }

        try await install(request, localeIdentifier: localeIdentifier, progress: progress)
        if await AssetInventory.status(forModules: modules) != .installed {
            // Nicht sofort werfen: eine parallel angelaufene Installation
            // kann den Status noch auf .downloading halten.
            try await waitForExistingInstallation(
                modules: modules,
                localeIdentifier: localeIdentifier,
                progress: progress
            )
        }
    }

    /// Sprachassets erfordern eine Locale-Reservierung mit hartem Limit
    /// (`AssetInventory.maximumReservedLocales`). Alt-Reservierungen aus
    /// früheren Läufen (z. B. Benchmark-Locales) können das Limit füllen;
    /// dann werden nicht angefragte Reservierungen freigegeben. Die App
    /// nutzt eine Sprache zur Zeit, das Freigeben fremder Einträge ist
    /// deshalb sicher.
    private static func ensureReservedLocale(_ locale: Locale) async throws {
        let target = normalizedLocaleKey(locale)
        if await AssetInventory.reservedLocales.contains(where: {
            normalizedLocaleKey($0) == target
        }) {
            return
        }
        if try await AssetInventory.reserve(locale: locale) { return }
        for reserved in await AssetInventory.reservedLocales
        where normalizedLocaleKey(reserved) != target {
            _ = await AssetInventory.release(reservedLocale: reserved)
            if try await AssetInventory.reserve(locale: locale) { return }
        }
        throw TranscriptionError.assetInstallationUnavailable(
            localeIdentifier: locale.identifier
        )
    }

    static func normalizedLocaleKey(_ locale: Locale) -> String {
        locale.identifier
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    private static func install(
        _ request: AssetInstallationRequest,
        localeIdentifier: String,
        progress: @escaping AssetProgressHandler
    ) async throws {
        let progressHandler = progress
        let observation = request.progress.observe(
            \.fractionCompleted,
            options: [.initial, .new]
        ) { progress, _ in
            progressHandler(.downloading(
                localeIdentifier: localeIdentifier,
                fractionCompleted: min(1, max(0, progress.fractionCompleted))
            ))
        }
        defer { observation.invalidate() }
        // Der Abbruch muss bis zu Apples Anfrage durchschlagen. Ein blosses
        // Abbrechen des Tasks reicht nicht sicher: `downloadAndInstall()`
        // sagt nirgends zu, dass es kooperativ abbricht. Ihr `Progress` ist
        // der dokumentierte Griff, den Apple selbst anbietet.
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
        } onCancel: {
            request.progress.cancel()
        }
        // Ein abgebrochener Transfer soll nicht als Erfolg zurueckkehren,
        // falls Apple ihn ohne Fehler beendet.
        try Task.checkCancellation()
    }

    private static func waitForExistingInstallation(
        modules: [any SpeechModule],
        localeIdentifier: String,
        progress assetProgressHandler: @escaping AssetProgressHandler
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1_800))
        while clock.now < deadline {
            try Task.checkCancellation()
            switch await AssetInventory.status(forModules: modules) {
            case .installed:
                return
            case .downloading:
                assetProgressHandler(.downloading(
                    localeIdentifier: localeIdentifier,
                    fractionCompleted: 0
                ))
            case .supported:
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: modules
                ) {
                    try await install(
                        request,
                        localeIdentifier: localeIdentifier,
                        progress: assetProgressHandler
                    )
                }
            case .unsupported:
                throw TranscriptionError.assetsUnsupported(
                    localeIdentifier: localeIdentifier
                )
            @unknown default:
                throw TranscriptionError.assetInstallationUnavailable(
                    localeIdentifier: localeIdentifier
                )
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw TranscriptionError.assetInstallationUnavailable(
            localeIdentifier: localeIdentifier
        )
    }
}

/// Serialisiert Asset-Installationen prozessweit je Locale. Zwei gleichzeitig
/// startende Transkriptionssitzungen (Mikro- und Systemspur) teilen sich so
/// eine Installation, statt sich gegenseitig in einen Fehlerpfad zu treiben.
actor AssetInstallationSerializer {
    static let shared = AssetInstallationSerializer()

    private var inFlight: [String: Task<Void, any Error>] = [:]

    func run(
        key: String,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        if let existing = inFlight[key] {
            try await Self.awaitCancellable(existing)
            return
        }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        try await Self.awaitCancellable(task)
    }

    /// Ein unstrukturierter `Task` erbt die Abbruchmarkierung nicht, und
    /// `task.value` ist kein Abbruchpunkt: ohne diese Weitergabe endete beim
    /// Widerruf nur das Warten, waehrend der Download weiterlief.
    ///
    /// Dass damit auch ein Wartender die geteilte Installation abbricht, ist
    /// hier die gewollte Bedeutung: abgebrochen wird nur beim Widerruf, und
    /// der heisst "nichts mehr laden", nicht "nur fuer mich nichts mehr".
    private static func awaitCancellable(_ task: Task<Void, any Error>) async throws {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
