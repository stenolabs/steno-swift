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
    case orphanedMedia(meetingID: MeetingID, fileName: String)
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
    transcriptionProviderResolver: @escaping TranscriptionProviderResolver,
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
    locale: Locale,
    activeMeetingIDs: Set<MeetingID> = []
) async throws -> PipelineRuntime {
    let library = try Library.open(at: libraryURL)
    let jobStore = try JobStore(layout: library.layout)
    try PipelineMediaSnapshotSession.sweepOrphans(layout: library.layout)
    try await RecoverySweep.run(
        library: library,
        jobStore: jobStore,
        activeMeetingIDs: activeMeetingIDs
    )
    _ = try await jobStore.recoverAtLaunch()
    var startupWarnings = library.openingMediaRecoveryReport.issues.map {
        PipelineStartupWarning.orphanedMedia(
            meetingID: $0.meetingID,
            fileName: $0.fileName
        )
    }
    startupWarnings += try await ImportedMeetingProcessingReconciler(
        library: library,
        stateStore: MeetingTransferStateStore(layout: library.layout),
        jobStore: jobStore
    ).reconcileAtPipelineStartup()
    let coordinator = PipelineCoordinator(
        library: library,
        jobStore: jobStore,
        transcriptionProviderResolver: transcriptionProviderResolver,
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

/// Uebergangspfad fuer bestehende Apple-only Aufrufer. Ein gepinnter anderer
/// Provider wird bewusst abgelehnt und niemals still auf Apple umgebogen.
public func startPipeline(
    at libraryURL: URL,
    providers: [MediaAsset.Kind: any TranscriptionProvider],
    diarizationProvider: (any DiarizationProvider)? = nil,
    modelCacheDirectory: URL? = nil,
    identityEngine: SpeakerSuggestionEngine = SpeakerSuggestionEngine(),
    textModelProviderResolver: @escaping TextModelProviderResolver = { selection in
        if let endpointID = selection.endpointID {
            throw PipelineError.unknownTextModelEndpoint(endpointID)
        }
        return FoundationModelsProvider()
    },
    locale: Locale,
    activeMeetingIDs: Set<MeetingID> = []
) async throws -> PipelineRuntime {
    try await startPipeline(
        at: libraryURL,
        transcriptionProviderResolver: { providerID, assetKind in
            guard providerID == .apple else {
                throw TranscriptionRegistryError.unknownProvider(providerID)
            }
            guard let provider = providers[assetKind] else {
                throw PipelineError.missingProvider(assetKind)
            }
            return provider
        },
        diarizationProvider: diarizationProvider,
        modelCacheDirectory: modelCacheDirectory,
        identityEngine: identityEngine,
        textModelProviderResolver: textModelProviderResolver,
        locale: locale,
        activeMeetingIDs: activeMeetingIDs
    )
}
