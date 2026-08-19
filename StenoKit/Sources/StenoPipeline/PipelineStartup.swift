import Foundation
import StenoDiarization
import StenoDomain
import StenoIdentity
import StenoIntelligence
import StenoLibrary
import StenoTranscription

public enum ImportedMeetingProcessingStartupIssue: Equatable, Sendable {
    case invalidTransferState
    case jobIdentityConflict
}

public enum PipelineStartupWarning: Equatable, Sendable {
    case importedMeetingProcessing(
        meetingID: MeetingID,
        issue: ImportedMeetingProcessingStartupIssue
    )
}

public struct PipelineRuntime: Sendable {
    public let library: Library
    public let jobStore: JobStore
    public let coordinator: PipelineCoordinator
    public let startupWarnings: [PipelineStartupWarning]

    public init(
        library: Library,
        jobStore: JobStore,
        coordinator: PipelineCoordinator,
        startupWarnings: [PipelineStartupWarning] = []
    ) {
        self.library = library
        self.jobStore = jobStore
        self.coordinator = coordinator
        self.startupWarnings = startupWarnings
    }
}

public func startPipeline(
    at libraryURL: URL,
    providers: [MediaAsset.Kind: any TranscriptionProvider],
    diarizationProvider: (any DiarizationProvider)? = nil,
    // Muss dasselbe Verzeichnis sein, das der Installer beschreibt. Sonst
    // laedt die App an eine Stelle und der Provider sucht an einer anderen:
    // ein Erstlauftest wuerde gruen aussehen und die Verarbeitung trotzdem
    // an fehlenden Modellen scheitern.
    modelCacheDirectory: URL? = nil,
    identityEngine: SpeakerSuggestionEngine = SpeakerSuggestionEngine(),
    textModelProviderResolver: @escaping TextModelProviderResolver = { selection in
        if let endpointID = selection.endpointID {
            throw PipelineError.unknownTextModelEndpoint(endpointID)
        }
        return FoundationModelsProvider()
    },
    locale: Locale
) async throws -> PipelineRuntime {
    let library = try Library.open(at: libraryURL)
    let jobStore = try JobStore(layout: library.layout)
    try PipelineMediaSnapshotSession.sweepOrphans(layout: library.layout)
    try await RecoverySweep.run(library: library, jobStore: jobStore)
    _ = try await jobStore.recoverAtLaunch()
    let startupWarnings = try await ImportedMeetingProcessingReconciler(
        library: library,
        stateStore: MeetingTransferStateStore(layout: library.layout),
        jobStore: jobStore
    ).reconcileAtPipelineStartup()
    let coordinator = PipelineCoordinator(
        library: library,
        jobStore: jobStore,
        providers: providers,
        diarizationProvider: diarizationProvider
            ?? FluidSortformerProvider(modelCacheDirectory: modelCacheDirectory),
        identityEngine: identityEngine,
        textModelProviderResolver: textModelProviderResolver,
        locale: locale
    )
    await coordinator.start()
    return PipelineRuntime(
        library: library,
        jobStore: jobStore,
        coordinator: coordinator,
        startupWarnings: startupWarnings
    )
}
