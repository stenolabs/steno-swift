@preconcurrency import AVFAudio
import Foundation
import StenoDiarization
import StenoDomain
import StenoLibrary
import StenoTranscription

enum FakeTranscriptionError: Error {
    case failed
}

enum FakeDiarizationError: Error, LocalizedError {
    case failed

    var errorDescription: String? {
        "Fake diarization provider failed."
    }
}

actor FakeDiarizationProvider: DiarizationProvider {
    enum Behavior: Sendable {
        case succeed
        case fail
        case modelsMissing
        case block
    }

    nonisolated let descriptor = EngineDescriptor(
        name: "FakeDiarization",
        version: "1.0",
        modelVersion: "fixture"
    )

    private let behavior: Behavior
    private var requestedURLs: [URL] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func diarize(
        _ url: URL,
        hints: DiarizationHints
    ) async throws -> DiarizationOutput {
        requestedURLs.append(url)
        switch behavior {
        case .succeed:
            let sourceKind = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let isSystem = sourceKind == MediaAsset.Kind.systemTrack.rawValue
            return DiarizationOutput(
                segments: [
                    DiarizationSegment(
                        clusterID: "SPEAKER_0",
                        start: isSystem ? 1 : 0,
                        end: isSystem ? 2 : 1
                    ),
                ],
                embeddings: ["SPEAKER_0": isSystem ? [0, 1] : [1, 0]],
                engine: descriptor
            )
        case .fail:
            throw FakeDiarizationError.failed
        case .modelsMissing:
            throw DiarizationError.modelsNotInstalled(missing: ["Sortformer"])
        case .block:
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
    }

    func callCount() -> Int {
        requestedURLs.count
    }
}

actor FakeTranscriptionProvider: TranscriptionProvider {
    enum Behavior: Sendable {
        case succeed
        case fail
        case block
        case mutateInputAndFail
        case mutateInputAndSucceed
    }

    struct RequestedFileIdentity: Equatable, Sendable {
        let deviceID: UInt64
        let fileID: UInt64
        let linkCount: UInt64
    }

    nonisolated let descriptor = EngineDescriptor(
        name: "FakeASR",
        version: "1.0",
        modelVersion: "fixture"
    )

    private let behavior: Behavior
    private var requestedURLs: [URL] = []
    private var requestedLocaleIdentifiers: [String] = []
    private var requestedSourceData: [Data] = []
    private var requestedFileIdentities: [RequestedFileIdentity] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func liveSession(
        format: AudioFormat,
        locale: Locale
    ) async throws -> any LiveTranscriptionSession {
        throw FakeTranscriptionError.failed
    }

    func transcribeFile(
        _ url: URL,
        locale: Locale
    ) async throws -> TranscriptOutput {
        requestedURLs.append(url)
        requestedLocaleIdentifiers.append(locale.identifier)
        var status = stat()
        if lstat(url.path, &status) == 0 {
            requestedFileIdentities.append(RequestedFileIdentity(
                deviceID: UInt64(status.st_dev),
                fileID: UInt64(status.st_ino),
                linkCount: UInt64(status.st_nlink)
            ))
        }
        switch behavior {
        case .succeed:
            let sourceData = try Data(contentsOf: url)
            requestedSourceData.append(sourceData)
            let sourceKind = String(decoding: sourceData, as: UTF8.self)
            let channel: TranscriptionChannel = sourceKind == MediaAsset.Kind.systemTrack.rawValue
                ? .system
                : .microphone
            let text = channel == .microphone ? "Mikrofon" : "System"
            return TranscriptOutput(
                localeIdentifier: locale.identifier,
                blocks: [
                    TranscriptionBlock(
                        channel: channel,
                        text: text,
                        start: channel == .microphone ? 0 : 1,
                        end: channel == .microphone ? 1 : 2,
                        words: [
                            TranscriptionWord(
                                text: text,
                                start: channel == .microphone ? 0 : 1,
                                end: channel == .microphone ? 1 : 2
                            ),
                        ]
                    ),
                ]
            )
        case .fail:
            throw FakeTranscriptionError.failed
        case .block:
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        case .mutateInputAndFail:
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                throw FakeTranscriptionError.failed
            }
            let descriptor = Darwin.open(url.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
            guard descriptor >= 0 else { throw FakeTranscriptionError.failed }
            Darwin.close(descriptor)
            throw FakeTranscriptionError.failed
        case .mutateInputAndSucceed:
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                throw FakeTranscriptionError.failed
            }
            let descriptor = Darwin.open(url.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
            guard descriptor >= 0 else { throw FakeTranscriptionError.failed }
            Darwin.close(descriptor)
            return TranscriptOutput(
                localeIdentifier: locale.identifier,
                blocks: [
                    TranscriptionBlock(
                        channel: .microphone,
                        text: "Manipuliert",
                        start: 0,
                        end: 1,
                        words: []
                    ),
                ]
            )
        }
    }

    func callCount() -> Int {
        requestedURLs.count
    }

    func requestedLocales() -> [String] {
        requestedLocaleIdentifiers
    }

    func requestedFiles() -> [URL] {
        requestedURLs
    }

    func requestedSources() -> [Data] {
        requestedSourceData
    }

    func requestedIdentities() -> [RequestedFileIdentity] {
        requestedFileIdentities
    }
}

struct PipelineFixture {
    let root: URL
    let library: Library
    let jobStore: JobStore
    let meeting: Meeting
    let job: Job
}

func withTemporaryDirectory<Result>(
    _ body: (URL) async throws -> Result
) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoPipelineTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

func makePipelineFixture(
    at root: URL,
    jobLocaleIdentifier: String? = nil,
    durations: [MediaAsset.Kind: TimeInterval] = [
        .micTrack: 2,
        .systemTrack: 2,
    ]
) async throws -> PipelineFixture {
    let library = try Library.open(at: root)
    let meeting = try await library.createMeeting(title: "Pipeline", status: .ready)
    for kind in [MediaAsset.Kind.micTrack, .systemTrack] {
        let source = root.appendingPathComponent("\(kind.rawValue).caf")
        try Data(kind.rawValue.utf8).write(to: source)
        _ = try await library.registerMediaAsset(
            for: meeting.id,
            sourceURL: source,
            kind: kind,
            sampleRate: 48_000,
            duration: durations[kind] ?? 2
        )
    }
    let jobStore = try JobStore(layout: library.layout)
    let job = Job(
        kind: .finalASR,
        meetingID: meeting.id,
        localeIdentifier: jobLocaleIdentifier
    )
    try await jobStore.enqueue(job)
    return PipelineFixture(
        root: root,
        library: library,
        jobStore: jobStore,
        meeting: meeting,
        job: job
    )
}

func makeImportedPipelineFixture(
    at root: URL,
    jobLocaleIdentifier: String = "de-DE"
) async throws -> PipelineFixture {
    let library = try Library.open(at: root)
    let meetingID = MeetingID()
    let generationID = MeetingTransferGenerationID()
    let job = Job(
        kind: .finalASR,
        meetingID: meetingID,
        localeIdentifier: jobLocaleIdentifier,
        importGenerationID: generationID
    )
    let receipt = MeetingTransferReceipt(
        sourceMeetingID: meetingID,
        sourceRevisionID: nil,
        sourcePackageContentDigest: String(repeating: "b", count: 64),
        importedAt: Date(timeIntervalSinceReferenceDate: 1),
        sourceAppVersion: nil,
        includedCapabilities: [.audio],
        sourceLocaleIdentifier: jobLocaleIdentifier,
        sourceLocaleOrigin: .explicit,
        importGenerationID: generationID
    )
    let meeting = Meeting(
        id: meetingID,
        title: "Imported pipeline",
        status: .ready,
        metadata: MeetingMetadata(transferReceipt: receipt)
    )
    let source = root.appending(path: "imported-mic.caf")
    try Data(MediaAsset.Kind.micTrack.rawValue.utf8).write(to: source)
    let asset = MediaAsset(
        meetingID: meetingID,
        kind: .micTrack,
        sampleRate: 48_000,
        duration: 1,
        provenanceKey: "transfer:\(meetingID):track-1:\(String(repeating: "c", count: 64))",
        fileName: "imported.caf"
    )
    _ = try await library.commitPreparedMeeting(PreparedMeetingImport(
        meeting: meeting,
        media: [.init(asset: asset, sourceURL: source)],
        revision: nil,
        transferState: .jobEnqueued(
            jobID: job.id,
            localeIdentifier: jobLocaleIdentifier
        )
    ))
    let jobStore = try JobStore(layout: library.layout)
    try await jobStore.enqueue(job)
    return PipelineFixture(
        root: root,
        library: library,
        jobStore: jobStore,
        meeting: meeting,
        job: job
    )
}

func makePipelineTestCAF(
    at url: URL,
    sampleRate: Double = 8_000,
    channelCount: AVAudioChannelCount = 1,
    frameCount: AVAudioFrameCount = 80,
    sampleOffset: Int = 0
) throws {
    guard let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: channelCount
    ), let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ) else {
        throw FakeTranscriptionError.failed
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    buffer.frameLength = frameCount
    if let channels = buffer.floatChannelData {
        for channel in 0..<Int(channelCount) {
            for frame in 0..<Int(frameCount) {
                channels[channel][frame] = Float((frame + sampleOffset) % 8) / 16
            }
        }
    }
    try file.write(from: buffer)
}

func eventually(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw FakeTranscriptionError.failed
}

func revisionDocuments(
    library: Library,
    meetingID: MeetingID
) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: library.layout.revisionsDirectory(meetingID),
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
}

func temporaryRunDirectories(
    library: Library,
    meetingID: MeetingID
) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: library.layout.runsDirectory(meetingID),
        includingPropertiesForKeys: [.isDirectoryKey]
    ).filter { $0.lastPathComponent.hasPrefix(".") }
}

func pipelineSnapshotSessions(library: Library) throws -> [URL] {
    let root = library.layout.root.appending(
        path: ".pipeline-inputs",
        directoryHint: .isDirectory
    )
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )
}

func pipelineSnapshotOwnerTokens(library: Library) throws -> [URL] {
    let root = library.layout.root.appending(
        path: ".pipeline-inputs",
        directoryHint: .isDirectory
    )
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    ).filter {
        $0.lastPathComponent.hasPrefix(".owner-")
            && $0.lastPathComponent.hasSuffix(".json")
    }
}

func processingRuns(
    library: Library,
    meetingID: MeetingID
) throws -> [ProcessingRun] {
    try FileManager.default.contentsOfDirectory(
        at: library.layout.runsDirectory(meetingID),
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ).filter { UUID(uuidString: $0.lastPathComponent) != nil }
    .map { directory in
        try JSONDecoder().decode(
            ProcessingRun.self,
            from: Data(contentsOf: directory.appendingPathComponent("run.json"))
        )
    }
}

func overwriteJob(
    _ job: Job,
    status: Job.Status,
    layout: LibraryLayout,
    importGenerationID: MeetingTransferGenerationID? = nil
) throws {
    let replacement = Job(
        schemaVersion: job.schemaVersion,
        id: job.id,
        kind: job.kind,
        meetingID: job.meetingID,
        sourceRunID: job.sourceRunID,
        templateID: job.templateID,
        revisionID: job.revisionID,
        textModelEndpointID: job.textModelEndpointID,
        textModelEndpointSnapshot: job.textModelEndpointSnapshot,
        templateRenderInputFingerprint: job.templateRenderInputFingerprint,
        localeIdentifier: job.localeIdentifier,
        importGenerationID: importGenerationID,
        status: status,
        attemptCount: job.attemptCount,
        createdAt: job.createdAt,
        errorMessage: job.errorMessage,
        failureReason: job.failureReason
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try AtomicFile.write(
        encoder.encode(replacement),
        to: layout.job(job.id)
    )
}

func providers(
    using provider: any TranscriptionProvider
) -> [MediaAsset.Kind: any TranscriptionProvider] {
    [
        .micTrack: provider,
        .systemTrack: provider,
        .imported: provider,
    ]
}
